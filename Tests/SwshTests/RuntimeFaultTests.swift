#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
import Testing
@testable import Swsh

private final class RuntimeFaultBundle: NSObject {}

/// The swsh executable built beside the test product. On Linux that product is
/// itself an executable in the build directory, not a bundle inside it.
func probeShellURL() -> URL {
  #if canImport(Darwin)
  let directory = Bundle(for: RuntimeFaultBundle.self).bundleURL
    .deletingLastPathComponent()
  #else
  let directory = URL(fileURLWithPath: CommandLine.arguments[0])
    .resolvingSymlinksInPath().deletingLastPathComponent()
  #endif
  return directory.appendingPathComponent("swsh")
}

struct RuntimeFaultTests {
  @Test(arguments: [
    "later-spawn", "shutdown-before-release", "restore-before-resume",
    "missed-cleanup-deadline", "batch-retention", "redirect-retention",
    "cancel-before-cleanup", "cancel-during-cleanup", "cancel-observer",
    "cancel-cleanup-restore-failure", "nonblocking-editor-input",
    "owned-resource-collection", "coalesced-status", "low-fd-pipe",
    "low-fd-payload", "low-fd-handoff",
  ])
  func isolatedRuntimeFault(_ fault: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    let fixture = try #require(
      Bundle.module.url(
        forResource: "runtime-fault",
        withExtension: "py",
        subdirectory: "Fixtures"
      )
    )
    let bundle = Bundle(for: RuntimeFaultBundle.self)
    process.arguments = [
      fixture.path, try #require(bundle.executablePath), fault,
    ]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(
      process.terminationStatus == 0,
      "\(String(decoding: data, as: UTF8.self))"
    )
    #expect(
      String(decoding: data, as: UTF8.self)
        .contains("runtime fault verified: \(fault)")
    )
  }

  #if !canImport(Darwin)
  /// On Linux the test product is an executable and cannot be loaded as a
  /// library, so the helper runs this one test in a fresh PTY process instead.
  /// Without the variable it does nothing.
  @Test
  func isolatedRuntimeFaultChild() {
    guard let fault = ProcessInfo.processInfo.environment["SWSH_RUNTIME_FAULT"]
    else { return }
    #expect(swshRuntimeFaultProbe(fault) == 0)
  }
  #endif
}

/// Called only in a fresh PTY helper process. Never mutates the test runner's
/// signal dispositions, controlling terminal, cwd, or child-status ownership.
@_cdecl("swsh_runtime_fault_probe")
public func swshRuntimeFaultProbe(_ argument: UnsafePointer<CChar>) -> Int32 {
  let fault = String(cString: argument)
  do {
    try runRuntimeFault(fault)
    print("runtime fault verified: \(fault)")
    return 0
  } catch {
    print("runtime fault failed: \(error)")
    return 1
  }
}

private func runRuntimeFault(_ fault: String) throws {
  if fault.hasPrefix("low-fd-") {
    try verifyDescriptorExhaustion(fault)
    return
  }
  if fault.hasPrefix("cancel-") {
    try runAsyncSessionProbe(fault);
    return
  }
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString
  )
  try FileManager.default.createDirectory(
    at: root,
    withIntermediateDirectories: false
  )
  defer { try? FileManager.default.removeItem(at: root) }
  let marker = root.appendingPathComponent("executed")
  var failModes = false
  var modeInstalls = 0
  let terminal = try TerminalControl(beforeInstall: {
    if failModes {
      modeInstalls += 1
      if modeInstalls == 2 {
        throw SystemFailure("injected terminal modes", code: EIO)
      }
    }
  })
  var children: [pid_t] = []
  var clockCalls = 0
  let clockStart = ContinuousClock.now
  let executable = Array(probeShellURL().path.utf8)
  let supervisor = try JobSupervisor(
    executable: executable,
    build: fault == "redirect-retention"
      ? try LauncherPayload.buildIdentity(executable: executable) : "probe",
    terminal: fault == "batch-retention" ? nil : terminal,
    launchCheckpoint: { point in
      switch point {
      case .beforeSpawn(let index):
        if fault == "later-spawn" && index == 1 {
          throw SystemFailure("posix_spawn", code: EAGAIN)
        }
      case .registered(_, let pid): children.append(pid)
      case .beforeRelease:
        if fault == "shutdown-before-release" {
          _ = kill(getpid(), SIGTERM)
          #if !canImport(Darwin)
          // Without kqueue the signal reaches the supervisor through a handler
          // on another thread, shortly after `kill` returns.
          usleep(100_000)
          #endif
        }
      }
    },
    cleanupNow: {
      if fault != "missed-cleanup-deadline" { return .now }
      clockCalls += 1
      return clockStart.advanced(by: clockCalls == 1 ? .zero : .seconds(5))
    }
  )
  defer {
    failModes = false
    if !supervisor.shutdown(), supervisor.hasLiveJobs,
      let leader = children.first
    {
      _ = kill(-leader, SIGKILL)
      let deadline = ContinuousClock.now.advanced(by: .seconds(1))
      while supervisor.hasLiveJobs && ContinuousClock.now < deadline {
        _ = try? supervisor.poll(milliseconds: 10)
      }
    }
    try? terminal.restoreForExit()
  }
  func command(_ source: String) -> PreparedCommand {
    PreparedCommand(
      assignments: [:],
      arguments: ["/bin/sh", "-c", source, "probe", marker.path]
        .map { Array($0.utf8) },
      redirects: []
    )
  }
  if fault == "coalesced-status" {
    let id = try supervisor.launch(
      (0 ..< 20).map { command($0 == 19 ? "exit 7" : "exit 0") },
      state: ShellState(),
      background: true
    )
    // Deliberately stop servicing notifications while multiple stages exit.
    // One wakeup must drain every owned child, regardless of event coalescing.
    usleep(200_000)
    guard try supervisor.wait(for: id) == .completed(.exited(7)),
      !supervisor.hasLiveJobs, children.count == 20
    else { throw ProbeFailure("coalesced exits lost a stage or its result") }
    for pid in children {
      var status: Int32 = 0
      guard waitpid(pid, &status, WNOHANG) == -1, errno == ECHILD else {
        throw ProbeFailure("coalesced child was not reaped")
      }
    }
    return
  }
  if fault == "owned-resource-collection" {
    // In its own process: concurrent test-runner spawns can otherwise inherit
    // a pipe between pipe() and CLOEXEC setup and delay its EOF observation.
    let pipe = try OwnedFD.pipe()
    try pipe.withEnds { (input: consuming OwnedFD, output: consuming OwnedFD) in
      do {
        var descriptors = UniqueArray<OwnedFD>()
        for _ in 0 ..< 20 {
          descriptors.append(
            try output.withDescriptor { try OwnedFD.duplicate($0) }
          )
        }
        descriptors.append(consume output)
      }
      try input.withDescriptor { fd in
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
          throw SystemFailure("nonblocking ownership probe")
        }
        var byte: UInt8 = 0
        guard systemRead(fd, &byte, 1) == 0 else {
          throw ProbeFailure("resource collection retained a writer")
        }
      }
    }
    return
  }
  if fault == "nonblocking-editor-input" {
    try terminal.edit()
    guard fcntl(terminal.inputDescriptor, F_GETFL) & O_NONBLOCK != 0,
      fcntl(terminal.descriptor, F_GETFL) & O_NONBLOCK == 0,
      fcntl(STDIN_FILENO, F_GETFL) & O_NONBLOCK == 0
    else { throw ProbeFailure("editor changed command or presentation flags") }
    guard tcflush(terminal.inputDescriptor, TCIFLUSH) == 0 else {
      throw SystemFailure("flush editor input")
    }
    var byte: UInt8 = 0
    guard systemRead(terminal.inputDescriptor, &byte, 1) == -1, errno == EAGAIN
    else {
      throw ProbeFailure("empty editor read must return without blocking")
    }
    return
  }
  if fault == "batch-retention" || fault == "redirect-retention" {
    let driver = try SessionDriver(supervisor: supervisor)
    let baseline = try FileManager.default
      .contentsOfDirectory(atPath: "/dev/fd").count
    let source =
      fault == "batch-retention"
      ? "/usr/bin/true & /bin/sleep 0.01; /swsh-missing-probe | /usr/bin/true; :"
      : "pwd >'\(marker.path)'; cd /swsh-missing-directory 2>'\(marker.path)'; x=yes >'\(marker.path)'; : <'\(marker.path)'"
    guard case .complete(let program) = Parser().parse(source) else {
      throw ProbeFailure("invalid retention probe source")
    }
    for _ in 0 ..< (fault == "batch-retention" ? 50 : 20) {
      _ = try driver.submit(program)
      guard supervisor.listing().isEmpty else {
        throw ProbeFailure("completed batch jobs accumulated")
      }
      let descriptors = try FileManager.default
        .contentsOfDirectory(atPath: "/dev/fd").count
      guard descriptors == baseline else {
        throw ProbeFailure("launch leaked descriptors")
      }
    }
    for pid in children {
      var status: Int32 = 0
      guard waitpid(pid, &status, WNOHANG) == -1, errno == ECHILD else {
        throw ProbeFailure("retired job retained a child")
      }
    }
    return
  }
  if fault == "missed-cleanup-deadline" {
    let id = try supervisor.launch(
      [command("trap '' HUP TERM; echo ready > \"$1\"; while :; do :; done")],
      state: ShellState()
    )
    let readyDeadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !FileManager.default.fileExists(atPath: marker.path),
      ContinuousClock.now < readyDeadline
    { usleep(1_000) }
    guard FileManager.default.fileExists(atPath: marker.path) else {
      throw ProbeFailure("child failed to become ready")
    }
    guard !supervisor.shutdown(), supervisor.hasLiveJobs else {
      throw ProbeFailure("missed deadline claimed successful cleanup")
    }
    let calls = clockCalls
    guard !supervisor.shutdown(), clockCalls == calls else {
      throw ProbeFailure("failed shutdown restarted its deadline")
    }
    // The test harness supplies the external termination a stuck process would
    // require. The supervisor remains the only reaper, and failure stays sticky.
    guard kill(-children[0], SIGKILL) == 0 else {
      throw SystemFailure("terminate probe job")
    }
    _ = try supervisor.wait(for: id)
    guard !supervisor.shutdown(), !supervisor.hasLiveJobs else {
      throw ProbeFailure("late termination erased cleanup failure")
    }
    var status: Int32 = 0
    guard waitpid(children[0], &status, WNOHANG) == -1, errno == ECHILD else {
      throw ProbeFailure("late child was not reaped")
    }
    return
  }
  if fault == "restore-before-resume" {
    let id = try supervisor.launch(
      [command("kill -STOP $$; echo resumed > \"$1\"")],
      state: ShellState()
    )
    guard try supervisor.wait(for: id) == .stopped else {
      throw ProbeFailure("job did not stop")
    }
    failModes = true
    do {
      try supervisor.resume(id, foreground: true)
      throw ProbeFailure("resume ignored terminal failure")
    } catch is SystemFailure {}
    usleep(30_000)
    try supervisor.poll(milliseconds: 0)
    guard !terminal.healthy, modeInstalls == 2,
      tcgetpgrp(terminal.descriptor) == children[0],
      supervisor.listing().first?.1 == .stopped
    else {
      throw ProbeFailure(
        "failed restoration resumed job or left terminal healthy"
      )
    }
  } else {
    let count = fault == "later-spawn" ? 2 : 1
    do {
      _ = try supervisor.launch(
        Array(repeating: command("echo executed > \"$1\""), count: count),
        state: ShellState()
      )
      throw ProbeFailure("launch unexpectedly succeeded")
    } catch let error as SystemFailure {
      let expected: Int32 = fault == "later-spawn" ? EAGAIN : EINTR
      guard error.code == expected else { throw error }
    }
    guard !supervisor.hasLiveJobs, supervisor.listing().isEmpty else {
      throw ProbeFailure("aborted launch retained children")
    }
  }
  guard children.count == 1 else {
    throw ProbeFailure("wrong number of registered children")
  }
  guard !FileManager.default.fileExists(atPath: marker.path) else {
    throw ProbeFailure("suspended child executed user code")
  }
  guard supervisor.shutdown() else { throw ProbeFailure("cleanup failed") }
  for pid in children {
    var status: Int32 = 0
    guard waitpid(pid, &status, WNOHANG) == -1, errno == ECHILD else {
      throw ProbeFailure("child not reaped by supervisor")
    }
  }
  guard supervisor.shutdown() else {
    throw ProbeFailure("shutdown is not idempotent")
  }
}

private struct ProbeFailure: Error {
  let message: String
  init(_ message: String) { self.message = message }
}

#if canImport(Darwin)
private let descriptorLimit = RLIMIT_NOFILE
#else
private let descriptorLimit = Int32(RLIMIT_NOFILE.rawValue)
#endif

private func verifyDescriptorExhaustion(_ fault: String) throws {
  var original = rlimit()
  guard getrlimit(descriptorLimit, &original) == 0 else {
    throw SystemFailure("getrlimit")
  }
  var limited = rlimit(rlim_cur: 64, rlim_max: original.rlim_max)
  guard setrlimit(descriptorLimit, &limited) == 0 else {
    throw SystemFailure("setrlimit")
  }
  defer { _ = setrlimit(descriptorLimit, &original) }
  var owners = UniqueArray<OwnedFD?>()
  while true {
    do {
      owners.append(
        .some(try OwnedFD.open(Array("/dev/null".utf8), flags: O_RDONLY))
      )
    } catch let error as SystemFailure where error.code == EMFILE { break }
  }
  let freeSlots =
    fault == "low-fd-handoff" ? 2 : (fault == "low-fd-pipe" ? 1 : 0)
  for index in 0 ..< freeSlots { owners[owners.count - 1 - index] = nil }
  let before = (0 ..< 64).filter { fcntl(Int32($0), F_GETFD) >= 0 }
  do {
    switch fault {
    case "low-fd-pipe": _ = try OwnedFD.pipe()
    case "low-fd-payload":
      _ = try LauncherPayload(
        build: "limit",
        executable: [47],
        arguments: [[47]],
        environment: [],
        redirects: []
      )
      .write()
    default: _ = try OwnedFD.descriptorChannel()
    }
    throw SystemFailure("descriptor exhaustion did not fail", code: EINVAL)
  } catch let error as SystemFailure where error.code == EMFILE {}
  let after = (0 ..< 64).filter { fcntl(Int32($0), F_GETFD) >= 0 }
  guard before == after else {
    throw ProbeFailure("failed allocation leaked descriptors")
  }
}
