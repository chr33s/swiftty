import Darwin
import Dispatch
import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
import SwiftMuxXPC
import Synchronization
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct GatewayForwardingTests {
  @Test
  func ordinaryServiceRefusesForwardingDeclarations() async throws {
    let harness = try Harness()
    let ordinary = try await harness.connect()
    #expect(await ordinary.welcome?.features.contains(.workspaceGraph) == false)
    do {
      _ = try await ordinary.execute(.observeWorkspaceGraph(true))
      Issue.record("ordinary service exposed gateway graph observation")
    } catch let error as MuxError { #expect(error.code == .unauthorized) }
    let instance = try #require(await ordinary.welcome?.server)
    for transport in [LeaseHolder.Transport.local, .remote] {
      do {
        _ = try await MuxConnection.connectWorker(
          endpoint: harness.endpoint,
          expectedPID: getpid(),
          expectedServer: instance,
          peerRequirement: nil,
          frontend: .native,
          forwardedTransport: transport
        )
        Issue.record("ordinary service accepted a forwarding declaration")
      } catch let error as MuxError {
        #expect(error.code == .unauthorized || error.code == .connectionLost)
      }
    }
    _ = try await ordinary.execute(.status)
    await ordinary.close()
  }

  @Test(arguments: [false, true])
  func missingOrWrongAcknowledgementFailsBeforeCommands(
    wrong: Bool
  ) async throws {
    let queue = DispatchQueue(label: "legacy-forwarding-test")
    let listener = SMXListener(anonymousOn: queue)
    let channels = Mutex<[SMXChannel]>([])
    let commands = Mutex(0)
    let instance = ServerInstanceID()
    listener.activate(connectionQueue: queue) { channel in
      channels.withLock { $0.append(channel) }
      channel.activate { event in
        guard case let .message(data) = event,
          let message = try? JSONDecoder()
            .decode(ClientMessage.self, from: data)
        else { return }
        if case .hello = message {
          let welcome = Welcome(
            protocolVersion: SMX.protocolVersion,
            build: SMX.build,
            server: instance,
            acceptedProfile: nil,
            limits: .standard,
            innerTerm: SMX.fallbackInnerTerm,
            forwardedTransport: wrong ? .local : nil
          )
          channel.send(
            try! JSONEncoder().encode(ServerMessage.welcome(welcome))
          )
        } else {
          commands.withLock { $0 += 1 }
        }
      }
    }
    defer {
      for channel in channels.withLock({ $0 }) { channel.cancel() }
      listener.cancel()
    }
    do {
      _ = try await MuxConnection.connectWorker(
        endpoint: listener.endpoint,
        expectedPID: getpid(),
        expectedServer: instance,
        peerRequirement: nil,
        frontend: .native,
        forwardedTransport: .remote
      )
      Issue.record("unacknowledged forwarding was accepted")
    } catch let error as MuxError {
      #expect(error.code == .incompatibleVersion)
    }
    #expect(commands.withLock { $0 } == 0)
  }
}
