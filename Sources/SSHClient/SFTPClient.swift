import Foundation
import NIOCore
import NIOSSH
import SessionCore
import Synchronization

public enum SFTPError: Error, Equatable, Sendable {
  /// The server answered with a non-OK status.
  case status(SFTPStatus)
  case protocolError(SFTPCodecError)
  case unexpectedResponse
  case unsupportedVersion(UInt32)
  /// More than the bounded number of requests are waiting.
  case queueFull
  case connectionClosed
  case invalidPath
  case invalidLength
  case subsystemRejected
  /// A request or the subsystem handshake exceeded its deadline.
  case requestTimedOut

  public var statusCode: SFTPStatusCode? {
    if case let .status(status) = self { status.code } else { nil }
  }
}

/// Opaque server handle; valid only on the subsystem that issued it.
public struct SFTPFileHandle: Hashable, Sendable { public let bytes: [UInt8] }

/// SFTP v3 client over one `sftp` subsystem channel (spec §10). At most
/// `RSTLimits.sftpOutstandingRequests` requests are on the wire; up to
/// `maxQueuedRequests` more wait in a bounded queue.
///
/// Reconnecting requires a new client: handles never survive a channel.
public final class SFTPClient: Sendable {
  public static let maxQueuedRequests = 32
  /// Largest single read/write payload accepted by this client.
  public static let maxIOLength = 64 * 1024

  let channel: any Channel
  /// Extensions advertised in the server's `VERSION` packet.
  public let serverExtensions: [SFTPExtensionPair]

  init(channel: any Channel, serverExtensions: [SFTPExtensionPair]) {
    self.channel = channel
    self.serverExtensions = serverExtensions
  }

  public var supportsPOSIXRename: Bool {
    serverExtensions.contains { $0.name == "posix-rename@openssh.com" }
  }

  public var isActive: Bool { channel.isActive }

  /// Closes the subsystem channel; outstanding requests fail. Idempotent.
  /// SSH closes too if the peer does not acknowledge within five seconds,
  /// or if closing an activated channel fails.
  public func close() async {
    channel.close(promise: nil)
    try? await channel.closeFuture.get()
  }

  /// Cancellation releases the transfer immediately, but the server
  /// still owns its handle. Cleanup runs independently with the same
  /// bounded request window and deadline as ordinary requests.
  func closeAfterFailure(_ handle: SFTPFileHandle) async {
    if Task.isCancelled {
      Task.detached { try? await self.close(handle) }
    } else {
      try? await close(handle)
    }
  }

  // MARK: Operations

  public func realpath(_ path: String) async throws -> String {
    try validate(path)
    let response = try await send(.realpath(id: 0, path: path))
    guard case let .name(_, entries) = response, entries.count == 1 else {
      throw SFTPError.unexpectedResponse
    }
    return entries[0].filename
  }

  public func stat(_ path: String) async throws -> SFTPAttributes {
    try validate(path)
    return try attributes(await send(.stat(id: 0, path: path)))
  }

  public func lstat(_ path: String) async throws -> SFTPAttributes {
    try validate(path)
    return try attributes(await send(.lstat(id: 0, path: path)))
  }

  public func fstat(_ handle: SFTPFileHandle) async throws -> SFTPAttributes {
    try attributes(await send(.fstat(id: 0, handle: handle.bytes)))
  }

  public func open(
    _ path: String,
    flags: SFTPOpenFlags,
    attributes: SFTPAttributes = SFTPAttributes()
  ) async throws -> SFTPFileHandle {
    try validate(path)
    return try handle(
      await send(.open(id: 0, path: path, flags: flags, attributes))
    )
  }

  public func openDirectory(_ path: String) async throws -> SFTPFileHandle {
    try validate(path)
    return try handle(await send(.opendir(id: 0, path: path)))
  }

  /// The next batch of entries, or `nil` at end of directory.
  public func readDirectory(
    _ handle: SFTPFileHandle
  ) async throws -> [SFTPNameEntry]? {
    switch try await send(.readdir(id: 0, handle: handle.bytes), allowEOF: true)
    {
    case let .name(_, entries):
      guard !entries.isEmpty else { throw SFTPError.unexpectedResponse }
      return entries
    case .status(_, let status) where status.code == .eof: return nil
    default: throw SFTPError.unexpectedResponse
    }
  }

  /// Lists at most `maxEntries` entries, excluding up to two dot entries.
  public func listDirectory(
    _ path: String,
    maxEntries: Int = 10_000
  ) async throws -> [SFTPNameEntry] {
    guard maxEntries >= 0 else { throw SFTPError.invalidLength }
    let handle = try await openDirectory(path)
    var entries: [SFTPNameEntry] = []
    var ignored = 0
    do {
      while let batch = try await readDirectory(handle) {
        for entry in batch {
          if entry.filename == "." || entry.filename == ".." {
            ignored += 1
            guard ignored <= 2 else { throw SFTPError.unexpectedResponse }
            continue
          }
          guard entries.count < maxEntries else {
            throw SFTPError.status(
              SFTPStatus(code: .failure, message: "too many entries")
            )
          }
          entries.append(entry)
        }
      }
    } catch {
      await closeAfterFailure(handle)
      throw error
    }
    try await close(handle)
    return entries
  }

  /// Closes a handle; a non-OK status is thrown so callers can treat
  /// failed closes as failed writes.
  public func close(_ handle: SFTPFileHandle) async throws {
    try expectOK(await send(.close(id: 0, handle: handle.bytes)))
  }

  /// Reads up to `length` bytes at `offset`; `nil` at end of file. May
  /// return fewer bytes than requested.
  public func read(
    _ handle: SFTPFileHandle,
    offset: UInt64,
    length: Int
  ) async throws -> [UInt8]? {
    guard (1 ... Self.maxIOLength).contains(length) else {
      throw SFTPError.invalidLength
    }
    let response = try await send(
      .read(
        id: 0,
        handle: handle.bytes,
        offset: offset,
        length: UInt32(length)
      ),
      allowEOF: true
    )
    switch response {
    case let .data(_, data):
      guard data.count <= length else { throw SFTPError.unexpectedResponse }
      return data
    case .status(_, let status) where status.code == .eof: return nil
    default: throw SFTPError.unexpectedResponse
    }
  }

  /// Positioned write; never uses append mode.
  public func write(
    _ handle: SFTPFileHandle,
    offset: UInt64,
    data: [UInt8]
  ) async throws {
    guard data.count <= Self.maxIOLength else { throw SFTPError.invalidLength }
    try expectOK(
      await send(
        .write(id: 0, handle: handle.bytes, offset: offset, data: data)
      )
    )
  }

  /// SFTP v3 rename; fails if `newPath` exists on OpenSSH servers.
  public func rename(_ oldPath: String, to newPath: String) async throws {
    try validate(oldPath)
    try validate(newPath)
    try expectOK(await send(.rename(id: 0, oldPath: oldPath, newPath: newPath)))
  }

  /// `posix-rename@openssh.com`: atomically replaces `newPath`.
  public func posixRename(_ oldPath: String, to newPath: String) async throws {
    try validate(oldPath)
    try validate(newPath)
    var w = SFTPWriter()
    try w.string(oldPath, max: SFTPLimits.maxPathBytes)
    try w.string(newPath, max: SFTPLimits.maxPathBytes)
    try expectOK(
      await send(
        .extended(id: 0, name: "posix-rename@openssh.com", data: w.bytes)
      )
    )
  }

  public func remove(_ path: String) async throws {
    try validate(path)
    try expectOK(await send(.remove(id: 0, path: path)))
  }

  // MARK: Plumbing

  private func validate(_ path: String) throws {
    guard !path.isEmpty, path.utf8.count <= SFTPLimits.maxPathBytes,
      !path.utf8.contains(0)
    else { throw SFTPError.invalidPath }
  }

  private func attributes(_ message: SFTPMessage) throws -> SFTPAttributes {
    guard case let .attrs(_, attributes) = message else {
      throw SFTPError.unexpectedResponse
    }
    return attributes
  }

  private func handle(_ message: SFTPMessage) throws -> SFTPFileHandle {
    guard case let .handle(_, bytes) = message else {
      throw SFTPError.unexpectedResponse
    }
    return SFTPFileHandle(bytes: bytes)
  }

  private func expectOK(_ message: SFTPMessage) throws {
    guard case .status = message else { throw SFTPError.unexpectedResponse }
  }

  /// Sends `request` (its id is assigned by the handler) and returns the
  /// response. Non-OK statuses throw, except EOF when `allowEOF`.
  private func send(
    _ request: SFTPMessage,
    allowEOF: Bool = false
  ) async throws -> SFTPMessage {
    try Task.checkCancellation()
    do { _ = try request.validatedBodyLength() } catch {
      throw SFTPError.protocolError(error)
    }
    let channel = self.channel
    let cancellation = SFTPRequestCancellation()
    let response = try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await channel.eventLoop
        .flatSubmit { () -> EventLoopFuture<SFTPMessage> in
          guard
            let handler = try? channel.pipeline.syncOperations.handler(
              type: SFTPChannelHandler.self
            )
          else {
            return channel.eventLoop.makeFailedFuture(
              SFTPError.connectionClosed
            )
          }
          return handler.enqueue(request, cancellation: cancellation)
        }
        .get()
    } onCancel: {
      cancellation.cancelled.withLock { $0 = true }
      channel.eventLoop.execute {
        let handler = try? channel.pipeline.syncOperations.handler(
          type: SFTPChannelHandler.self
        )
        handler?.cancel(cancellation)
      }
    }
    if case let .status(_, status) = response, status.code != .ok {
      if allowEOF, status.code == .eof { return response }
      throw SFTPError.status(status)
    }
    return response
  }
}

/// Records cancellation even when it arrives before event-loop enqueue.
final class SFTPRequestCancellation: Sendable { let cancelled = Mutex(false) }

/// Channel setup, timeout, and handler teardown can all fail readiness.
/// Only the first outcome may complete the shared handshake promise.
final class SFTPHandshake: Sendable {
  private let promise: EventLoopPromise<[SFTPExtensionPair]>
  private let completed = Mutex(false)

  init(eventLoop: any EventLoop) {
    promise = eventLoop.makePromise(of: [SFTPExtensionPair].self)
  }

  var futureResult: EventLoopFuture<[SFTPExtensionPair]> {
    promise.futureResult
  }

  func succeed(_ extensions: [SFTPExtensionPair]) {
    complete(.success(extensions))
  }
  func fail(_ error: any Error) { complete(.failure(error)) }

  private func complete(_ result: Result<[SFTPExtensionPair], any Error>) {
    let first = completed.withLock { completed in
      guard !completed else { return false }
      completed = true
      return true
    }
    if first { promise.completeWith(result) }
  }
}

/// Subsystem handler: framing, request ids, the outstanding window and
/// the bounded wait queue. Runs on the channel's event loop.
final class SFTPChannelHandler: ChannelDuplexHandler {
  typealias InboundIn = SSHChannelData
  typealias OutboundIn = SSHChannelData

  private enum Phase {
    case requestingSubsystem, awaitingVersion, ready, closed
  }

  private let ready: SFTPHandshake
  private let maxOutstanding: Int
  private let requestTimeout: TimeAmount
  private var phase = Phase.requestingSubsystem
  private var reader = SFTPPacketReader()
  private var nextID: UInt32 = 1
  private struct Pending {
    let cancellation: SFTPRequestCancellation
    var promise: EventLoopPromise<SFTPMessage>?
    let timer: Scheduled<Void>
  }
  private var outstanding: [UInt32: Pending] = [:]
  private var queue = CircularBuffer<(SFTPMessage, Pending)>()
  private var context: ChannelHandlerContext?
  private var handshakeTimer: Scheduled<Void>?

  init(
    ready: SFTPHandshake,
    maxOutstanding: Int = RSTLimits.sftpOutstandingRequests,
    requestTimeout: Duration = .seconds(30)
  ) {
    self.ready = ready
    self.maxOutstanding = maxOutstanding
    self.requestTimeout = TimeAmount(
      clamping: max(requestTimeout, .milliseconds(1))
    )
  }

  func handlerAdded(context: ChannelHandlerContext) {
    self.context = context
    handshakeTimer = deadline(context)
  }

  func handlerRemoved(context: ChannelHandlerContext) {
    phase = .closed
    failAll(SFTPError.connectionClosed)
    self.context = nil
  }

  func channelActive(context: ChannelHandlerContext) {
    guard phase != .closed else {
      context.fireChannelActive()
      return
    }
    context.triggerUserOutboundEvent(
      SSHChannelRequestEvent.SubsystemRequest(
        subsystem: "sftp",
        wantReply: true
      ),
      promise: nil
    )
    context.fireChannelActive()
  }

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    switch event {
    case is ChannelSuccessEvent where phase == .requestingSubsystem:
      phase = .awaitingVersion
      transmit(.initialize(version: 3, extensions: []), context: context)
    case is ChannelFailureEvent where phase == .requestingSubsystem:
      fail(SFTPError.subsystemRejected, context: context)
    default: context.fireUserInboundEventTriggered(event)
    }
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let message = unwrapInboundIn(data)
    guard phase != .closed, case .channel = message.type,
      case let .byteBuffer(buffer) = message.data
    else { return }
    reader.append(buffer.readableBytesView)
    do {
      while let packet = try reader.next() {
        try handle(packet, context: context)
        if phase == .closed { return }
      }
    } catch let error as SFTPCodecError {
      fail(SFTPError.protocolError(error), context: context)
    } catch { fail(error, context: context) }
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    fail(SFTPError.connectionClosed, context: context)
  }

  func channelInactive(context: ChannelHandlerContext) {
    phase = .closed
    failAll(SFTPError.connectionClosed)
    context.fireChannelInactive()
  }

  func close(
    context: ChannelHandlerContext,
    mode: CloseMode,
    promise: EventLoopPromise<Void>?
  ) {
    if mode == .all {
      phase = .closed
      failAll(SFTPError.connectionClosed)
    }
    context.close(mode: mode, promise: promise)
  }

  /// Queues or transmits a request, assigning its id.
  func enqueue(
    _ request: SFTPMessage,
    cancellation: SFTPRequestCancellation = SFTPRequestCancellation()
  ) -> EventLoopFuture<SFTPMessage> {
    let promise = ready.futureResult.eventLoop.makePromise(of: SFTPMessage.self)
    guard !cancellation.cancelled.withLock({ $0 }) else {
      promise.fail(CancellationError())
      return promise.futureResult
    }
    guard let context, phase == .ready else {
      promise.fail(SFTPError.connectionClosed)
      return promise.futureResult
    }
    do { _ = try request.validatedBodyLength() } catch {
      promise.fail(SFTPError.protocolError(error))
      return promise.futureResult
    }
    let pending = Pending(
      cancellation: cancellation,
      promise: promise,
      timer: deadline(context)
    )
    if outstanding.count < maxOutstanding {
      send(request, pending: pending, context: context)
    } else if queue.count < SFTPClient.maxQueuedRequests {
      queue.append((request, pending))
    } else {
      pending.timer.cancel()
      promise.fail(SFTPError.queueFull)
    }
    return promise.futureResult
  }

  func cancel(_ cancellation: SFTPRequestCancellation) {
    if let index = queue.firstIndex(where: {
      $0.1.cancellation === cancellation
    }) {
      let (_, pending) = queue.remove(at: index)
      pending.timer.cancel()
      pending.promise?.fail(CancellationError())
      return
    }
    if let id = outstanding.first(where: {
      $0.value.cancellation === cancellation
    })?
    .key {
      let promise = outstanding[id]?.promise
      // Keep the occupied slot until its reply arrives or its deadline
      // closes the channel. Otherwise late replies become unknown IDs,
      // and repeated cancellations can bypass the wire request bound.
      outstanding[id]?.promise = nil
      promise?.fail(CancellationError())
    }
  }

  private func deadline(_ context: ChannelHandlerContext) -> Scheduled<Void> {
    let bound = NIOLoopBound((self, context), eventLoop: context.eventLoop)
    return context.eventLoop.scheduleTask(in: requestTimeout) {
      let (handler, context) = bound.value
      handler.fail(SFTPError.requestTimedOut, context: context)
    }
  }

  private func send(
    _ request: SFTPMessage,
    pending: Pending,
    context: ChannelHandlerContext
  ) {
    var id = nextID
    while outstanding[id] != nil { id &+= 1 }
    nextID = id &+ 1
    outstanding[id] = pending
    transmit(request.replacingID(id), context: context)
  }

  private func transmit(_ message: SFTPMessage, context: ChannelHandlerContext)
  {
    let bytes: [UInt8]
    do { bytes = try message.encoded() } catch {
      fail(SFTPError.protocolError(error), context: context)
      return
    }
    var buffer = context.channel.allocator.buffer(capacity: bytes.count)
    buffer.writeBytes(bytes)
    context.writeAndFlush(
      NIOAny(SSHChannelData(type: .channel, data: .byteBuffer(buffer))),
      promise: nil
    )
  }

  private func handle(
    _ packet: SFTPMessage,
    context: ChannelHandlerContext
  ) throws {
    switch (phase, packet) {
    case let (.awaitingVersion, .version(version, extensions)):
      guard version == 3 else { throw SFTPError.unsupportedVersion(version) }
      phase = .ready
      handshakeTimer?.cancel()
      handshakeTimer = nil
      ready.succeed(extensions)
    case (.ready, .status), (.ready, .handle), (.ready, .data), (.ready, .name),
      (.ready, .attrs):
      guard let id = packet.id,
        let pending = outstanding.removeValue(forKey: id)
      else { throw SFTPError.unexpectedResponse }
      pending.timer.cancel()
      if let promise = pending.promise,
        !pending.cancellation.cancelled.withLock({ $0 })
      {
        promise.succeed(packet)
      } else {
        pending.promise?.fail(CancellationError())
        if case let .handle(_, bytes) = packet {
          // A cancelled OPEN/OPENDIR can still allocate a remote handle.
          // Use its freed request slot to close it before draining the queue.
          _ = enqueue(.close(id: 0, handle: bytes))
        }
      }
      while outstanding.count < maxOutstanding,
        let (request, next) = queue.popFirst()
      {
        if next.cancellation.cancelled.withLock({ $0 }) {
          next.timer.cancel()
          next.promise?.fail(CancellationError())
        } else {
          send(request, pending: next, context: context)
        }
      }
    default: throw SFTPError.unexpectedResponse
    }
  }

  private func fail(_ error: any Error, context: ChannelHandlerContext) {
    phase = .closed
    failAll(error)
    context.close(promise: nil)
  }

  private func failAll(_ error: any Error) {
    handshakeTimer?.cancel()
    handshakeTimer = nil
    ready.fail(error)
    let pending = Array(outstanding.values)
    outstanding.removeAll()
    for request in pending {
      request.timer.cancel()
      request.promise?.fail(error)
    }
    while let (_, request) = queue.popFirst() {
      request.timer.cancel()
      request.promise?.fail(error)
    }
  }
}

extension SFTPMessage {
  /// The same request with request id `id`.
  func replacingID(_ id: UInt32) -> SFTPMessage {
    switch self {
    case .initialize, .version: self
    case let .open(_, path, flags, attrs):
      .open(id: id, path: path, flags: flags, attrs)
    case let .close(_, handle): .close(id: id, handle: handle)
    case let .read(_, handle, offset, length):
      .read(id: id, handle: handle, offset: offset, length: length)
    case let .write(_, handle, offset, data):
      .write(id: id, handle: handle, offset: offset, data: data)
    case let .lstat(_, path): .lstat(id: id, path: path)
    case let .fstat(_, handle): .fstat(id: id, handle: handle)
    case let .opendir(_, path): .opendir(id: id, path: path)
    case let .readdir(_, handle): .readdir(id: id, handle: handle)
    case let .remove(_, path): .remove(id: id, path: path)
    case let .realpath(_, path): .realpath(id: id, path: path)
    case let .stat(_, path): .stat(id: id, path: path)
    case let .rename(_, old, new): .rename(id: id, oldPath: old, newPath: new)
    case let .extended(_, name, data): .extended(id: id, name: name, data: data)
    case let .status(_, status): .status(id: id, status)
    case let .handle(_, handle): .handle(id: id, handle)
    case let .data(_, data): .data(id: id, data)
    case let .name(_, entries): .name(id: id, entries)
    case let .attrs(_, attrs): .attrs(id: id, attrs)
    }
  }
}

extension SSHConnection {
  /// Opens an `sftp` subsystem channel and completes the v3
  /// `INIT`/`VERSION` exchange. Requests, including the handshake, default
  /// to a 30-second deadline. Before channel acceptance, aborting must close
  /// SSH; after it, expiry closes this subsystem, and SSH too unless the
  /// peer acknowledges that close within five seconds.
  public func openSFTP(
    requestTimeout: Duration = .seconds(30)
  ) async throws -> SFTPClient {
    try Task.checkCancellation()
    let ready = SFTPHandshake(eventLoop: channel.eventLoop)
    do {
      return try await withSessionChannel(
        timeout: max(requestTimeout, .milliseconds(1)),
        timeoutError: SFTPError.requestTimedOut,
        initialize: { child in
          try child.pipeline.syncOperations.addHandler(
            SFTPChannelHandler(ready: ready, requestTimeout: requestTimeout)
          )
        },
        operation: { child, attempt in
          let extensions = try await attempt.wait(for: ready.futureResult)
          return SFTPClient(channel: child, serverExtensions: extensions)
        }
      )
    } catch {
      ready.fail(error)
      throw error
    }
  }
}
