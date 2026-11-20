import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import ScreenProtocol
import SessionCore
import Synchronization

@testable import SSHClient

/// Fault injection for the in-process SFTP server.
struct SFTPFaultPlan: Sendable {
  /// Close the whole SSH connection, without replying, when the request
  /// count exceeds this value (one-shot).
  var dropAfterRequests: Int?
  /// Perform the next rename, then drop the connection without replying
  /// (one-shot).
  var dropRenameResponse = false
  /// Close the next handle but report a server failure (one-shot).
  var rejectNextClose = false
  var holdNextReadResponse = false
  var holdNextWriteResponse = false
  var holdNextOpenResponse = false
  var holdNextRealpathResponse = false
  var holdAllReadResponses = false
  var withholdVersionResponse = false
  /// Finite scripted READDIR batches, then the ordinary directory contents.
  var readDirectoryBatches: [[SFTPNameEntry]] = []
  var rejectedDirectoryPaths: Set<String> = []
  var rejectSessionChannel = false
  var holdSessionChannelOpen = false
  var withholdPTYReply = false
  var withholdShellReply = false
  var rejectPTY = false
  var rejectShell = false
  var dropAllServerWrites = false
  var holdNextPasswordAuth = false
  var reportedFileSize: UInt64?
}

enum SessionSetupReply: Sendable, Equatable { case exec, pty, shell, sftp }

/// Observable server-side state shared with tests.
final class TestServerState: Sendable {
  struct Connections: Sendable {
    var stopping = false
    var channels: [ObjectIdentifier: any Channel] = [:]
  }

  struct SFTPDrop: Sendable {
    enum Cause: Sendable { case requestLimit, rename }
    enum Operation: Sendable {
      case open, close, read, write, fstat, stat, rename, realpath, other
    }
    let operation: Operation
    let id = UUID()
    let cause: Cause
    let requestID: UInt32
    let parentPresent: Bool
    var parentClosed = false
    var childClosed = false
  }

  /// One bounded observation, without paths, contents or credentials.
  let lastSFTPDrop = Mutex<SFTPDrop?>(nil)
  let connections = Mutex(Connections())
  let authRequests = Mutex(0)
  let heldPasswordAuth = Mutex<
    EventLoopPromise<NIOSSHUserAuthenticationOutcome>?
  >(nil)
  let sftpRequests = Mutex(0)
  let sftpInitializations = Mutex(0)
  let renames = Mutex(0)
  let writes = Mutex(0)
  let reads = Mutex(0)
  let directoryReads = Mutex(0)
  let heldSFTPResponse = Mutex<(@Sendable () -> Void)?>(nil)
  let heldSFTPResponses = Mutex<[@Sendable () -> Void]>([])
  let sftpOpenHandles = Mutex(0)
  let faults = Mutex(SFTPFaultPlan())
  let heldSessionOpens = Mutex<[EventLoopPromise<Void>]>([])
  let sessionChannels = Mutex<[ObjectIdentifier: any Channel]>([:])
  let shellRequests = Mutex(0)
  let lastExecCommand = Mutex<String?>(nil)
  let execStdinFinished = Mutex(false)
  let beforeSetupReply = Mutex<(@Sendable (SessionSetupReply) -> Void)?>(nil)
  let droppedServerWrites = Mutex(0)
  let ptyRequest = Mutex<SSHChannelRequestEvent.PseudoTerminalRequest?>(nil)
  let windowSize = Mutex<(Int, Int)?>(nil)
  /// Exit immediately after accepting a shell, without emitting output.
  let shellExitStatus = Mutex<Int?>(nil)
  let bootstrapRequests = Mutex<[BootstrapRequest]>([])
  /// Failure for create/resume requests; list and terminate keep their replies.
  let bootstrapFailure = Mutex<BootstrapErrorCode>(.unknownSession)
  /// When set, either helper path hands its stdin envelope to this responder
  /// (a real `BootstrapService`, or a delayed response in lifecycle tests).
  let bootstrapForwarder = Mutex<(@Sendable ([UInt8]) async -> [UInt8])?>(nil)
}

final class TestAuthDelegate: NIOSSHServerUserAuthenticationDelegate, Sendable {
  let username: String
  let password: String
  let authorizedKeys: [NIOSSHPublicKey]
  let state: TestServerState

  init(
    username: String,
    password: String,
    authorizedKeys: [NIOSSHPublicKey],
    state: TestServerState
  ) {
    self.username = username
    self.password = password
    self.authorizedKeys = authorizedKeys
    self.state = state
  }

  var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods {
    [.password, .publicKey]
  }

  func requestReceived(
    request: NIOSSHUserAuthenticationRequest,
    responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
  ) {
    state.authRequests.withLock { $0 += 1 }
    guard request.username == username else {
      responsePromise.succeed(.failure)
      return
    }
    switch request.request {
    case let .password(offer):
      let hold = state.faults.withLock { faults in
        let hold = faults.holdNextPasswordAuth
        faults.holdNextPasswordAuth = false
        return hold
      }
      if hold {
        let registered = state.connections.withLock { connections in
          guard !connections.stopping else { return false }
          state.heldPasswordAuth.withLock { $0 = responsePromise }
          return true
        }
        if !registered { responsePromise.fail(SSHClientError.connectionClosed) }
        return
      }
      responsePromise.succeed(offer.password == password ? .success : .failure)
    case let .publicKey(offer):
      responsePromise.succeed(
        authorizedKeys.contains(offer.publicKey) ? .success : .failure
      )
    default: responsePromise.succeed(.failure)
    }
  }
}

/// In-process NIOSSH server on 127.0.0.1 with an ephemeral port.
final class TestSSHServer: Sendable {
  static let username = "tester"
  static let password = "correct horse"
  static let helperPath = "/usr/local/libexec/swifttyd"
  static let forwardHelperPath = "/opt/forward/swifttyd"

  let channel: any Channel
  let port: Int
  let hostKey: NIOSSHPrivateKey
  let state: TestServerState
  /// SFTP root; absolute request paths resolve beneath it.
  let root: URL

  private init(
    channel: any Channel,
    port: Int,
    hostKey: NIOSSHPrivateKey,
    state: TestServerState,
    root: URL
  ) {
    self.channel = channel
    self.port = port
    self.hostKey = hostKey
    self.state = state
    self.root = root
  }

  var hostKeyLine: String { String(openSSHPublicKey: hostKey.publicKey) }

  var identity: HostIdentity { HostIdentity(host: "127.0.0.1", port: port)! }

  static func start(
    hostKey: NIOSSHPrivateKey = NIOSSHPrivateKey(ed25519Key: .init()),
    authorizedKeys: [NIOSSHPublicKey] = []
  ) async throws -> TestSSHServer {
    let state = TestServerState()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "sftp-root-" + UUID().uuidString
    )
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    let auth = TestAuthDelegate(
      username: username,
      password: password,
      authorizedKeys: authorizedKeys,
      state: state
    )
    let rootPath = root.path
    let channel: any Channel
    do {
      channel = try await ServerBootstrap(
        group: MultiThreadedEventLoopGroup.singleton
      )
      .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
      .childChannelInitializer { channel in
        let id = ObjectIdentifier(channel)
        let admitted = state.connections.withLock { connections in
          guard !connections.stopping else { return false }
          connections.channels[id] = channel
          return true
        }
        guard admitted else { return channel.close() }
        channel.closeFuture.whenComplete { _ in
          _ = state.connections.withLock { $0.channels.removeValue(forKey: id) }
        }
        return channel.eventLoop.makeCompletedFuture {
          let ssh = NIOSSHHandler(
            role: .server(.init(hostKeys: [hostKey], userAuthDelegate: auth)),
            allocator: channel.allocator,
            inboundChildChannelInitializer: { child, type in
              let id = ObjectIdentifier(child)
              state.sessionChannels.withLock { $0[id] = child }
              child.closeFuture.whenComplete { _ in
                state.sessionChannels.withLock {
                  _ = $0.removeValue(forKey: id)
                }
              }
              if state.faults.withLock({ $0.rejectSessionChannel }) {
                return child.eventLoop.makeFailedFuture(
                  SSHClientError.channelRequestRejected("session")
                )
              }
              guard case .session = type else {
                return child.eventLoop.makeFailedFuture(
                  SSHClientError.channelRequestRejected("type")
                )
              }
              let gate = child.eventLoop.makePromise(of: Void.self)
              if state.faults.withLock({ $0.holdSessionChannelOpen }) {
                state.heldSessionOpens.withLock { $0.append(gate) }
              } else {
                gate.succeed()
              }
              return gate.futureResult.flatMapThrowing {
                try child.pipeline.syncOperations.addHandler(
                  TestSessionHandler(state: state, root: rootPath)
                )
              }
            }
          )
          try channel.pipeline.syncOperations.addHandler(
            DropServerWrites(state: state)
          )
          try channel.pipeline.syncOperations.addHandler(ssh)
          try channel.pipeline.syncOperations.addHandler(CloseOnErrorHandler())
        }
      }
      .bind(host: "127.0.0.1", port: 0).get()
    } catch {
      try? FileManager.default.removeItem(at: root)
      throw error
    }
    return TestSSHServer(
      channel: channel,
      port: channel.localAddress!.port!,
      hostKey: hostKey,
      state: state,
      root: root
    )
  }

  func shutdown() async {
    let accepted = state.connections.withLock { connections in
      connections.stopping = true
      return Array(connections.channels.values)
    }
    let authentication = state.heldPasswordAuth.withLock { value in
      let held = value
      value = nil
      return held
    }
    authentication?.fail(SSHClientError.connectionClosed)
    let held = state.heldSessionOpens.withLock { value in
      let held = value
      value.removeAll()
      return held
    }
    for promise in held { promise.fail(SSHClientError.connectionClosed) }
    try? await channel.close()
    for connection in accepted { try? await connection.close() }
    state.heldSFTPResponse.withLock { $0 = nil }
    state.heldSFTPResponses.withLock { $0.removeAll() }
    try? FileManager.default.removeItem(at: root)
  }

  func configuration() -> SSHClient.SSHClientConfiguration {
    SSHClient.SSHClientConfiguration(
      host: "127.0.0.1",
      port: port,
      username: Self.username,
      connectTimeout: .seconds(10)
    )
  }

  func trustingStore() -> InMemoryHostTrustStore {
    InMemoryHostTrustStore(keys: [identity: hostKeyLine])
  }

  func connect(
    credential: SSHCredential = .password(TestSSHServer.password)
  ) async throws -> SSHConnection {
    try await SSHConnection.connect(
      configuration: configuration(),
      credential: credential,
      trustStore: trustingStore(),
      trustDecider: RejectUnknownHostKeys()
    )
  }

  func url(_ path: String) -> URL {
    root.appendingPathComponent(String(path.drop(while: { $0 == "/" })))
  }
}

final class CloseOnErrorHandler: ChannelInboundHandler, Sendable {
  typealias InboundIn = Any
  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    context.close(promise: nil)
  }
}

/// Blackholes encrypted replies only after a test enables the fault. Handshake
/// and channel setup still use the actual SSH stack and loopback TCP sockets.
final class DropServerWrites: ChannelOutboundHandler, Sendable {
  typealias OutboundIn = ByteBuffer
  let state: TestServerState
  init(state: TestServerState) { self.state = state }

  func write(
    context: ChannelHandlerContext,
    data: NIOAny,
    promise: EventLoopPromise<Void>?
  ) {
    if state.faults.withLock({ $0.dropAllServerWrites }) {
      state.droppedServerWrites.withLock { $0 += 1 }
      promise?.succeed()
    } else {
      context.write(data, promise: promise)
    }
  }
}

/// Server side of one session channel: exec, shell (echo) or the SFTP
/// subsystem.
final class TestSessionHandler: ChannelInboundHandler {
  typealias InboundIn = SSHChannelData

  enum Mode {
    case idle
    case exec(String)
    case shell, sftp
  }

  let state: TestServerState
  let sftp: TestSFTPServer
  var mode = Mode.idle
  var stdin: [UInt8] = []

  init(state: TestServerState, root: String) {
    self.state = state
    self.sftp = TestSFTPServer(root: root, state: state)
  }

  func handlerAdded(context: ChannelHandlerContext) {
    _ = context.channel.setOption(
      ChannelOptions.allowRemoteHalfClosure,
      value: true
    )
  }

  func channelInactive(context: ChannelHandlerContext) {
    sftp.closeHandles()
    context.fireChannelInactive()
  }

  func handlerRemoved(context: ChannelHandlerContext) { sftp.closeHandles() }

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    switch event {
    case let request as SSHChannelRequestEvent.ExecRequest:
      state.lastExecCommand.withLock { $0 = request.command }
      mode = .exec(request.command)
      state.beforeSetupReply.withLock { $0 }?(.exec)
      reply(context, success: true, wantReply: request.wantReply)
      runExecIfImmediate(context, command: request.command)
    case let request as SSHChannelRequestEvent.PseudoTerminalRequest:
      state.ptyRequest.withLock { $0 = request }
      if !state.faults.withLock({ $0.withholdPTYReply }) {
        state.beforeSetupReply.withLock { $0 }?(.pty)
        reply(
          context,
          success: !state.faults.withLock { $0.rejectPTY },
          wantReply: request.wantReply
        )
      }
    case let request as SSHChannelRequestEvent.ShellRequest:
      mode = .shell
      state.shellRequests.withLock { $0 += 1 }
      if !state.faults.withLock({ $0.withholdShellReply }) {
        state.beforeSetupReply.withLock { $0 }?(.shell)
        reply(
          context,
          success: !state.faults.withLock { $0.rejectShell },
          wantReply: request.wantReply
        )
      }
      if let status = state.shellExitStatus.withLock({ $0 }) {
        exit(context, status: status)
      }
    case let request as SSHChannelRequestEvent.WindowChangeRequest:
      state.windowSize.withLock {
        $0 = (request.terminalCharacterWidth, request.terminalRowHeight)
      }
      send(
        context,
        Array(
          "[resize \(request.terminalCharacterWidth)x\(request.terminalRowHeight)]"
            .utf8
        )
      )
    case let request as SSHChannelRequestEvent.SubsystemRequest:
      let ok = request.subsystem == "sftp"
      if ok { mode = .sftp }
      state.beforeSetupReply.withLock { $0 }?(.sftp)
      reply(context, success: ok, wantReply: request.wantReply)
    case let event as ChannelEvent where event == .inputClosed:
      if case let .exec(command) = mode {
        state.execStdinFinished.withLock { $0 = true }
        finishExec(context, command: command)
      }
    default: context.fireUserInboundEventTriggered(event)
    }
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let message = unwrapInboundIn(data)
    guard case let .byteBuffer(buffer) = message.data else { return }
    let bytes = Array(buffer.readableBytesView)
    switch mode {
    case .exec: stdin += bytes
    case .shell:
      if bytes == Array("flood".utf8) {
        // 6 MiB burst for the read-credit test.
        for _ in 0 ..< 96 {
          send(context, [UInt8](repeating: 0x61, count: 64 * 1024))
        }
      } else {
        send(context, bytes)
      }
    case .sftp: sftp.receive(bytes, context: context)
    case .idle: break
    }
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    context.close(promise: nil)
  }

  private func reply(
    _ context: ChannelHandlerContext,
    success: Bool,
    wantReply: Bool
  ) {
    guard wantReply else { return }
    let event: Any = success ? ChannelSuccessEvent() : ChannelFailureEvent()
    context.triggerUserOutboundEvent(event, promise: nil)
  }

  func send(
    _ context: ChannelHandlerContext,
    _ bytes: [UInt8],
    type: SSHChannelData.DataType = .channel
  ) {
    var buffer = context.channel.allocator.buffer(capacity: bytes.count)
    buffer.writeBytes(bytes)
    context.writeAndFlush(
      NIOAny(SSHChannelData(type: type, data: .byteBuffer(buffer))),
      promise: nil
    )
  }

  func exit(_ context: ChannelHandlerContext, status: Int) {
    context.triggerUserOutboundEvent(
      SSHChannelRequestEvent.ExitStatus(exitStatus: status),
      promise: nil
    )
    context.close(promise: nil)
  }

  /// Commands that do not read stdin start immediately.
  private func runExecIfImmediate(
    _ context: ChannelHandlerContext,
    command: String
  ) {
    switch command {
    case "flood-stdout":
      for _ in 0 ..< 32 {
        send(context, [UInt8](repeating: 0x62, count: 64 * 1024))
      }
      exit(context, status: 0)
    default: break
    }
  }

  private func finishExec(_ context: ChannelHandlerContext, command: String) {
    let suffix = " bootstrap --stdio"
    switch command {
    case "wait-forever": send(context, Array("partial".utf8))
    case "echo-split":
      send(context, Array("out:".utf8) + stdin)
      send(context, Array("err".utf8), type: .stdErr)
      exit(context, status: 3)
    case TestSSHServer.helperPath + suffix,
      TestSSHServer.forwardHelperPath + suffix:
      guard let forward = state.bootstrapForwarder.withLock({ $0 }) else {
        if command == TestSSHServer.helperPath + suffix {
          send(context, Array("helper diagnostics".utf8), type: .stdErr)
          send(context, bootstrapReply())
          exit(context, status: 0)
        } else {
          exit(context, status: 1)
        }
        return
      }
      let input = stdin
      let bound = NIOLoopBound((self, context), eventLoop: context.eventLoop)
      let loop = context.eventLoop
      Task {
        let reply = await forward(input)
        loop.execute {
          let (handler, context) = bound.value
          handler.send(context, reply)
          handler.exit(context, status: 0)
        }
      }
    case "/opt/garbage/swifttyd" + suffix:
      send(context, bootstrapReply() + Array("x".utf8))
      exit(context, status: 0)
    case "/opt/banner/swifttyd" + suffix:
      send(context, Array("Welcome!\n".utf8) + bootstrapReply())
      exit(context, status: 0)
    case "/opt/noisy/swifttyd" + suffix:
      for _ in 0 ..< 8 {
        send(context, [UInt8](repeating: 0x21, count: 16 * 1024), type: .stdErr)
      }
      send(context, bootstrapReply())
      exit(context, status: 0)
    case "/opt/silent/swifttyd" + suffix:
      send(context, Array("agent unavailable".utf8), type: .stdErr)
      exit(context, status: 1)
    default: exit(context, status: 127)
    }
  }

  private func bootstrapReply() -> [UInt8] {
    let response: BootstrapResponse
    if let request = try? BootstrapEnvelope.decode(
      BootstrapRequest.self,
      from: stdin
    ) {
      state.bootstrapRequests.withLock { $0.append(request) }
      response =
        switch request.operation {
        case .list: .sessions([])
        case .terminate: .terminated(request.sessionID!)
        default: .failure(state.bootstrapFailure.withLock { $0 })
        }
    } else {
      response = .failure(.malformed)
    }
    return (try? BootstrapEnvelope.encode(response)) ?? []
  }
}
