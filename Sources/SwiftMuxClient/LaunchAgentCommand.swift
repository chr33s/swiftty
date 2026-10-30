import Darwin
import Dispatch
import Foundation
import Synchronization

/// The CLI's launchctl invocation, with a finite wait and exclusive child
/// ownership. A timeout is an error, never an absent-service exit status.
public enum LaunchAgentCommand {
  public enum Failure: Error, Equatable, CustomStringConvertible {
    case timedOut
    case invalidArgument
    case systemCall(String, Int32)
    case signaled(Int32)

    public var description: String {
      switch self {
      case .timedOut: "launchctl exceeded its ten-second deadline"
      case .invalidArgument: "invalid command argument"
      case let .systemCall(operation, code):
        "\(operation): \(String(cString: strerror(code)))"
      case let .signaled(signal): "command terminated by signal \(signal)"
      }
    }
  }

  public static func run(_ arguments: [String]) throws -> Int32 {
    try runExecutable(
      "/bin/launchctl",
      arguments: arguments,
      timeout: .seconds(10),
    )
  }

  /// Internal executable injection lets tests exercise real process behavior
  /// without touching an installed LaunchAgent or service registration.
  static func runExecutable(
    _ executable: String,
    arguments: [String],
    timeout: DispatchTimeInterval,
  ) throws -> Int32 {
    guard !executable.isEmpty,
      !([executable] + arguments).contains(where: { $0.utf8.contains(0) })
    else { throw Failure.invalidArgument }
    let pid = try spawn(executable, arguments: arguments)
    let wait = LaunchAgentCommandWait(pid: pid, deadline: .now() + timeout)
    wait.start()
    if wait.completion.wait(timeout: wait.deadline) == .timedOut {
      // The child must be signaled before the CLI returns and exits. A
      // queued asynchronous kill could be abandoned when the caller exits.
      wait.expire()
    }
    return try wait.result()
  }

  private static func spawn(
    _ executable: String,
    arguments: [String],
  ) throws -> pid_t {
    var actions: posix_spawn_file_actions_t?
    try check(posix_spawn_file_actions_init(&actions), "spawn actions")
    defer { posix_spawn_file_actions_destroy(&actions) }
    for fd: Int32 in 0 ... 2 {
      try check(
        posix_spawn_file_actions_addopen(
          &actions,
          fd,
          "/dev/null",
          fd == 0 ? O_RDONLY : O_WRONLY,
          0,
        ),
        "spawn stdio",
      )
    }
    var attributes: posix_spawnattr_t?
    try check(posix_spawnattr_init(&attributes), "spawn attributes")
    defer { posix_spawnattr_destroy(&attributes) }
    try check(
      posix_spawnattr_setflags(
        &attributes,
        Int16(
          POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP
            | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        ),
      ),
      "spawn flags",
    )
    try check(posix_spawnattr_setpgroup(&attributes, 0), "spawn process group")
    var defaultSignals = sigset_t()
    sigfillset(&defaultSignals)
    try check(
      posix_spawnattr_setsigdefault(&attributes, &defaultSignals),
      "spawn signal defaults",
    )
    var signalMask = sigset_t()
    sigemptyset(&signalMask)
    try check(
      posix_spawnattr_setsigmask(&attributes, &signalMask),
      "spawn signal mask",
    )
    let environment = ProcessInfo.processInfo.environment.map {
      "\($0.key)=\($0.value)"
    }
    var pid: pid_t = 0
    let status = try withStrings([executable] + arguments) { argv in
      try withStrings(environment) { env in
        posix_spawn(&pid, executable, &actions, &attributes, argv, env)
      }
    }
    try check(status, "posix_spawn")
    return pid
  }

  private static func check(_ status: Int32, _ operation: String) throws {
    if status != 0 { throw Failure.systemCall(operation, status) }
  }

  private static func withStrings<T>(
    _ strings: [String],
    _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) throws -> T,
  ) throws -> T {
    var pointers: [UnsafeMutablePointer<CChar>?] = []
    defer { for pointer in pointers { free(pointer) } }
    for string in strings {
      guard let pointer = strdup(string) else {
        throw Failure.systemCall("strdup", ENOMEM, )
      }
      pointers.append(pointer)
    }
    pointers.append(nil)
    return try pointers.withUnsafeBufferPointer { try body($0.baseAddress!) }
  }
}

/// All waitpid/signal operations belong to this queue, so a collected PID
/// cannot receive a late timeout signal. Reaping can outlive the caller if
/// the kernel has not made a killed child waitable yet.
///
/// Sendable: `exitSource`, `timer`, `finished` and `killed` are touched only
/// on `queue`; the result lives in the `outcome` Mutex. The sources retain
/// the wait until the child is reaped and they are cancelled on `queue`.
private final class LaunchAgentCommandWait: @unchecked Sendable {
  let deadline: DispatchTime
  let completion = DispatchSemaphore(value: 0)
  private let pid: pid_t
  private let queue = DispatchQueue(
    label: "swiftty.launchctl-wait",
    qos: .utility,
  )
  private let outcome = Mutex<Result<Int32, LaunchAgentCommand.Failure>?>(nil)
  private var exitSource: DispatchSourceProcess?
  private var timer: DispatchSourceTimer?
  private var finished = false
  private var killed = false

  init(pid: pid_t, deadline: DispatchTime) {
    self.pid = pid
    self.deadline = deadline
  }

  func start() { queue.async { self.observe() } }

  func expire() {
    complete(.failure(.timedOut))
    queue.sync { check(expired: true) }
  }

  func result() throws -> Int32 {
    let result = outcome.withLock { $0 }
    return try result!.get()
  }

  private func observe() {
    let exit = DispatchSource.makeProcessSource(
      identifier: pid,
      eventMask: .exit,
      queue: queue,
    )
    exit.setEventHandler { [self] in check() }
    exitSource = exit
    exit.resume()
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(
      deadline: .now() + .milliseconds(10),
      repeating: .milliseconds(10),
    )
    timer.setEventHandler { [self] in check() }
    self.timer = timer
    timer.resume()
    check()
  }

  private func check(expired: Bool = false) {
    guard !finished else { return }
    let expired = expired || DispatchTime.now() >= deadline
    var status: Int32 = 0
    var result: pid_t
    repeat {
      result = waitpid(pid, &status, WNOHANG)
    } while result < 0 && errno == EINTR
    if result != 0 {
      let error = errno
      finished = true
      exitSource?.cancel()
      exitSource = nil
      timer?.cancel()
      timer = nil
      if result < 0 {
        complete(.failure(.systemCall("waitpid", error)))
      } else if expired {
        complete(.failure(.timedOut))
      } else if status & 0x7F == 0 {
        complete(.success((status >> 8) & 0xFF))
      } else {
        complete(.failure(.signaled(status & 0x7F)))
      }
      return
    }
    guard !killed, expired else { return }
    killed = true
    if kill(-pid, SIGKILL) != 0 { kill(pid, SIGKILL) }
    complete(.failure(.timedOut))
  }

  private func complete(_ result: Result<Int32, LaunchAgentCommand.Failure>) {
    let first = outcome.withLock { outcome in
      guard outcome == nil else { return false }
      outcome = result
      return true
    }
    if first { completion.signal() }
  }
}
