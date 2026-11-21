#if os(macOS)
import Dispatch
import Foundation
import SwiftMuxProtocol
import SwiftMuxXPC

/// Bounded async access to the gateway's single-command control link.
/// Cancellation abandons a caller, never replays a transmitted operation or
/// releases its wire slot before the result arrives. Disconnect fails all work.
public actor MuxGatewayConnection {
  private nonisolated let queue = DispatchSerialQueue(
    label: "swiftmux.gateway.client"
  )
  public nonisolated var unownedExecutor: UnownedSerialExecutor {
    queue.asUnownedSerialExecutor()
  }

  private struct Request {
    let id: UUID
    let command: GatewayControlCommand
    let bytes: Int
    var continuation:
      CheckedContinuation<GatewayControlConnection.Reply, any Error>?
  }

  package static let maxPendingCommands = 64
  package static let maxPendingBytes = 4 << 20
  package private(set) var pendingBytes = 0
  private let peerRequirement: String?
  private var connection: GatewayControlConnection?
  private var handshake: CheckedContinuation<Void, any Error>?
  private var active: Request?
  private var waiting: [Request] = []
  private var failure: MuxError?
  package private(set) var identity: ServerInstanceID?
  package var pendingCommandCount: Int {
    waiting.count + (active == nil ? 0 : 1)
  }

  private init(peerRequirement: String?) {
    self.peerRequirement = peerRequirement
  }

  public static func connect(
    peerRequirement: String?,
    expectedPID: Int32? = nil,
    channel: @Sendable (DispatchQueue) -> SMXChannel
  ) async throws -> MuxGatewayConnection {
    try Task.checkCancellation()
    let client = MuxGatewayConnection(peerRequirement: peerRequirement)
    do {
      try await client.open(
        peerRequirement: peerRequirement,
        expectedPID: expectedPID,
        channel: channel
      )
      try Task.checkCancellation()
      try await client.checkOpen()
      return client
    } catch {
      await client.close()
      throw error
    }
  }

  private func open(
    peerRequirement: String?,
    expectedPID: Int32?,
    channel: @Sendable (DispatchQueue) -> SMXChannel
  ) async throws {
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation { continuation in
        handshake = continuation
        do {
          connection = try GatewayControlConnection(
            channel: channel(queue),
            peerRequirement: peerRequirement,
            expectedPID: expectedPID,
            ready: { [weak self] identity in
              self?
                .assumeIsolated {
                  $0.identity = identity
                  let waiter = $0.handshake
                  $0.handshake = nil
                  waiter?.resume()
                }
            },
            closed: { [weak self] error in
              self?.assumeIsolated { $0.finish(error) }
            }
          )
        } catch {
          finish(
            (error as? MuxError)
              ?? MuxError(.connectionLost, "gateway connection failed")
          )
        }
      }
    } onCancel: {
      self.queue.async { self.assumeIsolated { $0.close() } }
    }
  }

  public func close() {
    finish(MuxError(.connectionLost, "gateway client closed"))
    connection?.close()
    connection = nil
  }

  package func checkOpen() throws {
    if let failure { throw failure }
    guard identity != nil else {
      throw MuxError(.notAttached, "gateway is not ready")
    }
  }

  package func request(
    _ command: GatewayControlCommand
  ) async throws -> GatewayControlConnection.Reply {
    try Task.checkCancellation()
    try checkOpen()
    let bytes = try Self.payloadBytes(command)
    guard pendingCommandCount < Self.maxPendingCommands,
      bytes <= Self.maxPendingBytes - pendingBytes
    else { throw MuxError(.resourceLimit, "gateway control queue is full") }
    let id = UUID()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        pendingBytes += bytes
        waiting.append(
          Request(
            id: id,
            command: command,
            bytes: bytes,
            continuation: continuation
          )
        )
        pump()
      }
    } onCancel: {
      self.queue.async { self.assumeIsolated { $0.cancel(id) } }
    }
  }

  public func listWorkspaces() async throws -> [GatewayWorkspaceRecord] {
    guard case let .workspaces(records) = try await request(.listWorkspaces)
    else { throw MuxError(.invalidRequest, "unexpected inventory response") }
    return records
  }

  /// Supply and retain the ID before calling; cancellation can leave a created
  /// workspace whose result must be discovered, never recreated automatically.
  public func createWorkspace(
    _ id: WorkspaceID,
    request launch: NewWorkspaceRequest
  ) async throws {
    guard case .created = try await request(.create(id, launch)) else {
      throw MuxError(.invalidRequest, "unexpected creation response")
    }
  }

  public func endWorkspace(_ selector: WorkspaceSelector) async throws {
    guard case .ended = try await request(.end(selector)) else {
      throw MuxError(.invalidRequest, "unexpected End response")
    }
  }

  // MARK: Saved layouts (spec.durability.md §12.2)

  /// Listing marks Saved records as offered, which starts their retention.
  /// Installer maintenance: refuse new and reopened workspaces while on.
  public func setMaintenance(_ on: Bool) async throws {
    guard case .maintenance = try await request(.setMaintenance(on)) else {
      throw MuxError(.invalidRequest, "unexpected maintenance response")
    }
  }

  /// Asks the running gateway to pause, settle and hand over for `request`.
  public func prepareUpdate(
    _ request: GatewayUpdateRequest
  ) async throws -> GatewayUpdateResult {
    guard
      case let .update(result) = try await self.request(.prepareUpdate(request))
    else { throw MuxError(.invalidRequest, "unexpected update response") }
    return result
  }

  public func installationStatus() async throws -> GatewayInstallationStatus {
    guard
      case let .installation(status) = try await request(.installationStatus)
    else { throw MuxError(.invalidRequest, "unexpected installation status") }
    return status
  }

  public func savedWorkspaces() async throws -> SavedWorkspaceList {
    guard case let .savedWorkspaces(list) = try await request(.savedWorkspaces)
    else { throw MuxError(.invalidRequest, "unexpected saved list") }
    return list
  }

  /// A new workspace with the saved layout and fresh shells. An uncertain
  /// outcome is settled by the gateway from inventory; never retry blindly.
  public func reopenSaved(
    _ request: SavedReopenRequest
  ) async throws -> (WorkspaceID, WorkspaceTemplateOutcome) {
    guard
      case let .reopened(id, outcome) = try await self.request(
        .reopenSaved(request)
      )
    else { throw MuxError(.invalidRequest, "unexpected reopen response") }
    return (id, outcome)
  }

  public func setSavedPolicy(
    _ policy: SavedLayoutPolicy,
    expectedRevision: UInt64
  ) async throws -> SavedLayoutPolicy {
    guard
      case let .savedPolicy(value) = try await request(
        .setSavedPolicy(policy, expectedRevision: expectedRevision)
      )
    else { throw MuxError(.invalidRequest, "unexpected policy response") }
    return value
  }

  /// The output carried into a reopened workspace's pane (C1), decoded.
  public func previousOutput(
    _ workspace: WorkspaceID,
    pane: PaneID
  ) async throws -> SavedOutput {
    var bytes = Data()
    var offset = 0
    repeat {
      guard
        case let .previousOutput(page) = try await request(
          .previousOutput(workspace, pane: pane, offset: offset)
        )
      else { throw MuxError(.invalidRequest, "unexpected output response") }
      bytes.append(page.bytes)
      offset += page.bytes.count
      guard !page.bytes.isEmpty || offset >= page.total else {
        throw MuxError(.invalidRequest, "empty previous output page")
      }
      if offset >= page.total { break }
    } while true
    return try SavedOutput(decoding: bytes)
  }

  public func discardPreviousOutput(
    _ workspace: WorkspaceID,
    pane: PaneID?
  ) async throws {
    guard
      case .deletedSaved = try await request(
        .discardPreviousOutput(workspace, pane: pane)
      )
    else { throw MuxError(.invalidRequest, "unexpected discard response") }
  }

  /// Nil deletes every saved record and the key.
  public func deleteSaved(_ id: WorkspaceID?) async throws {
    guard case .deletedSaved = try await request(.deleteSaved(id)) else {
      throw MuxError(.invalidRequest, "unexpected delete response")
    }
  }

  /// Opens a terminal transport; attachment and takeover remain explicit worker
  /// operations. The returned connection has its own lifetime and must be closed.
  public func openWorkspace(
    _ selector: WorkspaceSelector,
    role: AttachmentRole = .observer,
    frontend: FrontendKind = .native,
    capabilities: ClientCapabilities = .supported
  ) async throws -> (workspace: WorkspaceID, connection: MuxConnection) {
    guard
      case let .route(route) = try await request(.route(selector, role: role))
    else { throw MuxError(.invalidRequest, "unexpected route response") }
    try Task.checkCancellation()
    let client = try await MuxConnection.connectWorker(
      endpoint: route.endpoint,
      expectedPID: route.gatewayPID,
      expectedServer: route.descriptor.server,
      peerRequirement: peerRequirement,
      frontend: frontend,
      terminalProfile: frontend == .terminal ? SMX.terminalProfile : nil,
      capabilities: capabilities
    )
    do {
      try Task.checkCancellation()
      try checkOpen()
      return (route.descriptor.workspace, client)
    } catch {
      await client.close()
      throw error
    }
  }

  private static func payloadBytes(
    _ command: GatewayControlCommand
  ) throws -> Int {
    switch command {
    case let .create(_, launch):
      return try MuxConnection.commandPayloadBytes(.newWorkspace(launch))
    case let .route(selector, _), let .end(selector):
      return try MuxConnection.commandPayloadBytes(.endWorkspace(selector))
    case let .reopenSaved(request):
      return try MuxConnection.commandPayloadBytes(
        .newWorkspace(NewWorkspaceRequest(launch: request.launch))
      ) + request.runCommandSlots.count * 8
    case .listWorkspaces, .savedWorkspaces, .setSavedPolicy, .deleteSaved,
      .previousOutput, .discardPreviousOutput, .installationStatus,
      .prepareUpdate, .setMaintenance:
      return 256
    }
  }

  private func pump() {
    guard failure == nil, active == nil, !waiting.isEmpty else { return }
    active = waiting.removeFirst()
    guard let active, let connection,
      connection.submit(
        active.command,
        completion: { [weak self] result in
          self?
            .assumeIsolated { client in
              let completed = client.active
              client.active = nil
              client.pendingBytes -= completed?.bytes ?? 0
              completed?.continuation?.resume(with: result)
              // Closed callbacks follow failed completion on the same queue.
              // Let them fence the owner before another operation is submitted.
              client.queue.async { [weak client] in
                client?.assumeIsolated { $0.pump() }
              }
            }
        }
      )
    else {
      // A healthy link accepts exactly one command. No retry of an uncertain send.
      close()
      return
    }
  }

  private func cancel(_ id: UUID) {
    if active?.id == id {
      let waiter = active?.continuation
      active?.continuation = nil
      waiter?.resume(throwing: CancellationError())
    } else if let index = waiting.firstIndex(where: { $0.id == id }) {
      let removed = waiting.remove(at: index)
      pendingBytes -= removed.bytes
      removed.continuation?.resume(throwing: CancellationError())
    }
  }

  private func finish(_ error: MuxError) {
    guard failure == nil else { return }
    failure = error
    let handshake = handshake
    self.handshake = nil
    let active = active
    self.active = nil
    let waiting = waiting
    self.waiting.removeAll()
    pendingBytes = 0
    handshake?.resume(throwing: error)
    active?.continuation?.resume(throwing: error)
    for request in waiting { request.continuation?.resume(throwing: error) }
  }
}
#endif
