import AppKit
import MetalKit
import SwifttyCore

/// An MTKView hosting one terminal session.
///
/// Draws on demand: the session's update callback marks the view dirty and
/// AppKit coalesces redraws to the display refresh.
@MainActor
final class TerminalView: MTKView, MTKViewDelegate {
    let session = TerminalSession()
    private let renderer: MetalRenderer
    private var fontSize: CGFloat = 13
    private var lastModes: Modes = .initial
    private var scrollAccumulator: CGFloat = 0
    private var gridSize = (columns: 0, rows: 0)
    /// Cursor of the last drawn frame, for placing the IME candidate window.
    private var lastCursor: CursorState?

    // Selection gesture in progress.
    private enum SelectionUnit { case cell, word, line }
    private var selectionUnit = SelectionUnit.cell
    /// Span the gesture started on (one cell, word or line).
    private var selectionOrigin: (start: TerminalPoint, end: TerminalPoint)?
    private var selectionDragged = false
    private var hasSelection = false

    // IME composition.
    private var markedText = ""
    /// The key event being interpreted, for commands the input system does not handle.
    private var interpretingEvent: NSEvent?

    var onTitle: ((String) -> Void)?
    var onExit: (() -> Void)?

    init(fontSize: CGFloat = 13) throws {
        self.fontSize = fontSize
        guard let device = MTLCreateSystemDefaultDevice() else { throw RendererError.setup("no Metal device") }
        renderer = try MetalRenderer(device: device, fontManager: CoreTextFontManager(), font: FontDescriptor(size: fontSize, scale: 2))
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = true
        autoResizeDrawable = true
        delegate = self

        session.onUpdate = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.needsDisplay = true } }
        }
        session.onEvent = { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(event) } }
        }
    }

    @available(*, unavailable) required init(coder: NSCoder) {
        fatalError()
    }

    func start() throws {
        updateGrid()
        try session.start(SessionConfiguration())
    }

    func stop() {
        session.stop()
    }

    func preferredSize(columns: Int, rows: Int) -> NSSize {
        let scale = renderer.font.descriptor.scale
        return NSSize(
            width: (CGFloat(columns) * renderer.cellSize.width + 2 * renderer.padding) / scale,
            height: (CGFloat(rows) * renderer.cellSize.height + 2 * renderer.padding) / scale,
        )
    }

    private func handle(_ event: TerminalEvent) {
        switch event {
        case let .title(title): onTitle?(title)
        case .bell: NSSound.beep()
        case let .clipboard(text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .workingDirectory: break
        case .exited: onExit?()
        default: break
        }
    }

    // MARK: Layout

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyFont()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGrid()
    }

    private func applyFont() {
        let scale = window?.backingScaleFactor ?? 2
        renderer.setFont(FontDescriptor(size: fontSize, scale: scale))
        updateGrid()
        needsDisplay = true
    }

    private func updateGrid() {
        let scale = window?.backingScaleFactor ?? renderer.font.descriptor.scale
        let pixels = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let size = renderer.gridSize(for: pixels)
        session.setCellPixelSize(width: Int(renderer.cellSize.width), height: Int(renderer.cellSize.height))
        guard size != gridSize else { return }
        gridSize = size
        session.resize(columns: size.columns, rows: size.rows)
    }

    @objc func increaseFontSize(_ sender: Any?) {
        fontSize = min(fontSize + 1, 72); applyFont()
    }

    @objc func decreaseFontSize(_ sender: Any?) {
        fontSize = max(fontSize - 1, 6); applyFont()
    }

    @objc func resetFontSize(_ sender: Any?) {
        fontSize = 13; applyFont()
    }

    // MARK: Drawing

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let snapshot = session.snapshot()
        lastModes = snapshot.modes
        lastCursor = snapshot.cursor
        renderer.draw(snapshot, in: self)
    }

    // MARK: Keyboard

    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        session.send(.focus(true))
        return true
    }

    override func resignFirstResponder() -> Bool {
        session.send(.focus(false))
        return true
    }

    override func keyDown(with event: NSEvent) {
        clearSelection()
        // While composing, every key belongs to the input method.
        if !hasMarkedText(), sendKey(event) {
            return
        }
        interpretingEvent = event
        interpretKeyEvents([event])
        interpretingEvent = nil
    }

    /// Sends keys the terminal encodes itself (specials, control
    /// combinations); returns false for text, which goes through the
    /// input method.
    private func sendKey(_ event: NSEvent) -> Bool {
        let mods = Self.modifiers(event.modifierFlags)
        if let key = Self.specialKeys[event.keyCode] {
            session.send(.key(KeyEvent(key, modifiers: mods)))
            return true
        }
        if mods.contains(.control), let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first {
            session.send(.key(KeyEvent(.character(scalar), modifiers: mods.subtracting(.shift))))
            return true
        }
        return false
    }

    @objc func paste(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string) {
            session.send(.paste(text))
        }
    }

    @objc func copy(_ sender: Any?) {
        guard let text = session.withState({ $0.selectionText }), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    override func selectAll(_ sender: Any?) {
        session.mutate { state in
            let first = state.firstAbsoluteRow
            state.setSelection(Selection(
                anchor: TerminalPoint(row: first, column: 0),
                head: TerminalPoint(row: first + state.addressableRows - 1, column: state.columns - 1),
            ))
        }
        hasSelection = true
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(copy(_:)) {
            return session.withState { $0.selection != nil }
        }
        return true
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> KeyModifiers {
        var mods: KeyModifiers = []
        if flags.contains(.shift) {
            mods.insert(.shift)
        }
        if flags.contains(.control) {
            mods.insert(.control)
        }
        if flags.contains(.option) {
            mods.insert(.alt)
        }
        if flags.contains(.command) {
            mods.insert(.command)
        }
        return mods
    }

    static let specialKeys: [UInt16: Key] = [
        36: .enter, 76: .enter, 48: .tab, 51: .backspace, 53: .escape,
        123: .left, 124: .right, 125: .down, 126: .up,
        115: .home, 119: .end, 116: .pageUp, 121: .pageDown, 117: .delete, 114: .insert,
        122: .function(1), 120: .function(2), 99: .function(3), 118: .function(4),
        96: .function(5), 97: .function(6), 98: .function(7), 100: .function(8),
        101: .function(9), 109: .function(10), 103: .function(11), 111: .function(12),
    ]

    // MARK: Mouse

    private func cell(for event: NSEvent) -> (column: Int, row: Int) {
        let c = unclampedCell(for: event)
        return (max(0, c.column), max(0, c.row))
    }

    /// Grid cell under the pointer; may lie outside the grid.
    private func unclampedCell(for event: NSEvent) -> (column: Int, row: Int) {
        let scale = window?.backingScaleFactor ?? 2
        let p = convert(event.locationInWindow, from: nil)
        let x = (p.x * scale - renderer.padding) / renderer.cellSize.width
        let y = ((bounds.height - p.y) * scale - renderer.padding) / renderer.cellSize.height
        return (Int(x.rounded(.down)), Int(y.rounded(.down)))
    }

    private var tracking: Bool {
        !lastModes.isDisjoint(with: Modes.mouseTracking)
    }

    private func sendMouse(_ action: MouseEvent.Action, _ button: MouseEvent.Button, _ event: NSEvent) {
        guard tracking else { return }
        let c = cell(for: event)
        session.send(.mouse(MouseEvent(action, button, column: c.column, row: c.row, modifiers: Self.modifiers(event.modifierFlags))))
    }

    /// Shift selects even while the application tracks the mouse.
    private func selects(_ event: NSEvent) -> Bool {
        !tracking || event.modifierFlags.contains(.shift)
    }

    override func mouseDown(with event: NSEvent) {
        guard selects(event) else { sendMouse(.press, .left, event); return }
        beginSelection(event)
    }

    override func mouseUp(with event: NSEvent) {
        guard selectionOrigin == nil else { endSelection(); return }
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
        selectionOrigin = session.mutate { state in
            let p = state.clamp(TerminalPoint(row: state.absoluteRow(viewportRow: c.row), column: c.column))
            let span = switch unit {
            case .cell: (start: p, end: p)
            case .word: state.wordRange(at: p)
            case .line: state.lineRange(at: p)
            }
            state.setSelection(unit == .cell ? nil : Selection(anchor: span.start, head: span.end, rectangle: rectangle))
            return span
        }
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

    private func endSelection() {
        if selectionUnit == .cell, !selectionDragged {
            clearSelection() // a plain click
        }
        selectionOrigin = nil
    }

    private func clearSelection() {
        guard hasSelection else { return }
        hasSelection = false
        session.mutateAsync { $0.setSelection(nil) }
    }

    override func rightMouseDown(with event: NSEvent) {
        sendMouse(.press, .right, event)
    }

    override func rightMouseUp(with event: NSEvent) {
        sendMouse(.release, .right, event)
    }

    override func otherMouseDown(with event: NSEvent) {
        sendMouse(.press, .middle, event)
    }

    override func otherMouseUp(with event: NSEvent) {
        sendMouse(.release, .middle, event)
    }

    override func mouseMoved(with event: NSEvent) {
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

// MARK: - IME

extension TerminalView: @MainActor NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        setPreedit("")
        if !text.isEmpty {
            session.send(.text(text))
        }
    }

    /// Selectors the input method did not turn into text (for example a
    /// dead key followed by an arrow); send the key as typed.
    override func doCommand(by selector: Selector) {
        guard let event = interpretingEvent, !sendKey(event), let text = event.characters, !text.isEmpty else { return }
        session.send(.text(text))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        setPreedit((string as? NSAttributedString)?.string ?? string as? String ?? "")
    }

    func unmarkText() {
        guard !markedText.isEmpty else { return }
        insertText(markedText, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func setPreedit(_ text: String) {
        guard text != markedText else { return }
        markedText = text
        renderer.options.preedit = Array(text.unicodeScalars)
        needsDisplay = true
    }

    func hasMarkedText() -> Bool {
        !markedText.isEmpty
    }

    func markedRange() -> NSRange {
        hasMarkedText() ? NSRange(location: 0, length: markedText.utf16.count) : NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func characterIndex(for point: NSPoint) -> Int {
        NSNotFound
    }

    /// The cursor cell in screen coordinates, where the candidate window goes.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        let scale = window?.backingScaleFactor ?? renderer.font.descriptor.scale
        let column = CGFloat(lastCursor?.x ?? 0), row = CGFloat(lastCursor?.y ?? 0)
        let cell = renderer.cellSize, padding = renderer.padding
        let x: CGFloat = (padding + column * cell.width) / scale
        let top: CGFloat = (padding + (row + 1) * cell.height) / scale
        let rect = NSRect(x: x, y: bounds.height - top, width: cell.width / scale, height: cell.height / scale)
        guard let window else { return rect }
        return window.convertToScreen(convert(rect, to: nil))
    }
}
