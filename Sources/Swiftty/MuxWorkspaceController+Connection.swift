import AppKit
import ServiceManagement
import SwiftMuxClient
import SwiftMuxProtocol
import SwifttyCore

/// A workspace list and the service instance its identities belong to.
struct WorkspaceListing: Sendable {
  var server: ServerInstanceID?
  var workspaces: [WorkspaceSummary]
}

extension MuxWorkspaceController {
  static func makeWorkspaceWindow(
    configuration: Configuration = Configuration()
  ) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(
        x: 0,
        y: 0,
        width: configuration.windowWidth ?? 900,
        height: configuration.windowHeight ?? 600
      ),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "swiftty"
    window.tabbingMode = .disallowed
    window.center()
    return window
  }

  /// Attaches to `selector` (creating a workspace when nil) in a new window.
  /// With `expectedLease`, takes it over from its current holder; callers
  /// pass it only after the user confirmed.
  static func open(
    _ selector: WorkspaceSelector?,
    configuration: Configuration,
    takeover expectedLease: UInt64? = nil,
    createConnection: @MainActor () async throws -> MuxConnection = {
      try await connect()
    },
    beforeReturnForTesting: (
      @MainActor (MuxWorkspaceController) async -> Void
    )? = nil,
  ) async throws -> MuxWorkspaceController {
    try Task.checkCancellation()
    let connection = try await createConnection()
    do {
      return try await open(
        selector,
        configuration: configuration,
        connection: connection,
        takeover: expectedLease,
        beforeReturnForTesting: beforeReturnForTesting,
      )
    } catch {
      await connection.close()
      throw error
    }
  }

  // MARK: Service connection

  enum ServiceState: Equatable {
    case available
    case requiresApproval
    case unavailable(String)
  }

  /// Registers the bundled agent when running from an app bundle and
  /// reports its state; never starts a second service on its own.
  static func ensureAgent() -> ServiceState {
    guard Bundle.main.bundleURL.pathExtension == "app" else {
      return .available
    }
    let service = SMAppService.agent(plistName: SMX.agentPlistName)
    switch service.status {
    case .enabled: return .available
    case .requiresApproval: return .requiresApproval
    case .notFound:
      return .unavailable(
        "The SwiftMux helper is missing from this app bundle."
      )
    case .notRegistered:
      do {
        try service.register()
        return service.status == .requiresApproval
          ? .requiresApproval : .available
      } catch {
        return .unavailable(
          "Registering the SwiftMux helper failed: \(error.localizedDescription)"
        )
      }
    @unknown default: return .unavailable("Unknown SwiftMux helper state.")
    }
  }

  static func connect(
    createConnection: @MainActor () async throws -> MuxConnection = {
      try await MuxConnection.connect(
        frontend: .native,
        capabilities: MuxWorkspaceController.clientCapabilities
      )
    }
  ) async throws -> MuxConnection {
    try Task.checkCancellation()
    switch ensureAgent() {
    case .available: break
    case .requiresApproval:
      SMAppService.openSystemSettingsLoginItems()
      throw MuxUnavailable(
        message:
          "Allow the SwiftMux helper in System Settings › Login Items. It keeps terminals running after Swiftty closes.",
      )
    case let .unavailable(reason): throw MuxUnavailable(message: reason)
    }
    do { return try await createConnection() } catch is CancellationError {
      throw CancellationError()
    } catch let error as MuxError where error.code == .incompatibleVersion {
      // Preserve the running service and its sessions.
      throw MuxUnavailable(
        message: "The running SwiftMux service is a different version "
          + "(\(error.message)). Its sessions are kept: reopen the Swiftty "
          + "version that started it, or restart the service to use this "
          + "one (its sessions end) with `swiftty --swiftmux-agent "
          + "unregister` and reopen Swiftty.",
      )
    } catch {
      // A bundled agent registered under another signing team is killed
      // at launch (launch constraint) until it is registered again.
      let remedy =
        Bundle.main.bundleURL.pathExtension == "app"
        ? "If Swiftty was re-signed, reinstall it with Scripts/install.sh "
          + "or run `swiftty --swiftmux-agent unregister`, then reopen Swiftty."
        : "Install it with `swmux agent install`."
      throw MuxUnavailable(
        message: "SwiftMux service unavailable (\(error)). \(remedy)",
      )
    }
  }

  /// Workspaces known to the service (no lease needed).
  static func listWorkspaces(
    createConnection: @MainActor () async throws -> MuxConnection = {
      try await connect()
    }
  ) async throws -> [WorkspaceSummary] {
    try await listing(createConnection: createConnection).workspaces
  }

  /// Workspaces known to the service, with the instance they belong to.
  static func listing(
    createConnection: @MainActor () async throws -> MuxConnection = {
      try await connect()
    }
  ) async throws -> WorkspaceListing {
    let connection = try await createConnection()
    do {
      // An interactive chooser must return control if the service stops replying.
      let reply = try await connection.execute(
        .listWorkspaces,
        timeout: .seconds(5)
      )
      guard case let .workspaces(list) = reply else {
        throw MuxError(.invalidRequest, "unexpected workspace-list reply")
      }
      let server = await connection.welcome?.server
      await connection.close()
      return WorkspaceListing(server: server, workspaces: list)
    } catch {
      await connection.close()
      throw error
    }
  }

  /// Opens `selector` on the new `connection` and only then leaves
  /// `current` (the window it replaces). A failed attach
  /// (`leaseHeld` before a confirmed takeover, `staleRevision`, …)
  /// closes `connection` and leaves `current` with its window and lease.
  static func replace(
    _ current: MuxWorkspaceController?,
    with selector: WorkspaceSelector,
    configuration: Configuration,
    connection: MuxConnection,
    takeover expectedLease: UInt64? = nil,
  ) async throws -> MuxWorkspaceController {
    let controller: MuxWorkspaceController
    do {
      guard current?.isClosed != true else { throw CancellationError() }
      controller = try await open(
        selector,
        configuration: configuration,
        connection: connection,
        takeover: expectedLease,
      )
    } catch {
      await connection.close()
      throw error
    }
    do {
      try Task.checkCancellation()
      if let current {
        guard !current.isClosed else { throw CancellationError() }
        await current.detach()
        try Task.checkCancellation()
        current.close()
      }
    } catch {
      await controller.detach()
      controller.close()
      throw error
    }
    return controller
  }

  func notice(_ message: String) {
    if let hook = confirmDestructive {
      Task { _ = await hook(message) }
      return
    }
    let alert = NSAlert()
    alert.messageText = message
    if let window {
      alert.beginSheetModal(for: window)
    } else {
      alert.runModal()
    }
  }

}
