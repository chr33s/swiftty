import Darwin
import CSwshSupport

struct SystemFailure: Error, CustomStringConvertible, Sendable {
  let operation: String
  let code: Int32
  init(_ operation: String, code: Int32 = errno) {
    self.operation = operation
    self.code = code
  }
  var description: String { "\(operation): \(String(cString: strerror(code)))" }
}

/// Only syscall factories can adopt a descriptor. Raw access never transfers ownership.
struct OwnedFD: ~Copyable {
  private let descriptor: Int32
  private init(adopting descriptor: Int32) { self.descriptor = descriptor }
  deinit { Darwin.close(descriptor) }

  static func eventQueue() throws -> OwnedFD {
    let fd = kqueue()
    guard fd >= 0 else { throw SystemFailure("kqueue") }
    let owner = OwnedFD(adopting: fd)
    guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
      throw SystemFailure("kqueue close-on-exec")
    }
    return owner
  }

  borrowing func withDescriptor<Result: ~Copyable>(
    _ body: (Int32) throws -> Result
  ) rethrows -> Result { try body(descriptor) }

  static func open(
    _ path: [UInt8],
    flags: Int32,
    mode: mode_t = 0o600
  ) throws -> OwnedFD {
    guard !path.contains(0) else {
      throw SystemFailure("open: NUL in path", code: EINVAL)
    }
    let fd = (path + [0])
      .withUnsafeBytes {
        Darwin.open(
          $0.baseAddress!.assumingMemoryBound(to: CChar.self),
          flags | O_CLOEXEC,
          mode
        )
      }
    guard fd >= 0 else { throw SystemFailure("open") }
    return OwnedFD(adopting: fd)
  }

  static func duplicate(
    _ descriptor: Int32,
    minimum: Int32 = 10
  ) throws -> OwnedFD {
    let copy = fcntl(descriptor, F_DUPFD_CLOEXEC, minimum)
    guard copy >= 0 else { throw SystemFailure("fcntl(F_DUPFD_CLOEXEC)") }
    return OwnedFD(adopting: copy)
  }

  static func temporaryPayload() throws -> OwnedFD {
    var template = Array("/tmp/swsh-payload.XXXXXX".utf8CString)
    let fd = mkstemp(&template)
    guard fd >= 0 else { throw SystemFailure("mkstemp") }
    let owner = OwnedFD(adopting: fd)
    guard unlink(template) == 0 else { throw SystemFailure("unlink payload") }
    guard fchmod(fd, 0o600) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
      throw SystemFailure("payload descriptor setup")
    }
    return owner
  }

  /// Called only by the launch owner, which serializes pipe creation and spawn.
  static func pipe() throws -> OwnedPipe {
    var descriptors: [Int32] = [-1, -1]
    guard Darwin.pipe(&descriptors) == 0 else { throw SystemFailure("pipe") }
    let input = OwnedFD(adopting: descriptors[0])
    let output = OwnedFD(adopting: descriptors[1])
    guard fcntl(descriptors[0], F_SETFD, FD_CLOEXEC) == 0,
      fcntl(descriptors[1], F_SETFD, FD_CLOEXEC) == 0
    else { throw SystemFailure("pipe close-on-exec") }
    return OwnedPipe(input: consume input, output: consume output)
  }

  static func descriptorChannel() throws -> OwnedPipe {
    var descriptors: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &descriptors) == 0 else {
      throw SystemFailure("descriptor socketpair")
    }
    let input = OwnedFD(adopting: descriptors[0])
    let output = OwnedFD(adopting: descriptors[1])
    guard fcntl(descriptors[0], F_SETFD, FD_CLOEXEC) == 0,
      fcntl(descriptors[1], F_SETFD, FD_CLOEXEC) == 0
    else { throw SystemFailure("descriptor channel close-on-exec") }
    // Keep internal sockets out of any originally closed standard slot.
    return OwnedPipe(
      input: try duplicate(input.withDescriptor { $0 }),
      output: try duplicate(output.withDescriptor { $0 })
    )
  }

  static func receiveStandardIO(from socket: Int32) throws -> OwnedStandardIO {
    var descriptors: [Int32] = [-1, -1, -1]
    guard swsh_receive_standard_descriptors(socket, &descriptors) == 0 else {
      throw SystemFailure("receive builtin descriptors")
    }
    return OwnedStandardIO(
      input: descriptors[0] < 0 ? nil : OwnedFD(adopting: descriptors[0]),
      output: descriptors[1] < 0 ? nil : OwnedFD(adopting: descriptors[1]),
      error: descriptors[2] < 0 ? nil : OwnedFD(adopting: descriptors[2])
    )
  }

  consuming func transfer() -> Int32 {
    let result = descriptor
    discard self
    return result
  }

  consuming func close() throws {
    let result = Darwin.close(descriptor)
    let error = errno
    discard self
    // Retrying close after EINTR risks closing a reused descriptor.
    guard result == 0 else { throw SystemFailure("close", code: error) }
  }
}

struct OwnedPipe: ~Copyable {
  var input: OwnedFD
  var output: OwnedFD

  consuming func withEnds<Result: ~Copyable>(
    _ body: (consuming OwnedFD, consuming OwnedFD) throws -> Result
  ) rethrows -> Result { try body(input, output) }
}

func writeBytes(_ bytes: [UInt8], to descriptor: Int32) throws {
  try bytes.withUnsafeBytes { buffer in
    var offset = 0
    while offset < buffer.count {
      let count = Darwin.write(
        descriptor,
        buffer.baseAddress! + offset,
        buffer.count - offset
      )
      if count < 0 && errno == EINTR { continue }
      guard count > 0 else {
        throw SystemFailure("write", code: count == 0 ? EIO : errno)
      }
      offset += count
    }
  }
}

/// Retains redirected stdin too, even for a builtin that does not read it.
struct OwnedStandardIO: ~Copyable {
  let input: OwnedFD?
  let output: OwnedFD?
  let error: OwnedFD?

  var builtinIO: BuiltinIO {
    BuiltinIO(
      output: output?.withDescriptor { $0 } ?? -1,
      error: error?.withDescriptor { $0 } ?? -1
    )
  }
}
