import AppKit
import SwiftMuxProtocol
import SwifttyCore
import SwifttyMac

/// Selection, mouse reporting, links, click-to-move and scrolling, as the
/// direct terminal view offers them. Reports and shell-integration
/// queries go to the service, which owns the emulator; a service without
/// the feature leaves the local behaviour (selection, history scrolling).
extension MuxPaneView {
  var features: ServiceFeatures { controller?.features ?? [] }

  /// Modes of the frame on screen.
  var modes: SupportedViewModes { presented?.frame.modes ?? [] }

  /// The program asked for mouse reports and the service can encode them.
  var reportsMouse: Bool {
    features.contains(.mouseReporting) && modes.contains(.mouseTracking)
  }

  /// Viewport cell under the pointer; may lie outside the grid.
  func cell(for event: NSEvent) -> (row: Int, column: Int) {
    cell(at: convert(event.locationInWindow, from: nil))
  }

  func cell(at p: NSPoint) -> (row: Int, column: Int) {
    let cell = TerminalPointer.cell(at: p, in: self, renderer: renderer)
    return (cell.row, cell.column)
  }

  /// History address of a viewport row of `presentation`.
  func address(row: Int, in presentation: MuxPresentation?) -> HistoryAddress? {
    guard let frame = presentation?.frame, frame.grid.rows > 0 else {
      return nil
    }
    let row = min(max(row, 0), frame.grid.rows - 1)
    return frame.history.address(
      viewportRow: row,
      alternateScreen: frame.grid.alternateScreen
    )
  }

  static func modifiers(_ flags: NSEvent.ModifierFlags) -> MuxKeyModifiers {
    var mods: MuxKeyModifiers = []
    if flags.contains(.shift) { mods.insert(.shift) }
    if flags.contains(.option) { mods.insert(.alt) }
    if flags.contains(.control) { mods.insert(.control) }
    return mods
  }

  // MARK: Mouse reporting

  func sendMouse(
    _ action: MuxMouse.Action,
    _ button: MuxMouse.Button,
    _ event: NSEvent
  ) {
    guard reportsMouse, let frame = presented?.frame else { return }
    let c = cell(for: event)
    let row = min(max(c.row, 0), frame.grid.rows - 1)
    let column = min(max(c.column, 0), frame.grid.columns - 1)
    if action == .motion, let last = lastReported, last.row == row,
      last.column == column, last.button == button
    {
      return
    }
    lastReported = (row, column, button)
    controller?
      .send(
        .mouse(
          MuxMouse(
            action,
            button,
            column: column,
            row: row,
            modifiers: Self.modifiers(event.modifierFlags)
          )
        ),
        to: pane
      )
  }

  /// Motion with a button held, when the program asked for it.
  private var reportsDrag: Bool {
    modes.contains(.mouseButtonMotion) || modes.contains(.mouseAnyMotion)
  }

  // MARK: Buttons

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    controller?.focus(pane)
    pendingOutput = nil
    pointer.beginLeftGesture(
      event,
      reporting: reportsMouse,
      openLink: {
        openLink(at: event);
        return true
      },
      report: {
        clearSelection();
        sendMouse(.press, .left, event)
      },
      select: { beginSelection(event, unit: $0) }
    )
  }

  private func beginSelection(_ event: NSEvent, unit: FrozenSelection.Unit) {
    // Bind the gesture to the presentation actually shown.
    guard let base = frozen ?? presented else { return }
    let at = cell(for: event)
    selectionDragged = unit != .cell
    if unit == .cell {
      selection = nil
      frozen = nil
      needsDisplay = true
      pendingAnchor = (at, base)
      return
    }
    frozen = base
    selection = FrozenSelection(anchor: at, head: at, unit: unit)
    needsDisplay = true
  }

  override func mouseDragged(with event: NSEvent) {
    pointer.dragLeftGesture(
      select: { extendSelection(event) },
      report: { if reportsDrag { sendMouse(.motion, .left, event) } }
    )
  }

  private func extendSelection(_ event: NSEvent) {
    let at = cell(for: event)
    if selection == nil, let (anchor, base) = pendingAnchor {
      frozen = base
      selection = FrozenSelection(anchor: anchor, head: at, unit: .cell)
    }
    selection?.head = at
    selectionDragged = true
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    pointer.endLeftGesture(
      select: { endSelection() },
      report: { sendMouse(.release, .left, event) }
    )
  }

  private func endSelection() {
    let click = pendingAnchor
    pendingAnchor = nil
    if !selectionDragged {
      clearSelection()
      if let click { moveShellCursor(to: click.0, in: click.1) }
    } else if config.copyOnSelect, selection != nil {
      copy(nil)
    }
  }

  /// Click-to-move: while the shell edits a command line (OSC 133), the
  /// service moves its cursor to the clicked cell with arrow keys.
  private func moveShellCursor(
    to cell: (row: Int, column: Int),
    in presentation: MuxPresentation
  ) {
    guard config.cursorClickToMove, !reportsMouse,
      features.contains(.shellIntegration), cell.row >= 0,
      cell.row < presentation.frame.grid.rows, cell.column >= 0,
      let address = address(row: cell.row, in: presentation)
    else { return }
    controller?.send(.moveCursor(address, column: cell.column), to: pane)
  }

  /// Ends selection and resumes current frames.
  func clearSelection() {
    guard selection != nil || frozen != nil || pendingAnchor != nil else {
      return
    }
    selection = nil
    frozen = nil
    pendingAnchor = nil
    selectionDragged = false
    needsDisplay = true
  }

  override func rightMouseDown(with event: NSEvent) {
    guard reportsMouse else { return super.rightMouseDown(with: event) }
    sendMouse(.press, .right, event)
  }

  override func rightMouseUp(with event: NSEvent) {
    guard reportsMouse else { return super.rightMouseUp(with: event) }
    sendMouse(.release, .right, event)
  }

  override func rightMouseDragged(with event: NSEvent) {
    if reportsDrag { sendMouse(.motion, .right, event) }
  }

  override func otherMouseDown(with event: NSEvent) {
    guard event.buttonNumber == 2 else { return }
    sendMouse(.press, .middle, event)
  }

  override func otherMouseUp(with event: NSEvent) {
    guard event.buttonNumber == 2 else { return }
    sendMouse(.release, .middle, event)
  }

  override func otherMouseDragged(with event: NSEvent) {
    guard event.buttonNumber == 2, reportsDrag else { return }
    sendMouse(.motion, .middle, event)
  }

  override func mouseMoved(with event: NSEvent) {
    updateHover(event)
    guard bounds.contains(convert(event.locationInWindow, from: nil)),
      modes.contains(.mouseAnyMotion)
    else { return }
    sendMouse(.motion, .none, event)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas { removeTrackingArea(area) }
    addTrackingArea(
      NSTrackingArea(
        rect: bounds,
        options: [
          .mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow,
          .inVisibleRect,
        ],
        owner: self
      )
    )
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: reportsMouse ? .arrow : .iBeam)
  }

  // MARK: Scrolling

  override func scrollWheel(with event: NSEvent) {
    let mode: TerminalPointer.ScrollMode
    if reportsMouse {
      mode = .mouse
    } else if features.contains(.mouseReporting),
      modes.contains(.alternateScreen), modes.contains(.alternateScroll)
    {
      mode = .arrows
    } else {
      mode = .history
    }
    pointer.scroll(event, in: self, renderer: renderer, mode: mode) { input in
      switch input {
      case let .wheel(button):
        let mapped: MuxMouse.Button
        switch button {
        case .wheelUp: mapped = .wheelUp
        case .wheelDown: mapped = .wheelDown
        case .wheelLeft: mapped = .wheelLeft
        case .wheelRight: mapped = .wheelRight
        default: return
        }
        sendMouse(.press, mapped, event)
      case let .key(key):
        if let key = Self.muxKey(key) {
          controller?.send(.key(key, []), to: pane)
        }
      case let .history(lines): controller?.scroll(pane, lines: lines)
      }
    }
  }

  // MARK: Links

  /// Opens web, mail, FTP and SSH links only: the program chooses the
  /// target, so a `file:` link could launch a local program.
  static func open(_ string: String) {
    guard let url = LinkPolicy.openableURL(string) else {
      NSSound.beep()
      return
    }
    NSWorkspace.shared.open(url)
  }

  private func openLink(at event: NSEvent) {
    let c = cell(for: event)
    if let link = hoveredLink, covers(link, c) { return Self.open(link.url) }
    queryLink(at: c) { link in if let link { Self.open(link.url) } }
  }

  private func queryLink(
    at c: (row: Int, column: Int),
    found: @escaping @MainActor @Sendable (MuxLink?) -> Void
  ) {
    guard let presentation = presented, c.row >= 0,
      c.row < presentation.frame.grid.rows, c.column >= 0,
      c.column < presentation.frame.grid.columns,
      let address = address(row: c.row, in: presentation)
    else { return found(nil) }
    controller?.link(in: pane, at: address, column: c.column, found: found)
  }

  /// Whether `link` covers a viewport cell of the frame on screen.
  func covers(_ link: MuxLink, _ c: (row: Int, column: Int)) -> Bool {
    guard let span = span(of: link) else { return false }
    let afterStart =
      c.row > span.startRow
      || (c.row == span.startRow && c.column >= span.startColumn)
    let beforeEnd =
      c.row < span.endRow
      || (c.row == span.endRow && c.column <= span.endColumn)
    return afterStart && beforeEnd
  }

  /// A link's cells in viewport coordinates of the frame on screen.
  private func span(of link: MuxLink) -> HighlightSpan? {
    guard let frame = presented?.frame,
      link.start.generation == frame.history.generation,
      link.start.alternateScreen == frame.grid.alternateScreen
    else { return nil }
    let top = frame.history.viewportTop
    return HighlightSpan(
      startRow: link.start.row - top,
      startColumn: link.startColumn,
      endRow: link.end.row - top,
      endColumn: link.endColumn
    )
  }

  func updateHover(_ event: NSEvent) {
    hoverEvent = event
    hoverModifiers = event.modifierFlags
    refreshHover()
  }

  override func mouseEntered(with event: NSEvent) { updateHover(event) }

  override func mouseExited(with event: NSEvent) {
    hoverEvent = nil
    hoverModifiers = []
    refreshHover()
  }

  override func flagsChanged(with event: NSEvent) {
    super.flagsChanged(with: event)
    // Keyboard events do not carry the last pointer location.
    hoverModifiers = event.modifierFlags
    refreshHover()
  }

  /// With Command held, the link under the pointer is underlined and the
  /// pointer becomes a hand.
  func refreshHover() {
    guard let event = hoverEvent, hoverModifiers.contains(.command),
      features.contains(.shellIntegration),
      bounds.contains(convert(event.locationInWindow, from: nil))
    else { return showLink(nil) }
    let c = cell(for: event)
    if let link = hoveredLink, covers(link, c) { return showLink(link) }
    guard linkQuery.map({ $0 != c }) ?? true else { return }
    linkQuery = c
    queryLink(at: c) { [weak self] link in
      guard let self, linkQuery.map({ $0 == c }) == true else { return }
      linkQuery = nil
      hoveredLink = link.flatMap {
        LinkPolicy.openableURL($0.url) != nil ? $0 : nil
      }
      // The pointer may have moved on (or Command been released) while
      // the service answered.
      if let hoverEvent, hoverModifiers.contains(.command),
        let shown = hoveredLink, covers(shown, cell(for: hoverEvent))
      {
        showLink(shown)
      } else {
        showLink(nil)
      }
    }
  }

  private func showLink(_ link: MuxLink?) {
    if link == nil { linkQuery = nil }
    let span = link.flatMap(span(of:))
    if renderer.options.underlinedSpan != span {
      renderer.options.underlinedSpan = span
      needsDisplay = true
    }
    // Only while the pointer is over this pane: another view owns it
    // otherwise.
    guard window?.isKeyWindow == true, let hoverEvent,
      bounds.contains(convert(hoverEvent.locationInWindow, from: nil))
    else { return }
    if span != nil {
      NSCursor.pointingHand.set()
    } else {
      (reportsMouse ? NSCursor.arrow : NSCursor.iBeam).set()
    }
  }

  // MARK: Context menu and command output

  override func menu(for event: NSEvent) -> NSMenu? {
    guard !reportsMouse else { return nil }
    let c = cell(for: event)
    menuAddress = address(row: c.row, in: frozen ?? presented)
    let menu = NSMenu()
    if selection != nil {
      menu.addItem(
        withTitle: "Copy",
        action: #selector(copy(_:)),
        keyEquivalent: ""
      )
    }
    menu.addItem(
      withTitle: "Paste",
      action: #selector(paste(_:)),
      keyEquivalent: ""
    )
    if features.contains(.shellIntegration) {
      let item = NSMenuItem(
        title: "Select Command Output",
        action: #selector(selectClickedCommandOutput(_:)),
        keyEquivalent: ""
      )
      item.target = self
      menu.addItem(item)
    }
    if let link = hoveredLink, covers(link, c) {
      menu.addItem(.separator())
      let item = NSMenuItem(
        title: "Open Link",
        action: #selector(openMenuLink(_:)),
        keyEquivalent: ""
      )
      item.representedObject = link.url
      item.target = self
      menu.addItem(item)
    }
    return menu
  }

  @objc
  private func openMenuLink(_ sender: NSMenuItem) {
    (sender.representedObject as? String).map(Self.open)
  }

  /// Selects the output of the most recent command with output, from
  /// shell-integration marks.
  @objc
  func selectCommandOutput(_ sender: Any?) { selectCommandOutput(at: nil) }

  /// The context menu's: the output of the command at its cell.
  @objc
  private func selectClickedCommandOutput(_ sender: Any?) {
    selectCommandOutput(at: menuAddress)
  }

  private func selectCommandOutput(at address: HistoryAddress?) {
    menuAddress = nil
    controller?
      .commandOutput(in: pane, at: address) { [weak self] output in
        guard let self else { return }
        guard let output else { return NSSound.beep() }
        // A new command-output request replaces any old frozen selection;
        // otherwise the requested history frame could never be admitted.
        clearSelection()
        pendingOutput = output
        if let presented { selectPendingOutput(in: presented) }
      }
  }

  /// Selects pending command output once `presentation` shows part of it.
  func selectPendingOutput(in presentation: MuxPresentation) {
    guard let output = pendingOutput else { return }
    let frame = presentation.frame
    guard output.start.generation == frame.history.generation,
      output.start.alternateScreen == frame.grid.alternateScreen
    else { return }
    let top = frame.history.viewportTop
    let first = max(0, output.start.row - top)
    let last = min(frame.grid.rows - 1, output.end.row - top)
    guard first <= last else { return }
    pendingOutput = nil
    pendingAnchor = nil
    frozen = presentation
    let selected = FrozenSelection(
      anchor: (first, 0),
      head: (last, frame.grid.columns - 1),
      unit: .cell
    )
    selection = selected
    outputSelection = (selected, output.text)
    selectionDragged = true
    needsDisplay = true
  }

  // MARK: Terminal commands

  @objc
  func jumpToPreviousPrompt(_ sender: Any?) { perform(.jumpToPrompt(-1)) }

  @objc
  func jumpToNextPrompt(_ sender: Any?) { perform(.jumpToPrompt(1)) }

  @objc
  func clearScreen(_ sender: Any?) { perform(.clearScreen) }

  @objc
  func resetTerminal(_ sender: Any?) { perform(.reset) }
}
