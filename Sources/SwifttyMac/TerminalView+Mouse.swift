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

  /// Backing-pixel position inside the padding, for SGR pixel reports.
  func terminalPixel(for event: NSEvent) -> (x: Int, y: Int) {
    let p = convert(event.locationInWindow, from: nil)
    let scale = window?.backingScaleFactor ?? 2
    return (
      Int((p.x * scale - renderer.options.paddingX).rounded()),
      Int(((bounds.height - p.y) * scale - renderer.options.paddingY).rounded())
    )
  }

  func unclampedCell(at p: NSPoint) -> (column: Int, row: Int) {
    TerminalPointer.cell(at: p, in: self, renderer: renderer)
  }

  var tracking: Bool { !lastModes.isDisjoint(with: Modes.mouseTracking) }

  func sendMouse(
    _ action: MouseEvent.Action,
    _ button: MouseEvent.Button,
    _ event: NSEvent
  ) {
    guard tracking else { return }
    let c = cell(for: event)
    let pixel = terminalPixel(for: event)
    submitInput(
      .mouse(
        MouseEvent(
          action,
          button,
          column: c.column,
          row: c.row,
          modifiers: Self.modifiers(event.modifierFlags),
          pixelX: pixel.x,
          pixelY: pixel.y
        )
      )
    )
  }

  public override func mouseDown(with event: NSEvent) {
    selectionOrigin = nil
    pointer.beginLeftGesture(
      event,
      reporting: tracking,
      openLink: {
        guard let link = link(for: event) else { return false }
        open(link.url)
        return true
      },
      report: { sendMouse(.press, .left, event) },
      select: { beginSelection(event, unit: $0) }
    )
  }

  public override func mouseUp(with event: NSEvent) {
    pointer.endLeftGesture(
      select: {
        guard selectionOrigin != nil else { return }
        if selectionDragged { extendSelection(event, scrollEdges: false) }
        endSelection(event)
      },
      report: { sendMouse(.release, .left, event) }
    )
  }

  public override func mouseDragged(with event: NSEvent) {
    pointer.dragLeftGesture(
      select: { extendSelection(event) },
      report: { sendMouse(.motion, .left, event) }
    )
  }

  // MARK: Selection

  private func beginSelection(_ event: NSEvent, unit: SelectionUnit) {
    let c = unclampedCell(for: event)
    let rectangle = event.modifierFlags.contains(.option)
    selectionUnit = unit
    selectionDragged = false
    let unit = selectionUnit
    guard let snapshot = lastSnapshot,
      let origin = session.selectPresentation(
        matching: snapshot,
        { state in
          let p = state.viewportPoint(row: c.row, column: c.column)
          let span =
            switch unit {
            case .cell: (start: p, end: p)
            case .word: state.wordRange(at: p)
            case .line: state.lineRange(at: p)
            }
          let selection: Selection? =
            unit == .cell
            ? nil
            : Selection(
              anchor: span.start,
              head: span.end,
              rectangle: rectangle
            )
          return (
            selection, (span: span, generation: state.addressingGeneration)
          )
        }
      )
    else { return }
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
    guard let snapshot = lastSnapshot else { return }
    let extended = session.selectPresentation(matching: snapshot) {
      state -> (Selection?, (extended: Bool, hasSelection: Bool)) in
      // Output may invalidate an active drag before the next frame.
      guard state.addressingGeneration == origin.generation,
        state.contains(absoluteRow: origin.start.row),
        state.contains(absoluteRow: origin.end.row),
        !requiresSelection || state.selection != nil
      else { return (state.selection, (false, state.selection != nil)) }
      let p = state.viewportPoint(row: c.row, column: c.column)
      let span =
        switch unit {
        case .cell: (start: p, end: p)
        case .word: state.wordRange(at: p)
        case .line: state.lineRange(at: p)
        }
      return (
        SelectionMath.extend(
          origin: (origin.start, origin.end),
          to: span,
          rectangle: rectangle
        ), (true, true)
      )
    }
    guard let extended else {
      // Pending output cannot become a drag endpoint. Still retire an origin
      // that output invalidated, even before the next frame can be submitted.
      let current = session.withState { state in
        (
          valid: state.addressingGeneration == origin.generation
            && state.contains(absoluteRow: origin.start.row)
            && state.contains(absoluteRow: origin.end.row)
            && (!requiresSelection || state.selection != nil),
          selected: state.selection != nil
        )
      }
      hasSelection = current.selected
      if !current.valid { selectionOrigin = nil }
      return
    }
    hasSelection = extended.hasSelection
    if !extended.extended {
      selectionOrigin = nil
    } else if scrollEdges {
      // Select the displayed edge first. Rows revealed by scrolling become
      // eligible only after their frame is accepted, on a later drag event.
      let lines = SelectionMath.edgeScroll(row: c.row, rows: snapshot.rowCount)
      if lines != 0 { session.scrollViewport(by: lines) }
    }
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
  /// a click moves its cursor there with arrow keys, or is reported to a
  /// shell that asked for `click_events`.
  private func moveShellCursor(to p: TerminalPoint, generation: UInt64) {
    guard capabilities.textInput, let snapshot = lastSnapshot else { return }
    let action =
      session.withPresentationState(matching: snapshot) { state in
        state.addressingGeneration == generation
          ? state.promptClickAction(at: p) : nil
      } ?? nil
    guard let action else { return }
    for input in ClickToMove.inputs(action) { submitInput(input) }
  }

  // MARK: Links and the pointer

  func link(for event: NSEvent) -> TerminalLink? {
    guard capabilities.openURLs, let snapshot = lastSnapshot else { return nil }
    let cell = unclampedCell(for: event)
    let detect = config.linkURL
    return session.withPresentationState(matching: snapshot) { state in
      state.link(
        at: state.viewportPoint(row: cell.row, column: cell.column),
        detectURLs: detect
      )
    } ?? nil
  }

  /// Opens web, mail, FTP and SSH links only: the application chooses
  /// the target, so a `file:` link could launch a local program.
  func open(_ string: String) {
    guard capabilities.openURLs, let url = LinkPolicy.openableURL(string) else {
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
      guard link.id == 0, let snapshot = lastSnapshot else {
        return nil as HighlightSpan?
      }
      return session.withPresentationState(matching: snapshot) {
        LinkPolicy.span(
          of: link.range,
          firstVisibleRow: $0.absoluteRow(viewportRow: 0)
        )
      }
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

  public override func mouseEntered(with event: NSEvent) { updateHover(event) }

  public override func mouseExited(with event: NSEvent) { clearHover() }

  public override func resetCursorRects() {
    addCursorRect(bounds, cursor: applicationCursor)
  }

  public override func flagsChanged(with event: NSEvent) {
    super.flagsChanged(with: event)
    // Keyboard events do not carry the last pointer location.
    hoverModifiers = event.modifierFlags
    refreshHover()
  }

  public override func rightMouseDown(with event: NSEvent) {
    guard tracking else { return super.rightMouseDown(with: event) }
    sendMouse(.press, .right, event)
  }

  public override func rightMouseUp(with event: NSEvent) {
    sendMouse(.release, .right, event)
  }

  public override func rightMouseDragged(with event: NSEvent) {
    sendMouse(.motion, .right, event)
  }

  public override func menu(for event: NSEvent) -> NSMenu? {
    guard !tracking else { return nil }
    let c = unclampedCell(for: event)
    guard let snapshot = lastSnapshot,
      let clicked = session.withPresentationState(
        matching: snapshot,
        { state in
          (
            state.viewportPoint(row: c.row, column: c.column),
            state.addressingGeneration
          )
        }
      )
    else { return nil }
    lastClick = clicked
    let menu = NSMenu()
    // Unavailable actions are left out rather than disabled.
    if capabilities.allows(.copyToClipboard) {
      menu.addItem(
        withTitle: "Copy",
        action: #selector(copy(_:)),
        keyEquivalent: ""
      )
    }
    if capabilities.allows(.pasteFromClipboard) {
      menu.addItem(
        withTitle: "Paste",
        action: #selector(paste(_:)),
        keyEquivalent: ""
      )
    }
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

  public override func otherMouseDown(with event: NSEvent) {
    guard event.buttonNumber == 2 else { return }
    sendMouse(.press, .middle, event)
  }

  public override func otherMouseUp(with event: NSEvent) {
    guard event.buttonNumber == 2 else { return }
    sendMouse(.release, .middle, event)
  }

  public override func otherMouseDragged(with event: NSEvent) {
    guard event.buttonNumber == 2 else { return }
    sendMouse(.motion, .middle, event)
  }

  public override func mouseMoved(with event: NSEvent) {
    updateHover(event)
    guard containsTerminalPoint(convert(event.locationInWindow, from: nil))
    else { return }
    if lastModes.contains(.mouseAny) { sendMouse(.motion, .none, event) }
  }

  public override func updateTrackingAreas() {
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

  public override func scrollWheel(with event: NSEvent) {
    let mode: TerminalPointer.ScrollMode
    if tracking {
      mode = .mouse
    } else if lastModes.contains(.alternateScreen),
      lastModes.contains(.alternateScroll)
    {
      mode = capabilities.textInput ? .arrows : .disabled
    } else {
      mode = capabilities.scrollback ? .history : .disabled
    }
    pointer.scroll(event, in: self, renderer: renderer, mode: mode) { input in
      switch input {
      case let .wheel(button): sendMouse(.press, button, event)
      case let .key(key): submitInput(.key(KeyEvent(key)))
      case let .history(lines): session.scrollViewport(by: lines)
      }
    }
  }
}
