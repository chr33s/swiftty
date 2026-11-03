import Darwin
import Dispatch
import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
import SwiftMuxXPC
import Synchronization
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct GatewayControlConnectionTests {
  @Test(arguments: [
    "handshakeTimeout", "commandTimeout", "wrongPID", "lost", "sequence",
    "type", "missingEndpoint", "extraEndpoint", "workspace", "version",
  ])
  func malformedOrUncertainResponsesFailOnce(mode: String) throws {
    let state = State()
    let identity = ServerInstanceID()
    let workspace = WorkspaceID()
    let serverQueue = DispatchQueue(label: "gateway-client-fake-guardian")
    let clientQueue = DispatchQueue(label: "gateway-client-under-test")
    let listener = SMXListener(anonymousOn: serverQueue)
    listener.activate(connectionQueue: serverQueue) { channel in
      state.channels.withLock { $0.append(channel) }
      channel.activate { event in
        guard case let .message(data) = event,
          let request = try? JSONDecoder()
            .decode(GatewayControlRequest.self, from: data)
        else { return }
        switch request {
        case .hello:
          guard mode != "handshakeTimeout" else { return }
          channel.send(
            try! JSONEncoder()
              .encode(
                GatewayControlEvent.welcome(
                  version: mode == "version" ? 999 : GatewayControl.version,
                  gateway: identity
                )
              )
          )
        case let .command(_, sequence, _):
          state.commands.withLock { $0 += 1 }
          if mode == "commandTimeout" { return }
          if mode == "lost" {
            channel.cancel();
            return
          }
          let value: GatewayControlResult
          if ["missingEndpoint", "workspace"].contains(mode) {
            value = .success(
              .route(
                GatewayRouteDescriptor(
                  workspace: mode == "workspace" ? WorkspaceID() : workspace,
                  server: ServerInstanceID()
                )
              )
            )
          } else if mode == "type" {
            value = .success(.ended)
          } else {
            value = .success(.workspaces([]))
          }
          let response = try! JSONEncoder()
            .encode(
              GatewayControlEvent.result(
                sequence: mode == "sequence" ? sequence + 1 : sequence,
                value: value
              )
            )
          if ["extraEndpoint", "workspace"].contains(mode) {
            channel.send(response, endpoint: listener.endpoint)
          } else {
            channel.send(response)
          }
        case .acknowledge: state.acknowledgements.withLock { $0 += 1 }
        }
      }
    }
    let endpoint = listener.endpoint
    let connection = try clientQueue.sync {
      try GatewayControlConnection(
        channel: .connect(endpoint: endpoint, queue: clientQueue),
        peerRequirement: nil,
        expectedPID: mode == "wrongPID" ? getpid() + 1 : getpid(),
        timeout: 0.2,
        ready: { _ in state.ready.signal() },
        closed: { error in
          state.errors.withLock { $0.append(error) }
          state.closed.signal()
        }
      )
    }
    defer {
      clientQueue.sync { connection.close() }
      state.channels.withLock { for channel in $0 { channel.cancel() } }
      listener.cancel()
    }
    let handshakeFailure = ["handshakeTimeout", "wrongPID", "version"]
      .contains(mode)
    if !handshakeFailure {
      #expect(state.ready.wait(timeout: .now() + 3) == .success)
      clientQueue.sync {
        let command: GatewayControlCommand =
          ["missingEndpoint", "workspace"].contains(mode)
          ? .route(.id(workspace), role: .observer)
          : ["commandTimeout", "lost"].contains(mode)
            ? .create(workspace, NewWorkspaceRequest()) : .listWorkspaces
        #expect(
          connection.submit(command) { result in
            state.results.withLock { $0.append(result) }
          }
        )
        #expect(
          !connection.submit(.listWorkspaces) { _ in
            Issue.record("non-admitted operation received a callback")
          }
        )
      }
    }
    #expect(state.closed.wait(timeout: .now() + 3) == .success)
    clientQueue.sync {
      #expect(
        !connection.submit(.listWorkspaces) { _ in
          Issue.record("closed connection admitted an operation")
        }
      )
      connection.close()
    }
    let errors = state.errors.withLock { $0 }
    #expect(errors.count == 1)
    let expected: MuxError.Code =
      mode == "wrongPID"
      ? .unauthorized
      : mode == "version"
        ? .incompatibleVersion
        : ["handshakeTimeout", "commandTimeout", "lost"].contains(mode)
          ? .connectionLost : .invalidRequest
    #expect(errors.first?.code == expected)
    let results = state.results.withLock { $0 }
    #expect(results.count == (handshakeFailure ? 0 : 1))
    if let result = results.first {
      guard case let .failure(error) = result else {
        Issue.record("invalid response was acknowledged");
        return
      }
      #expect(error.code == expected)
    }
    #expect(state.commands.withLock { $0 } == (handshakeFailure ? 0 : 1))
    #expect(state.acknowledgements.withLock { $0 } == 0)
  }

  private final class State: Sendable {
    let channels = Mutex<[SMXChannel]>([])
    let ready = DispatchSemaphore(value: 0)
    let closed = DispatchSemaphore(value: 0)
    let errors = Mutex<[MuxError]>([])
    let results = Mutex<[Result<GatewayControlConnection.Reply, MuxError>]>([])
    let commands = Mutex(0)
    let acknowledgements = Mutex(0)
  }
}
