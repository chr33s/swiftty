import Darwin
import Dispatch
import Foundation
import SwiftMuxGuardian
import SwiftMuxProtocol
import SwiftMuxXPC
import Synchronization
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct GuardianGatewayConnectionTests {
  @Test
  func writerCapabilityNegotiationPreservesLegacyWelcomeCoding() throws {
    enum LegacyWelcome: Codable {
      case welcome(incarnation: UUID, gateway: UUID)
    }
    let incarnation = UUID()
    let gateway = UUID()
    let oldBytes = try JSONEncoder()
      .encode(LegacyWelcome.welcome(incarnation: incarnation, gateway: gateway))
    guard
      case let .welcome(
        decodedIncarnation,
        decodedGateway,
        capability,
        admission,
        selection,
        phase
      ) = try JSONDecoder().decode(GuardianGatewayEvent.self, from: oldBytes)
    else {
      Issue.record("old welcome did not decode");
      return
    }
    #expect(decodedIncarnation == incarnation && decodedGateway == gateway)
    #expect(
      capability == nil && admission == nil && selection == nil && phase == nil
    )
    let newBytes = try JSONEncoder()
      .encode(
        GuardianGatewayEvent.welcome(
          incarnation: incarnation,
          gateway: gateway,
          supportsEnsureWriter: true
        )
      )
    guard
      case let .welcome(oldIncarnation, oldGateway) = try JSONDecoder()
        .decode(LegacyWelcome.self, from: newBytes)
    else { return }
    #expect(oldIncarnation == incarnation && oldGateway == gateway)
  }

  @Test(arguments: [
    "handshakeTimeout", "commandTimeout", "wrongPID", "lost", "sequence",
    "type", "missingEndpoint", "extraEndpoint", "workspace", "incarnation",
    "admissionRevision", "admissionPause", "admissionCount", "admissionPending",
    "workerOrphan", "workerIdentifier", "workerSame",
  ])
  func malformedOrUncertainResponsesFailOnce(mode: String) throws {
    let state = State()
    let incarnation = UUID()
    let workspace = WorkspaceID()
    let serverQueue = DispatchQueue(label: "gateway-client-fake-guardian")
    let clientQueue = DispatchQueue(label: "gateway-client-under-test")
    let listener = SMXListener(anonymousOn: serverQueue)
    listener.activate(connectionQueue: serverQueue) { channel in
      state.channels.withLock { $0.append(channel) }
      channel.activate { event in
        guard case let .message(data) = event,
          let request = try? JSONDecoder()
            .decode(GuardianGatewayRequest.self, from: data)
        else { return }
        switch request {
        case .hello:
          guard mode != "handshakeTimeout" else { return }
          channel.send(
            try! JSONEncoder()
              .encode(
                GuardianGatewayEvent.welcome(
                  incarnation: incarnation,
                  gateway: UUID(),
                  supportsAdmissionControl: true,
                  supportsWorkerSelection: true
                )
              )
          )
        case let .command(_, _, sequence, _):
          state.commands.withLock { $0 += 1 }
          if mode == "commandTimeout" { return }
          if mode == "lost" {
            channel.cancel();
            return
          }
          let value: GuardianGatewayResult
          if ["missingEndpoint", "workspace", "incarnation"].contains(mode) {
            value = .endpoint(
              authority: GuardianAuthority(
                incarnation: mode == "incarnation" ? UUID() : incarnation,
                workspace: mode == "workspace" ? WorkspaceID() : workspace,
                generation: 1
              ),
              instance: ServerInstanceID(),
              pid: getpid()
            )
          } else if mode.hasPrefix("worker") {
            var fields: [String: String] = [
              "selected": "one", "rollback": "two",
            ]
            if mode == "workerOrphan" { fields.removeValue(forKey: "selected") }
            if mode == "workerIdentifier" { fields["selected"] = "../one" }
            if mode == "workerSame" { fields["rollback"] = "one" }
            value = .workerSelection(
              try! JSONDecoder()
                .decode(
                  GuardianWorkerSelection.self,
                  from: JSONSerialization.data(withJSONObject: fields)
                )
            )
          } else if mode.hasPrefix("admission") {
            let status = try! JSONDecoder()
              .decode(
                GuardianAdmissionStatus.self,
                from: JSONSerialization.data(withJSONObject: [
                  "paused": mode != "admissionPause",
                  "selectionPending": mode == "admissionPending",
                  "revision": mode == "admissionRevision" ? 2 : 1,
                  "pendingWorkers": mode == "admissionCount" ? -1 : 0,
                ])
              )
            value = .admission(status)
          } else if mode == "type" {
            value = .writer(UUID())
          } else {
            value = .inventory([])
          }
          let response = try! JSONEncoder()
            .encode(
              GuardianGatewayEvent.result(
                sequence: mode == "sequence" ? sequence + 1 : sequence,
                value: value
              )
            )
          if ["extraEndpoint", "workspace", "incarnation"].contains(mode) {
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
      try GuardianGatewayConnection(
        channel: .connect(endpoint: endpoint, queue: clientQueue),
        peerRequirement: nil,
        expectedGuardianPID: mode == "wrongPID" ? getpid() + 1 : getpid(),
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
    let handshakeFailure = mode == "handshakeTimeout" || mode == "wrongPID"
    if !handshakeFailure {
      #expect(state.ready.wait(timeout: .now() + 3) == .success)
      clientQueue.sync {
        let command: GuardianGatewayCommand =
          ["missingEndpoint", "workspace", "incarnation"].contains(mode)
          ? .endpoint(workspace: workspace)
          : mode.hasPrefix("admission")
            ? .setAdmissionPaused(true, expectedRevision: 0)
            : mode.hasPrefix("worker") ? .workerSelection : .inventory
        #expect(
          connection.submit(command) { result in
            state.results.withLock { $0.append(result) }
          }
        )
        #expect(
          !connection.submit(.inventory) { _ in
            Issue.record("non-admitted operation received a callback")
          }
        )
      }
    }
    #expect(state.closed.wait(timeout: .now() + 3) == .success)
    clientQueue.sync {
      #expect(
        !connection.submit(.inventory) { _ in
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
    let results = Mutex<[Result<GuardianGatewayConnection.Reply, MuxError>]>([])
    let commands = Mutex(0)
    let acknowledgements = Mutex(0)
  }
}
