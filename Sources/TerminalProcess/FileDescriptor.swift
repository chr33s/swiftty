import Darwin

public struct POSIXError: Error, CustomStringConvertible, Sendable {
  public let operation: String
  public let code: Int32

  public init(_ operation: String, code: Int32 = errno) {
    self.operation = operation
    self.code = code
  }

  public var description: String {
    "\(operation): \(String(cString: strerror(code)))"
  }
}

/// A uniquely owned file descriptor, closed on deinit.
public struct FileDescriptor: ~Copyable {
  public let rawValue: Int32

  public init(_ rawValue: Int32) { self.rawValue = rawValue }

  deinit { Darwin.close(rawValue) }

  public func setNonBlocking() throws(POSIXError) {
    let flags = fcntl(rawValue, F_GETFL)
    guard flags >= 0, fcntl(rawValue, F_SETFL, flags | O_NONBLOCK) == 0 else {
      throw POSIXError("fcntl(O_NONBLOCK)")
    }
  }

  public func setCloseOnExec() { _ = fcntl(rawValue, F_SETFD, FD_CLOEXEC) }

  /// One `read(2)`; returns bytes read, 0 on EOF, -1 with `errno` set.
  @inline(__always)
  public func read(into buffer: UnsafeMutableRawBufferPointer) -> Int {
    Darwin.read(rawValue, buffer.baseAddress, buffer.count)
  }

  /// Writes as much as possible without blocking; returns bytes written,
  /// stopping early on EAGAIN. Returns nil on a hard error.
  public func writeAvailable(_ bytes: UnsafeRawBufferPointer) -> Int? {
    var offset = 0
    while offset < bytes.count {
      let n = Darwin.write(
        rawValue,
        bytes.baseAddress! + offset,
        bytes.count - offset
      )
      if n > 0 {
        offset += n;
        continue
      }
      if n < 0, errno == EINTR { continue }
      if n < 0, errno == EAGAIN { break }
      return offset > 0 ? offset : nil
    }
    return offset
  }
}
