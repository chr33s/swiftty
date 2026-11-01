import Darwin
import Dispatch
import Foundation
import SwiftMuxClient
import SwiftMuxProtocol

/// The `swmux` interactive attachment inside Swiftty: raw outer tty,
/// prefix commands, a composed workspace display and copy mode.
@MainActor
public final class TerminalClient {
  public enum Outcome: Equatable, Sendable {
    case detached(String)
    case lost(String)
    case failed(String)
  }

  struct CopyState {
    var pane: PaneID
    var frame: PaneFrame
    var row: Int
    var column: Int
    var anchor: (row: Int, column: Int)?
    var lines = false
  }

  struct Prompt {
    var label: String
    var text = ""
    var commit: @MainActor (String) -> Void
    /// Tells one prompt from another with the same label.
    let id = UUID()
    /// Copy mode the prompt was opened over. Its pane's frames keep it
    /// current, and leaving the prompt returns to it (else to normal mode).
    /// If its pane goes, the prompt stays open, relabelled, without it.
    var over: CopyState?
  }

  enum Mode {
    case normal
    case prefix
    case copy(CopyState)
    case prompt(Prompt)
    case help
    case confirm(String, @MainActor () -> Void)
  }

  let connection: MuxConnection
  let attachment: AttachmentID
  let tty: RawTTY
  let settings: Settings
  private var decoder: InputDecoder
  package private(set) var workspace: WorkspaceSnapshot
  /// Orders snapshots against the attach and switch replies.
  private var sequencer = LayoutSequencer()
  private var frames: [PaneID: PaneFrame] = [:]
  private var size: (columns: Int, rows: Int)
  private var renderer = DiffRenderer()
  private var geometryGeneration: UInt64 = 0
  private var lastGeometry: (revision: UInt64, entries: [GeometryBatch.Entry])?
  private var subscriptions: [PaneID] = []
  private var mode: Mode = .normal
  private var message: String?
  private var messageTimer: DispatchWorkItem?
  private var pasteBuffer: String?
  private var escapeTimer: DispatchWorkItem?
  private var redrawScheduled = false
  private var continuation: CheckedContinuation<Outcome, Never>?
  private var outcome: Outcome?
  private var sources: [any DispatchSourceProtocol] = []
  private let sourceCancellation = DispatchGroup()
  private var signalDispositions: [(Int32, sigaction)] = []
  private var eventTask: Task<Void, Never>?
  private var running = false
  private let limits: MuxLimits

  public init(
    connection: MuxConnection,
    attachment: AttachmentID,
    workspace: WorkspaceSnapshot,
    limits: MuxLimits,
    tty: RawTTY = RawTTY(),
    settings: Settings = Settings()
  ) {
    self.connection = connection
    self.attachment = attachment
    self.workspace = workspace
    _ = sequencer.attached(workspace)
    self.tty = tty
    self.settings = settings
    self.limits = limits
    decoder = InputDecoder(maxPasteBytes: limits.maxPasteBytes)
    size = tty.size
  }

  /// Runs until detach, cancellation or connection loss. A concurrent call
  /// fails; after completion, later calls return the original outcome.
  /// The outer tty is restored
  /// before returning, and before waiting on any service cleanup.
  public func run() async -> Outcome {
    guard !running else { return .failed("terminal client is already running") }
    if let outcome { return outcome }
    running = true
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        self.continuation = continuation
        guard !Task.isCancelled else {
          finish(.detached("cancelled"), detach: true)
          return
        }
        do {
          try tty.enter()
          try installSources()
          startEvents()
          syncLayout()
        } catch { finish(.failed("\(error)"), detach: true) }
      }
    } onCancel: {
      Task { @MainActor in self.finish(.detached("cancelled"), detach: true) }
    }
  }

  private func finish(_ result: Outcome, detach: Bool) {
    guard outcome == nil else { return }
    outcome = result
    for source in sources { source.cancel() }
    sources = []
    escapeTimer?.cancel()
    messageTimer?.cancel()
    eventTask?.cancel()
    let connection = self.connection
    Task {
      // Restore process signal state after the sources finish cancelling,
      // and restore the tty before waiting for the service.
      await withCheckedContinuation { continuation in
        sourceCancellation.notify(queue: .main) { continuation.resume() }
      }
      tty.restore()
      for (sig, var disposition) in signalDispositions {
        _ = sigaction(sig, &disposition, nil)
      }
      signalDispositions = []
      eventTask = nil
      if detach { await connection.detach() }
      await connection.close()
      self.running = false
      self.continuation?.resume(returning: result)
      self.continuation = nil
    }
  }

  // MARK: Sources

  private func installSources() throws {
    let read = DispatchSource.makeReadSource(
      fileDescriptor: tty.input,
      queue: .main
    )
    read.setEventHandler { [weak self] in
      MainActor.assumeIsolated { self?.readInput() }
    }
    startSource(read)
    // Signal handlers only notify normal execution code.
    for sig in [SIGWINCH, SIGTERM, SIGHUP, SIGCONT, SIGINT, SIGQUIT] {
      var ignored = sigaction()
      ignored.__sigaction_u.__sa_handler = SIG_IGN
      sigemptyset(&ignored.sa_mask)
      var previous = sigaction()
      guard sigaction(sig, &ignored, &previous) == 0 else {
        throw POSIXFailure("sigaction")
      }
      signalDispositions.append((sig, previous))
      let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
      source.setEventHandler { [weak self] in
        MainActor.assumeIsolated { self?.handleSignal(sig) }
      }
      startSource(source)
    }
  }

  private func startSource(_ source: any DispatchSourceProtocol) {
    let cancellation = sourceCancellation
    cancellation.enter()
    source.setCancelHandler { cancellation.leave() }
    source.resume()
    sources.append(source)
  }

  private func handleSignal(_ sig: Int32) {
    guard outcome == nil else { return }
    switch sig {
    case SIGWINCH:
      size = tty.size
      renderer.invalidate()
      syncLayout()
    case SIGCONT:
      try? tty.enter()
      renderer.invalidate()
      redraw()
    default: finish(.detached("terminated by signal \(sig)"), detach: true)
    }
  }

  private func startEvents() {
    let connection = self.connection
    eventTask = Task.detached { [weak self] in
      do {
        while let event = try await connection.nextEvent() {
          await self?.handle(event)
        }
        await self?.finish(.lost("connection closed"), detach: false)
      } catch { await self?.finish(.lost("\(error)"), detach: false) }
    }
  }

  // MARK: Service events

  package func handle(_ event: MuxEvent) {
    guard outcome == nil else { return }
    switch event {
    case let .frame(frame):
      guard frame.identity.attachment == attachment else { return }
      frames[frame.identity.pane] = frame
      if let state = copying, state.pane == frame.identity.pane {
        setCopying(following(state, frame))
      }
      redraw()
    case let .layout(snapshot): apply(snapshot)
    case let .paneExited(pane, status, truncated):
      if truncated {
        show("pane was force-killed; its final output may be incomplete")
      }
      if let i = workspace.panes.firstIndex(where: { $0.id == pane }) {
        workspace.panes[i].exitStatus = status
      }
      redraw()
    case let .title(pane, title):
      if let i = workspace.panes.firstIndex(where: { $0.id == pane }) {
        workspace.panes[i].title = title
      }
      redraw()
    case .bell: tty.write("\u{07}")
    case .activity, .ready: break
    case let .detached(reason): finish(.detached(reason), detach: false)
    case let .paste(_, state):
      if state != .completed { show("paste \(state.rawValue)") }
    case let .frameUnavailable(_, error): show("frame unavailable: \(error)")
    // This frontend never asks for clipboard requests.
    case .automation, .workspaces, .inbox, .clipboardRead, .clipboardWrite:
      break
    }
  }

  // MARK: Layout and geometry

  /// Shows `ws`. With `attached`, it is the switch reply and names the
  /// workspace this connection now holds; otherwise it is shown only for
  /// that workspace and when no older than the layout already shown.
  package func apply(_ ws: WorkspaceSnapshot, attached: Bool = false) {
    let update = attached ? sequencer.attached(ws) : sequencer.layout(ws)
    switch update {
    case nil: return
    case .resync:
      // The service dropped this connection's subscriptions.
      subscriptions = []
      lastGeometry = nil
    case let .show(ws, resync):
      if resync {
        subscriptions = []
        lastGeometry = nil
      }
      let sameWorkspace = ws.id == workspace.id
      if !sameWorkspace { frames = [:] }
      workspace = ws
      let live = Set(ws.panes.map(\.id))
      frames = frames.filter { live.contains($0.key) }
      if let pane = copying?.pane, !live.contains(pane) {
        // A prompt stays open so typing does not reach another pane; its
        // commit reports the pane is gone. Copy mode just ends (a switched
        // workspace reset its windows; a closed pane needs a notice).
        if case var .prompt(prompt) = mode {
          prompt.over = nil
          prompt.label = Self.noting(
            sameWorkspace ? "pane closed" : "workspace changed",
            in: prompt.label
          )
          mode = .prompt(prompt)
        } else {
          mode = .normal
          if sameWorkspace { show("pane closed") }
        }
      }
    }
    syncLayout()
  }

  private var compositor: Compositor {
    Compositor(columns: size.columns, rows: size.rows)
  }

  private var activeTab: TabSnapshot? { workspace.activeTabSnapshot }

  /// Sends a geometry batch for visible panes and subscribes to them.
  /// Panes whose area is empty keep their last valid size.
  func syncLayout() {
    guard let tab = activeTab else { return }
    let rects = compositor.frames(for: tab)
    let order = tab.layout.panes.filter { rects[$0] != nil }
    var entries: [GeometryBatch.Entry] = []
    for pane in order {
      guard let r = rects[pane], r.width >= 1, r.height >= 1 else { continue }
      entries.append(
        .init(
          pane: pane,
          columns: min(r.width, limits.maxColumns),
          rows: min(r.height, limits.maxRows)
        )
      )
    }
    if lastGeometry?.revision != workspace.layoutRevision
      || lastGeometry?.entries != entries
    {
      lastGeometry = (workspace.layoutRevision, entries)
      geometryGeneration += 1
      let batch = GeometryBatch(
        layoutRevision: workspace.layoutRevision,
        generation: geometryGeneration,
        entries: entries
      )
      command(.setGeometry(batch), quietOn: [.staleGeometry])
    }
    if order != subscriptions {
      subscriptions = order
      command(.setSubscriptions(order))
    }
    redraw()
  }

  /// Sends `command`; `then` gets a successful reply. A failure whose
  /// code is in `quiet` is dropped; any other goes to `failed` when given
  /// (which then reports it), else shows as a message.
  private func command(
    _ command: MuxCommand,
    quietOn quiet: Set<MuxError.Code> = [],
    then: (@MainActor (MuxReply) -> Void)? = nil,
    failed: (@MainActor (MuxError) -> Void)? = nil
  ) {
    connection.enqueue(command) { [weak self] result in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self, self.outcome == nil else { return }
          switch result {
          case let .success(reply):
            // A switch reply also names the attached workspace.
            if case let .layout(snapshot) = reply {
              var switched = false
              if case .switchWorkspace = command { switched = true }
              self.apply(snapshot, attached: switched)
            }
            then?(reply)
          case let .failure(error):
            // Quiet codes are dropped; a caller handling the rest reports
            // them its own way.
            guard !quiet.contains(error.code) else { break }
            if let failed {
              failed(error)
            } else {
              self.show(error.description)
            }
          }
        }
      }
    }
  }

  // MARK: Drawing

  private func redraw() {
    guard !redrawScheduled, outcome == nil else { return }
    redrawScheduled = true
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        self.redrawScheduled = false
        self.draw()
      }
    }
  }

  func compose() -> ScreenBuffer {
    var shown = frames
    var overlays: [PaneID: PaneOverlay] = [:]
    // A prompt over copy mode keeps showing the frozen copy view.
    if let state = copying {
      shown[state.pane] = state.frame
      overlays[state.pane] = PaneOverlay(
        selection: state.anchor.map {
          ($0, (state.row, state.column), state.lines)
        },
        cursor: (state.row, state.column)
      )
    }
    let showCursor: Bool =
      switch mode {
      case .normal, .prefix: true
      default: false
      }
    var screen = compositor.compose(
      workspace: workspace,
      frames: shown,
      overlays: overlays,
      status: status,
      showCursor: showCursor
    )
    if case .help = mode { drawHelp(into: &screen) }
    return screen
  }

  private func draw() {
    guard outcome == nil else { return }
    let screen = compose()
    let bytes = renderer.update(to: screen)
    if tty.write(bytes) {
      renderer.commit(screen)
    } else {
      renderer.invalidate()
    }
  }

  private var status: StatusLine {
    var line = StatusLine()
    line.left = "[\(workspace.name)] "
    for (i, tab) in workspace.tabs.enumerated() {
      let active = tab.id == workspace.activeTab
      let flags = (active ? "*" : "") + (tab.zoomedPane != nil ? "Z" : "")
      line.items.append(
        .init(text: "\(i):\(tab.name)\(flags) ", active: active)
      )
    }
    switch mode {
    case let .copy(state):
      line.right =
        "[copy \(state.frame.history.viewportOffset)/\(state.frame.history.scrollbackRows)] "
    case .prefix:
      line.right =
        "^\(settings.prefix.last.map { String($0).uppercased() } ?? "B") "
    case let .prompt(p):
      line.prompt = p.label + p.text
      line.promptCursor = true
    case let .confirm(question, _):
      line.prompt = question
      line.promptSuffix = "? (y/n)"
    default:
      // A program sets its title (the service sanitizes it).
      if let pane = activeTab?.activePane,
        let full = workspace.pane(pane)?.title,
        case let title = TerminalText.head(full, width: size.columns / 3),
        !title.isEmpty
      {
        line.right = "\"\(title)\" "
      }
    }
    if let message {
      // Beside an open prompt or question, else the whole line.
      if line.prompt != nil {
        line.right = message
      } else {
        line.prompt = message
        line.right = ""
      }
    }
    return line
  }

  private static let help = [
    "swmux — prefix then:",
    "c new tab        n/p next/prev tab   0-9 select tab",
    "% split ←→       \" split ↑↓         o next pane",
    "arrows focus     M-arrows resize     z zoom pane",
    "x end pane       & end tab           d detach",
    "[ copy mode      ] paste buffer      / search",
    ", rename tab     $ rename workspace  w switch workspace",
    "? help           prefix twice sends the prefix",
    "copy mode: hjkl/arrows move, v/V select, y copy,",
    "  PgUp/PgDn scroll, g/G top/bottom, n/N search, q quit",
  ]

  private func drawHelp(into screen: inout ScreenBuffer) {
    let width = min(size.columns - 2, (Self.help.map(\.count).max() ?? 0) + 4)
    let height = min(size.rows - 2, Self.help.count + 2)
    guard width > 4, height > 2 else { return }
    let x0 = (size.columns - width) / 2
    let y0 = max(0, (size.rows - 1 - height) / 2)
    let style = OuterStyle(foreground: .palette(15), background: .palette(4))
    screen.fill(
      LayoutRect(x: x0, y: y0, width: width, height: height),
      style: style
    )
    for (i, line) in Self.help.prefix(height - 2).enumerated() {
      screen.write(
        line,
        x: x0 + 2,
        y: y0 + 1 + i,
        style: style,
        limit: width - 4
      )
    }
  }

  private func show(_ text: String) {
    message = text
    messageTimer?.cancel()
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        self?.message = nil
        self?.redraw()
      }
    }
    messageTimer = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    redraw()
  }

  // MARK: Input

  private func readInput() {
    guard outcome == nil else { return }
    guard let bytes = tty.read() else {
      finish(.detached("terminal closed"), detach: true)
      return
    }
    guard !bytes.isEmpty else { return }
    feed(bytes)
  }

  func feed(_ bytes: [UInt8]) {
    for event in decoder.feed(bytes) { dispatch(event) }
    escapeTimer?.cancel()
    if decoder.hasPending {
      let work = DispatchWorkItem { [weak self] in
        MainActor.assumeIsolated {
          guard let self else { return }
          for event in self.decoder.flushPending() { self.dispatch(event) }
        }
      }
      escapeTimer = work
      DispatchQueue.main.asyncAfter(
        deadline: .now() + .milliseconds(settings.escapeDelayMilliseconds),
        execute: work
      )
    }
  }

  private var activePane: PaneID? { activeTab?.activePane }

  /// The decoder coalesces text from one read. Command modes consume
  /// individual keys; normal input and prompt text stay coalesced.
  private func dispatch(_ input: DecodedInput) {
    guard case let .text(text) = input else {
      handle(input)
      return
    }
    var remaining = text[...]
    while !remaining.isEmpty {
      switch mode {
      case .normal, .prompt:
        handle(.text(String(remaining)))
        return
      default: handle(.text(String(remaining.removeFirst())))
      }
    }
  }

  func handle(_ input: DecodedInput) {
    if message != nil {
      message = nil
      messageTimer?.cancel()
    }
    switch mode {
    case .normal:
      if case let .key(k, m) = input, k == settings.prefixKey.0,
        m == settings.prefixKey.1
      {
        mode = .prefix
        redraw()
        return
      }
      sendToPane(input)
    case .prefix:
      mode = .normal
      prefixCommand(input)
      redraw()
    case let .copy(state): copyMode(input, state)
    case var .prompt(prompt):
      switch input {
      case let .text(s), let .paste(s, _):
        prompt.text = Self.promptText(prompt.text, adding: s)
        mode = .prompt(prompt)
      case .key(.backspace, _):
        if !prompt.text.isEmpty { prompt.text.removeLast() }
        mode = .prompt(prompt)
      case .key(.enter, _):
        leave(prompt)
        prompt.commit(prompt.text)
      case .key(.escape, _), .key(.character(0x63), .control),
        .key(.character(0x67), .control):
        leave(prompt)
      default: break
      }
      redraw()
    case .help:
      mode = .normal
      redraw()
    case let .confirm(_, action):
      mode = .normal
      if case let .text(s) = input, s.lowercased() == "y" { action() }
      redraw()
    }
  }

  private func sendToPane(_ input: DecodedInput) {
    guard let pane = activePane else { return }
    if workspace.pane(pane)?.exitStatus != nil { return }
    switch input {
    case let .text(s):
      connection.enqueue(.text(s), to: pane, rejected: rejectedInput)
    case let .key(k, m):
      connection.enqueue(.key(k, m), to: pane, rejected: rejectedInput)
    case let .paste(s, truncated):
      if truncated { show("paste truncated to \(limits.maxPasteBytes) bytes") }
      paste(s, to: pane)
    }
  }

  private nonisolated var rejectedInput: @Sendable (MuxError) -> Void {
    { [weak self] error in
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.show("input rejected: \(error)") }
      }
    }
  }

  private func paste(_ text: String, to pane: PaneID) {
    connection.enqueuePaste(text, to: pane) { [weak self] result in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          switch result {
          case let .success(state) where state != .completed:
            self?.show("paste \(state.rawValue)")
          case let .failure(error): self?.show("paste failed: \(error)")
          default: break
          }
        }
      }
    }
  }

  // MARK: Prefix commands

  private func prefixCommand(_ input: DecodedInput) {
    guard let tab = activeTab, let pane = activePane else { return }
    switch input {
    case let .key(k, m)
    where k == settings.prefixKey.0 && m == settings.prefixKey.1:
      connection.enqueue(.key(k, m), to: pane, rejected: rejectedInput)
    case let .key(dir, mods) where [.up, .down, .left, .right].contains(dir):
      let direction: Direction =
        switch dir {
        case .up: .up
        case .down: .down
        case .left: .left
        default: .right
        }
      if mods.contains(.alt) || mods.contains(.control) {
        resize(pane: pane, tab: tab, direction: direction)
      } else if let target = LayoutGeometry.neighbor(
        of: pane,
        direction: direction,
        frames: compositor.frames(
          for: TabSnapshot(
            id: tab.id,
            name: tab.name,
            layout: tab.layout,
            activePane: pane
          )
        ),
        order: tab.layout.panes
      ) {
        command(.focusPane(target))
      }
    case let .text(s):
      switch s {
      case "c": command(.newTab(name: nil, launch: nil))
      case "n", "p":
        guard let i = workspace.tabs.firstIndex(where: { $0.id == tab.id })
        else { return }
        let n = workspace.tabs.count
        command(.selectTab(workspace.tabs[(i + (s == "n" ? 1 : n - 1)) % n].id))
      case "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
        let i = Int(s)!
        if i < workspace.tabs.count {
          command(.selectTab(workspace.tabs[i].id))
        }
      case "%": command(.split(pane: pane, axis: .leftRight, launch: nil))
      case "\"": command(.split(pane: pane, axis: .topBottom, launch: nil))
      case "o":
        let order = tab.layout.panes
        if let i = order.firstIndex(of: pane), order.count > 1 {
          command(.focusPane(order[(i + 1) % order.count]))
        }
      case "z": command(.toggleZoom(tab.id))
      case "x":
        mode = .confirm("end pane") { [weak self] in
          self?.command(.endPane(pane))
        }
      case "&":
        mode = .confirm("end tab \(tab.name)") { [weak self] in
          self?.command(.endTab(tab.id))
        }
      case "d":
        finish(.detached("detached from \(workspace.name)"), detach: true)
      case "[": enterCopyMode(pane)
      case "]": if let buffer = pasteBuffer { paste(buffer, to: pane) }
      case "/":
        // Search runs in copy mode, which needs the pane's first frame.
        enterCopyMode(pane)
        if case let .copy(state) = mode { promptSearch(over: state) }
      case ",":
        mode = .prompt(
          Prompt(label: "rename tab: ", text: tab.name) { [weak self] typed in
            if let name = DisplayText.plainName(typed) {
              self?.command(.renameTab(tab.id, name: name))
            }
          }
        )
      case "$":
        let id = workspace.id
        mode = .prompt(
          Prompt(label: "rename workspace: ", text: workspace.name) {
            [weak self] typed in
            guard let self, let name = DisplayText.plainName(typed) else {
              return
            }
            self.command(.renameWorkspace(.id(id), name: name)) { _ in
              self.workspace.name = name
              self.redraw()
            }
          }
        )
      case "w": chooseWorkspace()
      case "?": mode = .help
      default: break
      }
    default: break
    }
  }

  private func resize(pane: PaneID, tab: TabSnapshot, direction: Direction) {
    let axis: SplitAxis =
      direction == .left || direction == .right ? .leftRight : .topBottom
    guard let split = tab.layout.enclosingSplit(of: pane, axis: axis) else {
      return
    }
    let delta = direction == .right || direction == .down ? 0.05 : -0.05
    let ratio = min(0.95, max(0.05, split.ratio + delta))
    command(.setSplitRatio(tab: tab.id, path: split.path, ratio: ratio))
  }

  /// Names joined for a prompt label within `limit` display cells, the rest
  /// counted (", +N"). Names (plain, as the service requires) appear as
  /// typed; only a first name too long for the budget is shortened.
  static func listing(_ names: [String], limit: Int = 40) -> String {
    guard let first = names.first else { return "none" }
    func more(_ count: Int) -> String { count > 0 ? ", +\(count)" : "" }
    // Each name shown leaves room to count the names after it.
    let room = limit - more(names.count - 1).count
    guard TerminalText.width(first) <= room else {
      return TerminalText.head(first, width: max(1, room))
        + more(names.count - 1)
    }
    var shown = first
    var count = 1
    for name in names.dropFirst() {
      let rest = more(names.count - count - 1)
      guard
        TerminalText.width(shown) + 2 + TerminalText.width(name) + rest.count
          <= limit
      else { break }
      shown += ", " + name
      count += 1
    }
    return shown + more(names.count - count)
  }

  /// `text` with typed or pasted `input` added as one line of a prompt:
  /// line breaks and controls dropped, a tab as a space. The rest stays
  /// as typed (a search matches it); the status line shows what it cannot
  /// draw as "?". Characters are bounded once joined, however they came.
  static func promptText(_ text: String, adding input: String) -> String {
    var added = String.UnicodeScalarView()
    for scalar in input.unicodeScalars {
      switch scalar.properties.generalCategory {
      case .lineSeparator, .paragraphSeparator: continue
      // Line breaks (LF, CR, VT, FF, NEL) are controls too.
      case .control: if scalar == "\t" { added.append(" ") }
      default: added.append(scalar)
      }
    }
    return DisplayText.bounded(text + String(added))
  }

  /// `label` with a note before its closing ": ".
  static func noting(_ note: String, in label: String) -> String {
    let base = label.hasSuffix(": ") ? String(label.dropLast(2)) : label
    return "\(base) (\(note)): "
  }

  /// The copy state on screen: copy mode, or a prompt opened over it.
  private var copying: CopyState? {
    switch mode {
    case let .copy(state): state
    case let .prompt(prompt): prompt.over
    default: nil
    }
  }

  /// Replaces the copy state on screen, wherever the mode holds it.
  private func setCopying(_ state: CopyState) {
    switch mode {
    case .copy: mode = .copy(state)
    case var .prompt(prompt) where prompt.over != nil:
      prompt.over = state
      mode = .prompt(prompt)
    default: break
    }
  }

  /// Leaves a prompt for the copy mode it was opened over, else normal mode.
  private func leave(_ prompt: Prompt) {
    mode = prompt.over.map(Mode.copy) ?? .normal
  }

  /// Opens the workspace prompt at once; the names fill its label when
  /// the list arrives, if the prompt is still open.
  private func chooseWorkspace() {
    let prompt = Prompt(label: "workspace: ") { [weak self] typed in
      guard let self, let name = DisplayText.plainName(typed) else { return }
      self.command(.switchWorkspace(.name(name)))
    }
    mode = .prompt(prompt)
    let id = prompt.id
    // The list, or why there is none, fills the label while it is open.
    // False once the prompt has closed or changed.
    let relabel = { [weak self] (text: String) -> Bool in
      guard let self, case var .prompt(open) = self.mode, open.id == id else {
        return false
      }
      open.label = text
      self.mode = .prompt(open)
      self.redraw()
      return true
    }
    command(
      .listWorkspaces,
      then: { reply in
        guard case let .workspaces(list) = reply else { return }
        _ = relabel("workspace (\(Self.listing(list.map(\.name)))): ")
      },
      failed: { [weak self] error in
        // In the label if the prompt is still open, else as a message.
        if !relabel("workspace (no list: \(error.code)): ") {
          self?.show(error.description)
        }
      }
    )
  }

  // MARK: Copy mode

  private func enterCopyMode(_ pane: PaneID) {
    guard let frame = frames[pane] else {
      show("no frame yet")
      return
    }
    mode = .copy(
      CopyState(
        pane: pane,
        frame: frame,
        row: frame.cursor.y,
        column: frame.cursor.x
      )
    )
    redraw()
  }

  private func exitCopyMode(_ pane: PaneID) {
    mode = .normal
    command(.endSearch(pane: pane), quietOn: [.notFound])
    command(.scroll(pane: pane, .bottom), quietOn: [.notFound])
    redraw()
  }

  /// Copy mode on a newer frame of its pane: a viewport reached by
  /// scrolling or search replaces the frozen frame (selection across
  /// fetched pages is not supported).
  private func following(_ state: CopyState, _ frame: PaneFrame) -> CopyState {
    guard
      frame.identity.viewportRevision != state.frame.identity.viewportRevision
    else { return state }
    var state = state
    state.frame = frame
    state.anchor = nil
    state.row = min(state.row, frame.grid.rows - 1)
    state.column = min(state.column, frame.grid.columns - 1)
    return state
  }

  /// Opens the search prompt over copy mode on `state.pane`.
  private func promptSearch(over state: CopyState) {
    let pane = state.pane
    let openedIn = workspace.id
    var prompt = Prompt(label: "search: ") { [weak self] query in
      guard let self else { return }
      // Its pane may have gone while the prompt was open.
      guard self.workspace.id == openedIn else {
        self.show("workspace changed")
        return
      }
      guard self.workspace.pane(pane) != nil else {
        self.show("pane closed")
        return
      }
      // A query the service would refuse ends the search, as in the app.
      guard self.limits.validSearchQuery(query) else {
        self.command(.endSearch(pane: pane), quietOn: [.notFound])
        if !query.isEmpty { self.show("search query too long") }
        return
      }
      self.command(.search(pane: pane, query: query)) { reply in
        if case let .search(result) = reply, result.matchCount == 0 {
          self.show("no matches")
        }
      }
    }
    prompt.over = state
    mode = .prompt(prompt)
  }

  private func copyMode(_ input: DecodedInput, _ initial: CopyState) {
    var state = initial
    let rows = state.frame.grid.rows
    let columns = state.frame.grid.columns
    let pane = state.pane
    func scroll(_ request: ScrollRequest) {
      command(.scroll(pane: pane, request), quietOn: [.historyUnavailable])
    }
    var key: (MuxKey, MuxKeyModifiers)?
    var text: String?
    switch input {
    case let .key(k, m): key = (k, m)
    case let .text(s): text = s
    case .paste: return
    }
    switch (key?.0, key?.1, text) {
    case (.escape, _, _), (_, _, "q"):
      exitCopyMode(pane)
      return
    case (.up, _, _), (_, _, "k"):
      if state.row > 0 { state.row -= 1 } else { scroll(.lines(1)) }
    case (.down, _, _), (_, _, "j"):
      if state.row < rows - 1 { state.row += 1 } else { scroll(.lines(-1)) }
    case (.left, _, _), (_, _, "h"): state.column = max(0, state.column - 1)
    case (.right, _, _), (_, _, "l"):
      state.column = min(columns - 1, state.column + 1)
    case (.pageUp, _, _), (.character(0x62), MuxKeyModifiers.control, _):
      scroll(.pages(1))
    case (.pageDown, _, _), (.character(0x66), MuxKeyModifiers.control, _):
      scroll(.pages(-1))
    case (.character(0x75), MuxKeyModifiers.control, _):
      scroll(.lines(max(1, rows / 2)))
    case (.character(0x64), MuxKeyModifiers.control, _):
      scroll(.lines(-max(1, rows / 2)))
    case (_, _, "g"):
      scroll(.lines(state.frame.history.scrollbackRows))
      state.row = 0
    case (_, _, "G"):
      scroll(.bottom)
      state.row = rows - 1
    case (.home, _, _), (_, _, "0"): state.column = 0
    case (.end, _, _), (_, _, "$"):
      state.column = FrameText.lineEnd(state.frame, row: state.row)
    case (_, _, "w"):
      let (_, hi) = FrameText.word(
        state.frame,
        row: state.row,
        column: state.column
      )
      state.column = min(columns - 1, hi + 1)
      while state.column < columns - 1,
        state.frame.scalars(row: state.row, column: state.column) == [" "]
      { state.column += 1 }
    case (_, _, "b"):
      var c = max(0, state.column - 1)
      while c > 0, state.frame.scalars(row: state.row, column: c) == [" "] {
        c -= 1
      }
      state.column = FrameText.word(state.frame, row: state.row, column: c).0
    case (_, _, "v"), (_, _, " "):
      state.anchor = state.anchor == nil ? (state.row, state.column) : nil
      state.lines = false
    case (_, _, "V"):
      state.anchor =
        state.anchor == nil || !state.lines ? (state.row, state.column) : nil
      state.lines = state.anchor != nil
    case (.enter, _, _), (_, _, "y"):
      if let anchor = state.anchor {
        let text = FrameText.text(
          state.frame,
          from: anchor,
          to: (state.row, state.column),
          lines: state.lines
        )
        copy(text)
      }
      exitCopyMode(pane)
      return
    case (_, _, "/"):
      promptSearch(over: state)
      redraw()
      return
    case (_, _, "n"): command(.searchStep(pane: pane, forward: false))
    case (_, _, "N"): command(.searchStep(pane: pane, forward: true))
    default: break
    }
    mode = .copy(state)
    redraw()
  }

  /// Local copy: the paste buffer plus the system pasteboard.
  private func copy(_ text: String) {
    pasteBuffer = text
    let pbcopy = Process()
    pbcopy.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
    let pipe = Pipe()
    pbcopy.standardInput = pipe
    do {
      try pbcopy.run()
      pipe.fileHandleForWriting.write(Data(text.utf8))
      try? pipe.fileHandleForWriting.close()
      show("copied \(text.count) characters")
    } catch { show("copied to swmux buffer") }
  }
}
