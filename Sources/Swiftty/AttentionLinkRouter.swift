import AppKit
import MuxNavigation
import MuxNavigationSMX
import SwiftMuxProtocol
import SwifttyCore

/// Routes `swiftty://attention/open?ref=…` (and configured Universal
/// Links) into the attention navigator and renders its states as alerts
/// (spec.inbox.md §4). The native app has one host: this Mac's
/// SwiftMux service over local XPC.
@MainActor
final class AttentionLinkRouter {
  /// This Mac as a navigation host. Its ID is per-install, so links made
  /// here map back to it; links made elsewhere ask the user to choose.
  static let thisMac = NavigationHost(id: localHostID(), name: "This Mac")

  private let navigator: AttentionNavigator
  private let present: @MainActor (NSAlert) async -> NSApplication.ModalResponse
  /// Whether this app's own window holds `workspace`'s lease right now
  /// (not merely shows it: a detached window holds none).
  private let ownsWorkspace: @MainActor (WorkspaceID) -> Bool
  /// The last state rendered, so one state never shows two alerts.
  private var shown: AttentionNavigationState?
  private var requestID = UUID()
  private var startTask: Task<Void, Never>?

  /// `reveal` opens the workspace window (explicitly taking over when
  /// given a lease generation) and activates the pane.
  convenience init(
    ownsWorkspace: @escaping @MainActor (WorkspaceID) -> Bool,
    reveal:
      @escaping @MainActor @Sendable (PaneTarget, UInt64?) async throws -> Void
  ) {
    let opener = Opener(reveal: reveal)
    let navigator = AttentionNavigator(
      configuration: AttentionLinkConfiguration(
        infoDictionary: Bundle.main.infoDictionary
      ),
      hosts: StaticHostDirectory([Self.thisMac]),
      connector: SMXAttentionConnector(opener: opener) {
        try await MuxWorkspaceController.connect()
      }
    )
    self.init(navigator: navigator, ownsWorkspace: ownsWorkspace)
  }

  init(
    navigator: AttentionNavigator,
    ownsWorkspace: @escaping @MainActor (WorkspaceID) -> Bool,
    present:
      @escaping @MainActor (NSAlert) async -> NSApplication.ModalResponse = {
        $0.runModal()
      }
  ) {
    self.navigator = navigator
    self.ownsWorkspace = ownsWorkspace
    self.present = present
    navigator.onStateChange = { [weak self] state in self?.schedule(state) }
  }

  func handle(_ url: URL) {
    let id = UUID()
    requestID = id
    shown = nil
    startTask?.cancel()
    navigator.cancel()
    startTask = Task {
      guard id == requestID, !Task.isCancelled else { return }
      await navigator.open(url)
    }
  }

  /// Alerts run modally; present them after the state change returns.
  private func schedule(_ state: AttentionNavigationState) {
    let id = requestID
    Task { @MainActor in await self.render(state, request: id) }
  }

  private func render(_ state: AttentionNavigationState, request id: UUID) async
  {
    guard id == requestID, state == navigator.state, state != shown else {
      return
    }
    shown = state
    switch state {
    case .idle, .connecting, .opening, .opened: break
    case .rejected:
      let message = AttentionPresentation.rejectedLink
      await inform(
        String(localized: message.title),
        String(localized: message.detail)
      )
      guard isCurrent(state, request: id) else { return }
      navigator.cancel()
    case let .needsHostSelection(hosts):
      let host = await chooseHost(hosts)
      guard isCurrent(state, request: id) else { return }
      guard let host else { return navigator.cancel() }
      await navigator.selectHost(host)
    case let .unavailable(reason):
      let alert = NSAlert()
      alert.messageText = "Attention item unavailable"
      alert.informativeText = DisplayText.sanitize(reason)
      alert.addButton(withTitle: "Try Again")
      alert.addButton(withTitle: "Cancel")
      let response = await present(alert)
      guard isCurrent(state, request: id) else { return }
      if response == .alertFirstButtonReturn {
        shown = nil
        await navigator.retry()
      } else {
        navigator.cancel()
      }
    case let .ready(preview):
      if navigator.destination?.intent == .reveal {
        // Nothing is shown before the pane: seen only once it opens.
        await navigator.openInPane()
        return
      }
      let alert = itemAlert(preview, headline: headline(preview.item))
      if let note = Self.leaseNote(
        preview,
        owned: ownsWorkspace(preview.target.workspace)
      ) {
        alert.informativeText += "\n\n" + note
      }
      alert.addButton(withTitle: "Open in Pane")
      alert.addButton(withTitle: "Close")
      let open = await present(alert) == .alertFirstButtonReturn
      guard isCurrent(state, request: id) else { return }
      await navigator.didView()
      guard isCurrent(state, request: id) else { return }
      if open { await navigator.openInPane() } else { navigator.cancel() }
    case let .stale(preview):
      let alert = itemAlert(
        preview,
        headline: staleHeadline(preview.item.resolution)
      )
      alert.addButton(withTitle: "OK")
      _ = await present(alert)
      guard isCurrent(state, request: id) else { return }
      await navigator.didView()
      guard isCurrent(state, request: id) else { return }
      navigator.cancel()
    case let .missing(reason):
      let message = AttentionPresentation.missing(
        serviceRestarted: reason == .serviceRestarted
      )
      await inform(
        String(localized: message.title),
        String(localized: message.detail)
      )
      guard isCurrent(state, request: id) else { return }
      navigator.cancel()
    case let .paneExited(preview):
      let message = AttentionPresentation.paneExited
      let alert = itemAlert(preview, headline: String(localized: message.title))
      alert.informativeText += "\n\n" + String(localized: message.detail)
      alert.addButton(withTitle: "Show Final Output")
      alert.addButton(withTitle: "Close")
      let open = await present(alert) == .alertFirstButtonReturn
      guard isCurrent(state, request: id) else { return }
      await navigator.didView()
      guard isCurrent(state, request: id) else { return }
      if open { await navigator.openInPane() } else { navigator.cancel() }
    case let .confirmTakeover(offer):
      let alert = NSAlert()
      alert.alertStyle = .warning
      let message = AttentionPresentation.takeover(
        controllerChanged: offer.controllerChanged
      )
      alert.messageText = String(localized: message.title)
      var detail = String(localized: message.detail)
      if let holder = offer.holder {
        let place = holder.transport == .remote ? "a remote device" : "this Mac"
        detail =
          "Controlled from \(place) since "
          + holder.since.formatted(date: .omitted, time: .shortened) + ". "
          + detail
      }
      alert.informativeText = detail
      alert.addButton(withTitle: "Take Over")
      alert.addButton(withTitle: "Cancel")
      let response = await present(alert)
      guard isCurrent(state, request: id) else { return }
      if response == .alertFirstButtonReturn {
        await navigator.confirmTakeover()
      } else {
        navigator.declineTakeover()
        navigator.cancel()
      }
    }
  }

  private func isCurrent(
    _ state: AttentionNavigationState,
    request id: UUID
  ) -> Bool { id == requestID && state == navigator.state }

  /// The `.ready` note about another controller. `owned` is whether this
  /// app's window holds the lease now; a window detached by another
  /// frontend does not, so the note names that controller.
  static func leaseNote(_ preview: AttentionPreview, owned: Bool) -> String? {
    preview.leaseHeldElsewhere && !owned
      ? "Another client controls this workspace." : nil
  }

  private func headline(_ item: AttentionItem) -> String {
    switch item.category {
    case .needsYou: "A program needs you"
    case .failure: "A program failed"
    case .result: "A program finished"
    }
  }

  private func staleHeadline(_ resolution: AttentionResolution) -> String {
    String(localized: AttentionPresentation.staleHeadline(resolution))
  }

  /// Program text is untrusted: sanitized plain text only.
  private func itemAlert(
    _ preview: AttentionPreview,
    headline: String
  ) -> NSAlert {
    let alert = NSAlert()
    alert.messageText = headline
    let status = preview.item.status
    alert.informativeText = [status.app, status.title, status.message]
      .compactMap { $0.map { DisplayText.sanitize($0) } }.filter { !$0.isEmpty }
      .joined(separator: "\n")
    return alert
  }

  private func inform(_ title: String, _ text: String) async {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = text
    _ = await present(alert)
  }

  private func chooseHost(_ hosts: [NavigationHost]) async -> NavigationHost? {
    let alert = NSAlert()
    alert.messageText = "Which Mac should open this link?"
    alert.informativeText =
      "The link names a host this Mac doesn't know. Choose one of your own; "
      + "the link is checked against it before anything is shown."
    let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
    for host in hosts { popup.addItem(withTitle: host.name) }
    alert.accessoryView = popup
    alert.addButton(withTitle: "Continue")
    alert.addButton(withTitle: "Cancel")
    guard !hosts.isEmpty, await present(alert) == .alertFirstButtonReturn else {
      return nil
    }
    return hosts[popup.indexOfSelectedItem]
  }

  private static func localHostID() -> UUID {
    let key = "SwifttyLocalHostProfileID"
    if let text = UserDefaults.standard.string(forKey: key),
      let id = UUID(uuidString: text)
    {
      return id
    }
    let id = UUID()
    UserDefaults.standard.set(id.uuidString, forKey: key)
    return id
  }

  struct Opener: AttentionPaneOpener {
    let reveal: @MainActor @Sendable (PaneTarget, UInt64?) async throws -> Void

    func open(
      _ target: PaneTarget,
      takeover expectedLease: UInt64?
    ) async throws(AttentionServiceError) {
      do { try await reveal(target, expectedLease) } catch let error as MuxError
      { throw SMXAttentionService.map(error) } catch {
        throw .offline(error.localizedDescription)
      }
    }
  }
}
