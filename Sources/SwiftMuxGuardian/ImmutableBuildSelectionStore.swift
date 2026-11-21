import Darwin
import Foundation
import SwiftMuxProtocol

/// Only installation choice survives process restart. Live workspace pins and
/// process authority are deliberately absent from this file.
package struct ImmutableBuildSelectionStore {
  package struct Selection: Codable, Sendable, Equatable {
    var schema = 1
    package let selected: String
    package let rollback: String?

    package init(selected: String, rollback: String?) {
      self.selected = selected
      self.rollback = rollback
    }
  }

  let root: URL

  package init(root: URL) { self.root = root }
  private var destination: URL {
    root.appendingPathComponent(".selection.json")
  }

  package func load() throws -> Selection? {
    let fd = open(
      destination.path,
      O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
    )
    if fd < 0, errno == ENOENT { return nil }
    guard fd >= 0 else {
      throw MuxError(.unauthorized, "cannot open build selection")
    }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? file.close() }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == geteuid(), info.st_mode & 0o077 == 0, info.st_nlink == 1,
      info.st_size > 0, info.st_size <= 8192
    else { throw MuxError(.unauthorized, "unsafe build selection file") }
    let bytes = try file.read(upToCount: 8193) ?? Data()
    guard bytes.count <= 8192 else {
      throw MuxError(.resourceLimit, "build selection too large")
    }
    let value = try JSONDecoder().decode(Selection.self, from: bytes)
    guard value.schema == 1, value.selected != value.rollback else {
      throw MuxError(.invalidRequest, "invalid build selection")
    }
    return value
  }

  /// Flush a private temporary file before atomic replacement. Any failure
  /// before rename leaves the prior selection intact. There is no fallible
  /// operation after publication, so callers can update memory on success.
  package func save(_ value: Selection) throws {
    _ = try load()
    let bytes = try JSONEncoder().encode(value)
    do { try AtomicFile.write(bytes, to: destination) } catch {
      throw MuxError(
        .launchFailed,
        "cannot publish build selection: \(error.message)"
      )
    }
  }
}
