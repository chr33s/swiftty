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
        let y = ((bounds.height - p.y) * scale - renderer.options.paddingY) / renderer.cellSize.height
        return (Int(x.rounded(.down)), Int(y.rounded(.down)))
    }

    /// Absolute point under the pointer, clamped to the grid.
    func point(for event: NSEvent) -> TerminalPoint {
        let c = unclampedCell(for: event)
        return session.withState { state in
            state.clamp(TerminalPoint(row: state.absoluteRow(viewportRow: min(max(c.row, 0), state.rows - 1)), column: c.column))
        }
    }

    var tracking: Bool {
        !lastModes.isDisjoint(with: Modes.mouseTracking)
    }

    func sendMouse(_ action: MouseEvent.Action, _ button: MouseEvent.Button, _ event: NSEvent) {
        guard tracking else { return }
        let c = cell(for: event)
        session.send(.mouse(MouseEvent(action, button, column: c.column, row: c.row, modifiers: Self.modifiers(event.modifierFlags))))
    }

    /// Shift selects even while the application tracks the mouse.
    private func selects(_ event: NSEvent) -> Bool {
        !tracking || event.modifierFlags.contains(.shift)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let link = link(for: event) {
            open(link.url)
            return
        }
        guard selects(event) else { sendMouse(.press, .left, event); return }
        beginSelection(event)
    }

    override func mouseUp(with event: NSEvent) {
        guard selectionOrigin == nil else { endSelection(event); return }
        sendMouse(.release, .left, event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard selectionOrigin == nil else { extendSelection(event); return }
        sendMouse(.motion, .left, event)
    }

    // MARK: Selection

    private func beginSelection(_ event: NSEvent) {
        let c = unclampedCell(for: event)
        let rectangle = event.modifierFlags.contains(.option)
        selectionUnit = switch event.clickCount {
        case 2: .word
        case 3...: .line
        default: .cell
        }
        selectionDragged = false
        let unit = selectionUnit
        let origin = session.mutate { state in
            let p = state.clamp(TerminalPoint(row: state.absoluteRow(viewportRow: c.row), column: c.column))
            let span = switch unit {
            case .cell: (start: p, end: p)
            case .word: state.wordRange(at: p)
            case .line: state.lineRange(at: p)
            }
            state.setSelection(unit == .cell ? nil : Selection(anchor: span.start, head: span.end, rectangle: rectangle))
            return span
        }
        selectionOrigin = origin
        lastClick = origin.start
        hasSelection = selectionUnit != .cell
    }

    private func extendSelection(_ event: NSEvent) {
        guard let origin = selectionOrigin else { return }
        let c = unclampedCell(for: event)
        let rectangle = event.modifierFlags.contains(.option)
        let unit = selectionUnit
        selectionDragged = true
        session.mutate { state in
            // Dragging past the top or bottom edge scrolls the viewport.
            if c.row < 0 {
                state.scrollViewport(by: 1)
            } else if c.row >= state.rows {
                state.scrollViewport(by: -1)
            }
            let row = min(max(c.row, 0), state.rows - 1)
            let p = state.clamp(TerminalPoint(row: state.absoluteRow(viewportRow: row), column: c.column))
            let span = switch unit {
            case .cell: (start: p, end: p)
            case .word: state.wordRange(at: p)
            case .line: state.lineRange(at: p)
            }
            // Keep the whole unit the gesture started on.
            let selection = span.start < origin.start
                ? Selection(anchor: origin.end, head: span.start, rectangle: rectangle)
                : Selection(anchor: origin.start, head: span.end, rectangle: rectangle)
            state.setSelection(selection)
        }
        hasSelection = true
    }

    private func endSelection(_ event: NSEvent) {
        if selectionUnit == .cell, !selectionDragged {
            clearSelection() // a plain click
            if config.cursorClickToMove, !tracking, let origin = selectionOrigin {
                moveShellCursor(to: origin.start)
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
    private func moveShellCursor(to p: TerminalPoint) {
        guard let moves = session.withState({ $0.promptCursorMoves(to: p) }), moves != 0 else { return }
        let key: Key = moves < 0 ? .left : .right
        for _ in 0 ..< abs(moves) {
            session.send(.key(KeyEvent(key)))
        }
    }

    // MARK: Links and the pointer

    func link(for event: NSEvent) -> TerminalLink? {
        let p = point(for: event)
        let detect = config.linkURL
        return session.withState { $0.link(at: p, detectURLs: detect) }
    }

    func open(_ string: String) {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto", "ftp", "file", "ssh"].contains(scheme) else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// With Command held, the link under the pointer is underlined and the
    /// pointer becomes a hand.
    func updateHover(_ event: NSEvent) {
        let link = event.modifierFlags.contains(.command) ? self.link(for: event) : nil
        guard link != hoveredLink else { return }
        hoveredLink = link
        if let link {
            let span = session.withState { state in
                HighlightSpan(
                    startRow: state.viewportRow(absoluteRow: link.range.start.row), startColumn: link.range.start.column,
                    endRow: state.viewportRow(absoluteRow: link.range.end.row), endColumn: link.range.end.column,
                )
            }
            renderer.options.hoveredLink = link.id
            renderer.options.underlinedSpan = link.id == 0 ? span : nil
            NSCursor.pointingHand.set()
        } else {
            renderer.options.hoveredLink = 0
            renderer.options.underlinedSpan = nil
            applicationCursor.set()
        }
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: applicationCursor)
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        updateHover(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard tracking else { return super.rightMouseDown(with: event) }
        sendMouse(.press, .right, event)
    }

    override func rightMouseUp(with event: NSEvent) {
        sendMouse(.release, .right, event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard !tracking else { return nil }
        lastClick = point(for: event)
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Select Command Output", action: #selector(selectCommandOutput(_:)), keyEquivalent: "")
        if let link = link(for: event) {
            menu.addItem(.separator())
            let item = NSMenuItem(title: "Open Link", action: #selector(openMenuLink(_:)), keyEquivalent: "")
            item.representedObject = link.url
            menu.addItem(item)
        }
        return menu
    }

    @objc private func openMenuLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String else { return }
        open(url)
    }

    override func otherMouseDown(with event: NSEvent) {
        sendMouse(.press, .middle, event)
    }

    override func otherMouseUp(with event: NSEvent) {
        sendMouse(.release, .middle, event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(event)
        if lastModes.contains(.mouseAny) {
            sendMouse(.motion, .none, event)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func scrollWheel(with event: NSEvent) {
        let lineHeight = renderer.cellSize.height / (window?.backingScaleFactor ?? 2)
        scrollAccumulator += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / lineHeight : event.scrollingDeltaY
        let lines = Int(scrollAccumulator)
        guard lines != 0 else { return }
        scrollAccumulator -= CGFloat(lines)
        if tracking {
            for _ in 0 ..< abs(lines) {
                sendMouse(.press, lines > 0 ? .wheelUp : .wheelDown, event)
            }
        } else if lastModes.contains(.alternateScreen), lastModes.contains(.alternateScroll) {
            for _ in 0 ..< abs(lines) {
                session.send(.key(KeyEvent(lines > 0 ? .up : .down)))
            }
        } else {
            session.scrollViewport(by: lines)
        }
    }
}
