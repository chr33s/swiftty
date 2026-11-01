import AppKit
import MetalKit
import SwiftMuxBridge
import SwiftMuxProtocol
import SwifttyCore
import SwifttyMac

/// A decoded, validated frame with its app-owned renderer snapshot.
struct MuxPresentation: Sendable {
  let frame: PaneFrame
  let snapshot: RenderSnapshot
}

/// Selection on one frozen frame, in viewport cells. New output never
/// changes it; the frame it was made on stays retained until it ends.
struct FrozenSelection: Equatable {
  typealias Unit = TerminalPointer.SelectionUnit
  var anchor: (row: Int, column: Int)
  var head: (row: Int, column: Int)
  var unit: Unit

  static func == (a: FrozenSelection, b: FrozenSelection) -> Bool {
    a.anchor == b.anchor && a.head == b.head && a.unit == b.unit
  }

  /// Ordered, unit-expanded bounds clamped to the frame.
  func span(in frame: PaneFrame) -> HighlightSpan {
    let cols = frame.grid.columns
    func clamp(_ p: (row: Int, column: Int)) -> (row: Int, column: Int) {
      (min(max(p.row, 0), frame.grid.rows - 1), min(max(p.column, 0), cols - 1))
    }
    let a = clamp(anchor)
    let b = clamp(head)
    let ordered = a < b
    var start = ordered ? a : b
    var end = ordered ? b : a
    switch unit {
    case .cell: break
    case .line:
      start.column = 0
      end.column = cols - 1
    case .word:
      func isWord(_ r: Int, _ c: Int) -> Bool {
        let s = frame.scalars(row: r, column: c)
        return !(s.isEmpty || s == [" "])
          && !s.contains { " \t()[]{}<>\"'`|,;".unicodeScalars.contains($0) }
      }
      if isWord(start.row, start.column) {
        while start.column > 0, isWord(start.row, start.column - 1) {
          start.column -= 1
        }
      }
      if isWord(end.row, end.column) {
        while end.column < cols - 1, isWord(end.row, end.column + 1) {
          end.column += 1
        }
      }
    }
    return HighlightSpan(
      startRow: start.row,
      startColumn: start.column,
      endRow: end.row,
      endColumn: end.column
    )
  }

  /// Text from the frozen cells; soft-wrapped rows join without newlines.
  func text(in frame: PaneFrame) -> String {
    let s = span(in: frame)
    var lines: [String] = []
    var joinNext = false
    for row in s.startRow ... s.endRow {
      let lo = row == s.startRow ? s.startColumn : 0
      let hi = row == s.endRow ? s.endColumn : frame.grid.columns - 1
      var scalars = String.UnicodeScalarView()
      if lo <= hi {
        for c in lo ... hi {
          scalars.append(contentsOf: frame.scalars(row: row, column: c))
        }
      }
      var line = String(scalars)
      let wraps = frame.grid.isWrapped(row: row) && row != s.endRow
      if !wraps { while line.last == " " { line.removeLast() } }
      if joinNext, let last = lines.popLast() { line = last + line }
      lines.append(line)
      joinNext = wraps
    }
    return lines.joined(separator: "\n")
  }
}

private func < (a: (row: Int, column: Int), b: (row: Int, column: Int)) -> Bool
{ a.row != b.row ? a.row < b.row : a.column < b.column }

/// One remote pane: retains local presentations, draws through Metal,
/// and turns AppKit input into semantic input for its bound pane. It
/// never owns a PTY or a terminal emulator.
@MainActor
final class MuxPaneView: MTKView, MTKViewDelegate {
  let pane: PaneID
  weak var controller: MuxWorkspaceController?
  let renderer: MetalRenderer
  private(set) var config: Configuration

  /// Newest imported presentation not yet admitted for drawing.
  private var pending: MuxPresentation?
  /// Types the pane's program accepts drops of (kitty OSC 72), as
  /// registered with AppKit; nil when it takes none.
  var dropTypes: [String]?
  /// The presentation last accepted by the renderer: the baseline for
  /// selection, IME placement and accessibility.
  private(set) var presented: MuxPresentation?
  /// Set while a selection freezes the presentation used for interaction.
  var frozen: MuxPresentation?
  var selection: FrozenSelection? {
    didSet {
      if selection != outputSelection?.selection { outputSelection = nil }
    }
  }
  var selectionDragged = false
  private lazy var display = TerminalDisplay(
    view: self,
    renderer: renderer,
    suspendsWhenOccluded: false,
    submissionPolicy: .availableGPUOnly
  )
  private var localSequence: UInt64 = 0
  let pointer = TerminalPointer()
  var pendingAnchor: ((row: Int, column: Int), MuxPresentation)?
  /// A left-button gesture reported to the program, not selecting.
  var reportsLeftGesture: Bool {
    get { pointer.reportsLeftGesture }
    set { pointer.reportsLeftGesture = newValue }
  }
  /// The last reported pointer cell and button, so motion is sent only
  /// when it moves to another cell.
  var lastReported: (row: Int, column: Int, button: MuxMouse.Button)?
  /// Command output to select once a frame shows it (the service scrolls
  /// it into view first).
  var pendingOutput: CommandOutput?
  /// A command-output selection and its full text, which may extend
  /// beyond the rows the frozen frame shows.
  var outputSelection: (selection: FrozenSelection, text: String)?
  /// The cell a context menu was opened on, for Select Command Output.
  var menuAddress: HistoryAddress?
  var hoverEvent: NSEvent?
  var hoverModifiers: NSEvent.ModifierFlags = []
  /// The link last found under the pointer, and the cell queried for it.
  var hoveredLink: MuxLink?
  var linkQuery: (row: Int, column: Int)?
  let composition = TerminalComposition()
  var markedText: String { composition.text }
  var accessibilityCache = AccessibilityTextCache()
  let keyboard = TerminalKeyboard()
  private var interpretingEvent: NSEvent? { keyboard.interpretingEvent }
  var isActivePane = false {
    didSet { if oldValue != isActivePane { needsDisplay = true } }
  }

  init(pane: PaneID, configuration: Configuration) throws {
    self.pane = pane
    config = configuration
    renderer = try TerminalDisplay.makeRenderer(configuration: configuration)
    super.init(frame: .zero, device: renderer.device)
    TerminalDisplay.prepare(self)
    delegate = self
    display.apply(configuration: configuration, scale: 2)
    loadShader()
    setAccessibilityRole(.textArea)
    setAccessibilityLabel("Terminal pane")
  }

  @available(*, unavailable)
  required init(coder: NSCoder) { fatalError() }

  override var acceptsFirstResponder: Bool { true }
  // Panes take keys by a click or the workspace's focus commands. Tab out
  // of a text field (search, a tab rename) must not land on one and make
  // it the active pane.
  override var canBecomeKeyView: Bool { false }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if window !== newWindow { cancelComposition() }
    super.viewWillMove(toWindow: newWindow)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    display.observeVisibility()
    applyScale()
    // The focused pane draws from its window's key state.
    let center = NotificationCenter.default
    for name in [
      NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
    ] {
      center.removeObserver(self, name: name, object: nil)
      if let window {
        center.addObserver(
          self,
          selector: #selector(windowKeyChanged),
          name: name,
          object: window
        )
      }
    }
    for name in [
      NSWindow.didChangeOcclusionStateNotification,
      NSWindow.didChangeScreenNotification,
    ] {
      center.removeObserver(self, name: name, object: nil)
      if let window {
        center.addObserver(
          self,
          selector: #selector(windowVisibilityChanged),
          name: name,
          object: window
        )
      }
    }
  }

  @objc
  private func windowKeyChanged() {
    if window?.firstResponder === self { needsDisplay = true }
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    applyScale()
  }

  private func applyScale() {
    let scale = window?.backingScaleFactor ?? 2
    let font = config.fontDescriptor(scale: scale)
    if renderer.font.descriptor != font { renderer.setFont(font) }
    display.apply(configuration: config, scale: scale)
    updateFrameDriving()
    controller?.geometryChanged()
  }

  func apply(_ configuration: Configuration) {
    let shaderChanged = configuration.customShader != config.customShader
    config = configuration
    if shaderChanged { loadShader() }
    applyScale()
    refreshHover()
    needsDisplay = true
  }

  /// `custom-shader`, as the direct view loads it.
  private func loadShader() {
    display.loadShader(config.customShader)
    updateFrameDriving()
  }

  /// A shader that animates needs frames without new output.
  private func updateFrameDriving() { display.updateFrameDriving() }

  override var needsDisplay: Bool {
    get { super.needsDisplay }
    set {
      if !newValue || display.shouldInvalidate() {
        super.needsDisplay = newValue
      }
    }
  }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    display.observeVisibility()
    windowVisibilityChanged()
  }

  override func viewDidHide() {
    super.viewDidHide()
    updateFrameDriving()
  }

  override func viewDidUnhide() {
    super.viewDidUnhide()
    windowVisibilityChanged()
  }

  @objc
  private func windowVisibilityChanged() {
    updateFrameDriving()
    needsDisplay = true
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    controller?.geometryChanged()
  }

  /// Cell dimensions for the current drawable area; never zero.
  var gridSize: (columns: Int, rows: Int) {
    let scale = window?.backingScaleFactor ?? renderer.font.descriptor.scale
    let size = renderer.gridSize(
      for: CGSize(width: bounds.width * scale, height: bounds.height * scale)
    )
    return (max(1, size.columns), max(1, size.rows))
  }

  // MARK: Presentation

  /// Imports off the main actor; returns nil for frames that fail
  /// validation (they never partially update a presentation).
  nonisolated static func importFrame(
    _ frame: PaneFrame,
    limits: MuxLimits
  ) -> MuxPresentation? {
    guard
      let snapshot = try? FrameImporter.snapshot(
        from: frame,
        sequence: 1,
        limits: limits
      )
    else { return nil }
    return MuxPresentation(frame: frame, snapshot: snapshot)
  }

  /// Stores the newest frame for this binding; drawing admits it later.
  func receive(_ presentation: MuxPresentation, server: ServerInstanceID) {
    guard presentation.frame.identity.pane == pane,
      presentation.frame.identity.server == server
    else { return }
    if let current = pending ?? presented,
      current.frame.identity.server == server,
      current.frame.identity.revision > presentation.frame.identity.revision
        || current.frame.identity.geometryGeneration
          > presentation.frame.identity.geometryGeneration
    {
      return
    }
    pending = presentation
    if frozen == nil { needsDisplay = true }

  }

  /// Rebind/reattach/server change: drop every cached presentation.
  func reset() {
    pending = nil
    presented = nil
    frozen = nil
    selection = nil
    pendingAnchor = nil
    selectionDragged = false
    pointer.reset()
    reportsLeftGesture = false
    lastReported = nil
    pendingOutput = nil
    if dropTypes != nil { dropTargetChanged(nil) }
    hoveredLink = nil
    linkQuery = nil
    renderer.options.underlinedSpan = nil
    cancelComposition()
    needsDisplay = true
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  func draw(in view: MTKView) {
    let candidate: MuxPresentation?
    var drawn: RenderSnapshot?
    if let frozen {
      candidate = frozen
      localSequence &+= 1
      let span = selection.map { $0.span(in: frozen.frame) }
      drawn = try? FrameImporter.snapshot(
        from: frozen.frame,
        selection: span,
        sequence: localSequence
      )
    } else {
      // Imported snapshots carry their own storage and full damage.
      candidate = pending ?? presented
      drawn = candidate?.snapshot
    }
    guard let candidate, let drawn else { return }
    let result = display.submit(
      drawn,
      focused: isActivePane && window?.isKeyWindow == true
        && window?.firstResponder === self,
      cursorBlink: config.cursorStyleBlink
    )
    switch result {
    case .submitted:
      if frozen == nil {
        let tracking = presented?.frame.modes.contains(.mouseTracking)
        presented = candidate
        if tracking != candidate.frame.modes.contains(.mouseTracking) {
          window?.invalidateCursorRects(for: self)
        }
        if pending?.frame.identity.revision == candidate.frame.identity.revision
        {
          pending = nil
        }
        selectPendingOutput(in: candidate)
        let target =
          features.contains(.dropTargets)
          ? candidate.frame.dropTarget?.types : nil
        if target != dropTypes { dropTargetChanged(target) }
        NSAccessibility.post(element: self, notification: .valueChanged)
      }
    case .busy, .noDrawable, .resourceUnavailable: break
    }
  }

  // MARK: Keyboard

  override func becomeFirstResponder() -> Bool {
    controller?.paneBecameFirstResponder(self)
    needsDisplay = true
    return true
  }

  override func resignFirstResponder() -> Bool {
    needsDisplay = true
    return true
  }

  override func keyDown(with event: NSEvent) {
    display.resetBlink()
    if keyboard.consumesKeyDown(
      hideMouse: config.mouseHideWhileTyping,
      composing: hasMarkedText(),
      binding: binding(for: event),
      perform: { perform($0.action) }
    ) {
      return
    }
    if event.modifierFlags.contains(.command) {
      super.keyDown(with: event)
      return
    }
    keyboard.interpret(event, in: self, composing: hasMarkedText()) {
      guard
        let key = Self.semanticKey(
          for: event,
          keypadKeys: features.contains(.keypadKeys)
        )
      else { return false }
      clearSelection()
      controller?.send(.key(key.0, key.1), to: pane)
      return true
    }
  }

  /// Special keys and control combinations; nil for text, which goes
  /// through the input method and arrives once as committed text.
  /// Keypad keys need `keypadKeys`; otherwise typing ones go through the
  /// input method and the rest map to the keys they mirror.
  static func semanticKey(
    for event: NSEvent,
    keypadKeys: Bool = false
  ) -> (MuxKey, MuxKeyModifiers)? {
    var mods: MuxKeyModifiers = []
    let flags = event.modifierFlags
    if flags.contains(.shift) { mods.insert(.shift) }
    if flags.contains(.option) { mods.insert(.alt) }
    if flags.contains(.control) { mods.insert(.control) }
    if case let .keypad(k) = TerminalView.specialKeys[event.keyCode] {
      if keypadKeys, let keypad = MuxKeypadKey(rawValue: k.rawValue) {
        return (.keypad(keypad), mods)
      }
      if k.text != nil { return nil }
    }
    if let key = TerminalView.specialKeys[event.keyCode],
      let mapped = muxKey(key)
    {
      return (mapped, mods)
    }
    if flags.contains(.control),
      let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first
    {
      mods.remove(.shift)
      return (.character(scalar.value), mods)
    }
    return nil
  }

  static func muxKey(_ key: Key) -> MuxKey? {
    switch key {
    case let .character(s): .character(s.value)
    case .enter: .enter
    case .tab: .tab
    case .backspace: .backspace
    case .escape: .escape
    case .up: .up
    case .down: .down
    case .left: .left
    case .right: .right
    case .home: .home
    case .end: .end
    case .pageUp: .pageUp
    case .pageDown: .pageDown
    case .insert: .insert
    case .delete: .delete
    case let .function(n): .function(n)
    case let .keypad(k): k.mainKey.flatMap(muxKey)
    }
  }

  /// The selected text; a command-output selection copies all of it.
  var selectedText: String? {
    guard let selection, let frame = frozen?.frame else { return nil }
    if let output = outputSelection, output.selection == selection {
      return output.text
    }
    return selection.text(in: frame)
  }

  @objc
  func copy(_ sender: Any?) {
    guard let text = selectedText, !text.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  @objc
  func paste(_ sender: Any?) {
    // A program asking for kitty paste events reads what it wants itself.
    if features.contains(.kittyClipboard), modes.contains(.kittyPasteEvents) {
      clearSelection()
      controller?
        .send(
          .clipboardPaste(
            types: Array(TerminalView.mimeTypes(on: .general).prefix(16))
          ),
          to: pane
        )
      return
    }
    guard let text = NSPasteboard.general.string(forType: .string),
      !text.isEmpty
    else { return }
    clearSelection()
    controller?.paste(text, to: pane)
  }

  override func selectAll(_ sender: Any?) {
    guard let base = presented else { return }
    frozen = base
    selection = FrozenSelection(
      anchor: (0, 0),
      head: (base.frame.grid.rows - 1, base.frame.grid.columns - 1),
      unit: .cell
    )
    needsDisplay = true
  }

  @objc
  func performFindPanelAction(_ sender: Any?) {
    let tag =
      (sender as? NSMenuItem)?.tag
      ?? Int(NSFindPanelAction.showFindPanel.rawValue)
    controller?
      .performFind(
        UInt(exactly: tag).flatMap { NSFindPanelAction(rawValue: $0) }
      )
  }

  @objc
  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    let features = controller?.features ?? []
    let writable = controller?.holdsLease == true
    switch item.action {
    case #selector(copy(_:)): return selection != nil
    case #selector(jumpToPreviousPrompt(_:)), #selector(jumpToNextPrompt(_:)):
      return features.contains(.historyJumps)
        && presented?.frame.modes.contains(.alternateScreen) == false
    case #selector(clearScreen(_:)), #selector(resetTerminal(_:)):
      return writable && features.contains(.terminalControl)
    case #selector(selectCommandOutput(_:)):
      return writable && features.contains(.shellIntegration)
    default: return true
    }
  }

  // MARK: Composition

  /// Discards (never commits) an unfinished composition so it cannot
  /// reach another shell.
  func cancelComposition() {
    composition.discard(renderer: renderer, view: self)
  }

  fileprivate func setPreedit(_ text: String, selection: NSRange) {
    composition.set(text, selection: selection, renderer: renderer, view: self)
  }
}

extension MuxPaneView: @MainActor NSTextInputClient {
  func insertText(_ string: Any, replacementRange: NSRange) {
    let text =
      (string as? NSAttributedString)?.string ?? string as? String ?? ""
    setPreedit("", selection: NSRange(location: NSNotFound, length: 0))
    guard !text.isEmpty else { return }
    clearSelection()
    controller?.send(.text(text), to: pane)
  }

  override func doCommand(by selector: Selector) {
    // Keys the input method did not turn into text: send as typed.
    guard let event = interpretingEvent else { return }
    if let key = Self.semanticKey(
      for: event,
      keypadKeys: features.contains(.keypadKeys)
    ) {
      controller?.send(.key(key.0, key.1), to: pane)
    } else if let text = event.characters, !text.isEmpty {
      controller?.send(.text(text), to: pane)
    }
  }

  func setMarkedText(
    _ string: Any,
    selectedRange: NSRange,
    replacementRange: NSRange
  ) {
    setPreedit(
      (string as? NSAttributedString)?.string ?? string as? String ?? "",
      selection: selectedRange
    )
  }

  func unmarkText() {
    guard !markedText.isEmpty else { return }
    insertText(
      markedText,
      replacementRange: NSRange(location: NSNotFound, length: 0)
    )
  }

  func hasMarkedText() -> Bool { !composition.text.isEmpty }
  func markedRange() -> NSRange { composition.markedRange }
  func selectedRange() -> NSRange { composition.selection }

  func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

  func attributedSubstring(
    forProposedRange range: NSRange,
    actualRange: NSRangePointer?
  ) -> NSAttributedString? { nil }

  func characterIndex(for point: NSPoint) -> Int { NSNotFound }

  /// The cursor cell of the presented frame, for the candidate window.
  func firstRect(
    forCharacterRange range: NSRange,
    actualRange: NSRangePointer?
  ) -> NSRect {
    let cursor = (frozen ?? presented)?.snapshot.cursor
    return composition.firstRect(
      for: range,
      actualRange: actualRange,
      cursor: (cursor?.x ?? 0, cursor?.y ?? 0),
      renderer: renderer,
      view: self
    )
  }
}
