import Foundation
import MuxNavigation
import SwiftMuxProtocol
import SwiftUI

/// The recipient's saved hosts as navigation hosts: IDs and nicknames
/// only. A link can name a host profile ID but never adds a host,
/// endpoint or credential (spec.inbox.md §4).
struct RoamingHostDirectory: AttentionHostDirectory {
  let model: RoamingAppModel

  func configuredHosts() async -> [NavigationHost] {
    await MainActor.run {
      if model.hosts.isEmpty { model.load() }
      return model.hosts.map { NavigationHost(id: $0.id, name: $0.nickname) }
    }
  }
}

/// One followed link: a navigator bound to this app's hosts.
@MainActor
final class AttentionLinkSession: Identifiable {
  let id = UUID()
  let navigator: AttentionNavigator

  init(model: RoamingAppModel, connector: any AttentionServiceConnector) {
    navigator = AttentionNavigator(
      configuration: AttentionLinkConfiguration(
        infoDictionary: Bundle.main.infoDictionary
      ),
      hosts: RoamingHostDirectory(model: model),
      connector: connector
    )
  }
}

extension View {
  /// Routes `swiftty://attention/…`, configured Universal Links and
  /// attention Handoff into a destination sheet.
  func attentionLinks(_ model: RoamingAppModel) -> some View {
    modifier(AttentionLinkRouting(model: model))
  }
}

/// Opens attention destinations in the current scene's navigator and owns
/// the presented link session. An observable reference in the environment,
/// not a closure: SwiftUI cannot compare closures, so a closure-valued
/// entry would invalidate every reader on each write.
@MainActor
@Observable
final class AttentionRouter {
  @ObservationIgnored
  private let model: RoamingAppModel
  private(set) var session: AttentionLinkSession?
  @ObservationIgnored
  private var startTask: Task<Void, Never>?

  init(model: RoamingAppModel) {
    self.model = model
  }

  func open(_ destination: AttentionDestination) {
    open { await $0.open(destination) }
  }

  func dismissSession(_ id: UUID) {
    guard session?.id == id else { return }
    startTask?.cancel()
    startTask = nil
    session?.navigator.cancel()
    session = nil
    model.modalDepth -= 1
  }

  /// A newer link replaces the current one; the old navigator's late
  /// results are dropped with it.
  func open(
    _ start: @escaping @MainActor (AttentionNavigator) async -> Void
  ) {
    startTask?.cancel()
    session?.navigator.cancel()
    if session == nil { model.modalDepth += 1 }
    let next = AttentionLinkSession(
      model: model,
      connector: RoamingAttentionConnector(model: model)
    )
    session = next
    startTask = Task {
      guard session?.id == next.id, !Task.isCancelled else { return }
      await start(next.navigator)
    }
  }
}

struct AttentionLinkRouting: ViewModifier {
  let model: RoamingAppModel
  @State
  private var router: AttentionRouter

  init(model: RoamingAppModel) {
    self.model = model
    _router = State(initialValue: AttentionRouter(model: model))
  }

  func body(content: Content) -> some View {
    content.onOpenURL { url in router.open { await $0.open(url) } }
      .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
        guard let url = activity.webpageURL else { return }
        router.open { await $0.open(url) }
      }
      .onContinueUserActivity(AttentionHandoffRequest.activityType) {
        activity in
        // A watch handoff carries only a locator; it is resolved through
        // this device's hosts like any link and never grants a lease.
        guard
          let request = AttentionHandoffRequest(userInfo: activity.userInfo),
          let destination = try? request.destination()
        else { return }
        router.open(destination)
      }
      // Inbox entries open through the same navigator, in this scene.
      .environment(router)
      // iPadOS/visionOS/Catalyst: an attention link goes to an existing
      // window (this one, when it is frontmost) instead of a new scene;
      // every scene shares the one app model and its single terminal.
      .preferringAttentionEvents()
      .sheet(item: presentedSession) { session in
        AttentionDestinationView(navigator: session.navigator) {
          router.dismissSession(session.id)
        }
        .macSheetFrame(width: 440, height: 320).presentationBackground(.clear)
        .connectionPrompts(model).onDisappear { session.navigator.cancel() }
      }
      .onDisappear {
        if let session = router.session { router.dismissSession(session.id) }
      }
  }

  /// Captures the session shown at render time, so a late dismissal of a
  /// replaced sheet cannot dismiss its successor.
  private var presentedSession: Binding<AttentionLinkSession?> {
    let id = router.session?.id
    return Binding(
      get: { router.session },
      set: { if $0 == nil, let id { router.dismissSession(id) } }
    )
  }
}

/// Renders every navigator state. Program text is untrusted and shown
/// verbatim as plain text, never as markup or a link.
struct AttentionDestinationView: View {
  let navigator: AttentionNavigator
  let dismiss: () -> Void

  var body: some View {
    NavigationStack {
      content.padding()
        .frame(
          maxWidth: .infinity,
          maxHeight: .infinity,
          alignment: .topLeading
        )
        .glassSurface().glassButtonStyle()
        .navigationTitle(.localized("Attention"))
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button(.localized("Close")) {
              navigator.cancel()
              dismiss()
            }
          }
        }
    }
  }

  @ViewBuilder
  private var content: some View {
    switch navigator.state {
    case .idle: ProgressView()
    case .rejected:
      message(AttentionPresentation.rejectedLink, symbol: "link.badge.plus")
    case let .needsHostSelection(hosts):
      VStack(alignment: .leading, spacing: 12) {
        Text("Choose a host", bundle: #bundle).font(.headline)
        if hosts.isEmpty {
          Text(
            "Add the Mac this link came from to your hosts first. Links never add hosts.",
            bundle: #bundle
          )
          .foregroundStyle(.secondary)
        } else {
          Text(
            "This link names a host this device doesn't know. Pick one of your own hosts.",
            bundle: #bundle
          )
          .foregroundStyle(.secondary)
          ForEach(hosts) { host in
            Button(host.name) { Task { await navigator.selectHost(host) } }
          }
        }
      }
    case let .connecting(host):
      ProgressView { Text("Connecting to \(host.name)…", bundle: #bundle) }
    case let .unavailable(reason):
      VStack(alignment: .leading, spacing: 12) {
        message(
          .localized("Unavailable"),
          Text(verbatim: reason),
          symbol: "wifi.exclamationmark"
        )
        Button(.localized("Try Again")) { Task { await navigator.retry() } }
      }
    case let .ready(preview):
      VStack(alignment: .leading, spacing: 12) {
        item(preview)
        Button(.localized("Open in Pane")) {
          Task { await navigator.openInPane() }
        }
        .glassButtonStyle(prominent: true)
      }
      .task { await navigator.didView() }
    case let .stale(preview):
      VStack(alignment: .leading, spacing: 12) {
        message(
          AttentionPresentation.staleHeadline(preview.item.resolution),
          Text(
            "A newer request is not shown in its place.",
            bundle: #bundle
          ),
          symbol: "clock.arrow.circlepath"
        )
        item(preview)
      }
      .task { await navigator.didView() }
    case let .missing(reason):
      message(
        AttentionPresentation.missing(
          serviceRestarted: reason == .serviceRestarted
        ),
        symbol: "questionmark.square.dashed"
      )
    case let .paneExited(preview):
      VStack(alignment: .leading, spacing: 12) {
        message(AttentionPresentation.paneExited, symbol: "stop.circle")
        item(preview)
        Button(.localized("Show Final Output")) {
          Task { await navigator.openInPane() }
        }
      }
      .task { await navigator.didView() }
    case let .confirmTakeover(offer):
      VStack(alignment: .leading, spacing: 12) {
        message(
          AttentionPresentation.takeover(
            controllerChanged: offer.controllerChanged
          ),
          symbol: "person.2.badge.gearshape"
        )
        Button(.localized("Take Over"), role: .destructive) {
          Task { await navigator.confirmTakeover() }
        }
        Button(.localized("Not Now")) { navigator.declineTakeover() }
      }
    case .opening: ProgressView(.localized("Opening…"))
    case .opened:
      message(
        .localized("Opened"),
        Text("The pane is active.", bundle: #bundle),
        symbol: "checkmark.circle"
      )
    }
  }

  /// `detail` is app copy, or `Text(verbatim:)` for text the host
  /// reported.
  private func message(
    _ title: LocalizedStringResource,
    _ detail: Text,
    symbol: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(title, systemImage: symbol).font(.headline)
      detail.foregroundStyle(.secondary)
    }
  }

  /// Copy shared with the native macOS client.
  private func message(
    _ shared: AttentionPresentation.Message,
    symbol: String
  ) -> some View {
    message(shared.title, Text(shared.detail), symbol: symbol)
  }

  /// Program text is untrusted: sanitized plain text, never markup.
  private func item(_ preview: AttentionPreview) -> some View {
    let status = preview.item.status
    return VStack(alignment: .leading, spacing: 4) {
      Text(AttentionPresentation.categoryLabel(preview.item.category))
        .font(.subheadline.bold())
      if let app = AttentionPresentation.plain(status.app) {
        Text(verbatim: app).font(.caption)
      }
      if let title = AttentionPresentation.plain(status.title) {
        Text(verbatim: title)
      }
      if let message = AttentionPresentation.plain(status.message, limit: 300)
      {
        Text(verbatim: message).font(.callout).foregroundStyle(.secondary)
          .lineLimit(6)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

extension View {
  /// Scene preference for attention links where scenes exist (not tvOS).
  @ViewBuilder
  fileprivate func preferringAttentionEvents() -> some View {
    #if os(tvOS)
    self
    #else
    handlesExternalEvents(preferring: ["attention", "/a/"], allowing: ["*"])
    #endif
  }
}
