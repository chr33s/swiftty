#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The only successful return from exec is a new process image with the same PID.
/// Failed lookup/replacement is ordinary command status; the caller can continue.
struct ExecReplacement {
  func run(arguments: [[UInt8]], state: ShellState) -> Int32 {
    guard let name = arguments.first else {
      diagnostic("exec requires a program")
      return 2
    }
    let executable: [UInt8]
    switch ExecutableLookup().resolve(name, state: state, overlay: [:]) {
    case .executable(let path): executable = path
    case .failure(let status):
      diagnostic("exec: command lookup failed")
      return status
    }
    do {
      try DarwinSpawn()
        .replace(
          path: executable,
          arguments: arguments,
          environment: state.environment()
        )
    } catch let error as SystemFailure {
      diagnostic("exec: \(error)")
      return error.code == ENOENT || error.code == ENOTDIR ? 127 : 126
    } catch {
      diagnostic("exec: invalid process data")
      return 2
    }
  }

  private func diagnostic(_ message: String) {
    try? writeBytes(Array("swsh: \(message)\n".utf8), to: STDERR_FILENO)
  }
}
