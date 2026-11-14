import Darwin
import Foundation

/// Reads regular files through one descriptor so aliases and concurrent
/// growth cannot bypass the byte limit. Missing paths are distinct from
/// unreadable files, including dangling symbolic links.
package enum BoundedFile {
  package enum ReadError: Error {
    case tooLarge
    case invalidFile
    case posix(Int32)
  }

  package static func readIfPresent(_ url: URL, limit: Int) throws -> Data? {
    guard url.isFileURL, !url.path.utf8.contains(0), limit >= 0 else {
      throw ReadError.invalidFile
    }
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
    guard descriptor >= 0 else {
      let failure = errno
      if failure == ENOENT {
        var info = Darwin.stat()
        if Darwin.lstat(url.path, &info) < 0, errno == ENOENT { return nil }
      }
      throw ReadError.posix(failure)
    }
    defer { Darwin.close(descriptor) }
    var info = Darwin.stat()
    guard fstat(descriptor, &info) == 0 else { throw ReadError.posix(errno) }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
      throw ReadError.invalidFile
    }
    guard info.st_size <= limit else { throw ReadError.tooLarge }
    var data = Data()
    data.reserveCapacity(Int(info.st_size))
    var chunk = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
      let remaining = limit - data.count
      let count = chunk.withUnsafeMutableBytes {
        Darwin.read(
          descriptor,
          $0.baseAddress,
          remaining >= $0.count ? $0.count : remaining + 1
        )
      }
      if count < 0 {
        if errno == EINTR { continue }
        throw ReadError.posix(errno)
      }
      if count == 0 { return data }
      guard count <= remaining else { throw ReadError.tooLarge }
      data.append(contentsOf: chunk.prefix(count))
    }
  }
}
