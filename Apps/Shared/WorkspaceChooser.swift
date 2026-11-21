import Foundation
import MuxNavigation
import Observation
import ScreenProtocol
import SessionCore
import SwiftMuxProtocol
import SwiftUI

/// The Mac → Workspace step (spec.connection-setup.md D1): after SSH
/// verification and sign-in, list the Mac's workspaces from lease-free
/// authenticated metadata and attach only to the one the user picks.
///
/// Browsing, refreshing and cancelling create no workspace, acquire no
/// writer lease and leave the active terminal alone. Only New Workspace
/// sends a create request; taking control from another client needs
/// explicit confirmation of the lease generation shown.
@MainActor
@Observable
final class WorkspaceChooserModel {
  enum Phase: Equatable {
    case connecting
    case loaded
    case failed(String)
  }

  /// One row: the summary as observed, and whether this app shows it.
  struct Row: Identifiable, Hashable {
    var summary: WorkspaceSummary
    var isShownHere: Bool
    var id: WorkspaceID { summary.id }
    /// Another client holds the writer lease.
    var heldElsewhere: Bool { summary.isAttached && !isShownHere }
  }

  /// Rows shown; the service's own limits bound the reply further.
  static let maxRows = 256

  private(set) var host: HostProfile
  private(set) var phase: Phase = .connecting
  private(set) var rows: [Row] = []
  private(set) var serviceEpoch: SwiftMuxProtocol.ServerInstanceID?
  /// Why the list was refreshed instead of opening (lease or epoch race).
  private(set) var notice: String?
  /// A takeover awaiting the user's confirmation.
  var pendingTakeover: Row?
  /// The takeover dialog's binding: dismissing it drops the request.
  var isTakeoverPending: Bool {
    get { pendingTakeover != nil }
    set { if !newValue { pendingTakeover = nil } }
  }
  /// Set once a selection was handed to the terminal; the view dismisses.
  private(set) var finished = false

  @ObservationIgnored
  private let model: RoamingAppModel
  @ObservationIgnored
  private var context: HostMutationContext
  @ObservationIgnored
  private let connector: (any AttentionServiceConnector)?
  @ObservationIgnored
  private var service: (any RoamingAttentionMetadataService)?
  @ObservationIgnored
  private var task: Task<Void, Never>?
  @ObservationIgnored
  private var generation = 0
  @ObservationIgnored
  private var closed = false

  init(
    model: RoamingAppModel,
    host: HostProfile,
    context: HostMutationContext? = nil,
    connector: (any AttentionServiceConnector)? = nil
  ) {
    self.model = model
    self.host = host
    let selection = context ?? model.hostMutationContext(for: host)
    self.context = selection
    self.connector = connector
  }

  /// Signs in if needed and lists workspaces. Superseded loads are
  /// cancelled and their late results ignored.
  func load() {
    guard !closed, checkSelection() else { return }
    task?.cancel()
    generation += 1
    let generation = generation
    if rows.isEmpty { phase = .connecting }
    task = Task { await self.fetch(generation) }
  }

  private func fetch(_ generation: Int) async {
    do throws(AttentionServiceError) {
      let service = try await connected()
      let metadata = try await service.metadata(.workspaces)
      guard self.generation == generation, !closed, !Task.isCancelled else {
        return
      }
      guard checkSelection() else { return }
      publish(metadata)
    } catch {
      guard self.generation == generation, !closed else { return }
      await dropService()
      phase = .failed(Self.describe(error))
    }
  }

  private func connected() async throws(AttentionServiceError)
    -> any RoamingAttentionMetadataService
  {
    guard checkSelection() else {
      throw .other(RoamingAppModel.hostChangedMessage)
    }
    if let service { return service }
    let navigationHost = NavigationHost(id: host.id, name: host.nickname)
    // A successful legacy migration reconciles context. A later connection
    // must use that selection rather than the initial legacy description.
    let connector =
      connector
      ?? RoamingAttentionConnector(
        model: model,
        detailedErrors: true,
        selection: context
      )
    let opened = try await connector.connect(to: navigationHost)
    guard let metadata = opened as? any RoamingAttentionMetadataService else {
      await opened.close()
      throw .unsupported(
        String(
          localized: "This Mac cannot list its workspaces.",
          bundle: #bundle
        )
      )
    }
    guard !closed, !Task.isCancelled, checkSelection(afterAuthentication: true)
    else {
      await metadata.close()
      throw .other(String(localized: "Cancelled.", bundle: #bundle))
    }
    service = metadata
    return metadata
  }

  private func publish(_ metadata: HostMetadata) {
    serviceEpoch = metadata.serviceEpoch
    rows = (metadata.workspaces ?? []).prefix(Self.maxRows)
      .map { Row(summary: $0, isShownHere: isShownHere($0.id)) }
      .sorted { $0.summary.createdAt > $1.summary.createdAt }
    phase = .loaded
  }

  /// Whether this app's roaming terminal shows `workspace` on this host.
  private func isShownHere(_ workspace: WorkspaceID) -> Bool {
    guard let session = model.activeSession, !session.isClosed,
      session.kind == .roaming, let selection = session.selection,
      HostDataOwner(selection)
        == HostDataOwner(host: host, account: context.scope)
    else { return false }
    return session.sessionID == SessionID(workspace)
  }

  // MARK: Choosing

  /// Opens an existing workspace by identity. One held by another client
  /// asks for confirmation first.
  func choose(_ row: Row) {
    guard !closed, !finished, checkSelection() else { return }
    if row.heldElsewhere {
      pendingTakeover = row
      return
    }
    open(row, confirmedTakeover: false)
  }

  /// The user confirmed taking control of exactly the generation shown.
  func confirmTakeover() {
    guard !closed, checkSelection() else { return }
    guard let row = pendingTakeover else { return }
    pendingTakeover = nil
    open(row, confirmedTakeover: true)
  }

  /// New Workspace: the one explicit create.
  func createNew() {
    guard !closed, !finished, checkSelection() else { return }
    finish()
    model.openWorkspace(host, intent: .create)
  }

  private func open(_ row: Row, confirmedTakeover: Bool) {
    guard !closed, checkSelection(), let epoch = serviceEpoch else { return }
    task?.cancel()
    generation += 1
    let generation = generation
    notice = nil
    task = Task {
      do throws(AttentionServiceError) {
        let service = try await self.connected()
        // Re-read before attaching: the lease or service may have changed
        // since the list was shown. A change refreshes, never retries.
        let metadata = try await service.metadata(.workspaces)
        guard self.generation == generation, !self.closed, !Task.isCancelled
        else { return }
        let lease = try self.lease(
          for: row,
          in: metadata,
          observedEpoch: epoch,
          confirmedTakeover: confirmedTakeover
        )
        guard self.checkSelection() else { return }
        self.finish()
        self.model.openWorkspace(
          self.host,
          intent: .resume(
            SessionID(row.id),
            lease.map { ResumeTarget(expectedLease: $0) }
          )
        )
      } catch {
        // Lease or epoch races and vanished workspaces show the current
        // list; nothing is retried on the user's behalf.
        guard self.generation == generation, !self.closed else { return }
        self.notice = Self.describe(error)
        self.load()
      }
    }
  }

  /// The lease generation to take over, `nil` for a free workspace or
  /// this app's own. Fails when what the user saw is no longer true.
  private func lease(
    for row: Row,
    in metadata: HostMetadata,
    observedEpoch: SwiftMuxProtocol.ServerInstanceID,
    confirmedTakeover: Bool
  ) throws(AttentionServiceError) -> UInt64? {
    guard metadata.serviceEpoch == observedEpoch else {
      throw .serviceRestarted
    }
    guard let current = metadata.workspaces?.first(where: { $0.id == row.id })
    else { throw .notFound }
    guard current.isAttached, !isShownHere(current.id) else { return nil }
    guard confirmedTakeover else { throw .leaseHeld }
    guard row.summary.isAttached,
      current.leaseGeneration == row.summary.leaseGeneration
    else { throw .leaseChanged }
    return current.leaseGeneration
  }

  /// A chooser never reinterprets a retained UUID as a new account's host.
  /// Invalid selections require reopening; close only this metadata service.
  private func checkSelection(afterAuthentication: Bool = false) -> Bool {
    if afterAuthentication, context.original == host,
      let migrated = model.hostAfterLegacyMigration(context),
      migrated.auth != host.auth
    {
      host = migrated
      context = model.hostMutationContext(for: migrated)
    }
    guard context.original == host, model.hostMutationIsCurrent(context) else {
      close()
      rows = []
      notice = RoamingAppModel.hostChangedMessage
      phase = .failed(RoamingAppModel.hostChangedMessage)
      return false
    }
    return true
  }

  // MARK: Lifetime

  private func finish() {
    finished = true
    close()
  }

  /// Cancel or dismissal: closes the metadata connection only.
  func close() {
    guard !closed else { return }
    closed = true
    task?.cancel()
    task = nil
    pendingTakeover = nil
    let service = service
    self.service = nil
    if let service { Task { await service.close() } }
  }

  private func dropService() async {
    let service = service
    self.service = nil
    await service?.close()
  }

  /// Localized plain text: it can carry what the host reported, so it is
  /// a `String`, never read as Markdown.
  static func describe(_ error: AttentionServiceError) -> String {
    switch error {
    case .leaseHeld:
      String(
        localized:
          "Another device took control of this workspace. Review it and confirm again.",
        bundle: #bundle
      )
    case .leaseChanged:
      String(
        localized:
          "This workspace's controller changed. Review it and confirm again.",
        bundle: #bundle
      )
    case .serviceRestarted:
      String(
        localized:
          "SwiftMux restarted on the Mac. The list was refreshed; choose again.",
        bundle: #bundle
      )
    case .notFound:
      String(
        localized: "That workspace no longer exists on the Mac.",
        bundle: #bundle
      )
    default: RoamingInboxModel.describe(error)
    }
  }
}

// MARK: - View

/// Lists a Mac's workspaces after sign-in. Presented as a sheet; it hosts
/// the connection prompts while it is up.
struct WorkspaceChooserView: View {
  /// Created once, on first appearance, rather than in `init`, which
  /// runs on every parent redraw.
  @State
  private var chooser: WorkspaceChooserModel?
  let host: HostProfile
  let context: HostMutationContext
  let app: RoamingAppModel
  let dismiss: () -> Void

  init(
    host: HostProfile,
    context: HostMutationContext,
    app: RoamingAppModel,
    dismiss: @escaping () -> Void
  ) {
    self.host = host
    self.context = context
    self.app = app
    self.dismiss = dismiss
  }

  var body: some View {
    if let chooser {
      WorkspaceChooserContent(chooser: chooser, app: app, dismiss: dismiss)
    } else {
      Color.clear.onAppear {
        chooser = WorkspaceChooserModel(
          model: app,
          host: host,
          context: context
        )
      }
    }
  }
}

private struct WorkspaceChooserContent: View {
  @Bindable
  var chooser: WorkspaceChooserModel
  let app: RoamingAppModel
  let dismiss: () -> Void

  var body: some View {
    NavigationStack {
      List {
        if let notice = chooser.notice {
          Label(notice, systemImage: "arrow.triangle.2.circlepath")
            .foregroundStyle(.orange).listRowBackground(Color.clear)
            .accessibilityIdentifier("workspace.notice")
        }
        content
      }
      .glassListBackground().navigationTitle(chooser.host.nickname)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(.localized("Cancel"), action: cancel)
            .accessibilityIdentifier("workspace.cancel")
        }
        ToolbarItem(placement: .automatic) {
          Button {
            chooser.load()
          } label: {
            Label(.localized("Refresh"), systemImage: "arrow.clockwise")
          }
          .disabled(chooser.phase == .connecting)
        }
      }
      .confirmationDialog(
        takeoverTitle,
        isPresented: $chooser.isTakeoverPending,
        titleVisibility: .visible
      ) {
        Button(.localized("Take Control")) { chooser.confirmTakeover() }
          .accessibilityIdentifier("workspace.takeover")
        Button(.localized("Cancel"), role: .cancel) {
          chooser.pendingTakeover = nil
        }
      } message: {
        Text(
          """
          Another client controls this workspace. Taking control detaches it \
          there; nothing running in the workspace is ended.
          """,
          bundle: #bundle
        )
      }
    }
    .modalConnectionPrompts(app).task { chooser.load() }
    .onChange(of: chooser.finished) { _, finished in if finished { dismiss() } }
    .onDisappear { chooser.close() }
  }

  @ViewBuilder
  private var content: some View {
    switch chooser.phase {
    case .connecting:
      HStack {
        ProgressView()
        Text("Signing in to list workspaces…", bundle: #bundle)
          .foregroundStyle(.secondary)
      }
      .listRowBackground(Color.clear)
    case let .failed(message):
      Label(message, systemImage: "exclamationmark.triangle")
        .foregroundStyle(.orange).listRowBackground(Color.clear)
        .accessibilityIdentifier("workspace.error")
      Button(.localized("Try Again")) { chooser.load() }
        .listRowBackground(Color.clear)
    case .loaded:
      if chooser.rows.isEmpty {
        ContentUnavailableView(
          .localized("No Workspaces"),
          systemImage: "rectangle.stack",
          description: Text("This Mac has no workspaces yet.", bundle: #bundle)
        )
        .listRowBackground(Color.clear)
      }
      Section {
        ForEach(chooser.rows) { row in
          Button {
            chooser.choose(row)
          } label: {
            WorkspaceRowLabel(row: row)
          }
          .accessibilityIdentifier("workspace.open")
        }
      }
      .listRowBackground(Color.clear)
      Section {
        Button {
          chooser.createNew()
        } label: {
          Label(
            .localized("New Workspace"),
            systemImage: "plus.rectangle.on.rectangle"
          )
        }
        .accessibilityIdentifier("workspace.new")
      } footer: {
        Text(
          "Starts a new shell on the Mac. Existing workspaces keep running.",
          bundle: #bundle
        )
      }
      .listRowBackground(Color.clear)
    }
  }

  /// Plain text: the workspace name comes from the Mac.
  private var takeoverTitle: String {
    String(
      localized:
        "Take control of \u{201C}\(chooser.pendingTakeover.map { DisplayText.workspaceName($0.summary.name) } ?? "")\u{201D}?",
      bundle: #bundle
    )
  }

  private func cancel() {
    chooser.close()
    dismiss()
  }
}

/// Name, counts and control state of one workspace.
struct WorkspaceRowLabel: View {
  let row: WorkspaceChooserModel.Row

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      (row.summary.name.isEmpty
        ? Text("Untitled Workspace", bundle: #bundle)
        : Text(verbatim: DisplayText.workspaceName(row.summary.name)))
        .font(.headline)
      counts.font(.caption).foregroundStyle(.secondary)
      Label(control, systemImage: controlImage).font(.caption)
        .foregroundStyle(row.heldElsewhere ? .orange : .secondary)
    }
  }

  private var counts: Text {
    let s = row.summary
    let tabs = Text(
      "\(s.tabCount) tabs",
      bundle: #bundle,
      comment: "Plural: a workspace's tab count."
    )
    let panes = Text(
      "\(s.paneCount) panes",
      bundle: #bundle,
      comment: "Plural: a workspace's pane count."
    )
    guard let live = s.livePaneCount, live != s.paneCount else {
      return Text("\(tabs) · \(panes)", bundle: #bundle)
    }
    return Text("\(tabs) · \(panes) · \(live) running", bundle: #bundle)
  }

  private var control: LocalizedStringResource {
    if row.isShownHere { return .localized("Shown on this device") }
    guard row.summary.isAttached else { return .localized("Not attached") }
    switch row.summary.leaseHolder?.transport {
    case .local?: return .localized("Controlled on the Mac")
    case .remote?: return .localized("Controlled by another device")
    case nil: return .localized("Controlled by another client")
    }
  }

  private var controlImage: String {
    if row.isShownHere { return "checkmark.circle" }
    return row.summary.isAttached ? "lock" : "circle"
  }
}

// MARK: - Modal prompt routing

/// While a sheet is up it presents the connection prompts itself (the
/// root defers to it through `modalDepth`), balanced across appear and
/// disappear.
private struct ModalConnectionPrompts: ViewModifier {
  let model: RoamingAppModel
  let enabled: Bool
  @State
  private var counted = false

  func body(content: Content) -> some View {
    content.connectionPrompts(model, enabled: enabled)
      .onAppear {
        guard enabled, !counted else { return }
        counted = true
        model.modalDepth += 1
      }
      .onDisappear {
        guard counted else { return }
        counted = false
        model.modalDepth -= 1
      }
  }
}

extension View {
  /// `enabled` is a parameter rather than a conditional modifier, so
  /// toggling it never replaces the view and resets its state.
  func modalConnectionPrompts(
    _ model: RoamingAppModel,
    enabled: Bool = true
  ) -> some View {
    modifier(ModalConnectionPrompts(model: model, enabled: enabled))
  }
}
