import Foundation
import Network
import Observation
import SSHClient
import ScreenProtocol
import SessionCore
import SwiftUI
import SwifttyCore
import Synchronization
import TerminalSurface

// The live terminal surfaces behind `TerminalScreen` (replacing the
// former placeholder): one MainActor controller per opened
// `TerminalScreenModel`, owning the display session and its backend.

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
        The session is kept on the Mac.
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

/// Holds the current client for nonisolated input submission.
final class ClientSlot: Sendable {
  private let value = Mutex<RoamingClient?>(nil)

  var client: RoamingClient? { value.withLock { $0 } }

  func set(_ client: RoamingClient?) { value.withLock { $0 = client } }
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
    /// An explicit Start New Session: forget the remembered session and
    /// create one.
    case newSession
  }

  let model: TerminalScreenModel
  let display: TerminalSession
  private(set) var phase: SurfacePhase = .preparing(.localized("Signing in"))

  @ObservationIgnored
  private weak var app: RoamingAppModel?
  @ObservationIgnored
  private(set) var selection: HostConnectionSelection
  @ObservationIgnored
  private let slot: ClientSlot
  @ObservationIgnored
  private let pump: OrderedInputPump
  @ObservationIgnored
  private var client: RoamingClient?
  @ObservationIgnored
  private var grid = GridSize(columns: 80, rows: 24)
  @ObservationIgnored
  private var runTask: Task<Void, Never>?
  /// Lifecycle and grid calls to the client, applied in order.
  @ObservationIgnored
  private let lifecycleQueue = ClientLifecycleQueue()
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
    let slot = ClientSlot()
    self.slot = slot
    pump = OrderedInputPump(submit: { input in
      guard let client = slot.client else { return .refused(.notActive(.idle)) }
      return await client.submit(input)
    })
    // Semantic input arrives on the session queue, in order; the pump
    // keeps that order across the hop to the client actor.
    display.semanticInputHandler = { [pump] input in
      if let input = SurfaceInput(input) { pump.enqueue(input) }
    }
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
    if let old = client {
      client = nil
      slot.set(nil)
      lifecycleQueue.use(nil)
      await old.close(.detach)
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

    let client = RoamingClient(
      bootstrapper: SSHBootstrapper(endpoint: endpoint),
      connector: QUICGrantConnector(fallbackHost: endpoint.configuration.host),
      sink: display,
      configuration: RoamingClientConfiguration(initialGrid: grid)
    )
    self.client = client
    slot.set(client)
    lifecycleQueue.use(client)
    let token = ObjectIdentifier(client)
    await client.setStatusHandler { [weak self] status in
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
      resuming ? .localized("Resuming session") : .localized("Starting session")
    )
    do {
      try await client.start(target)
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
    slot.set(nil)
    pump.close()
    monitor?.cancel()
    #if os(macOS) || targetEnvironment(macCatalyst)
    powerMonitor?.invalidate()
    powerMonitor = nil
    #endif
    display.semanticInputHandler = nil
    display.gridProposalHandler = nil
    display.viewportScrollHandler = nil
    let client = client
    // An already-dispatched detach finishes first. Neither it nor the
    // close needs the main actor.
    let closing = Task.detached(priority: .high) {
      guard let client else { return }
      await pendingLifecycle?.value
      await client.close(mode)
      await client.setStatusHandler(nil)
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
          ? .localized("Previous session no longer exists")
          : .localized("Session lost"),
        detail: String(
          localized: """
            The Mac no longer has this session: it expired, was terminated, or the \
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
            "The session is kept on the Mac. Try again when the network is back.",
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
            device, or the device is locked. The session is kept on the Mac; no \
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
/// by an SSH shell channel. A different shell from any roaming session;
/// it ends with its connection and is never resumed.
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
  private(set) var selection: HostConnectionSelection
  @ObservationIgnored
  private var backend: SSHStreamBackend?
  @ObservationIgnored
  private(set) var connection: SSHConnection?
  @ObservationIgnored
  private var runTask: Task<Void, Never>?
  @ObservationIgnored
  private var cleanupTask: Task<Void, Never>?
  @ObservationIgnored
  private var closed = false
  @ObservationIgnored
  private var started = false

  init(
    model: TerminalScreenModel,
    app: RoamingAppModel,
    access: SSHAccess? = nil
  ) {
    self.model = model
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
    session.inputHandler = { input in
      // The view reports focus as soon as it appears, often before the
      // shell opens; that is not the user's input, so it raises no notice.
      if case .focus = input { return }
      relay.report(.notActive(.idle))
    }
    model.previewLines = { [session] in session.withState { $0.screenLines } }
  }

  /// Opens the shell once; a new shell needs a new screen.
  func start() {
    guard !closed, runTask == nil, backend == nil, !started else { return }
    started = true
    runTask = Task {
      await run()
      runTask = nil
    }
  }

  private func run() async {
    phase = .preparing(.localized("Signing in"))
    model.observe(.connecting)
    do {
      selection = try await access.prepare(selection)
      model.selection = selection
      let connection = try await access.connectPrepared(selection)
      guard !closed else {
        await connection.close()
        return
      }
      self.connection = connection
      phase = .preparing(.localized("Opening shell"))
      let (columns, rows) = session.withState { ($0.columns, $0.rows) }
      let channel = try await SSHShellByteChannel.open(
        on: connection,
        columns: columns,
        rows: rows
      )
      guard !closed else {
        await channel.close()
        return
      }
      let backend = SSHStreamBackend(channel: channel, session: session)
      backend.onInputRefusal = { [relay = refusalRelay] refusal in
        relay?.report(refusal)
      }
      backend.onScreenInstalled = { [weak self] date in
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            guard let self, !self.closed else { return }
            self.model.screenInstalled(at: date)
          }
        }
      }
      backend.onLifecycleChange = { [weak self] lifecycle in
        DispatchQueue.main.async {
          MainActor.assumeIsolated { self?.apply(lifecycle) }
        }
      }
      self.backend = backend
      phase = .running
      backend.start()
    } catch {
      // Shell setup owns a fresh connection. A rejected child channel
      // can leave SSH authenticated, so release the parent on failure.
      let failedConnection = connection
      connection = nil
      await failedConnection?.close()
      guard !closed else { return }
      model.observe(.lost)
      if let error = error as? SSHAccessError {
        phase = .failed(RoamingTerminalController.problem(for: error))
      } else {
        phase = .failed(
          SurfaceProblem(
            title: .localized("Shell unavailable"),
            detail: String(
              localized: "The Mac refused to open a shell on this connection.",
              bundle: #bundle
            ),
            actions: [.retry]
          )
        )
      }
    }
  }

  private func apply(_ lifecycle: SurfaceLifecycle) {
    guard !closed, cleanupTask == nil else { return }
    model.observe(lifecycle)
    if lifecycle.isFinal { releaseResources() }
    switch lifecycle {
    case .lost:
      phase = .failed(
        SurfaceProblem(
          title: .localized("SSH connection lost"),
          detail: String(
            localized: """
              This ordinary SSH shell ended with its connection and cannot be resumed. \
              A roaming session on the Mac is not affected.
              """,
            bundle: #bundle
          ),
          actions: [.retry]
        )
      )
    case let .exited(status):
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
    default: break
    }
  }

  func beginClose(_ mode: RoamingCloseMode) -> Task<Void, Never> {
    closed = true
    runTask?.cancel()
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
