import Foundation
import NIOCore
import NIOSSH
import ScreenProtocol
import SessionCore

/// Byte limits for a no-PTY exec channel.
public struct SSHExecLimits: Hashable, Sendable {
  /// Exceeding this fails the exec with `.outputLimitExceeded`.
  public var maxStdoutBytes: Int
  /// stderr is diagnostics only: excess bytes are dropped and
  /// `SSHExecResult.stderrTruncated` is set.
  public var maxStderrBytes: Int
  /// Upper bound on the whole exchange.
  public var timeout: Duration

  public init(
    maxStdoutBytes: Int = 1024 * 1024,
    maxStderrBytes: Int = 16 * 1024,
    timeout: Duration = .seconds(30)
  ) {
    self.maxStdoutBytes = maxStdoutBytes
    self.maxStderrBytes = maxStderrBytes
    self.timeout = timeout
  }
}

/// Outcome of an exec channel, with stdout and stderr kept separate.
public struct SSHExecResult: Hashable, Sendable {
  public var stdout: [UInt8]
  public var stderr: [UInt8]
  public var stderrTruncated: Bool
  /// `nil` when the server sent no exit status.
  public var exitStatus: Int?
  public var exitSignal: String?
}

/// Runs one exec request on a session channel without a PTY: sends
/// stdin then EOF, and collects bounded stdout/stderr until close.
final class ExecChannelHandler: ChannelDuplexHandler {
  typealias InboundIn = SSHChannelData
  typealias OutboundIn = SSHChannelData

  private let command: String
  private let stdin: [UInt8]
  private let limits: SSHExecLimits
  private let promise: EventLoopPromise<SSHExecResult>
  private var result = SSHExecResult(
    stdout: [],
    stderr: [],
    stderrTruncated: false,
    exitStatus: nil,
    exitSignal: nil
  )
  private var started = false
  private var closing = false
  private var failure: SSHClientError?
  private var timer: Scheduled<Void>?

  init(
    command: String,
    stdin: [UInt8],
    limits: SSHExecLimits,
    promise: EventLoopPromise<SSHExecResult>
  ) {
    self.command = command
    self.stdin = stdin
    self.limits = limits
    self.promise = promise
  }

  func handlerAdded(context: ChannelHandlerContext) {
    context.channel
      .setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
      .whenFailure { [channel = context.channel] _ in
        channel.close(promise: nil)
      }
  }

  func channelActive(context: ChannelHandlerContext) {
    guard !closing else {
      context.fireChannelActive()
      return
    }
    let bound = NIOLoopBound((self, context), eventLoop: context.eventLoop)
    timer = context.eventLoop.scheduleTask(
      in: TimeAmount(clamping: limits.timeout)
    ) {
      let (handler, context) = bound.value
      handler.fail(.execTimeout, context: context)
    }
    context.triggerUserOutboundEvent(
      SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true),
      promise: nil
    )
    context.fireChannelActive()
  }

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    switch event {
    case is ChannelSuccessEvent where !started && !closing:
      started = true
      if !stdin.isEmpty {
        var buffer = context.channel.allocator.buffer(capacity: stdin.count)
        buffer.writeBytes(stdin)
        context.writeAndFlush(
          NIOAny(SSHChannelData(type: .channel, data: .byteBuffer(buffer))),
          promise: nil
        )
      }
      context.close(mode: .output, promise: nil)
    case is ChannelFailureEvent where !started && !closing:
      fail(.channelRequestRejected("exec"), context: context)
    case let event as SSHChannelRequestEvent.ExitStatus:
      result.exitStatus = event.exitStatus
    case let event as SSHChannelRequestEvent.ExitSignal:
      result.exitSignal = String(event.signalName.prefix(64))
    default: context.fireUserInboundEventTriggered(event)
    }
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let message = unwrapInboundIn(data)
    guard !closing, failure == nil, case let .byteBuffer(buffer) = message.data
    else { return }
    switch message.type {
    case .channel:
      guard result.stdout.count + buffer.readableBytes <= limits.maxStdoutBytes
      else {
        fail(.outputLimitExceeded, context: context)
        return
      }
      result.stdout += buffer.readableBytesView
    case .stdErr:
      let room = max(0, limits.maxStderrBytes - result.stderr.count)
      if buffer.readableBytes > room { result.stderrTruncated = true }
      result.stderr += buffer.readableBytesView.prefix(room)
    default: break
    }
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    fail(.connectionClosed, context: context)
  }

  func channelInactive(context: ChannelHandlerContext) {
    closing = true
    timer?.cancel()
    if let failure {
      promise.fail(failure)
    } else if !started {
      promise.fail(SSHClientError.channelRequestRejected("exec"))
    } else {
      promise.succeed(result)
    }
    context.fireChannelInactive()
  }

  private func fail(_ error: SSHClientError, context: ChannelHandlerContext) {
    if failure == nil { failure = error }
    closing = true
    timer?.cancel()
    context.close(promise: nil)
  }

  func close(
    context: ChannelHandlerContext,
    mode: CloseMode,
    promise: EventLoopPromise<Void>?
  ) {
    if mode == .all {
      // Cancellation can close the channel before a queued exec reply arrives.
      // A late success must not write stdin/EOF into the SDK's closing state.
      closing = true
      timer?.cancel()
    }
    context.close(mode: mode, promise: promise)
  }
}

extension SSHConnection {
  /// Runs `command` on a no-PTY exec channel. `command` must be a fixed
  /// constant: never interpolate passwords, tokens, paths or session
  /// identifiers into it (spec §5.1); pass structured data via `stdin`.
  /// The timeout includes channel acceptance; aborting before acceptance
  /// closes SSH. Once accepted, the exec channel closes, and SSH closes too
  /// if that close fails or is not acknowledged within five seconds.
  public func execute(
    command: String,
    stdin: [UInt8] = [],
    limits: SSHExecLimits = SSHExecLimits()
  ) async throws -> SSHExecResult {
    let promise = channel.eventLoop.makePromise(of: SSHExecResult.self)
    do {
      return try await withSessionChannel(
        timeout: limits.timeout,
        timeoutError: SSHClientError.execTimeout,
        initialize: { child in
          try child.pipeline.syncOperations.addHandler(
            ExecChannelHandler(
              command: command,
              stdin: stdin,
              limits: limits,
              promise: promise
            )
          )
        },
        operation: { _, attempt in
          try await attempt.wait(for: promise.futureResult)
        }
      )
    } catch {
      promise.fail(error)
      throw error
    }
  }

  /// Bound on helper stderr retained for diagnostics.
  public static let bootstrapDiagnosticsLimit = 8 * 1024

  /// Runs exactly `<helperPath> bootstrap --stdio`, writes the
  /// envelope-encoded `request` to stdin, and requires stdout to be
  /// exactly one `BootstrapEnvelope` (spec §5.1). Any other stdout is a
  /// protocol error; stderr is bounded diagnostics only.
  public func runBootstrap(
    helperPath: String,
    request: BootstrapRequest,
    timeout: Duration = .seconds(30)
  ) async throws -> BootstrapResponse {
    guard Self.isValidHelperPath(helperPath) else {
      throw SSHClientError.invalidHelperPath
    }
    do { try request.validate() } catch {
      throw SSHClientError.invalidConfiguration("bootstrap request")
    }
    let input = try BootstrapEnvelope.encode(request)
    let result = try await execute(
      command: helperPath + " bootstrap --stdio",
      stdin: input,
      limits: SSHExecLimits(
        maxStdoutBytes: 4 + RSTLimits.maxBootstrapEnvelopeBytes,
        maxStderrBytes: Self.bootstrapDiagnosticsLimit,
        timeout: timeout
      )
    )
    let diagnostics = String(decoding: result.stderr, as: UTF8.self)
    if result.stdout.isEmpty {
      throw SSHClientError.bootstrapFailed(
        exitStatus: result.exitStatus,
        diagnostics: diagnostics
      )
    }
    do {
      return try BootstrapEnvelope.decode(
        BootstrapResponse.self,
        from: result.stdout
      )
    } catch {
      throw SSHClientError.bootstrapProtocol(String(describing: error))
    }
  }

  /// Absolute path of safe characters only: no whitespace, shell
  /// metacharacters, `..` components or control characters.
  public static func isValidHelperPath(_ path: String) -> Bool {
    guard path.hasPrefix("/"), path.utf8.count <= 1024 else { return false }
    let allowed = Set(
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+".utf8
    )
    guard path.utf8.allSatisfy(allowed.contains) else { return false }
    return !path.split(separator: "/").contains("..")
  }
}
