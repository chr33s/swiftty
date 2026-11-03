#if os(macOS)
import Foundation
import SwiftMuxProtocol

/// Owns one frontend attachment across workspace-worker connections. Presenters
/// must tag event/input tasks with Selection.id and discard work after it changes.
/// This owner never replays input or implicitly takes over another controller.
public actor MuxGatewaySession {
  public struct Selection: Sendable {
    public let id: UUID
    public let connection: MuxConnection
    public let attachment: AttachmentID
    public let role: AttachmentRole
    public let workspace: WorkspaceSnapshot
    public let welcome: Welcome
  }

  private var gateway: MuxGatewayConnection
  private let frontend: FrontendKind
  private var pending: Task<Selection, any Error>?
  private var closed = false
  public private(set) var selection: Selection?

  /// The shared gateway control connection remains caller-owned.
  public init(gateway: MuxGatewayConnection, frontend: FrontendKind = .native) {
    self.gateway = gateway
    self.frontend = frontend
  }

  /// A successful switch closes the previous transport and requires new full
  /// frames/geometry. A failed preparation preserves the previous selection.
  /// expectedLease is supplied only after the user's explicit takeover consent.
  public func select(
    _ selector: WorkspaceSelector,
    role: AttachmentRole = .controller,
    expectedLease: UInt64? = nil
  ) async throws -> Selection {
    try await select(
      selector,
      role: role,
      expectedLease: expectedLease,
      gateway: gateway,
      reconnecting: nil
    )
  }

  /// Reattach a lost selection once, through fresh caller-owned gateway control.
  /// A live transport (including one that lost its lease) cannot use this path.
  /// The selection identity fences a recovery racing a later workspace switch.
  public func reconnect(
    using gateway: MuxGatewayConnection,
    selection expected: UUID
  ) async throws -> Selection {
    try Task.checkCancellation()
    guard !closed, let previous = selection, previous.id == expected else {
      throw MuxError(
        .staleAttachment,
        "recovery selection is no longer current"
      )
    }
    var lost = false
    do { try await previous.connection.checkOpen() } catch { lost = true }
    guard lost else {
      throw MuxError(.alreadyAttached, "recovery requires a lost transport")
    }
    return try await select(
      .id(previous.workspace.id),
      role: previous.role,
      expectedLease: nil,
      gateway: gateway,
      reconnecting: expected
    )
  }

  private func select(
    _ selector: WorkspaceSelector,
    role: AttachmentRole,
    expectedLease: UInt64?,
    gateway: MuxGatewayConnection,
    reconnecting expected: UUID?
  ) async throws -> Selection {
    try Task.checkCancellation()
    guard !closed else {
      throw MuxError(.connectionLost, "gateway session closed")
    }
    guard pending == nil else {
      throw MuxError(.quiescing, "workspace selection in progress")
    }
    if let expected, selection?.id != expected {
      throw MuxError(
        .staleAttachment,
        "recovery selection is no longer current"
      )
    }
    guard expectedLease == nil || role == .controller else {
      throw MuxError(.invalidRequest, "observer cannot take over a controller")
    }
    let frontend = frontend
    let previousID = selection?.workspace.id
    let task = Task.detached {
      let opened = try await gateway.openWorkspace(
        selector,
        role: role,
        frontend: frontend
      )
      let connection = opened.connection
      do {
        try Task.checkCancellation()
        if opened.workspace == previousID, expectedLease == nil, expected == nil
        {
          throw MuxError(.alreadyAttached, "workspace is already selected")
        }
        let command: MuxCommand =
          expectedLease.map {
            .takeover(.id(opened.workspace), expectedLease: $0)
          } ?? .attach(AttachRequest(.id(opened.workspace), role: role))
        guard
          case let .attached(attachment, workspace) =
            try await connection.execute(command),
          workspace.id == opened.workspace,
          let welcome = await connection.welcome
        else {
          throw MuxError(.invalidRequest, "unexpected workspace attachment")
        }
        try Task.checkCancellation()
        return Selection(
          id: UUID(),
          connection: connection,
          attachment: attachment,
          role: role,
          workspace: workspace,
          welcome: welcome
        )
      } catch {
        await connection.close()
        throw error
      }
    }
    pending = task
    defer { pending = nil }
    let candidate = try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
    guard !closed, !Task.isCancelled else {
      await candidate.connection.close()
      if Task.isCancelled { throw CancellationError() }
      throw MuxError(.connectionLost, "gateway session closed during selection")
    }
    let previous = selection
    // Commit once. The previous connection's close fences its queued input and
    // ends its event stream. No terminal state or ACK ledger transfers locally.
    selection = candidate
    self.gateway = gateway
    await previous?.connection.close()
    guard !closed else {
      throw MuxError(.connectionLost, "gateway session closed")
    }
    return candidate
  }

  public func isCurrent(_ id: UUID) -> Bool { !closed && selection?.id == id }

  /// Closes only this frontend's transports, never workspaces or shared control.
  public func close() async {
    closed = true
    let pending = pending
    pending?.cancel()
    let current = selection
    selection = nil
    await current?.connection.close()
    if let pending, let candidate = try? await pending.value {
      await candidate.connection.close()
    }
  }
}
#endif
