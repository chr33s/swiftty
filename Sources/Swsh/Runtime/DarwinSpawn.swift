#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
import CSwshSupport
#elseif canImport(Musl)
import Musl
#endif

/// A single launch owner invokes this synchronously and registers the returned PID
/// before it can suspend or accept another request. No Swift executes after fork.
struct DarwinSpawn {
  enum Group: Equatable {
    case inherited
    case suspendedLeader
    case suspendedMember(pid_t)
  }

  enum Wiring {
    case duplicate(source: Int32, destination: Int32)
    case close(Int32)
  }

  func launch(
    path: [UInt8],
    arguments: [[UInt8]],
    environment: [[UInt8]],
    group: Group,
    wiring: [Wiring] = [],
    parentBuiltinSetup: Bool = false
  ) throws -> pid_t {
    try perform(
      path: path,
      arguments: arguments,
      environment: environment,
      group: group,
      wiring: wiring,
      replacing: false,
      parentBuiltinSetup: parentBuiltinSetup
    )
  }

  /// SETEXEC applies signal attributes at image replacement, without an intermediate child.
  /// No cwd or descriptor action is allowed in this first replacement contract.
  func replace(
    path: [UInt8],
    arguments: [[UInt8]],
    environment: [[UInt8]]
  ) throws -> Never {
    #if canImport(Darwin)
    _ = try perform(
      path: path,
      arguments: arguments,
      environment: environment,
      group: .inherited,
      replacing: true
    )
    preconditionFailure("POSIX_SPAWN_SETEXEC unexpectedly returned success")
    #else
    guard !path.isEmpty, !path.contains(0), !arguments.isEmpty else {
      throw SystemFailure("invalid executable or argv", code: EINVAL)
    }
    let argv = try CStringVector(arguments)
    let envp = try CStringVector(environment)
    let code = (path + [0])
      .withUnsafeBytes { executable in
        argv.withPointers { arguments in
          envp.withPointers { environment in
            swsh_replace(
              executable.baseAddress!.assumingMemoryBound(to: CChar.self),
              UnsafeMutablePointer(mutating: arguments),
              UnsafeMutablePointer(mutating: environment)
            )
          }
        }
      }
    throw SystemFailure("execve", code: code)
    #endif
  }

  private func perform(
    path: [UInt8],
    arguments: [[UInt8]],
    environment: [[UInt8]],
    group: Group,
    wiring: [Wiring] = [],
    replacing: Bool,
    parentBuiltinSetup: Bool = false
  ) throws -> pid_t {
    guard !path.isEmpty, !path.contains(0), !arguments.isEmpty else {
      throw SystemFailure("invalid executable or argv", code: EINVAL)
    }
    let argv = try CStringVector(arguments)
    let envp = try CStringVector(environment)
    #if !canImport(Darwin)
    if group != .inherited {
      // glibc has no suspended start: the child waits for SIGCONT before execve.
      var pairs: [Int32] = []
      for action in wiring {
        switch action {
        case .duplicate(let source, let destination):
          pairs += [source, destination]
        case .close(let descriptor): pairs += [-1, descriptor]
        }
      }
      let leader: pid_t
      if case .suspendedMember(let existing) = group {
        leader = existing
      } else {
        leader = 0
      }
      var pid: pid_t = 0
      let result = (path + [0])
        .withUnsafeBytes { executable in
          argv.withPointers { arguments in
            envp.withPointers { environment in
              swsh_spawn_gated(
                &pid,
                executable.baseAddress!.assumingMemoryBound(to: CChar.self),
                UnsafeMutablePointer(mutating: arguments),
                UnsafeMutablePointer(mutating: environment),
                leader,
                pairs,
                Int32(pairs.count / 2),
                parentBuiltinSetup ? 1 : 0
              )
            }
          }
        }
      try check(result, "posix_spawn")
      return pid
    }
    #endif
    #if canImport(Darwin)
    var attributes: posix_spawnattr_t?
    var actions: posix_spawn_file_actions_t?
    #else
    var attributes = posix_spawnattr_t()
    var actions = posix_spawn_file_actions_t()
    #endif
    try check(posix_spawnattr_init(&attributes), "posix_spawnattr_init")
    defer { posix_spawnattr_destroy(&attributes) }
    try check(
      posix_spawn_file_actions_init(&actions),
      "posix_spawn_file_actions_init"
    )
    defer { posix_spawn_file_actions_destroy(&actions) }
    for action in wiring {
      switch action {
      case .duplicate(let source, let destination):
        try check(
          posix_spawn_file_actions_adddup2(&actions, source, destination),
          "spawn dup2"
        )
      case .close(let descriptor):
        try check(
          posix_spawn_file_actions_addclose(&actions, descriptor),
          "spawn close"
        )
      }
    }
    var mask = sigset_t()
    sigemptyset(&mask)
    try check(
      posix_spawnattr_setsigmask(&attributes, &mask),
      "spawn signal mask"
    )
    var defaults = sigset_t()
    sigemptyset(&defaults)
    for signal in [
      SIGINT, SIGQUIT, SIGPIPE, SIGTSTP, SIGTTIN, SIGTTOU, SIGHUP, SIGTERM,
      SIGCHLD,
    ] {
      if parentBuiltinSetup && [SIGTSTP, SIGTTIN, SIGTTOU].contains(signal) {
        continue
      }
      sigaddset(&defaults, signal)
    }
    try check(
      posix_spawnattr_setsigdefault(&attributes, &defaults),
      "spawn signal defaults"
    )
    var flags = Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
    #if canImport(Darwin)
    if replacing { flags |= Int16(POSIX_SPAWN_SETEXEC) }
    #endif
    switch group {
    case .inherited: break
    case .suspendedLeader, .suspendedMember:
      #if canImport(Darwin)
      flags |= Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_START_SUSPENDED)
      #endif
      let pgid: pid_t
      if case .suspendedMember(let leader) = group {
        pgid = leader
      } else {
        pgid = 0
      }
      try check(
        posix_spawnattr_setpgroup(&attributes, pgid),
        "spawn process group"
      )
    }
    try check(posix_spawnattr_setflags(&attributes, flags), "spawn flags")
    var pid: pid_t = 0
    let result = (path + [0])
      .withUnsafeBytes { executable in
        argv.withPointers { arguments in
          envp.withPointers { environment in
            posix_spawn(
              &pid,
              executable.baseAddress!.assumingMemoryBound(to: CChar.self),
              &actions,
              &attributes,
              UnsafeMutablePointer(mutating: arguments),
              UnsafeMutablePointer(mutating: environment)
            )
          }
        }
      }
    try check(result, "posix_spawn")
    return pid
  }

  private func check(_ result: Int32, _ operation: String) throws {
    guard result == 0 else { throw SystemFailure(operation, code: result) }
  }
}
