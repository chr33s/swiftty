import Darwin
import Dispatch
import Foundation
import Security
import SwiftMuxProtocol
import TerminalProcess

/// Sole owner/reaper of a workspace worker. Constructed off the guardian queue;
/// after publication, all operations and callbacks are confined to that queue.
/// Shells are separate guardian children, never children of this process.
final class GuardianWorkerProcess: @unchecked Sendable {
  let pid: Int32
  let build: String
  private let queue: DispatchQueue
  private var bootstrapFD: Int32
  private let bootstrap: Data
  private var observation: DispatchSourceProcess?
  private var terminating = false
  private(set) var finished = false
  private(set) var status: Int32?
  var onFinished: (@Sendable () -> Void)?

  private init(
    pid: Int32,
    fd: Int32,
    data: Data,
    build: String,
    queue: DispatchQueue
  ) {
    self.pid = pid
    bootstrapFD = fd
    bootstrap = data
    self.build = build
    self.queue = queue
  }

  static func spawn(
    executable: String,
    arguments: [String],
    bootstrap: GuardianWorkerBootstrap,
    queue: DispatchQueue
  ) throws -> GuardianWorkerProcess {
    guard executable.hasPrefix("/"), !executable.utf8.contains(0),
      arguments.count <= 64, arguments.allSatisfy({ !$0.utf8.contains(0) }),
      arguments.reduce(0, { $0 + $1.utf8.count }) <= 16384,
      !bootstrap.build.isEmpty, bootstrap.build.utf8.count <= 128,
      !bootstrap.machService.isEmpty, bootstrap.machService.utf8.count <= 255
    else {
      throw MuxError(.invalidRequest, "invalid worker launch configuration")
    }
    if let requirement = bootstrap.peerRequirement {
      try validateSignature(executable, requirement: requirement)
    }
    let data = try JSONEncoder().encode(bootstrap)
    guard data.count <= 4096 else {
      throw MuxError(.resourceLimit, "worker bootstrap too large")
    }
    var descriptors: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
      throw POSIXError("worker bootstrap socketpair")
    }
    var transferred = false
    defer {
      Darwin.close(descriptors[0])
      if !transferred { Darwin.close(descriptors[1]) }
    }
    // Move the source above stdio and descriptor 3: dup2(fd, fd) would retain
    // CLOEXEC, and opening stdio could otherwise overwrite the source.
    let source = fcntl(descriptors[0], F_DUPFD_CLOEXEC, 4)
    guard source >= 0 else { throw POSIXError("worker bootstrap duplicate") }
    defer { Darwin.close(source) }
    guard fcntl(descriptors[0], F_SETFD, FD_CLOEXEC) == 0,
      fcntl(descriptors[1], F_SETFD, FD_CLOEXEC) == 0,
      fcntl(descriptors[1], F_SETFL, O_NONBLOCK) == 0
    else { throw POSIXError("worker bootstrap flags") }
    var enabled: Int32 = 1
    guard
      setsockopt(
        descriptors[1],
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &enabled,
        socklen_t(MemoryLayout<Int32>.size)
      ) == 0
    else { throw POSIXError("worker bootstrap no SIGPIPE") }
    var actions: posix_spawn_file_actions_t?
    try check(posix_spawn_file_actions_init(&actions), "worker spawn actions")
    defer { posix_spawn_file_actions_destroy(&actions) }
    try check(
      posix_spawn_file_actions_adddup2(&actions, source, 3),
      "worker bootstrap dup2"
    )
    for fd: Int32 in 0 ... 2 {
      try check(
        posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", O_RDWR, 0),
        "worker stdio"
      )
    }
    var attributes: posix_spawnattr_t?
    try check(posix_spawnattr_init(&attributes), "worker spawn attributes")
    defer { posix_spawnattr_destroy(&attributes) }
    try check(
      posix_spawnattr_setflags(
        &attributes,
        Int16(
          POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP
            | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        )
      ),
      "worker spawn flags"
    )
    try check(posix_spawnattr_setpgroup(&attributes, 0), "worker process group")
    var all = sigset_t()
    sigfillset(&all)
    try check(
      posix_spawnattr_setsigdefault(&attributes, &all),
      "worker signals"
    )
    var none = sigset_t()
    sigemptyset(&none)
    try check(
      posix_spawnattr_setsigmask(&attributes, &none),
      "worker signal mask"
    )
    var pid: Int32 = 0
    let result = try CStringVector.withStrings([executable] + arguments) {
      argv throws(TerminalProcess.POSIXError) in
      try CStringVector.withStrings([
        "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LANG=en_US.UTF-8",
      ]) { env in
        posix_spawn(&pid, executable, &actions, &attributes, argv, env)
      }
    }
    try check(result, "worker posix_spawn")
    transferred = true
    return GuardianWorkerProcess(
      pid: pid,
      fd: descriptors[1],
      data: data,
      build: bootstrap.build,
      queue: queue
    )
  }

  /// Register inventory and the exit callback before calling this. The child
  /// is blocked reading descriptor 3 until this bounded write and close.
  func activate() throws {
    dispatchPrecondition(condition: .onQueue(queue))
    let source = DispatchSource.makeProcessSource(
      identifier: pid,
      eventMask: .exit,
      queue: queue
    )
    observation = source
    source.setEventHandler { [weak self] in self?.collect() }
    source.resume()
    defer { closeBootstrap() }
    let count = bootstrap.withUnsafeBytes {
      Darwin.write(bootstrapFD, $0.baseAddress!, $0.count)
    }
    guard count == bootstrap.count else {
      terminate()
      throw MuxError(.launchFailed, "worker bootstrap delivery failed")
    }
    collect()
  }

  func terminate() {
    dispatchPrecondition(condition: .onQueue(queue))
    collect()
    guard !finished, !terminating else { return }
    terminating = true
    closeBootstrap()
    // An unreaped owned child pins its PID; collect first to avoid signalling
    // an unrelated process if an external reaper has violated ownership.
    _ = kill(pid, SIGTERM)
    queue.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
      guard let self else { return }
      self.collect()
      guard !self.finished else { return }
      _ = kill(self.pid, SIGKILL)
    }
  }

  private func collect() {
    guard !finished else { return }
    var raw: Int32 = 0
    var result: Int32
    repeat {
      result = waitpid(pid, &raw, WNOHANG)
    } while result < 0 && errno == EINTR
    guard result == pid || (result < 0 && errno == ECHILD) else { return }
    finished = true
    status = result == pid ? raw : nil
    observation?.cancel()
    observation = nil
    closeBootstrap()
    let callback = onFinished
    onFinished = nil
    callback?()
  }

  private func closeBootstrap() {
    if bootstrapFD >= 0 {
      Darwin.close(bootstrapFD);
      bootstrapFD = -1
    }
  }

  deinit {
    observation?.cancel()
    if bootstrapFD >= 0 { Darwin.close(bootstrapFD) }
    if !finished {
      var raw: Int32 = 0
      var result: Int32
      repeat {
        result = waitpid(pid, &raw, WNOHANG)
      } while result < 0 && errno == EINTR
      if result == 0 {
        _ = kill(pid, SIGKILL)
        repeat {
          result = waitpid(pid, &raw, 0)
        } while result < 0 && errno == EINTR
      }
    }
  }

  private static func check(_ code: Int32, _ operation: String) throws {
    guard code == 0 else { throw POSIXError(operation, code: code) }
  }

  static func validateSignature(_ path: String, requirement: String) throws {
    try GuardianArtifactValidation.validateSignature(
      path,
      requirement: requirement
    )
  }
}
