import AppKit
import SwifttyCore

/// Mouse reporting, selection, links, the pointer and scrolling.
extension TerminalView {
  func cell(for event: NSEvent) -> (column: Int, row: Int) {
    let c = unclampedCell(for: event)
    return (max(0, c.column), max(0, c.row))
  }

  /// Grid cell under the pointer; may lie outside the grid.
  func unclampedCell(for event: NSEvent) -> (column: Int, row: Int) {
    unclampedCell(at: convert(event.locationInWindow, from: nil))
  }

  func unclampedCell(at p: NSPoint) -> (column: Int, row: Int) {
    let scale = window?.backingScaleFactor ?? 2
    let x = (p.x * scale - renderer.options.paddingX) / renderer.cellSize.width
    let y =
      ((bounds.height - p.y) * scale - renderer.options.paddingY)
      / renderer.cellSize.height
    return (TerminalGeometry.cellIndex(x), TerminalGeometry.cellIndex(y))
  }

  /// Absolute point under the pointer, clamped to the grid.
  func point(for event: NSEvent) -> TerminalPoint {
    let c = unclampedCell(for: event)
    return session.withState { state in
      state.viewportPoint(row: c.row, column: c.column)
    }
  }

  var tracking: Bool { !lastModes.isDisjoint(with: Modes.mouseTracking) }

  func sendMouse(
    _ action: MouseEvent.Action,
    _ button: MouseEvent.Button,
    _ event: NSEvent
  ) {
    guard tracking else { return }
    let c = cell(for: event)
    session.send(
      .mouse(
        MouseEvent(
          action,
          button,
          column: c.column,
          row: c.row,
          modifiers: Self.modifiers(event.modifierFlags)
        )
      )
    )
  }

  /// Shift selects even while the application tracks the mouse.
  private func selects(_ event: NSEvent) -> Bool {
    !tracking || event.modifierFlags.contains(.shift)
  }

  override func mouseDown(with event: NSEvent) {
    reportsLeftMouseGesture = false
    selectionOrigin = nil
    if event.modifierFlags.contains(.command), let link = link(for: event) {
      open(link.url)
      return
    }
    guard selects(event) else {
      reportsLeftMouseGesture = true
      sendMouse(.press, .left, event)
      return
    }
    beginSelection(event)
  }

  override func mouseUp(with event: NSEvent) {
    defer { reportsLeftMouseGesture = false }
    guard selectionOrigin == nil else {
      if selectionDragged { extendSelection(event, scrollEdges: false) }
      endSelection(event)
      return
    }
    if reportsLeftMouseGesture { sendMouse(.release, .left, event) }
  }

  override func mouseDragged(with event: NSEvent) {
    guard selectionOrigin == nil else {
      extendSelection(event);
      return
    }
    if reportsLeftMouseGesture { sendMouse(.motion, .left, event) }
  }

  // MARK: Selection

  private func beginSelection(_ event: NSEvent) {
    let c = unclampedCell(for: event)
    let rectangle = event.modifierFlags.contains(.option)
    selectionUnit =
      switch event.clickCount {
      case 2: .word
      case 3...: .line
      default: .cell
      }
    selectionDragged = false
    let unit = selectionUnit
    let origin = session.mutate { state in
      let p = state.viewportPoint(row: c.row, column: c.column)
      let span =
        switch unit {
        case .cell: (start: p, end: p)
        case .word: state.wordRange(at: p)
        case .line: state.lineRange(at: p)
        }
      state.setSelection(
        unit == .cell
          ? nil
          : Selection(anchor: span.start, head: span.end, rectangle: rectangle)
      )
      return (span: span, generation: state.addressingGeneration)
    }
    selectionOrigin = (origin.span.start, origin.span.end, origin.generation)
    lastClick = (origin.span.start, origin.generation)
    hasSelection = selectionUnit != .cell
  }

  private func extendSelection(_ event: NSEvent, scrollEdges: Bool = true) {
    guard let origin = selectionOrigin else { return }
    let c = unclampedCell(for: event)
    let rectangle = event.modifierFlags.contains(.option)
    let unit = selectionUnit
    let requiresSelection = hasSelection
    selectionDragged = true
    let extended = session.mutate {
      state -> (extended: Bool, hasSelection: Bool) in
      // Output may invalidate an active drag before the next frame.
      guard state.addressingGeneration == origin.generation,
        state.contains(absoluteRow: origin.start.row),
        state.contains(absoluteRow: origin.end.row),
        !requiresSelection || state.selection != nil
      else { return (false, state.selection != nil) }
      // Dragging past the top or bottom edge scrolls the viewport.
      if scrollEdges {
        state.scrollViewport(
          by: SelectionMath.edgeScroll(row: c.row, rows: state.rows)
        )
      }
      let p = state.viewportPoint(row: c.row, column: c.column)
      let span =
        switch unit {
        case .cell: (start: p, end: p)
        case .word: state.wordRange(at: p)
        case .line: state.lineRange(at: p)
        }
      state.setSelection(
        SelectionMath.extend(
          origin: (origin.start, origin.end),
          to: span,
          rectangle: rectangle
        )
      )
      return (true, true)
    }
    hasSelection = extended.hasSelection
    if !extended.extended { selectionOrigin = nil }
  }

  private func endSelection(_ event: NSEvent) {
    if selectionUnit == .cell, !selectionDragged {
      clearSelection()  // a plain click
      if config.cursorClickToMove, !tracking, let origin = selectionOrigin {
        moveShellCursor(to: origin.start, generation: origin.generation)
      }
    } else if config.copyOnSelect, hasSelection {
      copy(nil)
    }
    selectionOrigin = nil
  }

  func clearSelection() {
    guard hasSelection else { return }
    hasSelection = false
    session.mutateAsync { $0.setSelection(nil) }
  }

  /// Click-to-move: while the shell is editing a command line (OSC 133),
  /// a click moves its cursor there with arrow keys.
  private func moveShellCursor(to p: TerminalPoint, generation: UInt64) {
    let moves = session.withState { state in
      state.addressingGeneration == generation
        ? state.promptCursorMoves(to: p) : nil
    }
    guard let moves else { return }
    for key in ClickToMove.keys(moves) { session.send(.key(key)) }
  }

  // MARK: Links and the pointer

  func link(for event: NSEvent) -> TerminalLink? {
    let p = point(for: event)
    let detect = config.linkURL
    return session.withState { $0.link(at: p, detectURLs: detect) }
  }

  /// Opens web, mail, FTP and SSH links only: the application chooses
  /// the target, so a `file:` link could launch a local program.
  func open(_ string: String) {
    guard let url = LinkPolicy.openableURL(string) else {
      NSSound.beep()
      return
    }
    NSWorkspace.shared.open(url)
  }

  /// With Command held, the link under the pointer is underlined and the
  /// pointer becomes a hand.
  func updateHover(_ event: NSEvent) {
    hoverEvent = event
    hoverModifiers = event.modifierFlags
    refreshHover()
  }

  func clearHover() {
    hoverEvent = nil
    hoverModifiers = []
    refreshHover()
  }

  func containsTerminalPoint(_ location: NSPoint) -> Bool {
    bounds.contains(location) && !(searchBar?.frame.contains(location) ?? false)
  }

  func refreshHover() {
    let pointerOverTerminal =
      hoverEvent.map {
        containsTerminalPoint(convert($0.locationInWindow, from: nil))
      } ?? true
    let link = hoverEvent.flatMap { event -> TerminalLink? in
      guard hoverModifiers.contains(.command), pointerOverTerminal else {
        return nil
      }
      return self.link(for: event)
        .flatMap { LinkPolicy.openableURL($0.url) != nil ? $0 : nil }
    }
    hoverCell = hoverEvent.map { cell(for: $0) }
    let span = link.flatMap { link in
      link.id == 0
        ? session.withState {
          LinkPolicy.span(
            of: link.range,
            firstVisibleRow: $0.absoluteRow(viewportRow: 0)
          )
        } : nil
    }
    guard
      link != hoveredLink || renderer.options.hoveredLink != (link?.id ?? 0)
        || renderer.options.underlinedSpan != span
    else { return }
    hoveredLink = link
    renderer.options.hoveredLink = link?.id ?? 0
    renderer.options.underlinedSpan = span
    if window?.isKeyWindow == true, pointerOverTerminal {
      if link != nil {
        NSCursor.pointingHand.set()
      } else {
        applicationCursor.set()
      }
    }
    needsDisplay = true
  }

  override func mouseEntered(with event: NSEvent) { updateHover(event) }

  override func mouseExited(with event: NSEvent) { clearHover() }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: applicationCursor)
  }

  override func flagsChanged(with event: NSEvent) {
    super.flagsChanged(with: event)
    // Keyboard events do not carry the last pointer location.
    hoverModifiers = event.modifierFlags
    refreshHover()
  }

  override func rightMouseDown(with event: NSEvent) {
    guard tracking else { return super.rightMouseDown(with: event) }
    sendMouse(.press, .right, event)
  }

  override func rightMouseUp(with event: NSEvent) {
    sendMouse(.release, .right, event)
  }

  override func rightMouseDragged(with event: NSEvent) {
    sendMouse(.motion, .right, event)
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    guard !tracking else { return nil }
    let c = unclampedCell(for: event)
    lastClick = session.withState { state in
      (
        state.viewportPoint(row: c.row, column: c.column),
        state.addressingGeneration
      )
    }
    let menu = NSMenu()
    menu.addItem(
      withTitle: "Copy",
      action: #selector(copy(_:)),
      keyEquivalent: ""
    )
    menu.addItem(
      withTitle: "Paste",
      action: #selector(paste(_:)),
      keyEquivalent: ""
    )
    menu.addItem(
      withTitle: "Select Command Output",
      action: #selector(selectCommandOutput(_:)),
      keyEquivalent: ""
    )
    if let link = link(for: event) {
      menu.addItem(.separator())
      let item = NSMenuItem(
        title: "Open Link",
        action: #selector(openMenuLink(_:)),
        keyEquivalent: ""
      )
      item.representedObject = link.url
      menu.addItem(item)
    }
    return menu
  }

  @objc
  private func openMenuLink(_ sender: NSMenuItem) {
    guard let url = sender.representedObject as? String else { return }
    open(url)
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
    guard event.buttonNumber == 2 else { return }
    sendMouse(.motion, .middle, event)
  }

  override func mouseMoved(with event: NSEvent) {
    updateHover(event)
    guard containsTerminalPoint(convert(event.locationInWindow, from: nil))
    else { return }
    if lastModes.contains(.mouseAny) { sendMouse(.motion, .none, event) }
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
        owner: self,
      )
    )
  }

  override func scrollWheel(with event: NSEvent) {
    let lineHeight =
      renderer.cellSize.height / (window?.backingScaleFactor ?? 2)
    let lines = scrollAccumulator.add(
      event.hasPreciseScrollingDeltas
        ? event.scrollingDeltaY / lineHeight : event.scrollingDeltaY
    )
    if tracking {
      let cellWidth =
        renderer.cellSize.width / (window?.backingScaleFactor ?? 2)
      let columns = horizontalScrollAccumulator.add(
        event.hasPreciseScrollingDeltas
          ? event.scrollingDeltaX / cellWidth : event.scrollingDeltaX
      )
      for _ in 0 ..< abs(lines) {
        sendMouse(.press, lines > 0 ? .wheelUp : .wheelDown, event)
      }
      for _ in 0 ..< abs(columns) {
        sendMouse(.press, columns > 0 ? .wheelLeft : .wheelRight, event)
      }
    } else {
      horizontalScrollAccumulator.reset()
      guard lines != 0 else { return }
      if lastModes.contains(.alternateScreen),
        lastModes.contains(.alternateScroll)
      {
        for _ in 0 ..< abs(lines) {
          session.send(.key(KeyEvent(lines > 0 ? .up : .down)))
        }
      } else {
        session.scrollViewport(by: lines)
      }
    }
  }
}
