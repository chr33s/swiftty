import Foundation
import SwiftMuxClient
import SwiftMuxGuardian
import SwiftMuxProtocol

/// A worker's ordered metadata subscription. This owns its connection/event
/// consumer and never attaches, grants a writer, resizes, or creates a workspace.
/// Summary availability is not terminal-frame or full-graph readiness.
package actor GatewayWorkspaceObservation {
  package let authority: GuardianAuthority
  package private(set) var summary: WorkspaceSummary?
  private let client: MuxConnection
  private let supervisor: GatewaySupervisor
  private var reading = false
  private var closed = false

  private init(
    authority: GuardianAuthority,
    summary: WorkspaceSummary?,
    client: MuxConnection,
    supervisor: GatewaySupervisor
  ) {
    self.authority = authority
    self.summary = summary
    self.client = client
    self.supervisor = supervisor
  }

  package static func open(
    authority: GuardianAuthority,
    supervisor: GatewaySupervisor,
    peerRequirement: String?
  ) async throws -> GatewayWorkspaceObservation {
    let client = try await supervisor.connectWorker(
      authority,
      peerRequirement: peerRequirement,
      frontend: .native
    )
    do {
      // Subscription and initial snapshot are serialized in one worker command.
      // A separate list-then-subscribe pair would lose intervening changes.
      guard
        case let .workspaces(items) = try await client.execute(
          .observeWorkspaces(true)
        )
      else {
        throw MuxError(
          .invalidRequest,
          "missing workspace observation snapshot"
        )
      }
      let summary = try validate(items, authority: authority)
      try await supervisor.checkOpen()
      try Task.checkCancellation()
      return GatewayWorkspaceObservation(
        authority: authority,
        summary: summary,
        client: client,
        supervisor: supervisor
      )
    } catch {
      await client.close()
      throw error
    }
  }

  /// One consumer. An empty list means the worker has no published workspace;
  /// it never authorizes starting a shell. Failure invalidates the cached summary.
  package func next(timeout: Duration? = nil) async throws -> WorkspaceSummary?
  {
    guard !closed else {
      throw MuxError(.connectionLost, "workspace observation closed")
    }
    guard !reading else {
      throw MuxError(
        .invalidRequest,
        "workspace observation already has a consumer"
      )
    }
    reading = true
    defer { reading = false }
    do {
      let event: MuxEvent?
      if let timeout {
        event = try await client.nextEvent(timeout: timeout)
      } else {
        event = try await client.nextEvent()
      }
      guard let event, !closed else {
        throw MuxError(.connectionLost, "workspace observation ended")
      }
      guard case let .workspaces(items) = event else {
        throw MuxError(
          .invalidRequest,
          "unexpected workspace observation event"
        )
      }
      let value = try Self.validate(items, authority: authority)
      try await supervisor.checkOpen()
      guard !closed else {
        throw MuxError(.connectionLost, "workspace observation closed")
      }
      summary = value
      return value
    } catch is CancellationError {
      // Cancelling a wait does not cancel the underlying subscription.
      throw CancellationError()
    } catch let error as MuxConnection.EventWaitError { throw error } catch {
      await close()
      throw error
    }
  }

  package func close() async {
    closed = true
    summary = nil
    await client.close()
  }

  private static func validate(
    _ items: [WorkspaceSummary],
    authority: GuardianAuthority
  ) throws -> WorkspaceSummary? {
    guard items.count <= 1, items.allSatisfy({ $0.id == authority.workspace })
    else {
      throw MuxError(.unauthorized, "worker advertised another workspace")
    }
    return items.first
  }
}
