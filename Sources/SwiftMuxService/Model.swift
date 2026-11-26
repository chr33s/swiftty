import SwiftMuxGuardian
import Dispatch
import Foundation
import SwiftMuxProtocol
import SwiftMuxXPC
import SwifttyConfig
import SwifttyEngine
import SwifttyJS

extension MuxLimits {
  /// The standard limits with the user's `terminal.image_storage_limit`
  /// (0 disables images) capped at the protocol's per-screen budget
  /// (spec.graphics.md §8.2). Production entry points use this; tests
  /// keep `standard` and never read the user's settings.
  public static func userConfigured() -> MuxLimits {
    var limits = MuxLimits.standard
    let url =
      ((try? ConfigDiscovery.resolve(arguments: [])) ?? nil)
      ?? ConfigDiscovery.defaultURL()
    let configured =
      (try? ConfigLoader.load(from: url))?.terminal.imageStorageLimit
      ?? TerminalState.defaultImageStorageLimit
    limits.imageBytesPerScreen = min(
      max(0, configured),
      limits.imageBytesPerScreen
    )
    return limits
  }
}

public struct MuxServiceConfiguration: Sendable {
  /// The shared automation VM. The host installs callbacks before creating the service.
  public var javaScriptRuntime: JavaScriptRuntime?
  /// Production config, evaluated once before the first pane starts.
  public var javaScriptDirectory: URL?
  /// Private fixture observation; production callers leave this nil.
  var observePaneIO: (@Sendable (PaneID, PaneIOObservation) -> Void)?
  public var launcherPath: String
  public var limits = MuxLimits.standard
  public var innerTerm = SMX.fallbackInnerTerm
  public var terminfoDirectory: String?
  /// Code-signing requirement every peer must satisfy (shipping builds).
  public var peerRequirement: String?
  /// Exit delay once the service reaches its empty-state barrier; nil
  /// keeps the service running (tests, foreground use). Invalid delays
  /// also keep it running rather than triggering an immediate exit.
  public var idleExitDelay: TimeInterval?
  /// Compress idle pane history where supported. Local policy only: pane
  /// budgets, `MuxLimits` and SMX messages are unchanged.
  public var scrollbackCompression = true
  /// Runs on the pane queue before each launch (tests hold a launch open).
  package var beforeLaunch: (@Sendable () -> Void)?
  /// Internal process adapter selected by the workspace host. Nil keeps the
  /// current local guardian owner; it is not a frontend-selected option.
  var paneProcessFactory:
    (
      @Sendable (PaneID, WorkspaceID, DispatchQueue, MuxLimits) throws ->
        any PaneProcess
    )?

  /// Guardian worker mode: one lifetime workspace identity, provisioned by
  /// its supervisor. Ordinary local services continue allocating identities.
  var workerWorkspace: WorkspaceID?
  /// A planned replacement's candidate continues its predecessor's service
  /// instance (spec.durability.md §6).
  var instance: ServerInstanceID?
  var requiresGatewayBinding = false

  public init(launcherPath: String) { self.launcherPath = launcherPath }
}

struct Tab: LayeredTab {
  var id = TabID()
  var name: String
  /// Nil when every tiled pane has been floated.
  var layout: LayoutNode?
  var layers: [FloatingLayer] = []
  var activePane: PaneID
  var zoomedPane: PaneID?
  /// Where focus returns when the focused layer closes or minimizes.
  var previousPane: PaneID?

  func layerIndex(containing pane: PaneID) -> Int? {
    layers.firstIndex { $0.layout.contains(pane) }
  }

  var snapshot: TabSnapshot {
    TabSnapshot(
      id: id,
      name: name,
      layout: layout,
      activePane: activePane,
      zoomedPane: zoomedPane,
      layers: layers
    )
  }

  /// Records the pane being left, then focuses `pane` and the layer that
  /// holds it.
  mutating func focus(_ pane: PaneID) {
    if pane != activePane {
      previousPane = activePane
      activePane = pane
    }
    if let index = layerIndex(containing: pane) {
      layers[index].focusedPane = pane
    }
  }

  /// Takes `pane` out of whichever tree holds it. An emptied layer is
  /// dropped; an emptied tiled tree becomes nil.
  mutating func remove(_ pane: PaneID) {
    if let index = layerIndex(containing: pane) {
      if let next = layers[index].layout.removing(pane) {
        layers[index].layout = next
        if layers[index].focusedPane == pane {
          layers[index].focusedPane = next.panes[0]
        }
      } else {
        layers.remove(at: index)
      }
    } else if let layout, layout.contains(pane) {
      self.layout = layout.removing(pane)
    }
    if zoomedPane == pane { zoomedPane = nil }
  }

  /// Splits `pane` in whichever tree holds it. False when none does.
  mutating func split(_ pane: PaneID, axis: SplitAxis, newPane: PaneID) -> Bool
  {
    if let index = layerIndex(containing: pane) {
      layers[index].layout = layers[index].layout
        .splitting(pane, axis: axis, newPane: newPane)
    } else if let layout, layout.contains(pane) {
      self.layout = layout.splitting(pane, axis: axis, newPane: newPane)
    } else {
      return false
    }
    return true
  }

  /// A tab keeps a visible pane: when only minimized layers remain, the
  /// front-most one shows again.
  mutating func revealIfHidden() {
    guard visiblePanes.isEmpty, let index = layers.lastIndex(where: \.minimized)
    else { return }
    layers[index].minimized = false
  }

  /// Focus after the current pane leaves the visible set.
  mutating func restoreFocus() {
    if let previous = previousPane, contains(previous),
      visiblePanes.contains(previous)
    {
      activePane = previous
    } else if let pane = visiblePanes.first ?? panes.first {
      activePane = pane
    }
    previousPane = nil
    if let index = layerIndex(containing: activePane) {
      layers[index].focusedPane = activePane
    }
  }
}

struct Workspace {
  var id = WorkspaceID()
  var name: String
  var createdAt = Date()
  var tabs: [Tab]
  var activeTab: TabID
  var remainOnExit: Bool
  /// Local use survives detach; remote reservation expiry must not end
  /// a workspace that another frontend has already used.
  var wasAttachedLocally = false
  /// Environment snapshot taken at creation; new panes reuse it.
  var launch: LaunchSpec
  var layoutRevision: UInt64 = 1
  /// Workspace › Don't Save Output (spec.durability.md §12.2.2).
  var outputOptOut = false

  func tabIndex(containing pane: PaneID) -> Int? {
    tabs.firstIndex { $0.contains(pane) }
  }

  var allPanes: [PaneID] { tabs.flatMap(\.panes) }

  /// An older client would drop these panes or fail to decode the tab.
  var hasFloatingLayers: Bool {
    tabs.contains { !$0.layers.isEmpty || $0.layout == nil }
  }
}

struct PaneRecord {
  let runtime: PaneRuntime
  let workspace: WorkspaceID
  var columns: Int
  var rows: Int
  var title = ""
  /// The foreground program (`PaneEvent.program`); empty when unknown.
  var program = ""
  var workingDirectory: String?
  /// How the pane started, for saved layouts.
  var launch: SavedPaneLaunch = .loginShell
  /// The OSC 7577 command chosen for this pane, when one was accepted.
  var resume: SavedProgramResume? = nil
  /// The last directory on this Mac; splits and saved layouts use only this.
  var localDirectory: String?
  var directoryFallback = false
  var exitStatus: Int32?
  /// Removed from the layout; kept only until its process is reaped.
  var detachedFromLayout = false

  func summary(_ id: PaneID) -> PaneSummary {
    PaneSummary(
      id: id,
      columns: columns,
      rows: rows,
      title: title,
      pid: runtime.pid > 0 ? runtime.pid : nil,
      exitStatus: exitStatus,
      workingDirectory: workingDirectory,
      program: program.isEmpty ? nil : program
    )
  }
}

/// How the service reaches a client.
enum ClientTransport {
  case xpc(SMXChannel)
  /// In-process (the roaming bridge): values, never encoded.
  case local(LocalClientSink)
}

final class Client {
  let id: UUID
  let transport: ClientTransport
  var hello: Hello?
  /// Receives `workspaces` events (metadata only, no lease).
  var observesWorkspaces = false
  var observesWorkspaceGraph = false
  var workspaceGraphOutstanding = false
  /// Receives `inbox` events.
  var subscribesInbox = false
  /// Bridged from the roaming transport rather than local XPC.
  var remote = false
  /// Accepted on an in-process forwarding listener: its hello may declare
  /// the transport an in-process frontend authenticated, as a bound
  /// gateway's may.
  var acceptsForwarding = false

  /// Negotiated frame encoding: binary and deltas only when the hello
  /// asked for them (the service supports both).
  var frameEncoding: PaneRuntime.FrameEncoding {
    let capabilities = hello?.capabilities ?? []
    return PaneRuntime.FrameEncoding(
      binary: capabilities.contains(.binaryFrames),
      deltas: capabilities.contains(.frameDeltas),
      images: capabilities.contains(.images)
    )
  }

  init(channel: SMXChannel) {
    id = UUID()
    transport = .xpc(channel)
  }

  init(id: UUID, local sink: LocalClientSink, remote: Bool) {
    self.id = id
    transport = .local(sink)
    self.remote = remote
  }

  var local: LocalClientSink? {
    if case let .local(sink) = transport { sink } else { nil }
  }

  func cancel() {
    switch transport {
    case let .xpc(channel): channel.cancel()
    case let .local(sink): sink.onClosed("closed by service")
    }
  }
}

/// A frame sent to a client and not yet acknowledged.
struct SentFrame {
  var revision: UInt64
  var bytes: Int
  var geometry: UInt64
  /// The viewport revision it shows: a viewer's window, or the
  /// controller's scroll position and search.
  var viewport: UInt64
  /// The base for later deltas once the client acknowledges this frame.
  var baseline: FrameBaseline? = nil
}

struct QueuedFrame {
  var frame: SentFrame
  var data: Data
}

struct FrameSlot {
  var dirty = true
  /// Output while the tab was hidden but its old subscription remained.
  var hiddenActivity = false
  /// Token of the capture in progress; a completion carrying any other
  /// token belongs to an earlier subscription and is dropped.
  var capture: UInt64?
  /// Captures with a token up to this one used a window or size that has
  /// since changed. Their failures are not reported; the slot recaptures
  /// (a moved window marks it dirty, a resize when the runtime applies it).
  var supersededThrough: UInt64 = 0
  /// Budget held for `capture` until it completes or the slot goes.
  var reserved = 0
  var inflight: SentFrame?
  /// Newest complete frame waiting behind the one in flight. Replaced,
  /// never queued deeper than one.
  var queued: QueuedFrame?
  var lastSent: UInt64 = 0
  /// The controller viewport revision of the newest frame sent. A newer
  /// one (a scroll) is captured without waiting out the frame interval;
  /// the single frame in flight still paces it to the client.
  var lastViewport: UInt64 = 0
  var lastCapture: UInt64 = 0
  /// The newest frame the client acknowledged: the base of the next delta.
  /// Nil forces a complete frame.
  var baseline: FrameBaseline?

  mutating func sent(_ frame: SentFrame) {
    inflight = frame
    lastSent = DispatchTime.now().uptimeNanoseconds
    lastViewport = frame.viewport
  }
}

/// Initial-frame gate. Which panes it waits on is derived when Ready is
/// published (`MuxService.readyFrames`): the subscribed visible panes,
/// less those whose capture failed. Hidden panes are never required.
struct Readiness {
  var enabled = false
  /// The client has named a subscription since attaching.
  var armed = false
  /// Acknowledged frames of subscribed panes, visible or not, so a pane
  /// that becomes visible is already counted.
  var installed: [PaneID: (frame: UInt64, geometry: UInt64, viewport: UInt64)] =
    [:]
  /// Panes whose last capture failed (reported through
  /// `frameUnavailable`); Ready does not wait on them.
  var failed: Set<PaneID> = []
  /// Per resized pane, the geometry generation a frame must carry to
  /// count; frames at an older size never do.
  var minimumGeometry: [PaneID: UInt64] = [:]
  var sent = false

  /// Starts gating with the subscription the client just named.
  mutating func arm(_ panes: [PaneID]) {
    guard enabled, !sent else { return }
    armed = true
    failed.formIntersection(panes)
    installed = installed.filter { panes.contains($0.key) }
  }

  /// A resize produces a new frame; only that one counts, and a pane that
  /// had failed is waited on again.
  mutating func resized(_ pane: PaneID, to geometry: UInt64) {
    guard enabled, !sent else { return }
    installed.removeValue(forKey: pane)
    failed.remove(pane)
    minimumGeometry[pane] = geometry
  }

  /// A failed pane is captured again (its window moved); Ready waits for
  /// the new frame.
  mutating func retry(_ pane: PaneID) {
    guard failed.remove(pane) != nil else { return }
    installed.removeValue(forKey: pane)
  }

  /// Forgets a pane that left the layout.
  mutating func forget(_ pane: PaneID) {
    installed.removeValue(forKey: pane)
    failed.remove(pane)
    minimumGeometry.removeValue(forKey: pane)
  }

  /// Records an acknowledged frame of the pane's current `window` unless
  /// Ready is out or the frame predates a resize. True when recorded (Ready
  /// may now be due). A window that moves later is checked on publish.
  mutating func install(
    _ pane: PaneID,
    _ frame: SentFrame,
    window: UInt64,
  ) -> Bool {
    guard enabled, !sent, frame.viewport == window,
      frame.geometry >= minimumGeometry[pane, default: 0]
    else { return false }
    installed[pane] = (frame.revision, frame.geometry, frame.viewport)
    failed.remove(pane)
    return true
  }
}

/// A search match a viewer selected. Its rows are absolute, so they only
/// identify the match in the history generation it came from.
struct SelectedMatch: Sendable {
  var range: TerminalRange
  /// Position in the match list, kept when rows are renumbered.
  var index: Int
  /// Advances on reflow, clear and alternate-screen switches.
  var historyGeneration: UInt64
}

/// One viewer's window, also what each of its captures applies. Display
/// size never changes the PTY.
struct ViewerViewport: Sendable {
  /// This window's subscription; unique in the service, so a move or
  /// search issued for an earlier one is never applied to it.
  let id: UInt64
  var followTail: Bool
  var historyGeneration: UInt64
  var anchorRow: Int?
  var rows: Int?
  var columns: Int?
  /// The last completed search; a step continues it.
  var searchQuery: String?
  /// Match selected by the last search reply. Capture reselects it after
  /// `search` clears the engine selection.
  var searchSelected: SelectedMatch?
  var revision: UInt64 = 1
}

extension ViewerViewport {
  func request(_ pane: PaneID) -> ViewportRequest {
    ViewportRequest(
      pane: pane,
      anchorRow: anchorRow,
      followTail: followTail,
      historyGeneration: historyGeneration,
      rows: rows,
      columns: columns,
    )
  }
}

struct ActivePaste: Codable {
  var pane: PaneID
  var bytes = 0
}

/// One interactive lease on one workspace (spec.inbox.md §2). A client
/// holds at most one; a workspace has at most one holder.
struct Lease {
  var client: UUID
  var attachment = AttachmentID()
  var workspace: WorkspaceID
  /// The workspace's lease generation when this lease was granted.
  var generation: UInt64
  var holder: LeaseHolder
  /// Next input sequence this attachment may submit (watermark + 1).
  var nextInput: UInt64 = 1
  var subscriptions: [PaneID] = []
  var frames: [PaneID: FrameSlot] = [:]
  /// Rotates which subscribed pane is captured first.
  var paneCursor = 0
  var geometryGeneration: UInt64 = 0
  var pastes: [UInt64: ActivePaste] = [:]
  /// Unsubscribed panes already reported through `activity`.
  var reportedActivity: Set<PaneID> = []
  var readiness = Readiness()
}

/// A window command waiting its turn, with its own reply so it can be
/// failed early when its window goes.
struct WaitingWindowCommand {
  let run: (isolated MuxService) -> Void
  let reply: MuxService.Reply
}

/// One pane's window commands for a viewer: whether one is running, and
/// those waiting behind it.
struct WindowCommandQueue {
  var running = false
  var waiting: [WaitingWindowCommand] = []

  /// Removes and returns the waiting commands (to fail with
  /// `failWindowCommands`); the running one replies itself.
  mutating func takeWaiting() -> [WaitingWindowCommand] {
    defer { waiting = [] }
    return waiting
  }
}

/// Read-only attachment. It never holds the writer lease or a paste.
struct Viewer {
  let client: UUID
  let attachment = AttachmentID()
  let workspace: WorkspaceID
  var subscriptions: [PaneID] = []
  var frames: [PaneID: FrameSlot] = [:]
  var paneCursor = 0
  var viewports: [PaneID: ViewerViewport] = [:]
  var readiness = Readiness()
  /// Panes already told their history anchor is stale; one notice each
  /// until the viewer moves.
  var staleAnchorReported: Set<PaneID> = []
  /// Window commands per pane: present while one runs, holding those
  /// waiting behind it (`MuxService.inWindowOrder`).
  var windowCommands: [PaneID: WindowCommandQueue] = [:]
  /// Frame bytes this observer holds against the shared budget.
  var heldFrameBytes: Int {
    frames.values.reduce(0) {
      $0 + ($1.inflight?.bytes ?? 0) + ($1.queued?.frame.bytes ?? 0)
        + $1.reserved
    }
  }
}
