import Foundation
import Network
import Observation
import SSHClient
import ScreenProtocol
import SwiftMuxProtocol
import SessionCore
import SwiftUI
import SwifttyCore
import Synchronization
import TerminalSurface

// Live surfaces behind `TerminalScreen`: one MainActor controller per
// opened `TerminalScreenModel`, owning the display session and its backend.

/// Real surfaces for `app`'s sessions: a roaming presentation fed by
/// `RoamingClient`, or an ordinary SSH shell.
public struct LiveTerminalSurfaceFactory: TerminalSurfaceFactory {
  private weak let app: RoamingAppModel?

  public init(app: RoamingAppModel) { self.app = app }

  @MainActor
  public func makeSurface(for model: TerminalScreenModel) -> AnyView {
    guard let app else { return AnyView(EmptyView()) }
    return AnyView(LiveTerminalSurface(model: model, app: app))
  }
}

/// What a surface can offer when it cannot show a working terminal.
enum SurfaceAction: Hashable, Sendable {
  /// Try the same thing again (fresh SSH authorization).
  case retry
  /// Forget the old roaming session and create a new one.
  case startNewSession
  /// Open an ordinary SSH shell: a different shell (spec §9).
  case openOrdinarySSH
}

/// A nonsecret explanation of why no working terminal is shown.
struct SurfaceProblem: Equatable, Sendable {
  var title: LocalizedStringResource
  /// Already localized. A `String` rather than a resource so values it
  /// interpolates (key lines, addresses) are never read as Markdown.
  var detail: String
  var actions: [SurfaceAction]
}

enum SurfacePhase: Equatable, Sendable {
  /// Sign-in or setup in progress, with a short description.
  case preparing(LocalizedStringResource)
  /// The backend owns the state; the status bar mirrors it.
  case running
  case failed(SurfaceProblem)
}

/// SSH succeeded and granted an attachment, but the grant's roaming
/// endpoint could not be reached. Names the endpoint SSH returned and
/// never blames authentication, guesses at firewalls or permissions, or
/// substitutes another address.
struct EndpointStageNotice: Hashable, Sendable {
  static let title: LocalizedStringResource = .localized(
    "SSH connected; roaming endpoint unavailable"
  )
  let endpoint: String
  let timedOut: Bool
  /// What the network or TLS stack reported, verbatim.
  let reason: String?

  init?(
    state: ClientConnectionState,
    failure: RoamingFailure?,
    endpoint: BootstrapEndpoint?,
    reason: String? = nil
  ) {
    guard let endpoint, state == .attaching || state == .reconnecting else {
      return nil
    }
    switch failure {
    case .endpointUnreachable: timedOut = false
    case .attachTimedOut: timedOut = true
    default: return nil
    }
    let host =
      endpoint.host.contains(":") ? "[\(endpoint.host)]" : endpoint.host
    self.endpoint = "\(host):\(endpoint.port) (UDP)"
    self.reason = timedOut ? nil : reason.flatMap { $0.isEmpty ? nil : $0 }
  }

  /// Localized plain text: the endpoint and reason are never read as
  /// Markdown.
  var detail: String {
    let advice = String(
      localized: """
        Sign-in succeeded; this address is the one the Mac's roaming \
        configuration advertises. A local-network name or address may not be \
        reachable over the route used for SSH, such as cellular or a VPN. \
        The workspace is kept on the Mac.
        """,
      bundle: #bundle
    )
    let stage =
      timedOut
      ? String(
        localized:
          "The Mac's roaming endpoint at \(endpoint) did not answer in time. \(advice)",
        bundle: #bundle
      )
      : String(
        localized:
          "The Mac's roaming endpoint at \(endpoint) could not be reached. \(advice)",
        bundle: #bundle
      )
    guard let reason else { return stage }
    return String(
      localized: "\(stage) Reported error: \(reason).",
      bundle: #bundle
    )
  }
}

// MARK: - Roaming

/// One roaming terminal: a presentation-mode `TerminalSession` displaying
/// frames from a `RoamingClient` built from the host profile.
///
/// Sign-in runs one interactive SSH connection first (password prompt,
/// explicit unknown-key decision); the client's own bootstraps afterwards
/// use `RejectUnknownHostKeys`, so automatic reconnects never prompt.
@MainActor
@Observable
final class RoamingTerminalController: TerminalSurfaceController {
  enum StartChoice {
    /// The workspace the user chose (`WorkspaceIntent`); a retry reuses
    /// it, resuming a workspace once one was granted. Without a choice,
    /// only a remembered workspace is resumed: nothing is created.
    case selected
    /// An explicit New Workspace: forget the remembered session and
    /// create one.
    case newSession
  }

  let model: TerminalScreenModel
  let display: TerminalSession
  private(set) var phase: SurfacePhase = .preparing(.localized("Signing in"))
  /// The workspace's tabs and panes, from a host with `layoutControl`;
  /// nil hides the Panes and Tabs menus.
  private(set) var layout: RemoteLayout?
  /// Why the last layout action failed, until dismissed.
  var layoutFailure: String?
  /// Frames on their way to `display`, so a pane's screen can be kept
  /// when it is left.
  @ObservationIgnored
  private lazy var frameTap = FrameTap(forward: display)
  /// Each pane's last screen, shown beside the terminal while paging to it.
  @ObservationIgnored
  private var paneScreens: [PaneID: PresentationFrame] = [:]

  @ObservationIgnored
  private weak var app: RoamingAppModel?
  @ObservationIgnored
  private(set) var selection: HostConnectionSelection
  @ObservationIgnored
  private var backend: RoamingScreenBackend?
  private var client: RoamingClient? { backend?.client }
  @ObservationIgnored
  private var grid = GridSize(columns: 80, rows: 24)
  @ObservationIgnored
  private var runTask: Task<Void, Never>?
  /// Lifecycle and grid calls to the client, applied in order.
  @ObservationIgnored
  private let lifecycleQueue = ClientLifecycleQueue()
  /// Layout actions, in order among themselves. Each waits for the host's
  /// answer, which a half-open path withholds until reattachment, so they
  /// never hold up lifecycle calls or a close.
  @ObservationIgnored
  private let layoutQueue = ClientLifecycleQueue()
  @ObservationIgnored
  private var closed = false
  /// The detach or terminate begun by `beginClose(_:)`.
  @ObservationIgnored
  private var closing: Task<Void, Never>?
  @ObservationIgnored
  private var started = false
  @ObservationIgnored
  private var monitor: NWPathMonitor?
  @ObservationIgnored
  private var pathSeen = false
  /// The windows showing this screen.
  @ObservationIgnored
  private var scenes = ScenePhases()
  /// The last lifecycle call was `enterBackground`.
  @ObservationIgnored
  private var backgrounded = false
  #if os(macOS) || targetEnvironment(macCatalyst)
  @ObservationIgnored
  private var powerMonitor: SystemPowerMonitor?
  #endif
  /// The workspace this screen attaches to, once chosen.
  @ObservationIgnored
  private(set) var intent: WorkspaceIntent?

  init(model: TerminalScreenModel, app: RoamingAppModel) {
    self.model = model
    self.app = app
    selection = model.selection ?? app.connectionSelection(for: model.host)
    model.selection = selection
    let display = TerminalSession(
      presentationColumns: 80,
      rows: 24,
      configuration: Configuration().sessionConfiguration()
    )
    self.display = display
    display.gridProposalHandler = { [weak self] columns, rows in
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.propose(columns: columns, rows: rows) }
      }
    }
    // Scrolling moves this client's own history window on the host.
    display.viewportScrollHandler = { [weak self] lines in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          _ = self?.serial { await $0.scrollViewport(by: lines) }
        }
      }
    }
    // A selection reaching beyond the shown rows is copied from the host
    // (spec.roaming.md §7.5); the view writes the pasteboard when it lands.
    display.remoteCopyHandler = { [weak self] selection, done in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let client = self?.client else { return done(nil) }
          Task { done(try? await client.copySelection(selection)) }
        }
      }
    }
    model.previewLines = { [display] in display.withState { $0.screenLines } }
    observeSystem()
  }

  /// First display: start once. Later attempts are explicit user actions,
  /// so a lost session is never silently replaced by a new one.
  func startIfNeeded() {
    guard !started else { return }
    start()
  }

  /// Starts (or retries) sign-in and attachment. No-op while running.
  func start(_ choice: StartChoice = .selected) {
    guard !closed, runTask == nil else { return }
    started = true
    runTask = Task {
      await run(choice)
      runTask = nil
    }
  }

  private func run(_ choice: StartChoice) async {
    guard let app else { return }
    do {
      selection = try await app.ssh.prepare(selection)
      model.selection = selection
    } catch {
      guard !closed else { return }
      phase = .failed(Self.problem(for: error))
      return
    }
    guard !closed, !Task.isCancelled else { return }
    let host = selection.host
    if choice == .newSession {
      app.forgetSession(for: selection)
      _ = model.takeWorkspaceIntent()
      intent = .create
    } else if let chosen = model.takeWorkspaceIntent() {
      intent = chosen
    } else if intent == nil,
      let remembered = app.resumableSessionID(for: selection)
    {
      intent = .resume(remembered, nil)
    }
    guard let intent else {
      phase = .failed(Self.noWorkspaceChosen)
      return
    }
    phase = .preparing(.localized("Signing in"))
    if let old = backend {
      backend = nil
      display.semanticInputHandler = nil
      lifecycleQueue.use(nil)
      layoutQueue.use(nil)
      await old.close()
    }
    guard !closed, !Task.isCancelled else { return }
    let endpoint: SSHEndpoint
    do {
      // Interactive trust and credential check; the client's own SSH
      // bootstraps then run without prompts.
      let probe = try await app.ssh.connectPrepared(selection)
      await probe.close()
      guard !closed, !Task.isCancelled else { return }
      endpoint = try await app.ssh.bootstrapEndpoint(for: selection)
    } catch {
      guard !closed else { return }
      phase = .failed(Self.problem(for: error))
      return
    }
    guard !closed, !Task.isCancelled else { return }

    let backend = RoamingScreenBackend(
      bootstrapper: SSHBootstrapper(endpoint: endpoint),
      connector: QUICGrantConnector(fallbackHost: endpoint.configuration.host),
      sink: frameTap,
      configuration: RoamingClientConfiguration(initialGrid: grid)
    )
    self.backend = backend
    backend.bindInput(to: display)
    let client = backend.client
    lifecycleQueue.use(client)
    layoutQueue.use(client)
    let token = ObjectIdentifier(client)
    let frameTap = frameTap
    backend.onStatus = { [weak self] status in
      // In order with the frames the client installs: the shown pane's
      // next frame follows its Layout.
      frameTap.show(status.layout?.activeTabLayout?.activePane)
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.apply(status, from: token) }
      }
    }

    guard !closed, !Task.isCancelled else { return }

    let target: RoamingTarget =
      switch intent {
      case .create: .create(grid)
      case let .resume(id, reveal?): .reveal(id, reveal)
      case let .resume(id, nil): .resume(id)
      }
    let resuming = intent != .create
    // A reveal's pane focus and takeover apply to this attempt only.
    if case let .resume(id, _?) = intent { self.intent = .resume(id, nil) }
    phase = .preparing(
      resuming
        ? .localized("Resuming workspace") : .localized("Starting workspace")
    )
    do {
      try await backend.start(target)
      guard !closed else { return }
      if case .preparing = phase { phase = .running }
    } catch {
      guard !closed, self.client === client else { return }
      if error == .sessionLost || error == .sessionExited {
        app.forgetSession(for: selection)
      }
      if error == .authenticationFailed { app.forgetPassword(for: host) }
      phase = .failed(Self.problem(for: error, resuming: resuming))
    }
  }

  private func apply(_ status: RoamingStatus, from token: ObjectIdentifier) {
    guard !closed, let client, ObjectIdentifier(client) == token else { return }
    model.observe(status)
    if status.layout != layout {
      layout = status.layout
      // Forget closed panes' screens.
      let live = Set(layout?.tabs.flatMap { $0.panes.map(\.id) } ?? [])
      paneScreens = paneScreens.filter { live.contains($0.key) }
    }
    guard let app else { return }
    switch status.state {
    case .sessionLost:
      app.forgetSession(for: selection)
      phase = .failed(Self.problem(for: .sessionLost, resuming: false))
    case .sessionExited:
      app.forgetSession(for: selection)
      phase = .failed(Self.exited(status.exitStatus))
    case .userClosed: break
    default:
      if let id = status.sessionID {
        app.rememberSession(id, for: selection)
        // A retry reattaches the granted workspace; it never creates again.
        if intent == .create { intent = .resume(id, nil) }
      }
      if status.state == .active, phase != .running { phase = .running }
    }
  }

  /// Changes the workspace layout on the Mac; the screen follows the
  /// active pane. A refusal is shown; a reattachment cancels silently.
  func perform(_ action: LayoutAction) {
    keepShownPaneScreen()
    guard !closed else { return }
    layoutQueue.enqueue { [weak self] client in
      do { try await client.layout(action) } catch let error
        as RoamingClient.LayoutError
      {
        guard error.code != .staleEpoch else { return }
        let message = Self.describe(error.code)
        DispatchQueue.main.async {
          MainActor.assumeIsolated { self?.layoutFailure = message }
        }
      } catch {}
    }
  }

  /// The shown tab has another pane to swipe to.
  var canSwitchPanes: Bool { (layout?.activeTabLayout?.panes.count ?? 0) > 1 }

  /// Shows the next (or previous) pane of the shown tab, wrapping around.
  func switchPane(next: Bool) {
    guard let tab = layout?.activeTabLayout,
      let target = Self.neighbor(
        of: tab.activePane,
        in: tab.panes.map(\.id),
        next: next
      )
    else { return }
    perform(.focusPane(pane: target))
  }

  /// The last screen seen of the pane a page turn would show.
  func neighborScreen(next: Bool) -> PresentationFrame? {
    guard let tab = layout?.activeTabLayout,
      let target = Self.neighbor(
        of: tab.activePane,
        in: tab.panes.map(\.id),
        next: next
      )
    else { return nil }
    return paneScreens[target]
  }

  /// Keeps the shown pane's screen for when the user pages back to it.
  private func keepShownPaneScreen() {
    // Filed under the pane the frame shows, which lags a Layout that
    // already names the next pane.
    guard let (pane, frame) = frameTap.latestPaneFrame else { return }
    paneScreens[pane] = frame
  }

  /// The pane after (or before) `current`, wrapping; nil with no other.
  nonisolated static func neighbor<ID: Equatable>(
    of current: ID,
    in panes: [ID],
    next: Bool
  ) -> ID? {
    guard panes.count > 1, let index = panes.firstIndex(of: current) else {
      return nil
    }
    let step = next ? 1 : panes.count - 1
    return panes[(index + step) % panes.count]
  }

  nonisolated static func describe(_ code: RSTErrorCode) -> String {
    switch code {
    case .unsupported, .notAttached:
      String(
        localized: "The Mac isn't accepting layout changes right now.",
        bundle: #bundle
      )
    case .writerBusy:
      String(
        localized: "Another device is controlling this workspace.",
        bundle: #bundle
      )
    case .limitExceeded:
      String(
        localized: "The workspace can't hold any more panes or tabs.",
        bundle: #bundle
      )
    case .inputInvalid:
      String(
        localized: "That tab or pane is no longer there, or the name was refused.",
        bundle: #bundle
      )
    default:
      String(localized: "The Mac couldn't change the layout.", bundle: #bundle)
    }
  }

  /// Whether to offer the ordinary-SSH fallback while the roaming
  /// attachment keeps failing (e.g. UDP blocked; spec §9).
  var offersOrdinarySSH: Bool {
    guard model.profile.sshShell, phase == .running else { return false }
    switch model.connectionState {
    case .attaching, .reconnecting:
      return model.reconnectAttempt >= 2 || model.lastFailure == .attachTimedOut
        || model.lastFailure == .endpointUnreachable
    default: return false
    }
  }

  /// Which stage failed when SSH authorized an attachment but its QUIC
  /// endpoint did not answer (spec.connection-setup.md D6).
  var endpointNotice: EndpointStageNotice? {
    guard phase == .running else { return nil }
    return EndpointStageNotice(
      state: model.connectionState,
      failure: model.lastFailure,
      endpoint: model.roamingEndpoint,
      reason: model.lastFailureDetail
    )
  }

  // MARK: Lifecycle

  /// Mobile, spatial and TV scenes detach in the background and
  /// reattach in the foreground. A Mac window losing focus is not a
  /// suspension; sleep is (spec §9, `SystemPowerMonitor`).
  ///
  /// The controller belongs to the screen model, which more than one
  /// window can show, so only the windows' combined phase counts: one of
  /// two windows going to the background detaches nothing. Transient
  /// inactivity (Control Center, a permission alert) never detaches
  /// (spec.apple.md A02). Whether the last call detached is remembered, so
  /// a window shown after the others went away still reattaches, while a
  /// screen's first appearance does not.
  func scenePhaseChanged(_ phase: ScenePhase?, scene: UUID) {
    guard let change = scenes.set(phase, for: scene) else { return }
    switch model.profile.kind {
    case .catalyst: return
    case .mobile, .vision, .tv: break
    }
    switch change.new {
    case .background where !backgrounded:
      backgrounded = true
      serial { await $0.enterBackground() }
    case .active where change.old != nil || backgrounded:
      backgrounded = false
      serial { await $0.enterForeground() }
    default: break
    }
  }

  private func propose(columns: Int, rows: Int) {
    let next = GridSize(
      columns: min(max(columns, 1), RSTLimits.maxColumns),
      rows: min(max(rows, 1), RSTLimits.maxRows)
    )
    guard next != grid else { return }
    // Kept even without a client (e.g. during SSH sign-in): the next
    // client starts from `grid`, so the latest proposal is never lost.
    grid = next
    serial { await $0.proposeGrid(columns: next.columns, rows: next.rows) }
  }

  @discardableResult
  private func serial(
    _ operation: @escaping @Sendable (RoamingClient) async -> Void
  ) -> Task<Void, Never>? {
    guard !closed else { return nil }
    return lifecycleQueue.enqueue(operation)
  }

  private func observeSystem() {
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { [weak self] _ in
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.pathChanged() }
      }
    }
    monitor.start(queue: DispatchQueue(label: "dev.swiftty.roaming.path"))
    self.monitor = monitor
    #if os(macOS) || targetEnvironment(macCatalyst)
    // A Mac: sleep detaches, wake reattaches; focus does not.
    powerMonitor = SystemPowerMonitor(
      onSleep: { [weak self] in self?.serial { await $0.enterBackground() } },
      onWake: { [weak self] in self?.serial { await $0.wake() } }
    )
    #endif
  }

  /// A path change is a hint to probe, never proof of failure.
  private func pathChanged() {
    guard pathSeen else {
      pathSeen = true
      return
    }
    serial { await $0.pathChanged() }
  }

  func beginClose(_ mode: RoamingCloseMode) -> Task<Void, Never> {
    if let closing { return closing }
    closed = true
    runTask?.cancel()
    let pendingLifecycle = lifecycleQueue.use(nil)
    layoutQueue.use(nil)
    backend?.stopInput()
    monitor?.cancel()
    #if os(macOS) || targetEnvironment(macCatalyst)
    powerMonitor?.invalidate()
    powerMonitor = nil
    #endif
    display.semanticInputHandler = nil
    display.gridProposalHandler = nil
    display.viewportScrollHandler = nil
    let backend = backend
    // An already-dispatched detach finishes first. Neither it nor the
    // close needs the main actor.
    let closing = Task.detached(priority: .high) {
      guard let backend else { return }
      await pendingLifecycle?.value
      await backend.close(mode)
      backend.onStatus = nil
    }
    self.closing = closing
    return closing
  }

  // MARK: Messages

  /// No workspace was chosen and none is remembered: nothing is created
  /// without an explicit request.
  static let noWorkspaceChosen = SurfaceProblem(
    title: .localized("Choose a workspace"),
    detail: String(
      localized: """
        Open this Mac from the host list to pick one of its workspaces, or start \
        a new one here.
        """,
      bundle: #bundle
    ),
    actions: [.startNewSession]
  )

  static func problem(for error: SSHAccessError) -> SurfaceProblem {
    let actions: [SurfaceAction] =
      switch error {
      case .hostKeyChanged, .hostKeyMismatch, .trustStoreUnavailable: []
      default: [.retry]
      }
    return SurfaceProblem(
      title: error.title,
      detail: error.detail,
      actions: actions
    )
  }

  static func problem(
    for error: RoamingClientError,
    resuming: Bool
  ) -> SurfaceProblem {
    switch error {
    case .sessionLost:
      SurfaceProblem(
        title: resuming
          ? .localized("Previous workspace no longer exists")
          : .localized("Workspace lost"),
        detail: String(
          localized: """
            The Mac no longer has this workspace: it expired, was ended, or the \
            helper restarted. Nothing was replayed into another shell.
            """,
          bundle: #bundle
        ),
        actions: [.startNewSession]
      )
    case .sessionExited: exited(nil)
    case .unreachable:
      SurfaceProblem(
        title: .localized("Mac unreachable over SSH"),
        detail: String(
          localized:
            "The workspace is kept on the Mac. Try again when the network is back.",
          bundle: #bundle
        ),
        actions: [.retry]
      )
    case .hostKeyRejected:
      SurfaceProblem(
        title: .localized("Host key not trusted"),
        detail: String(
          localized:
            "The connection was closed before any credentials were sent.",
          bundle: #bundle
        ),
        actions: [.retry]
      )
    case .authenticationFailed:
      SurfaceProblem(
        title: .localized("Authentication failed"),
        detail: String(
          localized: "The server rejected the credentials.",
          bundle: #bundle
        ),
        actions: [.retry]
      )
    case .credentialUnavailable:
      SurfaceProblem(
        title: .localized("Key unavailable"),
        detail: String(
          localized: """
            The selected SSH key could not be read: it was deleted, is not on this \
            device, or the device is locked. The workspace is kept on the Mac; no \
            credentials were sent.
            """,
          bundle: #bundle
        ),
        actions: [.retry]
      )
    case .protocolViolation:
      SurfaceProblem(
        title: .localized("Roaming helper unavailable"),
        detail: String(
          localized: """
            swifttyd did not answer at \(defaultHelperPath). Install it on the Mac, \
            or use an ordinary SSH shell.
            """,
          bundle: #bundle
        ),
        actions: [.retry, .openOrdinarySSH]
      )
    case let .rejected(code):
      SurfaceProblem(
        title: .localized("Roaming session refused"),
        detail: String(
          localized:
            "The Mac refused the request (\(String(describing: code))).",
          bundle: #bundle
        ),
        actions: [.retry, .openOrdinarySSH]
      )
    case .cancelled:
      SurfaceProblem(
        title: .localized("Session cancelled"),
        detail: String(
          localized: "The connection attempt was cancelled.",
          bundle: #bundle
        ),
        actions: [.retry]
      )
    case .invalidState:
      SurfaceProblem(
        title: .localized("Session busy"),
        detail: String(
          localized: "Another attempt is still in progress.",
          bundle: #bundle
        ),
        actions: [.retry]
      )
    }
  }

  static func exited(_ status: Int32?) -> SurfaceProblem {
    SurfaceProblem(
      title: .localized("Session exited"),
      detail: status.map {
        String(
          localized: "The shell exited with status \($0).",
          bundle: #bundle
        )
      }
        ?? String(
          localized: "The shell on the Mac has exited.",
          bundle: #bundle
        ),
      actions: [.startNewSession]
    )
  }
}

// MARK: - Ordinary SSH

/// An ordinary SSH shell (spec §A.3.B): a local `TerminalSession` fed
/// by an SSH shell channel. A different shell from any roaming session; a
/// shell ends with its connection and is never resumed.
///
/// With automatic reconnection on (spec.roaming.md §9.1), a dropped
/// connection opens a **new** shell in the same screen, after bounded
/// bursts of attempts, and says so natively; nothing typed into the old
/// shell is replayed. Health checks and TCP keepalive detect a half-open
/// connection.
@MainActor
@Observable
final class SSHShellController: TerminalSurfaceController {
  let model: TerminalScreenModel
  let session: TerminalSession
  private(set) var phase: SurfacePhase = .preparing(.localized("Signing in"))
  private(set) var inputNotice: LocalizedStringResource?

  @ObservationIgnored
  private var refusalRelay: InputRefusalRelay?

  @ObservationIgnored
  private let access: SSHAccess
  @ObservationIgnored
  private weak var app: RoamingAppModel?
  @ObservationIgnored
  private(set) var selection: HostConnectionSelection
  @ObservationIgnored
  private var backend: SSHStreamBackend?
  @ObservationIgnored
  private(set) var connection: SSHConnection?
  @ObservationIgnored
  private var runTask: Task<Void, Never>?
  @ObservationIgnored
  private var cleanupTask: Task<Void, Never>?
  /// The dropped shell's close. It detaches the backend from `session`, so
  /// a replacement waits for it before using the session.
  @ObservationIgnored
  private var retiring: Task<Void, Never>?
  @ObservationIgnored
  private var closed = false
  @ObservationIgnored
  private var started = false
  /// Identifies the current shell; callbacks from a replaced one are
  /// ignored.
  @ObservationIgnored
  private var generation = 0
  /// Present while recovering a lost connection.
  @ObservationIgnored
  private(set) var recovery: RecoverySchedule?
  @ObservationIgnored
  private var recoveryTask: Task<Void, Never>?
  /// An attempt is signing in or opening a shell now.
  @ObservationIgnored
  private var attempting = false
  @ObservationIgnored
  private var healthTask: Task<Void, Never>?
  @ObservationIgnored
  private var probeTask: Task<Void, Never>?
  @ObservationIgnored
  private var monitor: NWPathMonitor?
  @ObservationIgnored
  private var pathSeen = false
  @ObservationIgnored
  private var scenes = ScenePhases()
  @ObservationIgnored
  private var backgrounded = false
  /// Shells opened by automatic recovery, for the status notice and tests.
  @ObservationIgnored
  private(set) var replacementShells = 0

  init(
    model: TerminalScreenModel,
    app: RoamingAppModel,
    access: SSHAccess? = nil
  ) {
    self.model = model
    self.app = app
    self.access = access ?? app.ssh
    selection = model.selection ?? app.connectionSelection(for: model.host)
    model.selection = selection
    let session = TerminalSession(
      columns: 80,
      rows: 24,
      configuration: Configuration().sessionConfiguration()
    )
    self.session = session
    let relay = InputRefusalRelay { [weak self] refusal in
      guard let self, !closed else { return }
      switch refusal {
      case .backpressure:
        inputNotice = .localized(
          "Input was not sent because the SSH connection is busy. Try again."
        )
      case .invalid:
        inputNotice = .localized(
          "Input was not sent because it exceeds the supported input limits."
        )
      case .closed, .notActive:
        inputNotice = .localized(
          "Input was not sent because the SSH shell is not ready."
        )
      }
    }
    refusalRelay = relay
    installIdleInputHandler()
    model.previewLines = { [session] in session.withState { $0.screenLines } }
  }

  private var settings: ConnectionResilienceSettings {
    app?.resilience ?? .default
  }

  /// Until a shell is open, input is refused rather than queued for it.
  private func installIdleInputHandler() {
    let relay = refusalRelay
    session.inputHandler = { input in
      // The view reports focus as soon as it appears, often before the
      // shell opens; that is not the user's input, so it raises no notice.
      if case .focus = input { return }
      relay?.report(.notActive(.idle))
    }
  }

  /// Opens the shell once; a new shell needs a new screen.
  func start() {
    guard !closed, runTask == nil, backend == nil, !started else { return }
    started = true
    observeSystem()
    runTask = Task {
      await run()
      runTask = nil
    }
  }

  private func run() async {
    phase = .preparing(.localized("Signing in"))
    model.observe(.connecting)
    do {
      try await openShell()
    } catch {
      guard !closed else { return }
      model.observe(.lost)
      phase = .failed(Self.problem(for: error))
    }
  }

  /// Signs in, opens a shell channel and installs its backend.
  private func openShell() async throws {
    do {
      selection = try await access.prepare(selection)
      model.selection = selection
      let connection = try await access.connectPrepared(selection)
      guard !closed else {
        await connection.close()
        throw CancellationError()
      }
      self.connection = connection
      phase = .preparing(.localized("Opening shell"))
      let (columns, rows) = session.withState { ($0.columns, $0.rows) }
      let channel = try await SSHShellByteChannel.open(
        on: connection,
        columns: columns,
        rows: rows
      )
      // The dropped backend's close clears the session's writer and resets
      // its parser; that must not land on the replacement's output.
      await retiring?.value
      guard !closed else {
        await channel.close()
        throw CancellationError()
      }
      generation += 1
      let current = generation
      let backend = SSHStreamBackend(channel: channel, session: session)
      backend.onInputRefusal = { [relay = refusalRelay] refusal in
        relay?.report(refusal)
      }
      backend.onScreenInstalled = { [weak self] date in
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            guard let self, !self.closed, self.generation == current else {
              return
            }
            self.model.screenInstalled(at: date)
          }
        }
      }
      backend.onLifecycleChange = { [weak self] lifecycle in
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            guard let self, self.generation == current else { return }
            self.apply(lifecycle)
          }
        }
      }
      self.backend = backend
      phase = .running
      backend.start()
      startHealthChecks()
    } catch {
      // Shell setup owns a fresh connection. A rejected child channel
      // can leave SSH authenticated, so release the parent on failure.
      let failedConnection = connection
      connection = nil
      await failedConnection?.close()
      throw error
    }
  }

  private func apply(_ lifecycle: SurfaceLifecycle) {
    guard !closed, cleanupTask == nil else { return }
    switch lifecycle {
    case .lost:
      guard settings.autoReconnect, let connection else {
        shellLost()
        return
      }
      // Only a dropped connection is recovered. A channel the server closed
      // on a live connection is a shell that ended, not a network failure.
      let current = generation
      Task { [weak self] in
        let health =
          connection.isActive
          ? await connection.probe(timeout: .seconds(5)) : .closed
        guard let self, !self.closed, self.generation == current,
          self.cleanupTask == nil
        else { return }
        if health == .responsive { self.shellLost() } else { self.beginRecovery() }
      }
    case let .exited(status):
      // The program ended; that is not a network failure to recover from.
      model.observe(lifecycle)
      releaseResources()
      phase = .failed(
        SurfaceProblem(
          title: .localized("Shell exited"),
          detail: status.map {
            String(
              localized: "The shell exited with status \($0).",
              bundle: #bundle
            )
          } ?? String(localized: "The shell exited.", bundle: #bundle),
          actions: [.retry]
        )
      )
    default:
      model.observe(lifecycle)
      if lifecycle.isFinal { releaseResources() }
    }
  }

  private func shellLost() {
    model.observe(.lost)
    releaseResources()
    phase = .failed(Self.connectionLost)
  }

  // MARK: Recovery

  /// The connection dropped: drop the dead shell, then open new ones until
  /// one succeeds, the user closes the screen, or an error needs the user.
  private func beginRecovery() {
    guard recovery == nil, !closed else { return }
    model.observe(.interrupted)
    dropShell()
    recovery = RecoverySchedule(attemptsPerBurst: settings.attemptsPerBurst)
    if !backgrounded { scheduleRecovery() }
    else { phase = .preparing(.localized("Waiting to reconnect")) }
  }

  private func scheduleRecovery() {
    guard var schedule = recovery, !closed, recoveryTask == nil else { return }
    let delay = schedule.next()
    let total = schedule.total
    recovery = schedule
    if schedule.isCoolingDown, delay == RecoverySchedule.cooldown {
      phase = .failed(Self.retrying(after: delay))
    } else {
      phase = .preparing(.localized("Reconnecting (attempt \(total))"))
    }
    recoveryTask = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard let self, !Task.isCancelled else { return }
      await self.attemptRecovery()
    }
  }

  private func attemptRecovery() async {
    guard !closed, recovery != nil else {
      recoveryTask = nil
      return
    }
    phase = .preparing(.localized("Reconnecting"))
    model.observe(.connecting)
    attempting = true
    defer { attempting = false }
    do {
      try await openShell()
      recoveryTask = nil
      guard !closed else { return }
      recovery = nil
      replacementShells += 1
      // Honest outcome (Shell's "New shell opened"): the previous shell and
      // anything it was running are gone; no input was replayed.
      inputNotice = .localized(
        """
        New shell opened. The connection dropped, so the previous shell ended \
        and was not resumed; a command it was running may not have finished.
        """
      )
    } catch {
      recoveryTask = nil
      guard !closed else { return }
      // Backgrounding cancelled this attempt. A foreground return while it
      // was in flight left the next attempt to it.
      if Task.isCancelled {
        if !backgrounded { scheduleRecovery() }
        return
      }
      if Self.blocksRecovery(error) {
        recovery = nil
        model.observe(.lost)
        phase = .failed(Self.problem(for: error))
        return
      }
      if !backgrounded { scheduleRecovery() }
    }
  }

  /// A trigger (foreground, network path change, explicit retry) starts a
  /// fresh burst now rather than waiting out a cooldown.
  private func triggerRecovery() {
    guard var schedule = recovery, !closed, !backgrounded else { return }
    schedule.trigger()
    recovery = schedule
    // An attempt in flight finishes; if it fails, the next starts at once.
    guard !attempting else { return }
    recoveryTask?.cancel()
    recoveryTask = nil
    scheduleRecovery()
  }

  /// Errors that need the user: credentials, trust, a cancelled prompt.
  static func blocksRecovery(_ error: any Error) -> Bool {
    if error is CancellationError { return true }
    guard let error = error as? SSHAccessError else { return false }
    return error != .unreachable
  }

  /// Closes the dead connection without ending the screen.
  private func dropShell() {
    // The dead backend's own close must not end this screen.
    generation += 1
    healthTask?.cancel()
    healthTask = nil
    probeTask?.cancel()
    probeTask = nil
    let backend = backend
    let connection = connection
    self.backend = nil
    self.connection = nil
    installIdleInputHandler()
    retiring = Task.detached(priority: .high) {
      await backend?.close()
      await connection?.close()
    }
  }

  // MARK: Health

  /// Periodic bounded probes while the shell is shown in the foreground.
  private func startHealthChecks() {
    healthTask?.cancel()
    healthTask = nil
    guard settings.healthChecks, !backgrounded else { return }
    let interval = Duration.seconds(settings.probeInterval)
    healthTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: interval)
        guard !Task.isCancelled, let self else { return }
        await self.checkHealth()
      }
    }
  }

  /// One bounded check. An unresponsive connection is closed, so the
  /// backend reports it lost and recovery starts.
  private func checkHealth() async {
    guard let connection, recovery == nil, !closed else { return }
    let health = await connection.probe()
    guard !closed, connection === self.connection else { return }
    if health != .responsive { await connection.close() }
  }

  /// A single check on foreground activation or a path change, even with
  /// periodic checks off.
  private func probeOnce() {
    guard probeTask == nil, connection != nil else { return }
    probeTask = Task { [weak self] in
      await self?.checkHealth()
      self?.probeTask = nil
    }
  }

  // MARK: System events

  func scenePhaseChanged(_ phase: ScenePhase?, scene: UUID) {
    guard let change = scenes.set(phase, for: scene) else { return }
    switch model.profile.kind {
    case .catalyst: return
    case .mobile, .vision, .tv: break
    }
    switch change.new {
    case .background where !backgrounded:
      backgrounded = true
      healthTask?.cancel()
      healthTask = nil
      recoveryTask?.cancel()
      recoveryTask = nil
    case .active where change.old != nil || backgrounded:
      backgrounded = false
      if recovery != nil {
        triggerRecovery()
      } else if backend != nil {
        startHealthChecks()
        probeOnce()
      }
    default: break
    }
  }

  private func observeSystem() {
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { [weak self] _ in
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.pathChanged() }
      }
    }
    monitor.start(queue: DispatchQueue(label: "dev.swiftty.ssh.path"))
    self.monitor = monitor
  }

  private func pathChanged() {
    guard pathSeen else {
      pathSeen = true
      return
    }
    guard !closed, !backgrounded else { return }
    if recovery != nil { triggerRecovery() } else { probeOnce() }
  }

  // MARK: Problems

  static var connectionLost: SurfaceProblem {
    SurfaceProblem(
      title: .localized("SSH connection lost"),
      detail: String(
        localized: """
          This ordinary SSH shell ended with its connection and cannot be resumed. \
          Your workspace on the Mac is not affected.
          """,
        bundle: #bundle
      ),
      actions: [.retry]
    )
  }

  static func retrying(after delay: Duration) -> SurfaceProblem {
    SurfaceProblem(
      title: .localized("SSH connection lost"),
      detail: String(
        localized: """
          Still trying to reconnect, every \(delay.components.seconds) seconds. \
          A reconnect opens a new shell; the previous one ended with its \
          connection.
          """,
        bundle: #bundle
      ),
      actions: [.retry]
    )
  }

  static func problem(for error: any Error) -> SurfaceProblem {
    if let error = error as? SSHAccessError {
      return RoamingTerminalController.problem(for: error)
    }
    return SurfaceProblem(
      title: .localized("Shell unavailable"),
      detail: String(
        localized: "The Mac refused to open a shell on this connection.",
        bundle: #bundle
      ),
      actions: [.retry]
    )
  }

  /// The problem card's action while recovering: try now. Otherwise the
  /// view opens a new screen.
  func retryNow() -> Bool {
    guard recovery != nil, !closed else { return false }
    backgrounded = false
    triggerRecovery()
    return true
  }

  // MARK: Close

  func beginClose(_ mode: RoamingCloseMode) -> Task<Void, Never> {
    closed = true
    runTask?.cancel()
    recoveryTask?.cancel()
    recoveryTask = nil
    recovery = nil
    return releaseResources()
  }

  /// Also waits for setup still unwinding on the main actor.
  func close(_ mode: RoamingCloseMode) async {
    await beginClose(mode).value
    await runTask?.value
  }

  @discardableResult
  private func releaseResources() -> Task<Void, Never> {
    if let cleanupTask { return cleanupTask }
    healthTask?.cancel()
    healthTask = nil
    probeTask?.cancel()
    probeTask = nil
    monitor?.cancel()
    monitor = nil
    refusalRelay?.close()
    refusalRelay = nil
    let backend = backend
    let connection = connection
    self.backend = nil
    self.connection = nil
    let cleanup = Task.detached(priority: .high) {
      await backend?.close()
      await connection?.close()
    }
    cleanupTask = cleanup
    return cleanup
  }

  func dismissInputNotice() { inputNotice = nil }
}

/// Forwards roaming frames to the display, keeping the newest and the pane
/// it shows.
final class FrameTap: PresentationSink {
  private struct State {
    /// The active pane of the newest Layout.
    var shown: PaneID?
    var newest: PresentationFrame?
    /// The pane `newest` belongs to: the one shown when it arrived.
    var newestPane: PaneID?
  }

  private let forward: TerminalSession
  private let state = Mutex(State())

  init(forward: TerminalSession) { self.forward = forward }

  /// The newest frame with its pane; nil before a Layout named one.
  var latestPaneFrame: (PaneID, PresentationFrame)? {
    state.withLock { s in
      guard let pane = s.newestPane, let frame = s.newest else { return nil }
      return (pane, frame)
    }
  }

  /// A Layout made `pane` active; called in order with `install(_:)`. The
  /// host sends the new pane's screen after its Layout, so the newest frame
  /// still belongs to the pane shown before.
  func show(_ pane: PaneID?) { state.withLock { $0.shown = pane } }

  @discardableResult
  func install(_ frame: PresentationFrame) -> Bool {
    guard forward.install(frame) else { return false }
    state.withLock { s in
      s.newest = frame
      s.newestPane = s.shown
    }
    return true
  }
}
