import Foundation
import NIOCore
import NIOSSH

/// Events from an interactive shell channel, delivered on the
/// connection's event loop. Handlers must not block.
public enum SSHShellEvent: Sendable, Equatable {
  /// Terminal bytes (stdout and any extended data, in arrival order).
  case output([UInt8])
  case exitStatus(Int)
  case exitSignal(String)
  /// The channel closed; no further events follow.
  case closed
}

/// Interactive PTY shell. Output is pulled with explicit read credit so
/// a slow terminal parser applies SSH-window backpressure to the server
/// instead of buffering without bound (spec §A.3.B).
///
/// Credit is a byte budget: reads continue while it is positive. One read
/// may deliver everything the server already sent within the channel
/// window, so credit can go negative by at most one window.
public final class SSHShellChannel: Sendable {
  /// Bound on a single `write(_:)`.
  public static let maxWriteBytes = 64 * 1024
  public static let maxColumns = 4096
  public static let maxRows = 4096

  let channel: any Channel

  init(channel: any Channel) { self.channel = channel }

  /// Completes when the channel closes.
  public var closeFuture: EventLoopFuture<Void> { channel.closeFuture }

  /// Adds `bytes` of read credit; the parser calls this as it consumes
  /// delivered output.
  public func grantReadCredit(_ bytes: Int) {
    guard bytes > 0 else { return }
    let channel = self.channel
    channel.eventLoop.execute {
      (try? channel.pipeline.syncOperations.handler(
        type: ShellChannelHandler.self
      ))?
      .grant(bytes)
    }
  }

  /// Sends terminal input, waiting while the channel is not writable and
  /// until the bytes are handed to the SSH connection.
  public func write(_ bytes: [UInt8]) async throws {
    guard bytes.count <= Self.maxWriteBytes else {
      throw SSHClientError.writeTooLarge(bytes.count)
    }
    guard !bytes.isEmpty else { return }
    let channel = self.channel
    try await channel.eventLoop
      .flatSubmit { () -> EventLoopFuture<Void> in
        guard
          let handler = try? channel.pipeline.syncOperations.handler(
            type: ShellChannelHandler.self
          )
        else {
          return channel.eventLoop.makeFailedFuture(
            SSHClientError.connectionClosed
          )
        }
        return handler.write(bytes)
      }
      .get()
  }

  /// Sends an SSH `window-change` request.
  public func resize(columns: Int, rows: Int) async throws {
    guard (1 ... Self.maxColumns).contains(columns),
      (1 ... Self.maxRows).contains(rows)
    else { throw SSHClientError.invalidGridSize }
    let event = SSHChannelRequestEvent.WindowChangeRequest(
      terminalCharacterWidth: columns,
      terminalRowHeight: rows,
      terminalPixelWidth: 0,
      terminalPixelHeight: 0
    )
    do { try await channel.triggerUserOutboundEvent(event).get() } catch {
      throw SSHClientError.connectionClosed
    }
  }

  /// Closes the channel. Idempotent. SSH closes too if the peer does not
  /// acknowledge within five seconds, or if closing an activated channel fails.
  public func close() async {
    channel.close(promise: nil)
    try? await channel.closeFuture.get()
  }
}

final class ShellChannelHandler: ChannelDuplexHandler {
  typealias InboundIn = SSHChannelData
  typealias OutboundIn = SSHChannelData

  static let maxWritabilityWaiters = 64

  private let columns: Int
  private let rows: Int
  private let onEvent: @Sendable (SSHShellEvent) -> Void
  private let opened: EventLoopPromise<Void>
  private let eventLoop: any EventLoop
  private var openCompleted = false
  private var phase = Phase.requestingPTY
  private var credit: Int
  private var readOutstanding = false
  private var context: ChannelHandlerContext?
  /// Writes waiting for channel writability, in submission order.
  private var waiters: [([UInt8], EventLoopPromise<Void>)] = []

  enum Phase { case requestingPTY, requestingShell, open, closed }

  init(
    columns: Int,
    rows: Int,
    initialCredit: Int,
    opened: EventLoopPromise<Void>,
    onEvent: @escaping @Sendable (SSHShellEvent) -> Void
  ) {
    self.columns = columns
    self.rows = rows
    self.credit = initialCredit
    self.opened = opened
    self.eventLoop = opened.futureResult.eventLoop
    self.onEvent = onEvent
  }

  func handlerAdded(context: ChannelHandlerContext) {
    self.context = context
    context.channel.setOption(ChannelOptions.autoRead, value: false)
      .and(
        context.channel.setOption(
          ChannelOptions.allowRemoteHalfClosure,
          value: true
        )
      )
      .whenFailure { [channel = context.channel] _ in
        channel.close(promise: nil)
      }
  }

  func handlerRemoved(context: ChannelHandlerContext) { self.context = nil }

  func channelActive(context: ChannelHandlerContext) {
    guard phase != .closed else {
      context.fireChannelActive()
      return
    }
    let request = SSHChannelRequestEvent.PseudoTerminalRequest(
      wantReply: true,
      term: "xterm-256color",
      terminalCharacterWidth: columns,
      terminalRowHeight: rows,
      terminalPixelWidth: 0,
      terminalPixelHeight: 0,
      terminalModes: SSHTerminalModes([:])
    )
    context.triggerUserOutboundEvent(request, promise: nil)
    context.fireChannelActive()
  }

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    switch event {
    case is ChannelSuccessEvent:
      switch phase {
      case .requestingPTY:
        phase = .requestingShell
        context.triggerUserOutboundEvent(
          SSHChannelRequestEvent.ShellRequest(wantReply: true),
          promise: nil
        )
      case .requestingShell:
        phase = .open
        openCompleted = true
        opened.succeed()
        readIfPermitted(context)
      default: break
      }
    case is ChannelFailureEvent:
      if phase == .requestingPTY || phase == .requestingShell {
        openCompleted = true
        opened.fail(
          SSHClientError.channelRequestRejected(
            phase == .requestingPTY ? "pty-req" : "shell"
          )
        )
        phase = .closed
        context.close(promise: nil)
      }
    case let event as SSHChannelRequestEvent.ExitStatus:
      onEvent(.exitStatus(event.exitStatus))
    case let event as SSHChannelRequestEvent.ExitSignal:
      onEvent(.exitSignal(String(event.signalName.prefix(64))))
    default: context.fireUserInboundEventTriggered(event)
    }
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let message = unwrapInboundIn(data)
    guard phase != .closed, case let .byteBuffer(buffer) = message.data,
      buffer.readableBytes > 0
    else { return }
    credit -= buffer.readableBytes
    onEvent(.output(Array(buffer.readableBytesView)))
  }

  func channelReadComplete(context: ChannelHandlerContext) {
    readOutstanding = false
    readIfPermitted(context)
    context.fireChannelReadComplete()
  }

  func channelWritabilityChanged(context: ChannelHandlerContext) {
    if context.channel.isWritable { releaseWaiters(error: nil) }
    context.fireChannelWritabilityChanged()
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    phase = .closed
    context.close(promise: nil)
  }

  func close(
    context: ChannelHandlerContext,
    mode: CloseMode,
    promise: EventLoopPromise<Void>?
  ) {
    if mode == .all {
      phase = .closed
      releaseWaiters(error: SSHClientError.connectionClosed)
    }
    context.close(mode: mode, promise: promise)
  }

  func channelInactive(context: ChannelHandlerContext) {
    if !openCompleted {
      openCompleted = true
      opened.fail(SSHClientError.connectionClosed)
    }
    phase = .closed
    releaseWaiters(error: SSHClientError.connectionClosed)
    onEvent(.closed)
    context.fireChannelInactive()
  }

  func grant(_ bytes: Int) {
    let (sum, overflow) = credit.addingReportingOverflow(bytes)
    credit = overflow ? .max : sum
    if let context { readIfPermitted(context) }
  }

  func write(_ bytes: [UInt8]) -> EventLoopFuture<Void> {
    guard let context, phase == .open else {
      return eventLoop.makeFailedFuture(SSHClientError.connectionClosed)
    }
    if context.channel.isWritable, waiters.isEmpty {
      return send(bytes, context: context)
    }
    guard waiters.count < Self.maxWritabilityWaiters else {
      return context.eventLoop.makeFailedFuture(
        SSHClientError.writeTooLarge(bytes.count)
      )
    }
    let waiter = context.eventLoop.makePromise(of: Void.self)
    waiters.append((bytes, waiter))
    return waiter.futureResult
  }

  private func send(
    _ bytes: [UInt8],
    context: ChannelHandlerContext
  ) -> EventLoopFuture<Void> {
    var buffer = context.channel.allocator.buffer(capacity: bytes.count)
    buffer.writeBytes(bytes)
    return context.writeAndFlush(
      NIOAny(SSHChannelData(type: .channel, data: .byteBuffer(buffer)))
    )
  }

  private func readIfPermitted(_ context: ChannelHandlerContext) {
    guard phase == .open, credit > 0, !readOutstanding else { return }
    readOutstanding = true
    context.read()
  }

  private func releaseWaiters(error: (any Error)?) {
    if let error {
      let pending = waiters
      waiters.removeAll()
      for (_, waiter) in pending { waiter.fail(error) }
      return
    }
    // Send queued writes in order while the channel stays writable.
    while let context, context.channel.isWritable, !waiters.isEmpty {
      let (bytes, waiter) = waiters.removeFirst()
      send(bytes, context: context).cascade(to: waiter)
    }
  }
}

extension SSHConnection {
  /// Opens an interactive shell with a PTY (`xterm-256color`).
  ///
  /// - Parameters:
  ///   - columns: Initial PTY width, within `SSHShellChannel.maxColumns`.
  ///   - rows: Initial PTY height, within `SSHShellChannel.maxRows`.
  ///   - initialReadCredit: nonnegative bytes of output the caller is ready to
  ///     accept before its first `grantReadCredit`. Zero starts paused.
  ///   - setupTimeout: Total bound on channel acceptance, PTY, and shell
  ///     replies. Aborting before acceptance closes SSH; after it the child
  ///     closes, and SSH too if the close acknowledgement takes more than
  ///     five seconds (`ChannelCloseHandler.acknowledgementTimeout`).
  ///   - onEvent: Called on the event loop; must return quickly.
  /// - Returns: The accepted channel after PTY and shell setup succeed.
  /// - Throws: An error for invalid dimensions, cancellation, setup timeout,
  ///   or failed channel, PTY, or shell requests.
  public func openShell(
    columns: Int,
    rows: Int,
    initialReadCredit: Int = 64 * 1024,
    setupTimeout: Duration = .seconds(30),
    onEvent: @escaping @Sendable (SSHShellEvent) -> Void
  ) async throws -> SSHShellChannel {
    guard initialReadCredit >= 0 else {
      throw SSHClientError.invalidConfiguration("negative shell read credit")
    }
    guard (1 ... SSHShellChannel.maxColumns).contains(columns),
      (1 ... SSHShellChannel.maxRows).contains(rows)
    else { throw SSHClientError.invalidGridSize }
    let opened = channel.eventLoop.makePromise(of: Void.self)
    do {
      return try await withSessionChannel(
        timeout: setupTimeout,
        timeoutError: SSHClientError.channelSetupTimeout,
        initialize: { child in
          try child.pipeline.syncOperations.addHandler(
            ShellChannelHandler(
              columns: columns,
              rows: rows,
              initialCredit: initialReadCredit,
              opened: opened,
              onEvent: onEvent
            )
          )
        },
        operation: { child, attempt in
          try await attempt.wait(for: opened.futureResult)
          return SSHShellChannel(channel: child)
        }
      )
    } catch {
      opened.fail(error)
      throw error
    }
  }
}
