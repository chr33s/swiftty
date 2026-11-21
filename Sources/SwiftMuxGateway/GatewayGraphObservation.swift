import Foundation
import SwiftMuxClient
import SwiftMuxGuardian
import SwiftMuxProtocol

/// A worker's ordered graph subscription. This owns its connection/event
/// consumer and never attaches, grants a writer, resizes, or creates a workspace.
/// Graph availability is not terminal-frame readiness.
package actor GatewayGraphObservation {
  package let authority: GuardianAuthority
  package private(set) var graph: WorkspaceSnapshot?
  private let client: MuxConnection
  private let supervisor: GatewaySupervisor
  private var reading = false
  private var closed = false

  private init(
    authority: GuardianAuthority,
    graph: WorkspaceSnapshot?,
    client: MuxConnection,
    supervisor: GatewaySupervisor
  ) {
    self.authority = authority
    self.graph = graph
    self.client = client
    self.supervisor = supervisor
  }

  package static func open(
    authority: GuardianAuthority,
    supervisor: GatewaySupervisor,
    peerRequirement: String?
  ) async throws -> GatewayGraphObservation {
    let client = try await supervisor.connectWorker(
      authority,
      peerRequirement: peerRequirement,
      frontend: .native
    )
    do {
      guard await client.welcome?.features.contains(.workspaceGraph) == true
      else {
        throw MuxError(
          .incompatibleVersion,
          "worker does not support graph observation"
        )
      }
      // Subscription and initial snapshot are serialized in one worker command.
      // A separate list-then-subscribe pair would lose intervening changes.
      guard
        case let .workspaceGraph(items) = try await client.execute(
          .observeWorkspaceGraph(true)
        )
      else {
        throw MuxError(
          .invalidRequest,
          "missing workspace observation snapshot"
        )
      }
      let graph = try validate(items, authority: authority)
      try await supervisor.checkOpen()
      try Task.checkCancellation()
      return GatewayGraphObservation(
        authority: authority,
        graph: graph,
        client: client,
        supervisor: supervisor
      )
    } catch {
      await client.close()
      throw error
    }
  }

  /// One consumer. A nil graph means the worker has no published workspace;
  /// it never authorizes starting a shell. Failure invalidates the cached graph.
  package func next(timeout: Duration? = nil) async throws -> WorkspaceSnapshot?
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
    var consumed = false
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
      guard case let .workspaceGraph(items) = event else {
        throw MuxError(
          .invalidRequest,
          "unexpected workspace observation event"
        )
      }
      consumed = true
      _ = try Self.validate(items, authority: authority)
      // Rearm one notification credit and fetch any changes coalesced while
      // that credit was outstanding, at the same worker ordering point.
      guard
        case let .workspaceGraph(latest) = try await client.execute(
          .observeWorkspaceGraph(true)
        )
      else {
        throw MuxError(.invalidRequest, "missing rearmed workspace graph")
      }
      let value = try Self.validate(latest, authority: authority)
      try await supervisor.checkOpen()
      guard !closed else {
        throw MuxError(.connectionLost, "workspace observation closed")
      }
      graph = value
      return value
    } catch is CancellationError {
      // Once credit was consumed, cancellation of rearm has an uncertain
      // outcome. Close rather than leave a seemingly usable stalled stream.
      if consumed { await close() }
      throw CancellationError()
    } catch let error as MuxConnection.EventWaitError { throw error } catch {
      await close()
      throw error
    }
  }

  /// The saved-layout view at the current point (spec.durability.md
  /// §12.2.3); nil when the worker predates `savedLayoutMetadata`.
  package func savedLayoutState() async throws -> SavedLayoutState? {
    guard !closed,
      await client.welcome?.features.contains(.savedLayoutMetadata) == true
    else { return nil }
    guard
      case let .savedLayoutState(state) = try await client.execute(
        .savedLayoutState
      )
    else { throw MuxError(.invalidRequest, "missing saved layout state") }
    guard state.graph.map({ $0.id == authority.workspace }) ?? true else {
      throw MuxError(.unauthorized, "invalid saved layout identity")
    }
    return state
  }

  /// A pane's newest main-screen rows (C1), assembled from bounded pages;
  /// nil bytes when unchanged since `revision`.
  package func savedOutput(
    pane: PaneID,
    ifChangedSince revision: UInt64?
  ) async throws -> (revision: UInt64, bytes: Data?) {
    guard !closed,
      await client.welcome?.features.contains(.savedLayoutMetadata) == true
    else { throw MuxError(.incompatibleVersion, "no saved output support") }
    var bytes = Data()
    var offset = 0
    var current: UInt64 = 0
    repeat {
      guard
        case let .savedOutputPage(page) = try await client.execute(
          .exportSavedOutput(
            pane: pane,
            ifChangedSince: offset == 0 ? revision : nil,
            offset: offset
          )
        ), page.offset == offset, page.bytes.count <= SavedOutputPage.maxBytes,
        page.total <= SavedOutput.maxBytes, offset == 0 || page.modified,
        offset == 0 || page.revision == current
      else { throw MuxError(.invalidRequest, "invalid saved output page") }
      current = page.revision
      guard page.modified else { return (current, nil) }
      bytes.append(page.bytes)
      offset += page.bytes.count
      guard !page.bytes.isEmpty || offset >= page.total else {
        throw MuxError(.invalidRequest, "empty saved output page")
      }
      if offset >= page.total { break }
    } while true
    return (current, bytes)
  }

  package func close() async {
    closed = true
    graph = nil
    await client.close()
  }

  private static func validate(
    _ graph: WorkspaceSnapshot?,
    authority: GuardianAuthority
  ) throws -> WorkspaceSnapshot? {
    guard
      graph.map({ $0.id == authority.workspace && $0.attachmentRole == nil })
        ?? true
    else {
      throw MuxError(
        .unauthorized,
        "invalid worker graph identity or attachment"
      )
    }
    return graph
  }
}
