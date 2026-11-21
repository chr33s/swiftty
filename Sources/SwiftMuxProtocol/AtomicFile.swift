#if canImport(Darwin)
import Darwin
import Foundation

/// The one crash-safe replace for small owner-private state files (saved
/// layouts, policy, build selection, update plans, the installer record).
/// Every byte is written to a private temporary beside the destination and
/// flushed; the rename publishes it; the directory is flushed so the rename
/// survives power loss.
package enum AtomicFile {
  package static func write(
    _ data: Data,
    to destination: URL,
    permissions: mode_t = 0o600
  ) throws(MuxError) {
    let directory = destination.deletingLastPathComponent()
    let temporary = directory.appendingPathComponent(
      ".\(destination.lastPathComponent).\(UUID().uuidString)"
    )
    let fd = open(
      temporary.path,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      permissions
    )
    guard fd >= 0 else { throw failure("create", destination) }
    var written = 0
    let error: MuxError? = data.withUnsafeBytes { raw in
      while written < raw.count {
        let n = Darwin.write(
          fd,
          raw.baseAddress! + written,
          raw.count - written
        )
        if n < 0 {
          if errno == EINTR { continue }
          return failure("write", destination)
        }
        written += n
      }
      // Order the data before the rename that publishes it.
      if fcntl(fd, F_BARRIERFSYNC) != 0, fsync(fd) != 0 {
        return failure("flush", destination)
      }
      return nil
    }
    close(fd)
    if let error {
      unlink(temporary.path)
      throw error
    }
    guard rename(temporary.path, destination.path) == 0 else {
      let error = failure("rename", destination)
      unlink(temporary.path)
      throw error
    }
    let handle = open(directory.path, O_RDONLY | O_CLOEXEC)
    if handle >= 0 {
      _ = fsync(handle)
      close(handle)
    }
  }

  private static func failure(_ step: String, _ url: URL) -> MuxError {
    MuxError(
      .invalidRequest,
      "cannot \(step) \(url.lastPathComponent): \(String(cString: strerror(errno)))"
    )
  }
}
#endif
