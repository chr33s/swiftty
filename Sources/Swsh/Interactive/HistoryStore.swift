import Darwin
import Foundation

/// A separate bounded JSON-lines store. Whole source submissions are history entries.
final class HistoryStore {
  private let path: [UInt8]?
  private(set) var entries: [[UInt8]] = []
  private let maximumBytes = 1024 * 1024

  init(home: [UInt8]?) {
    path = home.map { $0 + Array("/.swsh_history".utf8) }
    guard let path else { return }
    do {
      let file = try OwnedFD.open(
        path,
        flags: O_RDONLY | O_NOFOLLOW | O_NONBLOCK
      )
      entries = try file.withDescriptor(readEntries)
    } catch { /* Missing or unreadable history never prevents startup. */  }
  }

  func append(_ source: [UInt8]) {
    guard !source.isEmpty, source.count <= 64 * 1024, entries.last != source
    else { return }
    entries.append(source)
    if entries.count > 1000 { entries.removeFirst(entries.count - 1000) }
    guard let path else { return }
    do {
      let file = try OwnedFD.open(
        path,
        flags: O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK
      )
      try file.withDescriptor { fd in
        guard flock(fd, LOCK_EX) == 0 else {
          throw SystemFailure("lock history")
        }
        defer { flock(fd, LOCK_UN) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(),
          (info.st_mode & S_IFMT) == S_IFREG
        else { throw SystemFailure("invalid history owner/type", code: EINVAL) }
        guard fchmod(fd, 0o600) == 0 else {
          throw SystemFailure("history permissions")
        }
        var latest = try readEntries(fd)
        if latest.last != source { latest.append(source) }
        latest = Array(latest.suffix(1000))
        var encoded: [[UInt8]] = try latest.map {
          Array(try JSONEncoder().encode(String(decoding: $0, as: UTF8.self)))
            + [10]
        }
        var size = encoded.reduce(0) { $0 + $1.count }
        while size > maximumBytes && !encoded.isEmpty {
          size -= encoded.removeFirst().count
        }
        entries = Array(latest.suffix(encoded.count))
        guard lseek(fd, 0, SEEK_SET) == 0, ftruncate(fd, 0) == 0 else {
          throw SystemFailure("rewrite history")
        }
        for line in encoded { try writeBytes(line, to: fd) }
      }
    } catch
    { /* History persistence is best-effort, separate from command status. */  }
  }

  private func readEntries(_ fd: Int32) throws -> [[UInt8]] {
    var info = stat()
    guard fstat(fd, &info) == 0 else { throw SystemFailure("history stat") }
    guard info.st_size >= 0, info.st_size <= maximumBytes else { return [] }
    var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
    var offset = 0
    while offset < bytes.count {
      let count = bytes.withUnsafeMutableBytes {
        Darwin.read(fd, $0.baseAddress! + offset, $0.count - offset)
      }
      if count < 0 && errno == EINTR { continue }
      guard count > 0 else { break }
      offset += count
    }
    return bytes.prefix(offset).split(separator: 10).suffix(1000)
      .compactMap {
        guard let value = try? JSONDecoder().decode(String.self, from: Data($0))
        else { return nil }
        return Array(value.utf8)
      }
  }
}
