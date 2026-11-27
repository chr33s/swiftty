import ScreenProtocol
import SessionCore
import SwiftMuxProtocol
import SwiftUI
import SwifttyCore
import TerminalSurface

#if canImport(UIKit)
import SwifttyMobile
import UIKit
#elseif os(macOS)
import AppKit
import SwifttyMac
#endif

extension View {
  /// What sits behind a terminal surface. iPhone and iPad paint the
  /// terminal's colour, opaque, behind the whole screen
  /// (`TerminalChromeBackground`); glass there would tint a translucent
  /// terminal away from the bars, so none is added. Elsewhere, glass.
  @ViewBuilder
  func terminalBacking() -> some View {
    #if os(iOS) && !targetEnvironment(macCatalyst)
    self
    #else
    glassSurface(fillsSafeArea: false)
    #endif
  }
}

/// How the terminal pages between panes: the screen last seen of the pane
/// a drag reveals (nil: none yet), and the switch once a drag commits.
struct PaneSwitching {
  var neighborScreen: (_ next: Bool) -> PresentationFrame?
  var commit: (_ next: Bool) -> Void
}

/// Chooses the controller for a screen (created once, owned by the
/// model) and shows its surface.
struct LiveTerminalSurface: View {
  let model: TerminalScreenModel
  let app: RoamingAppModel

  var body: some View {
    switch Self.controller(for: model, app: app) {
    case let roaming as RoamingTerminalController:
      RoamingSurfaceView(controller: roaming, app: app)
    case let ssh as SSHShellController:
      SSHSurfaceView(controller: ssh, app: app)
    default: EmptyView()
    }
  }

  /// `model`'s controller, created on first display. A closed screen
  /// still on its way out gets none.
  static func controller(
    for model: TerminalScreenModel,
    app: RoamingAppModel
  ) -> (any TerminalSurfaceController)? {
    if let existing = model.controller { return existing }
    guard !model.isClosed else { return nil }
    let created: any TerminalSurfaceController
    switch model.kind {
    case .roaming: created = RoamingTerminalController(model: model, app: app)
    case .ordinarySSH: created = SSHShellController(model: model, app: app)
    }
    model.controller = created
    return created
  }
}

// MARK: - Roaming

/// Forwards this window's scene phase to the controller, which combines
/// it with any other window showing the same screen. Its own modifier, so
/// reading the phase does not invalidate the surface view.
private struct ScenePhaseForwarding: ViewModifier {
  let controller: RoamingTerminalController
  @Environment(\.scenePhase)
  private var scenePhase
  @State
  private var scene = UUID()

  func body(content: Content) -> some View {
    // onAppear (not onChange's initial call) so a view that disappears
    // and reappears with the same identity registers again.
    content.onAppear { controller.scenePhaseChanged(scenePhase, scene: scene) }
      .onChange(of: scenePhase) { _, phase in
        controller.scenePhaseChanged(phase, scene: scene)
      }
      .onDisappear { controller.scenePhaseChanged(nil, scene: scene) }
  }
}

struct RoamingSurfaceView: View {
  let controller: RoamingTerminalController
  let app: RoamingAppModel
  @State
  private var confirmTerminate = false
  @State
  private var showsFiles = false
  @State
  private var renaming: RenameTarget?
  @State
  private var newName = ""
  @State
  private var ending: EndRequest?

  /// What the rename prompt names.
  enum RenameTarget: Equatable {
    case tab(TabID)
    case workspace
  }

  /// Closing a pane or tab ends its processes; as on the Mac, it asks
  /// first while one is still running.
  struct EndRequest: Equatable {
    let action: LayoutAction
    let confirms: Bool
    let message: String
    let detail: String
  }

  var body: some View {
    TerminalCanvas(
      session: controller.display,
      capabilities: controller.model.capabilities,
      configuration: app.terminalSettings.configuration(),
      paneSwitching: controller.canSwitchPanes
        ? PaneSwitching(
          neighborScreen: { controller.neighborScreen(next: $0) },
          commit: { controller.switchPane(next: $0) }
        ) : nil
    )
    .uiTestingScreenProbe(controller.model).terminalBacking()
    .overlay { overlay }
    .safeAreaInset(edge: .bottom) {
      if controller.offersOrdinarySSH {
        FallbackBanner(
          model: controller.model,
          app: app,
          notice: controller.endpointNotice
        )
      }
    }
    .task { controller.startIfNeeded() }
    .modifier(ScenePhaseForwarding(controller: controller))
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Menu {
          #if !os(tvOS)
          if controller.model.profile.sftp {
            Section(.localized("Files")) {
              Button(.localized("Files…"), systemImage: "folder") {
                showsFiles = true
              }
              .accessibilityIdentifier("session.files")
            }
          }
          #endif
          if let layout = controller.layout, let tab = layout.activeTabLayout {
            panesSection(layout, tab)
            tabsSection(layout, tab)
          }
          workspacesSection
        } label: {
          Label(.localized("Workspace"), systemImage: "ellipsis")
        }
        .accessibilityIdentifier("session.menu")
      }
    }
    .alert(
      renaming == .workspace
        ? Text("Rename Workspace", bundle: #bundle)
        : Text("Rename Tab", bundle: #bundle),
      isPresented: Binding(
        get: { renaming != nil },
        set: { if !$0 { renaming = nil } }
      )
    ) {
      TextField(text: $newName) { Text("Name", bundle: #bundle) }
        .accessibilityIdentifier("session.renameField")
      Button(.localized("Rename")) { commitRename() }
      Button(.localized("Cancel"), role: .cancel) { renaming = nil }
    }
    .alert(
      Text("Couldn't change the layout", bundle: #bundle),
      isPresented: Binding(
        get: { controller.layoutFailure != nil },
        set: { if !$0 { controller.layoutFailure = nil } }
      )
    ) {
      Button(.localized("OK"), role: .cancel) { controller.layoutFailure = nil }
    } message: {
      Text(controller.layoutFailure ?? "")
    }
    .confirmationDialog(
      Text(
        "End the workspace on \(controller.model.host.nickname)?",
        bundle: #bundle
      ),
      isPresented: $confirmTerminate,
      titleVisibility: .visible
    ) {
      Button(.localized("End Workspace"), role: .destructive) {
        app.close(.terminate)
      }
      Button(.localized("Cancel"), role: .cancel) {}
    } message: {
      Text(
        "This ends all running programs in every tab and pane of this workspace.",
        bundle: #bundle
      )
    }
    .confirmationDialog(
      Text(ending?.message ?? ""),
      isPresented: Binding(
        get: { ending != nil },
        set: { if !$0 { ending = nil } }
      ),
      titleVisibility: .visible,
      presenting: ending
    ) { request in
      Button(.localized("End"), role: .destructive) {
        controller.perform(request.action)
      }
      Button(.localized("Cancel"), role: .cancel) {}
    } message: { request in
      Text(request.detail)
    }
    #if !os(tvOS)
    .adaptiveSheet(isPresented: $showsFiles) {
      SFTPBrowserView(selection: controller.selection, app: app)
      .macSheetFrame(width: 560, height: 480)
    }
    #endif
  }

  // MARK: Menu sections

  /// Panes of the shown tab. Closing is offered only while another pane or
  /// tab remains: ending the last one is End Workspace.
  @ViewBuilder
  private func panesSection(
    _ layout: RemoteLayout,
    _ tab: RemoteLayout.Tab
  ) -> some View {
    Section(.localized("Panes")) {
      Button(.localized("Split Right"), systemImage: "rectangle.split.2x1") {
        controller.perform(.split(axis: .leftRight))
      }
      .accessibilityIdentifier("session.splitRight")
      Button(.localized("Split Down"), systemImage: "rectangle.split.1x2") {
        controller.perform(.split(axis: .topBottom))
      }
      .accessibilityIdentifier("session.splitDown")
      if tab.panes.count > 1 {
        Menu {
          Picker(
            selection: Binding(
              get: { tab.activePane },
              set: { controller.perform(.focusPane(pane: $0)) }
            )
          ) {
            ForEach(Array(tab.panes.enumerated()), id: \.element.id) {
              index,
              pane in Text(Self.title(of: pane, at: index)).tag(pane.id)
            }
          } label: {
            EmptyView()
          }
          .pickerStyle(.inline)
        } label: {
          Label(.localized("Show Pane"), systemImage: "rectangle.on.rectangle")
        }
        .accessibilityIdentifier("session.panes")
      }
      if tab.panes.count > 1 || layout.tabs.count > 1 {
        Button(.localized("Close Pane"), systemImage: "xmark") {
          end(Self.ending(pane: tab.activePane, of: tab))
        }
        .accessibilityIdentifier("session.closePane")
      }
    }
  }

  @ViewBuilder
  private func tabsSection(
    _ layout: RemoteLayout,
    _ tab: RemoteLayout.Tab
  ) -> some View {
    Section(.localized("Tabs")) {
      Button(.localized("New Tab"), systemImage: "plus") {
        controller.perform(.newTab)
      }
      .accessibilityIdentifier("session.newTab")
      if layout.tabs.count > 1 {
        Menu {
          Picker(
            selection: Binding(
              get: { layout.activeTab },
              set: { controller.perform(.selectTab(tab: $0)) }
            )
          ) {
            ForEach(Array(layout.tabs.enumerated()), id: \.element.id) {
              index,
              tab in Text(Self.title(of: tab, at: index)).tag(tab.id)
            }
          } label: {
            EmptyView()
          }
          .pickerStyle(.inline)
        } label: {
          Label(.localized("Show Tab"), systemImage: "square.on.square")
        }
        .accessibilityIdentifier("session.tabs")
      }
      Button(.localized("Rename Tab…"), systemImage: "pencil") {
        // A numbered default is not offered for editing, as on the Mac.
        newName = tab.hasAutomaticName ? "" : tab.name
        renaming = .tab(tab.id)
      }
      .accessibilityIdentifier("session.renameTab")
      if layout.tabs.count > 1 {
        Button(.localized("Close Tab"), systemImage: "xmark") {
          end(Self.ending(tab: tab, in: layout))
        }
        .accessibilityIdentifier("session.closeTab")
      }
    }
  }

  @ViewBuilder
  private var workspacesSection: some View {
    Section(.localized("Workspaces")) {
      if let layout = controller.layout {
        Button(.localized("Rename Workspace…"), systemImage: "pencil") {
          newName = layout.workspaceName
          renaming = .workspace
        }
        .accessibilityIdentifier("session.renameWorkspace")
      }
      Button(.localized("Detach"), systemImage: "eject") { app.close(.detach) }
        .accessibilityHint(
          Text(
            "Disconnect from this workspace. Programs keep running on your Mac.",
            bundle: #bundle
          )
        )
        .accessibilityIdentifier("session.detach")
      if controller.model.sessionID != nil {
        Button(
          .localized("End Workspace…"),
          systemImage: "trash",
          role: .destructive
        ) { confirmTerminate = true }
      }
    }
  }

  private func commitRename() {
    defer { renaming = nil }
    let name = Self.renamed(newName)
    guard !name.isEmpty, let target = renaming else { return }
    switch target {
    case let .tab(id): controller.perform(.renameTab(tab: id, name: name))
    case .workspace: controller.perform(.renameWorkspace(name: name))
    }
  }

  /// A typed name as sent: trimmed, and cut at a character to the wire
  /// limit the host would otherwise refuse (spec.roaming.md §7.6).
  static func renamed(_ text: String) -> String {
    RemoteLayout.bounded(text.trimmingCharacters(in: .whitespacesAndNewlines))
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func end(_ request: EndRequest) {
    if request.confirms {
      ending = request
    } else {
      controller.perform(request.action)
    }
  }

  /// Ending `pane`; asks while its process runs, or when the layout does
  /// not list it.
  static func ending(pane: PaneID, of tab: RemoteLayout.Tab) -> EndRequest {
    let index = tab.panes.firstIndex { $0.id == pane }
    let name = index.map { title(of: tab.panes[$0], at: $0) } ?? ""
    return EndRequest(
      action: .closePane(pane: pane),
      confirms: index.map { !tab.panes[$0].exited } ?? true,
      message: String(localized: "End the pane “\(name)”?", bundle: #bundle),
      detail: String(
        localized: "Its process is still running and will be terminated.",
        bundle: #bundle
      )
    )
  }

  /// Ending `tab` and every pane in it; asks while any process runs.
  static func ending(
    tab: RemoteLayout.Tab,
    in layout: RemoteLayout
  ) -> EndRequest {
    let index = layout.tabs.firstIndex { $0.id == tab.id } ?? 0
    let name = title(of: tab, at: index)
    let count = tab.panes.count
    return EndRequest(
      action: .closeTab(tab: tab.id),
      confirms: tab.panes.isEmpty || tab.panes.contains { !$0.exited },
      message: String(localized: "End the tab “\(name)”?", bundle: #bundle),
      detail: count > 1
        ? String(
          localized:
            "Its \(count) panes and their processes will be terminated.",
          bundle: #bundle
        )
        : String(
          localized: "Its process is still running and will be terminated.",
          bundle: #bundle
        )
    )
  }

  /// The program's title, as the Mac shows it, else a numbered default.
  static func title(of pane: RemoteLayout.Pane, at index: Int) -> String {
    pane.displayTitle ?? String(localized: "Pane \(index + 1)", bundle: #bundle)
  }

  /// The given name, else the active pane's program (the Mac's tab strip
  /// replaces the service's numbered defaults the same way), else a
  /// numbered default.
  static func title(of tab: RemoteLayout.Tab, at index: Int) -> String {
    tab.displayName ?? String(localized: "Tab \(index + 1)", bundle: #bundle)
  }

  @ViewBuilder
  private var overlay: some View {
    switch controller.phase {
    case .preparing(let message): ProgressCard(message: message)
    case .running: EmptyView()
    case .failed(let problem):
      ProblemCard(problem: problem) { action in
        switch action {
        case .retry: controller.start(.selected)
        case .startNewSession: controller.start(.newSession)
        case .openOrdinarySSH:
          Task { await app.openOrdinarySSH(from: controller.model) }
        }
      }
    }
  }
}

/// Offered while the roaming attachment keeps failing (UDP blocked,
/// helper unreachable). Clearly a different shell (spec §9).
struct FallbackBanner: View {
  let model: TerminalScreenModel
  let app: RoamingAppModel
  var notice: EndpointStageNotice?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let notice {
        Text(EndpointStageNotice.title).font(.subheadline.bold())
          .accessibilityIdentifier("session.endpointStage")
        Text(notice.detail).font(.caption).foregroundStyle(.secondary)
          .selectableIfSupported()
      } else {
        Text("The roaming connection can't be reached.", bundle: #bundle)
          .font(.subheadline.bold())
      }
      Text(
        """
        An ordinary SSH shell opens separately. Your workspace remains on the \
        Mac and can be resumed later.
        """,
        bundle: #bundle
      )
      .font(.caption).foregroundStyle(.secondary)
      Button(.localized("Open Ordinary SSH Shell"), systemImage: "terminal") {
        Task { await app.openOrdinarySSH(from: model) }
      }
      .accessibilityIdentifier("session.openSSH")
    }
    .padding().frame(maxWidth: .infinity, alignment: .leading)
    .glassPanel(cornerRadius: 0).glassButtonStyle()
  }
}

// MARK: - Ordinary SSH

struct SSHSurfaceView: View {
  let controller: SSHShellController
  let app: RoamingAppModel

  var body: some View {
    VStack(spacing: 0) {
      // Never presented as the resumed workspace.
      Label(
        .localized(
          """
          Ordinary SSH shell. It is separate from your workspace and ends if the \
          connection drops.
          """
        ),
        systemImage: "exclamationmark.triangle"
      )
      .font(.caption).padding(.horizontal).padding(.vertical, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
      .glassPanel(cornerRadius: 0, tint: .yellow.opacity(0.2))
      if let notice = controller.inputNotice {
        HStack {
          Label(notice, systemImage: "exclamationmark.triangle")
          Spacer()
          Button(.localized("Dismiss"), systemImage: "xmark") {
            controller.dismissInputNotice()
          }
        }
        .font(.caption).padding(8)
        .glassPanel(cornerRadius: 0, tint: .yellow.opacity(0.2))
      }
      TerminalCanvas(
        session: controller.session,
        capabilities: controller.model.capabilities,
        configuration: app.terminalSettings.configuration()
      )
      .uiTestingScreenProbe(controller.model).terminalBacking()
      .overlay { overlay }
    }
    .ignoresSafeArea(.keyboard, edges: .bottom)
    .modifier(SSHSessionActions(controller: controller, app: app))
    .modifier(SSHScenePhaseForwarding(controller: controller))
    .task { controller.start() }
  }

  @ViewBuilder
  private var overlay: some View {
    switch controller.phase {
    case .preparing(let message): ProgressCard(message: message)
    case .running: EmptyView()
    case .failed(let problem):
      ProblemCard(
        problem: problem,
        retryTitle: controller.recovery != nil
          ? .localized("Reconnect Now") : .localized("Open New SSH Shell")
      ) { _ in
        // While recovering, try now in this screen; otherwise open a new,
        // different shell. Either way the old one is gone.
        guard !controller.retryNow() else { return }
        Task { await app.openOrdinarySSH(from: controller.model) }
      }
    }
  }
}

/// Forwards this window's scene phase to the SSH shell, which pauses
/// health checks and recovery in the background and checks the connection
/// on return (spec.roaming.md §9.1).
private struct SSHScenePhaseForwarding: ViewModifier {
  let controller: SSHShellController
  @Environment(\.scenePhase)
  private var scenePhase
  @State
  private var scene = UUID()

  func body(content: Content) -> some View {
    content.onAppear { controller.scenePhaseChanged(scenePhase, scene: scene) }
      .onChange(of: scenePhase) { _, phase in
        controller.scenePhaseChanged(phase, scene: scene)
      }
      .onDisappear { controller.scenePhaseChanged(nil, scene: scene) }
  }
}

/// The ordinary SSH shell's Files and Disconnect. iPhone and iPad have no
/// Close button, so a menu carries Disconnect; elsewhere Files stands
/// alone. A modifier keeps the platform branches out of the view's chain.
private struct SSHSessionActions: ViewModifier {
  let controller: SSHShellController
  let app: RoamingAppModel
  @State
  private var showsFiles = false

  func body(content: Content) -> some View {
    #if os(iOS) && !targetEnvironment(macCatalyst)
    content.toolbar {
      ToolbarItem(placement: .primaryAction) {
        Menu {
          if controller.model.profile.sftp {
            Section(.localized("Files")) { filesButton }
          }
          Button(.localized("Disconnect"), systemImage: "xmark") { app.close() }
            .accessibilityIdentifier("session.disconnect")
        } label: {
          Label(.localized("Session"), systemImage: "ellipsis")
        }
        .accessibilityIdentifier("session.menu")
      }
    }
    .adaptiveSheet(isPresented: $showsFiles) { browser }
    #elseif os(tvOS)
    content
    #else
    content.toolbar {
      if controller.model.profile.sftp {
        ToolbarItem(placement: .primaryAction) { filesButton }
      }
    }
    .adaptiveSheet(isPresented: $showsFiles) { browser }
    #endif
  }

  #if !os(tvOS)
  private var filesButton: some View {
    Button(.localized("Files…"), systemImage: "folder") { showsFiles = true }
      .accessibilityIdentifier("session.files")
  }

  private var browser: some View {
    SFTPBrowserView(selection: controller.selection, app: app)
      .macSheetFrame(width: 560, height: 480)
  }
  #endif
}

// MARK: - Shared pieces

struct ProgressCard: View {
  let message: LocalizedStringResource

  var body: some View {
    VStack(spacing: 12) {
      ProgressView()
      Text(message).font(.headline)
    }
    .padding(24).glassPanel().accessibilityElement(children: .combine)
  }
}

struct ProblemCard: View {
  let problem: SurfaceProblem
  var retryTitle: LocalizedStringResource = .localized("Try Again")
  let perform: (SurfaceAction) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(problem.title, systemImage: "exclamationmark.triangle")
        .font(.headline)
      Text(problem.detail).font(.callout).foregroundStyle(.secondary)
        .selectableIfSupported()
      ForEach(problem.actions, id: \.self) { action in
        switch action {
        case .retry:
          Button(retryTitle) { perform(.retry) }
            .glassButtonStyle(prominent: true)
            .accessibilityIdentifier("session.retry")
        case .startNewSession:
          Button(.localized("New Workspace")) { perform(.startNewSession) }
            .glassButtonStyle(prominent: true)
        case .openOrdinarySSH:
          VStack(alignment: .leading, spacing: 4) {
            Button(.localized("Open Ordinary SSH Shell")) {
              perform(.openOrdinarySSH)
            }
            .accessibilityIdentifier("session.openSSH")
            Text("Opens a separate SSH shell.", bundle: #bundle).font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .padding(24).frame(maxWidth: 480).glassPanel().glassButtonStyle().padding()
  }
}

// MARK: - Platform display

/// The terminal over its own background, which reaches the bottom edge
/// of the screen rather than stopping at the safe area.
struct TerminalCanvas: View {
  let session: TerminalSession
  let capabilities: SurfaceCapabilities
  var configuration: Configuration = Configuration()
  /// Paging between panes with a sideways drag; nil keeps every drag for
  /// scrolling (UIKit only).
  var paneSwitching: PaneSwitching? = nil
  #if canImport(UIKit)
  /// The terminal's background, translucent when the configuration's
  /// `background-opacity` is below 1.
  @State
  private var background: UIColorBox?
  #endif

  var body: some View {
    #if canImport(UIKit)
    TerminalDisplayView(
      session: session,
      capabilities: capabilities,
      configuration: configuration,
      onBackgroundColor: { background = UIColorBox(color: $0) },
      paneSwitching: paneSwitching
    )
    // The terminal lifts itself above the keyboard; SwiftUI must not
    // shrink it, which would resize the grid.
    .ignoresSafeArea(.keyboard, edges: .bottom)
    // A translucent fill would stack under the terminal's own.
    .background {
      if let background, background.isOpaque {
        Color(uiColor: background.color).ignoresSafeArea(edges: .bottom)
      }
    }
    .preference(
      key: TerminalBackgroundKey.self,
      value: background.map { Color(uiColor: $0.color) }
    )
    #else
    TerminalDisplayView(
      session: session,
      capabilities: capabilities,
      configuration: configuration
    )
    #endif
  }
}

#if canImport(UIKit)
/// The reported background, kept as a `UIColor` so its opacity is known.
struct UIColorBox: Equatable {
  let color: UIColor
  var isOpaque: Bool { color.cgColor.alpha >= 1 }
}
#endif

/// The terminal's background color, at its own opacity, reported up to
/// `TerminalScreen` so the navigation bar and safe areas can match it.
struct TerminalBackgroundKey: PreferenceKey {
  static let defaultValue: Color? = nil

  static func reduce(value: inout Color?, nextValue: () -> Color?) {
    value = value ?? nextValue()
  }
}

#if canImport(UIKit)
/// Hosts `TerminalUIView` (iOS, iPadOS, Mac Catalyst, visionOS, tvOS).
struct TerminalDisplayView: UIViewRepresentable {
  let session: TerminalSession
  let capabilities: SurfaceCapabilities
  var configuration: Configuration = Configuration()
  /// The terminal's background color, for filling the margins outside
  /// the view.
  var onBackgroundColor: ((UIColor) -> Void)?
  var paneSwitching: PaneSwitching? = nil

  func makeUIView(context: Context) -> UIView {
    do {
      let view = try TerminalUIView(
        session: session,
        configuration: configuration
      )
      view.capabilities = capabilities
      // App-switcher snapshots omit terminal content (spec §12).
      view.hidesContentWhenInactive = true
      DispatchQueue.main.async { _ = view.becomeFirstResponder() }
      let clip = TerminalClipView(terminal: view, configuration: configuration)
      attach(clip)
      return clip
    } catch {
      let label = UILabel()
      label.text = String(
        localized: "Terminal rendering is unavailable on this device.",
        bundle: #bundle
      )
      label.textAlignment = .center
      label.numberOfLines = 0
      return label
    }
  }

  func updateUIView(_ view: UIView, context: Context) {
    guard let clip = view as? TerminalClipView else { return }
    let view = clip.terminal
    attach(clip)
    if clip.appliedConfiguration != configuration {
      clip.applyConfiguration(configuration)
    }
    guard view.capabilities != capabilities else { return }
    view.capabilities = capabilities
  }

  /// The background report and pane paging, through the clip view.
  private func attach(_ clip: TerminalClipView) {
    let handler = onBackgroundColor
    clip.terminal.onBackgroundColor = { [weak clip] color in
      clip?.pageColor = color.withAlphaComponent(1)
      handler?(color)
    }
    clip.paneSwitching = paneSwitching
    clip.terminal.onPaneDrag =
      paneSwitching == nil ? nil : { [weak clip] in clip?.drag($0) }
    // The drag's end would now reach no handler.
    if paneSwitching == nil { clip.endPaging() }
  }
}

/// Clips the terminal to its frame: lifted above a docked keyboard, its
/// top scrolls out of view instead of over the navigation bar.
final class TerminalClipView: UIView {
  let terminal: TerminalUIView
  var paneSwitching: PaneSwitching?
  private(set) var appliedConfiguration: Configuration
  /// The terminal's background, opaque: shown where no page is drawn.
  var pageColor: UIColor?
  /// Horizontal displacement of the pages; zero at rest.
  private var slideOffset: CGFloat = 0
  /// The neighbouring pane's last screen, beside the terminal while
  /// paging. Created on the first drag; never interactive.
  private var neighbor: TerminalUIView?
  /// Where the neighbour sits: 1 to the right (the next pane), -1 to the
  /// left, 0 over the terminal while the new pane's screen arrives.
  private var neighborSide: CGFloat = 0
  /// Increments per page turn or settle; a stale completion does nothing.
  private var pageGeneration = 0
  /// A finger is moving the pages.
  private var dragging = false
  static let turnDuration: TimeInterval = 0.25
  /// Longest wait for the new pane's screen once the page has turned.
  static let arrivalTimeout: TimeInterval = 0.8

  init(terminal: TerminalUIView, configuration: Configuration) {
    self.terminal = terminal
    self.appliedConfiguration = configuration
    super.init(frame: .zero)
    clipsToBounds = true
    addSubview(terminal)
  }

  func applyConfiguration(_ configuration: Configuration) {
    appliedConfiguration = configuration
    terminal.apply(configuration)
    neighbor?.apply(configuration)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func layoutSubviews() {
    super.layoutSubviews()
    // Bounds and center, not frame: the lift is a transform.
    let size = CGRect(origin: .zero, size: bounds.size)
    terminal.bounds = size
    terminal.center = CGPoint(x: bounds.midX + slideOffset, y: bounds.midY)
    if let neighbor {
      neighbor.bounds = size
      neighbor.transform = terminal.transform
      neighbor.center = CGPoint(
        x: bounds.midX + slideOffset + neighborSide * bounds.width,
        y: bounds.midY
      )
    }
  }

  /// Follows a sideways drag: the terminal and the neighbouring pane move
  /// with the finger; on release the page turns or settles back. With
  /// Reduce Motion nothing moves and a committed drag switches at once.
  func drag(_ drag: PaneDrag) {
    let reduceMotion = UIAccessibility.isReduceMotionEnabled
    switch drag {
    case let .changed(dx):
      guard !reduceMotion, bounds.width > 0 else { return }
      if !dragging {
        dragging = true
        beginPaging()
      }
      show(side: dx < 0 ? 1 : -1)
      slideOffset = dx
      setNeedsLayout()
      layoutIfNeeded()
    case let .ended(dx, velocity):
      dragging = false
      let next = PaneDrag.commit(
        travel: dx,
        velocity: velocity,
        width: bounds.width
      )
      if let next {
        if reduceMotion { paneSwitching?.commit(next) } else { turn(next) }
      } else {
        settle()
      }
    case .cancelled:
      dragging = false
      settle()
    }
  }

  /// Paging was withdrawn (one pane left): a drag in progress settles
  /// back instead of leaving the pages displaced.
  func endPaging() {
    guard dragging else { return }
    dragging = false
    settle()
  }

  /// Takes over from any turn still settling: the terminal shows its
  /// pane again and the neighbour is placed afresh.
  private func beginPaging() {
    pageGeneration &+= 1
    terminal.onScreenReplaced = nil
    terminal.holdsFrames = false
    terminal.alpha = 1
    neighborSide = 0
    backgroundColor = pageColor
  }

  /// Puts the neighbour on `side` showing that pane's last screen, or
  /// hides it (the page colour shows) when there is none yet.
  private func show(side: CGFloat) {
    guard side != neighborSide || neighbor == nil else { return }
    neighborSide = side
    guard let view = neighbor ?? makeNeighbor() else { return }
    if let screen = paneSwitching?.neighborScreen(side > 0),
      view.session.installPresentation(screen)
    {
      view.isHidden = false
    } else {
      view.isHidden = true
    }
  }

  private func makeNeighbor() -> TerminalUIView? {
    let session = TerminalSession(
      presentationColumns: 80,
      rows: 24,
      configuration: appliedConfiguration.sessionConfiguration()
    )
    guard
      let view = try? TerminalUIView(
        session: session,
        configuration: appliedConfiguration
      )
    else { return nil }
    view.isUserInteractionEnabled = false
    view.accessibilityElementsHidden = true
    view.hidesContentWhenInactive = true
    view.isHidden = true
    addSubview(view)
    neighbor = view
    return view
  }

  /// Completes the turn and asks for the pane. The terminal keeps the old
  /// pane's picture while it leaves; once out of sight it returns under
  /// the neighbour's picture and takes over when the new screen is drawn.
  private func turn(_ next: Bool) {
    let side: CGFloat = next ? 1 : -1
    show(side: side)
    pageGeneration &+= 1
    let generation = pageGeneration
    terminal.holdsFrames = true
    paneSwitching?.commit(next)
    slideOffset = -side * bounds.width
    setNeedsLayout()
    UIView.animate(
      withDuration: Self.turnDuration,
      delay: 0,
      options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]
    ) {
      self.layoutIfNeeded()
    } completion: { [weak self] _ in
      self?.turned(generation)
    }
  }

  private func turned(_ generation: Int) {
    guard generation == pageGeneration else { return }
    UIView.performWithoutAnimation {
      slideOffset = 0
      neighborSide = 0
      setNeedsLayout()
      layoutIfNeeded()
    }
    // Under the neighbour's picture, or hidden when there is none.
    if neighbor?.isHidden ?? true { terminal.alpha = 0 }
    terminal.onScreenReplaced = { [weak self] in self?.finish(generation) }
    terminal.holdsFrames = false
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.arrivalTimeout) {
      [weak self] in self?.finish(generation)
    }
  }

  private func finish(_ generation: Int) {
    guard generation == pageGeneration else { return }
    terminal.onScreenReplaced = nil
    terminal.holdsFrames = false
    terminal.alpha = 1
    neighbor?.isHidden = true
    neighborSide = 0
    backgroundColor = nil
  }

  /// Back to the shown pane.
  private func settle() {
    pageGeneration &+= 1
    let generation = pageGeneration
    terminal.holdsFrames = false
    terminal.alpha = 1
    guard slideOffset != 0 else { return finish(generation) }
    slideOffset = 0
    setNeedsLayout()
    UIView.animate(
      withDuration: Self.turnDuration,
      delay: 0,
      usingSpringWithDamping: 0.9,
      initialSpringVelocity: 0,
      options: [.beginFromCurrentState, .allowUserInteraction]
    ) {
      self.layoutIfNeeded()
    } completion: { [weak self] _ in
      self?.finish(generation)
    }
  }
}
#elseif os(macOS)
/// Hosts the AppKit `TerminalView` (native macOS: the SwiftPM test host).
struct TerminalDisplayView: NSViewRepresentable {
  let session: TerminalSession
  let capabilities: SurfaceCapabilities
  var configuration: Configuration = Configuration()
  var prepare: ((TerminalView) -> Void)?

  final class Coordinator {
    var appliedConfiguration: Configuration
    init(configuration: Configuration) {
      self.appliedConfiguration = configuration
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(configuration: configuration)
  }

  func makeNSView(context: Context) -> NSView {
    do {
      let view = try TerminalView(
        configuration: configuration,
        session: session
      )
      view.capabilities = capabilities
      prepare?(view)
      DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
      return view
    } catch {
      return NSTextField(
        labelWithString: String(
          localized: "Terminal rendering is unavailable on this Mac.",
          bundle: #bundle
        )
      )
    }
  }

  func updateNSView(_ view: NSView, context: Context) {
    guard let view = view as? TerminalView else { return }
    if context.coordinator.appliedConfiguration != configuration {
      context.coordinator.appliedConfiguration = configuration
      view.apply(configuration)
    }
    guard view.capabilities != capabilities else { return }
    view.capabilities = capabilities
  }
}
#endif
