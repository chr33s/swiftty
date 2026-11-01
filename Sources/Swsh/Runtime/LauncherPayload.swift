import CryptoKit
import Darwin
import Foundation

/// A private exact-executable protocol. Source workers carry exact body bytes and
/// value snapshots; external/builtin launchers carry expanded arguments, never closures.
struct LauncherPayload: Codable, Equatable {
  static let maximumBytes = 8 * 1024 * 1024
  static let magic = Array("SWSH0001".utf8)
  enum Kind: String, Codable { case external, builtin, descriptors, source }
  var kind = Kind.external
  let build: String
  let executable: [UInt8]
  let arguments: [[UInt8]]
  let environment: [[UInt8]]
  let redirects: [DescriptorAction]
  var lookupFailure: Int32? = nil
  var supervisorDescriptor: Int32? = nil
  var replyDescriptor: Int32? = nil
  var sourceContext: SourceWorkerContext? = nil
  var builtinContext: BuiltinWorkerContext? = nil

  func write() throws -> OwnedFD {
    let data = try JSONEncoder().encode(self)
    guard data.count <= Self.maximumBytes else {
      throw SystemFailure("launcher payload too large", code: E2BIG)
    }
    let owner = try OwnedFD.temporaryPayload()
    try owner.withDescriptor { fd in
      let length = UInt64(data.count)
      let header =
        Self.magic
        + (0 ..< 8).map { UInt8(truncatingIfNeeded: length >> ($0 * 8)) }
      try writeBytes(header + Array(data), to: fd)
      guard lseek(fd, 0, SEEK_SET) == 0 else {
        throw SystemFailure("rewind launcher payload")
      }
    }
    return owner
  }

  static func read(descriptor: Int32, build: String) throws -> LauncherPayload {
    var info = stat()
    guard fstat(descriptor, &info) == 0 else {
      throw SystemFailure("payload fstat")
    }
    guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 16,
      info.st_size <= maximumBytes + 16
    else { throw SystemFailure("invalid payload size/type", code: EINVAL) }
    let header = try readExactly(16, from: descriptor)
    guard Array(header.prefix(8)) == magic else {
      throw SystemFailure("invalid payload header", code: EINVAL)
    }
    let length = header.suffix(8).enumerated()
      .reduce(UInt64(0)) { $0 | (UInt64($1.element) << ($1.offset * 8)) }
    guard length <= maximumBytes, length == info.st_size - 16 else {
      throw SystemFailure("invalid payload length", code: EINVAL)
    }
    let bytes = try readExactly(Int(length), from: descriptor)
    let payload: Self
    do {
      payload = try JSONDecoder().decode(Self.self, from: Data(bytes))
    } catch {
      // Decoder descriptions can quote private payload values. Keep them out of logs.
      throw SystemFailure("invalid launcher payload encoding", code: EINVAL)
    }
    guard payload.build == build else {
      throw SystemFailure("launcher build mismatch", code: EINVAL)
    }
    guard !payload.executable.isEmpty, !payload.executable.contains(0),
      !payload.arguments.isEmpty,
      payload.arguments.allSatisfy({ !$0.contains(0) }),
      payload.environment.allSatisfy({ !$0.contains(0) })
    else { throw SystemFailure("invalid launcher process data", code: EINVAL) }
    if let status = payload.lookupFailure {
      guard payload.kind == .external, [126, 127].contains(status) else {
        throw SystemFailure("invalid lookup failure", code: EINVAL)
      }
    }
    for action in payload.redirects {
      let valid: Bool
      switch action {
      case .open(let descriptor, let path, _):
        valid = descriptor >= 0 && !path.contains(0)
      case .duplicate(let descriptor, let source):
        valid = descriptor >= 0 && source >= 0
      case .close(let descriptor): valid = descriptor >= 0
      }
      guard valid else {
        throw SystemFailure("invalid launcher descriptor action", code: EINVAL)
      }
    }
    if let lease = payload.supervisorDescriptor {
      guard payload.kind == .source, lease >= 3, lease != descriptor,
        payload.redirects.allSatisfy({ action in
          switch action {
          case .open(let fd, _, _), .close(let fd): return fd != lease
          case .duplicate(let fd, let source):
            return fd != lease && source != lease
          }
        })
      else {
        throw SystemFailure(
          "invalid source supervisor descriptor",
          code: EINVAL
        )
      }
    }
    if let reply = payload.replyDescriptor {
      guard payload.kind == .descriptors, reply >= 3, reply != descriptor,
        payload.redirects.allSatisfy({ action in
          switch action {
          case .open(let fd, _, _), .close(let fd): return fd != reply
          case .duplicate(let fd, let source):
            return fd != reply && source != reply
          }
        })
      else {
        throw SystemFailure("invalid descriptor reply channel", code: EINVAL)
      }
    }
    guard (payload.kind == .source) == (payload.sourceContext != nil) else {
      throw SystemFailure("source context kind mismatch", code: EINVAL)
    }
    switch payload.kind {
    case .source:
      guard let context = payload.sourceContext, payload.builtinContext == nil,
        !context.source.contains(0),
        String(validating: context.source, as: UTF8.self) != nil,
        (0 ..< 128).contains(context.state.executionDepth),
        context.state.variables.values.allSatisfy({ !$0.contains(0) }),
        context.state.opaqueEnvironment.allSatisfy({ !$0.contains(0) }),
        context.functionArguments?.allSatisfy({ !$0.contains(0) }) ?? true,
        context.state.functions.values.allSatisfy({
          !$0.contains(0) && String(validating: $0, as: UTF8.self) != nil
        })
      else {
        throw SystemFailure("invalid source worker payload", code: EINVAL)
      }
    case .descriptors:
      guard payload.replyDescriptor != nil, payload.builtinContext == nil else {
        throw SystemFailure("invalid descriptor setup payload", code: EINVAL)
      }
    case .external:
      guard payload.builtinContext == nil else {
        throw SystemFailure(
          "external payload contains builtin context",
          code: EINVAL
        )
      }
    case .builtin:
      guard let context = payload.builtinContext,
        BuiltinWorkerContext.supports(context.builtin),
        payload.arguments.first == Array(context.builtin.rawValue.utf8),
        context.variables.values.allSatisfy({ !$0.contains(0) }),
        context.opaqueEnvironment.allSatisfy({ !$0.contains(0) }),
        context.builtin != .exec || payload.redirects.isEmpty
      else {
        throw SystemFailure("invalid builtin worker payload", code: EINVAL)
      }
    }
    return payload
  }

  static func buildIdentity(executable: [UInt8]) throws -> String {
    let file = try OwnedFD.open(executable, flags: O_RDONLY)
    var digest = SHA256()
    try file.withDescriptor { fd in
      var buffer = [UInt8](repeating: 0, count: 64 * 1024)
      while true {
        let count = Darwin.read(fd, &buffer, buffer.count)
        if count < 0 && errno == EINTR { continue }
        guard count >= 0 else {
          throw SystemFailure("read executable identity")
        }
        if count == 0 { break }
        digest.update(data: Data(buffer.prefix(count)))
      }
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func readExactly(
    _ count: Int,
    from fd: Int32
  ) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    try bytes.withUnsafeMutableBytes { buffer in
      var offset = 0
      while offset < count {
        let result = Darwin.read(
          fd,
          buffer.baseAddress! + offset,
          count - offset
        )
        if result < 0 && errno == EINTR { continue }
        guard result > 0 else {
          throw SystemFailure(
            "truncated launcher payload",
            code: result == 0 ? EINVAL : errno
          )
        }
        offset += result
      }
    }
    return bytes
  }
}
