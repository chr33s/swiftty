#if os(macOS)
import Darwin
import Dispatch
import Foundation
import ScreenProtocol
import SessionCore
import Synchronization

public enum ControlSocketError: Error, Equatable, Sendable {
  /// The directory is not an owner-only (0700) directory of this user.
  case insecureDirectory
  /// The socket is missing, not a socket, or owned by another user.
  case insecureSocket
  case pathTooLong
  /// Socket names must be one nonempty, NUL-free filename component.
  case invalidName
  /// A Unix socket path must be nonempty and cannot contain NUL.
  case invalidPath
  case invalidTimeout
  /// The one elapsed budget for the client's connect/write/read expired.
  case timedOut
  case peerRejected
  case system(String, Int32)
}

/// The owner-only directory holding the agent's control socket (spec §4).
public enum ControlDirectory {
  /// `~/Library/Application Support/SwiftMux/roaming`.
  public static var defaultURL: URL {
    URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent("Library/Application Support/SwiftMux/roaming")
  }

  /// Creates the directory with mode 0700 when missing, then verifies it
  /// is a real directory (not a symlink) owned by `uid` with no group or
  /// other permissions.
  public static func prepare(
    _ url: URL,
    uid: uid_t = getuid()
  ) throws(ControlSocketError) {
    let path = url.path
    if mkdir(path, 0o700) != 0, errno != EEXIST {
      throw .system("mkdir", errno)
    }
    try verify(url, uid: uid)
  }

  public static func verify(
    _ url: URL,
    uid: uid_t = getuid()
  ) throws(ControlSocketError) {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { throw .system("lstat", errno) }
    guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == uid,
      info.st_mode & 0o077 == 0
    else { throw .insecureDirectory }
  }
}

/// Unix-domain control socket served by the agent. Each client sends
/// exactly one bounded bootstrap envelope and receives one response.
/// Peers must have the agent's UID (`getpeereid`). At most 32 exchanges
/// are admitted per server, including cancelled handlers until they finish.
/// Further connections are closed without invoking the handler.
///
/// Sendable: the listener descriptor, its read source, path ownership and
/// admitted exchanges live in the `state` Mutex; accepts run on `queue`.
/// The descriptor is closed by its source's cancel handler after `stop`.
public final class ControlSocketServer: @unchecked Sendable {
  public typealias Handler = @Sendable ([UInt8]) async -> [UInt8]
  private static let maxConcurrentExchanges = 32

  public let path: String
  private let expectedUID: uid_t
  private let handler: Handler
  private let ioTimeout: Duration
  private let state = Mutex<
    (
      fd: Int32, source: DispatchSourceRead?,
      ownership: ControlSocketOwnership?,
      exchanges: [ObjectIdentifier: ControlSocketExchange]
    )
  >((-1, nil, nil, [:]))
  private let queue = DispatchQueue(label: "swifttyd.control-socket")

  /// - Parameters:
  ///   - directory: An owner-only directory (see `ControlDirectory`).
  ///   - name: One nonempty, NUL-free filename component within the directory.
  ///   - expectedUID: The only peer UID served.
  ///   - ioTimeout: Positive deadline for the entire accepted exchange,
  ///     including the handler and response. Also bounds each blocking I/O
  ///     call, rounded up to microseconds. Progress does not reset it.
  ///   - handler: Produces the response for one request envelope.
  /// - Throws: `ControlSocketError` for an insecure directory, an overlong
  ///   socket path, an invalid filename or an invalid timeout.
  public init(
    directory: URL,
    name: String = "control.sock",
    expectedUID: uid_t = getuid(),
    ioTimeout: Duration = .seconds(5),
    handler: @escaping Handler
  ) throws(ControlSocketError) {
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
      !name.utf8.contains(0)
    else { throw .invalidName }
    _ = try socketTimeoutValue(ioTimeout)
    try ControlDirectory.verify(directory)
    path = directory.appendingPathComponent(name).path
    self.expectedUID = expectedUID
    self.handler = handler
    self.ioTimeout = ioTimeout
    guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path)
    else { throw .pathTooLong }
  }

  deinit { stop() }

  /// Starts listening. Repeated calls while running keep the same listener.
  /// A stopped instance can be started again.
  /// - Throws: `ControlSocketError` if another listener owns the path or
  ///   startup cannot secure the listener and its ownership lock.
  public func start() throws(ControlSocketError) {
    try state.withLock { current throws(ControlSocketError) in
      guard current.source == nil else { return }
      let listener = try makeListener()
      current.fd = listener.fd
      current.source = listener.source
      current.ownership = listener.ownership
      listener.source.resume()
    }
  }

  private func makeListener() throws(ControlSocketError) -> (
    fd: Int32, source: DispatchSourceRead, ownership: ControlSocketOwnership
  ) {
    let ownership = try ControlSocketOwnership(path: path)
    var transferred = false
    defer {
      if !transferred {
        ownership.removeSocketIfOwned()
        ownership.release()
      }
    }
    try ownership.removeStaleSocket()
    var info = stat()
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw .system("socket", errno) }
    defer { if !transferred { close(fd) } }
    guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
      throw .system("fcntl F_SETFD", errno)
    }
    var address = try Self.address(path)
    // The process umask is shared by every thread, so it is left alone;
    // the owner-only directory already shields the socket until chmod.
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0 else { throw .system("bind", errno) }
    try ownership.claimSocket()
    guard chmod(path, 0o600) == 0 else { throw .system("chmod", errno) }
    guard lstat(path, &info) == 0, info.st_uid == getuid(),
      info.st_mode & 0o077 == 0
    else { throw .insecureSocket }
    guard listen(fd, 16) == 0 else { throw .system("listen", errno) }
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0 else { throw .system("fcntl F_GETFL", errno) }
    guard fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
      throw .system("fcntl F_SETFL", errno)
    }
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler { [weak self] in self?.acceptAll(fd) }
    source.setCancelHandler { close(fd) }
    transferred = true
    return (fd, source, ownership)
  }

  /// Stops listening, shuts down accepted sockets and cancels their handlers.
  /// A handler that ignores cancellation cannot write a response afterward.
  public func stop() {
    let exchanges = state.withLock { s in
      // Cancelled work retains its admission slot until its worker finishes,
      // including across restart of this server instance.
      defer {
        s.fd = -1
        s.source = nil
        s.ownership = nil
      }
      s.source?.cancel()
      // Keep removal ordered with start, so an old stop cannot unlink the
      // replacement listener after a concurrent restart.
      s.ownership?.removeSocketIfOwned()
      s.ownership?.release()
      return Array(s.exchanges.values)
    }
    for exchange in exchanges { exchange.cancel() }
  }

  private func acceptAll(_ listener: Int32) {
    while true {
      let client = state.withLock { current in
        guard current.fd == listener, current.source != nil else {
          return Int32(-1)
        }
        return accept(listener, nil, nil)
      }
      guard client >= 0 else { return }
      let deadline = ContinuousClock.now + ioTimeout
      var uid: uid_t = 0
      var gid: gid_t = 0
      guard fcntl(client, F_SETFD, FD_CLOEXEC) == 0,
        getpeereid(client, &uid, &gid) == 0, uid == expectedUID
      else {
        close(client)
        continue
      }
      let exchange = ControlSocketExchange(fd: client) { [weak self] finished in
        self?.state
          .withLock {
            _ = $0.exchanges.removeValue(forKey: ObjectIdentifier(finished))
          }
      }
      let admitted = state.withLock { current in
        guard current.fd == listener, current.source != nil,
          current.exchanges.count < Self.maxConcurrentExchanges
        else { return false }
        current.exchanges[ObjectIdentifier(exchange)] = exchange
        return true
      }
      guard admitted else {
        exchange.cancel()
        continue
      }
      exchange.expire(at: deadline)
      let handler = handler
      let timeout = ioTimeout
      DispatchQueue.global(qos: .userInitiated)
        .async { Self.serve(exchange, timeout: timeout, handler: handler) }
    }
  }

  private static func serve(
    _ exchange: ControlSocketExchange,
    timeout: Duration,
    handler: @escaping Handler
  ) {
    let request = exchange.withSocket { fd -> [UInt8]? in
      let flags = fcntl(fd, F_GETFL)
      guard flags >= 0, fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
        return nil
      }
      do { try setTimeouts(fd, timeout) } catch { return nil }
      return try? readEnvelope(fd)
    }
    guard let request = request ?? nil else {
      exchange.finish()
      return
    }
    let task = Task {
      defer { exchange.finish() }
      guard !Task.isCancelled, !exchange.isStopped else { return }
      let response = await handler(request)
      guard !Task.isCancelled else { return }
      _ = exchange.withSocket { writeAll($0, response) }
    }
    exchange.install(task)
  }

  static func address(_ path: String) throws(ControlSocketError) -> sockaddr_un
  {
    guard !path.isEmpty, !path.utf8.contains(0) else { throw .invalidPath }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count < capacity else { throw .pathTooLong }
    let bytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
      raw.copyBytes(from: bytes)
      raw[bytes.count] = 0
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return address
  }
}

/// Client side of the control socket (used by `bootstrap --stdio`).
public enum ControlSocketClient {
  /// Sends one envelope and returns the one response envelope. Verifies
  /// the socket is owned by this user before connecting. The timeout covers
  /// connect, all request writes and all response reads, without resetting
  /// after partial progress.
  public static func exchange(
    path: String,
    envelope: [UInt8],
    timeout: Duration = .seconds(10)
  ) throws(ControlSocketError) -> [UInt8] {
    _ = try socketTimeoutValue(timeout)
    let started = ContinuousClock.now
    var address = try ControlSocketServer.address(path)
    var info = stat()
    guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK,
      info.st_uid == getuid()
    else { throw .insecureSocket }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw .system("socket", errno) }
    defer { close(fd) }
    guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
      throw .system("fcntl FD_CLOEXEC", errno)
    }
    try setTimeouts(fd, timeout)
    let io = try ControlSocketClientIO(
      fd: fd,
      timeout: timeout,
      started: started
    )
    try io.connect(to: &address)
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
      throw .peerRejected
    }
    try io.write(envelope)
    return try io.readEnvelope()
  }
}

// MARK: Bounded envelope I/O

private func socketTimeoutValue(
  _ timeout: Duration
) throws(ControlSocketError) -> timeval {
  guard timeout > .zero else { throw .invalidTimeout }
  var seconds = timeout.components.seconds
  let attoseconds = timeout.components.attoseconds
  let unit: Int64 = 1_000_000_000_000
  var microseconds = attoseconds / unit
  if attoseconds % unit != 0 { microseconds += 1 }
  // Round up, since a zero timeval disables the kernel deadline entirely.
  if microseconds == 1_000_000 {
    let (rounded, overflow) = seconds.addingReportingOverflow(1)
    guard !overflow else { throw .invalidTimeout }
    seconds = rounded
    microseconds = 0
  }
  guard let whole = Int(exactly: seconds) else { throw .invalidTimeout }
  return timeval(tv_sec: whole, tv_usec: Int32(microseconds))
}

func setTimeouts(_ fd: Int32, _ timeout: Duration) throws(ControlSocketError) {
  var value = try socketTimeoutValue(timeout)
  for (option, name) in [
    (SO_RCVTIMEO, "SO_RCVTIMEO"), (SO_SNDTIMEO, "SO_SNDTIMEO"),
  ] {
    guard
      setsockopt(
        fd,
        SOL_SOCKET,
        option,
        &value,
        socklen_t(MemoryLayout<timeval>.size)
      ) == 0
    else { throw .system("setsockopt \(name)", errno) }
  }
  var noSignal: Int32 = 1
  guard
    setsockopt(
      fd,
      SOL_SOCKET,
      SO_NOSIGPIPE,
      &noSignal,
      socklen_t(MemoryLayout<Int32>.size)
    ) == 0
  else { throw .system("setsockopt SO_NOSIGPIPE", errno) }
}

/// Reads exactly one `UInt32BE(length)` + body envelope, rejecting an
/// over-limit length before reading the body.
func readEnvelope(_ fd: Int32) throws(FramingError) -> [UInt8] {
  var prefix = [UInt8](repeating: 0, count: 4)
  guard readExactly(fd, &prefix, count: 4) else { throw .truncated }
  guard let total = try BootstrapEnvelope.expectedLength(prefix) else {
    throw .truncated
  }
  var body = [UInt8](repeating: 0, count: total - 4)
  guard readExactly(fd, &body, count: total - 4) else { throw .truncated }
  return prefix + body
}

func readExactly(_ fd: Int32, _ buffer: inout [UInt8], count: Int) -> Bool {
  var offset = 0
  while offset < count {
    let n = buffer.withUnsafeMutableBytes {
      read(fd, $0.baseAddress! + offset, count - offset)
    }
    if n > 0 {
      offset += n
      continue
    }
    if n < 0, errno == EINTR { continue }
    return false
  }
  return true
}

func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
  var offset = 0
  while offset < bytes.count {
    let n = bytes.withUnsafeBytes {
      write(fd, $0.baseAddress! + offset, bytes.count - offset)
    }
    if n > 0 {
      offset += n
      continue
    }
    if n < 0, errno == EINTR { continue }
    return false
  }
  return true
}
#endif
