import CompanionModel
import SwiftUI

/// Root view shared by every direct client. Per-platform differences come
/// from `PlatformProfile`, not from separate view hierarchies.
public struct RoamingRootView: View {
  @Bindable
  var model: RoamingAppModel
  @Environment(\.scenePhase)
  private var scenePhase
  @State
  private var inbox: RoamingInboxModel?
  /// This window, among the scenes sharing `model`.
  @State
  private var scene = UUID()

  public init(model: RoamingAppModel) { self.model = model }

  public var body: some View {
    NavigationStack {
      HostListView(model: model)
        .toolbar {
          if let inbox {
            ToolbarItem(placement: .automatic) {
              NavigationLink {
                AttentionInboxView(inbox: inbox, model: model)
              } label: {
                Label(
                  inbox.needsYouCount > 0
                    ? "Inbox (\(inbox.needsYouCount))" : "Inbox",
                  systemImage: inbox.needsYouCount > 0 ? "tray.full" : "tray"
                )
              }
            }
          }
          ToolbarItem(placement: .automatic) {
            NavigationLink {
              SettingsView(model: model)
            } label: {
              Label(.localized("Settings"), systemImage: "gearshape")
            }
            .accessibilityIdentifier("settings")
          }
        }
        .navigationDestination(item: $model.presentedSession) { session in
          TerminalScreen(model: session) { model.close() }
        }
    }
    .glassWindowBackground()
    // While a child sheet (SFTP) is up it presents the prompts itself.
    .connectionPrompts(model, enabled: model.modalDepth == 0)
    .privacyShield(when: hidesContent)
    // Attention deep links resolve only through this device's hosts.
    .attentionLinks(model)
    .task {
      model.load()
      Task { await model.refreshConnections() }
      if inbox == nil {
        inbox = RoamingInboxModel(model: model)
        inbox?.refresh(interactive: false)
      }
    }
    .modifier(InboxHostRefresh(model: model, inbox: inbox))
    .onChange(of: scenePhase, initial: true) { _, phase in
      // Foreground recovery fetches this window's inbox again (no push
      // delivery); never prompting for a password in the background.
      if phase == .active { inbox?.refresh(interactive: false) }
      model.scenePhaseChanged(phase, scene: scene)
    }
    // A root view shown again registers again; a repeat is a no-op.
    .onAppear { model.scenePhaseChanged(scenePhase, scene: scene) }
    .onDisappear { model.scenePhaseChanged(nil, scene: scene) }
  }

  /// Hide terminal content from app-switcher snapshots on platforms that
  /// take them. A Mac window losing focus is not a
  /// suspension, so it stays visible there (spec §9).
  private var hidesContent: Bool {
    switch model.profile.kind {
    case .catalyst: false
    case .mobile, .vision, .tv:
      scenePhase != .active && model.activeSession != nil
    }
  }
}

/// Refetches the inbox when the saved hosts change. Its own modifier, so
/// reading `hosts` for the side effect does not invalidate the root view.
private struct InboxHostRefresh: ViewModifier {
  let model: RoamingAppModel
  let inbox: RoamingInboxModel?

  func body(content: Content) -> some View {
    content.onChange(of: model.hosts) { _, _ in
      inbox?.refresh(interactive: false)
    }
  }
}

/// Presents pending trust and password prompts from `model`.
struct ConnectionPrompts: ViewModifier {
  @Bindable
  var model: RoamingAppModel
  let enabled: Bool

  func body(content: Content) -> some View {
    content.sheet(item: enabled ? pendingPassword : .constant(nil)) { prompt in
      PasswordPromptView(prompt: prompt) {
        model.resolvePassword($0, for: prompt.id)
      }
      .macSheetFrame(width: 420, height: 260).presentationBackground(.clear)
    }
    .background {
      // A second presentation anchor: one sheet per view.
      Color.clear.sheet(item: enabled ? pendingTrust : .constant(nil)) {
        prompt in
        TrustPromptView(prompt: prompt) {
          model.resolveTrust($0, for: prompt.id)
        }
        .macSheetFrame(width: 480, height: 320).presentationBackground(.clear)
      }
    }
  }

  /// Dismissing the trust sheet without answering rejects the key.
  private var pendingTrust: Binding<TrustPrompt?> {
    let id = model.pendingTrust?.id
    return Binding(
      get: { model.pendingTrust },
      set: { if $0 == nil, let id { model.resolveTrust(.reject, for: id) } }
    )
  }

  /// Dismissing the password sheet cancels sign-in.
  private var pendingPassword: Binding<PasswordPrompt?> {
    let id = model.pendingPassword?.id
    return Binding(
      get: { model.pendingPassword },
      set: { if $0 == nil, let id { model.resolvePassword(nil, for: id) } }
    )
  }
}

extension View {
  /// Shows `model`'s host-key and password prompts while `enabled`.
  func connectionPrompts(
    _ model: RoamingAppModel,
    enabled: Bool = true
  ) -> some View { modifier(ConnectionPrompts(model: model, enabled: enabled)) }
}

extension TerminalScreenModel: Hashable {
  nonisolated public static func == (
    lhs: TerminalScreenModel,
    rhs: TerminalScreenModel
  ) -> Bool { lhs === rhs }

  nonisolated public func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(self))
  }
}

extension View {
  /// Covers the view with an opaque shield while `hidden` is true.
  public func privacyShield(when hidden: Bool) -> some View {
    overlay {
      if hidden {
        ZStack {
          Rectangle().fill(.background)
          Image(systemName: "lock.rectangle").font(.largeTitle)
            .foregroundStyle(.secondary)
        }
        .ignoresSafeArea()
        .accessibilityLabel(Text("Content hidden", bundle: #bundle))
      }
    }
  }
}

/// iPhone settings for the Apple Watch companion. Preview text is off by
/// default; turning sharing off clears the watch's cached data.
public struct CompanionSettingsView: View {
  @Bindable
  var model: RoamingAppModel

  public init(model: RoamingAppModel) { self.model = model }

  public var body: some View {
    Form {
      Section {
        Toggle(
          .localized("Share session status"),
          isOn: $model.companionSettings.sharingEnabled
        )
      } footer: {
        Text(
          """
          Shows the selected session's nickname, connection state and the time \
          this iPhone last observed it. Turning this off clears the watch.
          """,
          bundle: #bundle
        )
      }
      .listRowBackground(Color.clear)
      Section {
        Toggle(
          .localized("Allow text preview"),
          isOn: $model.companionSettings.previewEnabled
        )
        .disabled(!model.companionSettings.sharingEnabled)
      } footer: {
        Text(
          """
          When the watch asks and this app is open, sends a short preview of the \
          visible terminal text. It is never stored on the watch or shown in \
          complications or notifications.
          """,
          bundle: #bundle
        )
      }
      .listRowBackground(Color.clear)
    }
    .glassListBackground().navigationTitle(.localized("Apple Watch"))
  }
}
