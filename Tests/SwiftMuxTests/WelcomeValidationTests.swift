import Dispatch
import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
import SwiftMuxXPC
import Synchronization
import Testing

struct WelcomeValidationTests {
  enum InvalidProfile: CaseIterable, Sendable {
    case missing, empty, different, unsupported

    var requested: String {
      self == .unsupported ? "unsupported-terminal/1" : SMX.terminalProfile
    }

    var accepted: String? {
      switch self {
      case .missing: nil
      case .empty: ""
      case .different: "other-terminal/1"
      case .unsupported: requested
      }
    }
  }

  enum Invalid: CaseIterable, Sendable {
    case version, frameOverflow, frameEnvelopeOverflow, negativeFrame,
      gridOverflow, gridBytesOverflow, chunkZero
    case negativeInput, controlZero, negativeHistory, stylesZero, graphemesZero,
      geometryZero

    var welcome: Welcome {
      var limits = MuxLimits.standard
      var version = SMX.protocolVersion
      switch self {
      case .version: version += 1
      case .frameOverflow: limits.maxFrameBytes = Int.max
      case .frameEnvelopeOverflow:
        limits.maxFrameBytes = Int.max - (64 << 10) + 1
      case .negativeFrame: limits.maxFrameBytes = -1
      case .gridOverflow:
        limits.maxColumns = Int.max;
        limits.maxRows = 2
      case .gridBytesOverflow:
        limits.maxColumns = Int.max / 2;
        limits.maxRows = 1
      case .chunkZero: limits.maxPasteChunkBytes = 0
      case .negativeInput: limits.inputBytesPerPane = -1
      case .controlZero: limits.maxControlRecordBytes = 0
      case .negativeHistory: limits.historyBytesPerPane = -1
      case .stylesZero: limits.maxStyles = 0
      case .graphemesZero: limits.maxGraphemeScalars = 0
      case .geometryZero: limits.maxGeometryBatch = 0
      }
      return Welcome(
        protocolVersion: version,
        build: SMX.build,
        server: ServerInstanceID(),
        acceptedProfile: nil,
        limits: limits,
        innerTerm: SMX.innerTerm,
      )
    }
  }

  @Test(arguments: Invalid.allCases)
  func invalidWelcomeIsRefusedBeforeReturningAConnection(
    _ invalid: Invalid,
  ) async throws {
    let peer = WelcomePeer(invalid.welcome)
    defer { peer.close() }
    do {
      let connection = try await MuxConnection.connect(
        endpoint: peer.listener.endpoint,
        frontend: .native,
      )
      // Do not use an accepted invalid connection: frame arithmetic can trap.
      await connection.close()
      Issue.record("Accepted invalid welcome: \(invalid)")
    } catch let error as MuxError {
      #expect(
        error.code
          == (invalid == .version ? .incompatibleVersion : .invalidRequest)
      )
    }
    let deadline = ContinuousClock.now + .seconds(1)
    while !peer.closed.withLock({ $0 }), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(1))
    }
    #expect(peer.closed.withLock { $0 })
  }

  @Test
  func validCustomLimitsRemainNegotiated() async throws {
    var limits = MuxLimits.standard
    limits.maxFrameBytes = 1
    limits.maxControlRecordBytes = 4096
    limits.maxPasteChunkBytes = 1
    limits.frameIntervalNanoseconds = 0
    let welcome = Welcome(
      protocolVersion: SMX.protocolVersion,
      build: SMX.build,
      server: ServerInstanceID(),
      acceptedProfile: nil,
      limits: limits,
      innerTerm: SMX.innerTerm,
    )
    let peer = WelcomePeer(welcome)
    defer { peer.close() }
    let connection = try await MuxConnection.connect(
      endpoint: peer.listener.endpoint,
      frontend: .native,
    )
    #expect(await connection.welcome?.limits == limits)
    await connection.close()
  }

  @Test(arguments: InvalidProfile.allCases)
  func terminalWelcomeMustConfirmTheSupportedRequestedProfile(
    _ profile: InvalidProfile
  ) async throws {
    let peer = WelcomePeer(
      Welcome(
        protocolVersion: SMX.protocolVersion,
        build: SMX.build,
        server: ServerInstanceID(),
        acceptedProfile: profile.accepted,
        limits: .standard,
        innerTerm: SMX.innerTerm
      )
    )
    defer { peer.close() }
    do {
      let connection = try await MuxConnection.connect(
        endpoint: peer.listener.endpoint,
        frontend: .terminal,
        terminalProfile: profile.requested
      )
      await connection.close()
      Issue.record("Accepted unconfirmed terminal profile: \(profile)")
    } catch let error as MuxError { #expect(error.code == .invalidRequest) }
    let deadline = ContinuousClock.now + .seconds(1)
    while !peer.closed.withLock({ $0 }), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(1))
    }
    #expect(peer.closed.withLock { $0 })
  }

  @Test(arguments: [FrontendKind.terminal, .native, .control])
  func supportedFrontendWelcomesRemainNegotiated(
    _ frontend: FrontendKind
  ) async throws {
    let profile = frontend == .terminal ? SMX.terminalProfile : nil
    let peer = WelcomePeer(
      Welcome(
        protocolVersion: SMX.protocolVersion,
        build: SMX.build,
        server: ServerInstanceID(),
        acceptedProfile: profile,
        limits: .standard,
        innerTerm: SMX.innerTerm
      )
    )
    defer { peer.close() }
    let connection = try await MuxConnection.connect(
      endpoint: peer.listener.endpoint,
      frontend: frontend,
      terminalProfile: profile
    )
    #expect(await connection.welcome?.acceptedProfile == profile)
    await connection.close()
  }
}

private final class WelcomePeer: Sendable {
  let listener: SMXListener
  let closed = Mutex(false)
  private let channels = Mutex<[SMXChannel]>([])

  init(_ welcome: Welcome) {
    let queue = DispatchQueue(label: "welcome-validation-peer")
    listener = SMXListener(anonymousOn: queue)
    listener.activate(connectionQueue: queue) { [weak self] channel in
      guard let self else {
        channel.cancel();
        return
      }
      channels.withLock { $0.append(channel) }
      channel.activate { [weak self] event in
        guard let self else { return }
        if case .closed = event {
          closed.withLock { $0 = true };
          return
        }
        guard case let .message(data) = event,
          case .hello = try? SMXCodec.decode(
            ClientMessage.self,
            from: data,
            limit: 1 << 20,
          )
        else { return }
        do {
          try channel.send(
            SMXCodec.encode(ServerMessage.welcome(welcome), limit: 1 << 20, )
          )
        } catch { Issue.record("Could not send welcome: \(error)") }
      }
    }
  }

  func close() {
    channels.withLock { $0 }.forEach { $0.cancel() }
    listener.cancel()
  }
}
