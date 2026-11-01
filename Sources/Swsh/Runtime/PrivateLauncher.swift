import Darwin
import CSwshSupport

/// Runs only at the private CLI entry point in a fresh process.
/// User job launchers enter after group release; parent-builtin setup inherits the shell group.
struct PrivateLauncher {
  func run(
    payloadDescriptor: Int32,
    build: String,
    kind: LauncherPayload.Kind
  ) -> Int32 {
    let payload: LauncherPayload
    do {
      defer { Darwin.close(payloadDescriptor) }
      payload = try LauncherPayload.read(
        descriptor: payloadDescriptor,
        build: build
      )
      guard payload.kind == kind else {
        throw SystemFailure("wrong private payload kind", code: EINVAL)
      }
    } catch {
      diagnostic(error)
      return 2
    }
    defer {
      if let lease = payload.supervisorDescriptor { Darwin.close(lease) }
    }
    if let lease = payload.supervisorDescriptor {
      var info = stat()
      guard fstat(lease, &info) == 0, (info.st_mode & S_IFMT) == S_IFIFO,
        fcntl(lease, F_SETFD, FD_CLOEXEC) == 0
      else {
        diagnostic(SystemFailure("source supervisor descriptor"))
        return 2
      }
    }
    do { for action in payload.redirects { try apply(action) } } catch {
      diagnostic(error)
      return 1
    }
    if let status = payload.lookupFailure {
      try? writeBytes(
        Array("swsh: command lookup failed: ".utf8) + payload.arguments[0] + [
          10
        ],
        to: STDERR_FILENO
      )
      return status
    }
    if let reply = payload.replyDescriptor {
      defer { Darwin.close(reply) }
      guard swsh_send_standard_descriptors(reply) == 0 else {
        diagnostic(SystemFailure("send builtin descriptors"))
        return 1
      }
      return 0
    }
    do {
      if let context = payload.sourceContext {
        return try context.run(
          executable: payload.executable,
          build: build,
          supervisorDescriptor: payload.supervisorDescriptor
        )
      }
      if let context = payload.builtinContext {
        return try context.run(arguments: payload.arguments)
      }
      let argv = try CStringVector(payload.arguments)
      let envp = try CStringVector(payload.environment)
      let result = (payload.executable + [0])
        .withUnsafeBytes { path in
          argv.withPointers { arguments in
            envp.withPointers { environment in
              execve(
                path.baseAddress!.assumingMemoryBound(to: CChar.self),
                UnsafeMutablePointer(mutating: arguments),
                UnsafeMutablePointer(mutating: environment)
              )
            }
          }
        }
      precondition(result == -1)
      let code = errno
      diagnostic(SystemFailure("execve", code: code))
      return code == ENOENT ? 127 : 126
    } catch {
      diagnostic(error)
      return 126
    }
  }

  private func apply(_ action: DescriptorAction) throws {
    switch action {
    case .close(let descriptor):
      if Darwin.close(descriptor) != 0 && errno != EBADF {
        throw SystemFailure("redirect close")
      }
    case .duplicate(let descriptor, let source):
      guard dup2(source, descriptor) >= 0 else {
        throw SystemFailure("redirect dup2")
      }
    case .open(let descriptor, let path, let mode):
      let flags: Int32
      switch mode {
      case .read: flags = O_RDONLY
      case .write: flags = O_WRONLY | O_CREAT | O_TRUNC
      case .append: flags = O_WRONLY | O_CREAT | O_APPEND
      }
      let owner = try OwnedFD.open(path, flags: flags, mode: 0o666)
      // open may itself return the requested descriptor when that slot was closed.
      if owner.withDescriptor({ $0 }) == descriptor {
        guard fcntl(descriptor, F_SETFD, 0) == 0 else {
          throw SystemFailure("redirect inheritance")
        }
        _ = owner.transfer()
      } else {
        try owner.withDescriptor { fd in
          guard dup2(fd, descriptor) >= 0 else {
            throw SystemFailure("redirect dup2")
          }
        }
      }
    }
  }

  private func diagnostic(_ error: any Error) {
    try? writeBytes(Array("swsh: \(error)\n".utf8), to: STDERR_FILENO)
  }
}
