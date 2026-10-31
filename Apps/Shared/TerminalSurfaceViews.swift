import SessionCore
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

  var body: some View {
    TerminalCanvas(
      session: controller.display,
      capabilities: controller.model.capabilities
    )
    .uiTestingScreenProbe(controller.model)
    .glassSurface(fillsSafeArea: false).overlay { overlay }
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
            Button(.localized("Files…"), systemImage: "folder") {
              showsFiles = true
            }
            .accessibilityIdentifier("session.files")
          }
          #endif
          Button(.localized("Detach"), systemImage: "eject") {
            app.close(.detach)
          }
          .accessibilityIdentifier("session.detach")
          if controller.model.sessionID != nil {
            Button(
              .localized("Terminate Session…"),
              systemImage: "xmark.octagon",
              role: .destructive
            ) { confirmTerminate = true }
          }
        } label: {
          Label(.localized("Session"), systemImage: "ellipsis.circle")
        }
        .accessibilityIdentifier("session.menu")
      }
    }
    .confirmationDialog(
      Text(
        "Terminate the session on \(controller.model.host.nickname)?",
        bundle: #bundle
      ),
      isPresented: $confirmTerminate,
      titleVisibility: .visible
    ) {
      Button(.localized("Terminate Session"), role: .destructive) {
        app.close(.terminate)
      }
      Button(.localized("Cancel"), role: .cancel) {}
    } message: {
      Text(
        "The shell on the Mac and every program running in it will be ended.",
        bundle: #bundle
      )
    }
    #if !os(tvOS)
    .adaptiveSheet(isPresented: $showsFiles) {
      SFTPBrowserView(selection: controller.selection, app: app)
      .macSheetFrame(width: 560, height: 480)
    }
    #endif
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
        An ordinary SSH shell is a different shell. The roaming session stays \
        on the Mac and can be resumed later.
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
  @State
  private var showsFiles = false

  var body: some View {
    VStack(spacing: 0) {
      // Never presented as the resumed roaming session.
      Label(
        .localized(
          "Ordinary SSH shell — not the roaming session. It ends if the connection drops."
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
        capabilities: controller.model.capabilities
      )
      .uiTestingScreenProbe(controller.model)
      .glassSurface(fillsSafeArea: false).overlay { overlay }
    }
    .ignoresSafeArea(.keyboard, edges: .bottom)
    #if !os(tvOS)
    .toolbar {
      if controller.model.profile.sftp {
        ToolbarItem(placement: .primaryAction) {
          Button(.localized("Files…"), systemImage: "folder") {
            showsFiles = true
          }.accessibilityIdentifier("session.files")
        }
      }
    }
    .adaptiveSheet(isPresented: $showsFiles) {
      SFTPBrowserView(selection: controller.selection, app: app)
      .macSheetFrame(width: 560, height: 480)
    }
    #endif
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
        retryTitle: .localized("Open New SSH Shell")
      ) { _ in
        // A new, different shell; the old one is gone.
        Task { await app.openOrdinarySSH(from: controller.model) }
      }
    }
  }
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
          Button(.localized("Start New Session")) { perform(.startNewSession) }
            .glassButtonStyle(prominent: true)
        case .openOrdinarySSH:
          VStack(alignment: .leading, spacing: 4) {
            Button(.localized("Open Ordinary SSH Shell")) {
              perform(.openOrdinarySSH)
            }
            .accessibilityIdentifier("session.openSSH")
            Text(
              "A different shell; it is not the roaming session.",
              bundle: #bundle
            )
            .font(.caption).foregroundStyle(.secondary)
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
      onBackgroundColor: { background = UIColorBox(color: $0) }
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
    TerminalDisplayView(session: session, capabilities: capabilities)
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
  /// The terminal's background color, for filling the margins outside
  /// the view.
  var onBackgroundColor: ((UIColor) -> Void)?

  func makeUIView(context: Context) -> UIView {
    do {
      let view = try TerminalUIView(session: session)
      view.capabilities = capabilities
      view.onBackgroundColor = backgroundHandler
      // App-switcher snapshots omit terminal content (spec §12).
      view.hidesContentWhenInactive = true
      DispatchQueue.main.async { _ = view.becomeFirstResponder() }
      return TerminalClipView(terminal: view)
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
    guard let view = (view as? TerminalClipView)?.terminal else { return }
    view.onBackgroundColor = backgroundHandler
    guard view.capabilities != capabilities else { return }
    view.capabilities = capabilities
  }

  private var backgroundHandler: (UIColor) -> Void {
    let handler = onBackgroundColor
    return { handler?($0) }
  }

}

/// Clips the terminal to its frame: lifted above a docked keyboard, its
/// top scrolls out of view instead of over the navigation bar.
final class TerminalClipView: UIView {
  let terminal: TerminalUIView

  init(terminal: TerminalUIView) {
    self.terminal = terminal
    super.init(frame: .zero)
    clipsToBounds = true
    addSubview(terminal)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func layoutSubviews() {
    super.layoutSubviews()
    // Bounds and center, not frame: the lift is a transform.
    terminal.bounds = CGRect(origin: .zero, size: bounds.size)
    terminal.center = CGPoint(x: bounds.midX, y: bounds.midY)
  }
}
#elseif os(macOS)
/// Hosts the AppKit `TerminalView` (native macOS: the SwiftPM test host).
struct TerminalDisplayView: NSViewRepresentable {
  let session: TerminalSession
  let capabilities: SurfaceCapabilities
  var prepare: ((TerminalView) -> Void)?

  func makeNSView(context: Context) -> NSView {
    do {
      let view = try TerminalView(
        configuration: Configuration(),
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
    guard let view = view as? TerminalView, view.capabilities != capabilities
    else { return }
    view.capabilities = capabilities
  }
}
#endif
