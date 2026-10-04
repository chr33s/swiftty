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
        let mods = Self.modifiers(event.modifierFlags)
        if let key = Self.specialKeys[event.keyCode] {
            session.send(.key(KeyEvent(key, modifiers: mods)))
            return
        }
        if mods.contains(.control), let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first {
            session.send(.key(KeyEvent(.character(scalar), modifiers: mods.subtracting(.shift))))
            return
        }
        if let text = event.characters, !text.isEmpty {
            session.send(.text(text))
        }
    }

    @objc func paste(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string) {
            session.send(.paste(text))
        }
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
        let scale = window?.backingScaleFactor ?? 2
        let p = convert(event.locationInWindow, from: nil)
        let x = (p.x * scale - renderer.padding) / renderer.cellSize.width
        let y = ((bounds.height - p.y) * scale - renderer.padding) / renderer.cellSize.height
        return (max(0, Int(x)), max(0, Int(y)))
    }

    private var tracking: Bool {
        !lastModes.isDisjoint(with: Modes.mouseTracking)
    }

    private func sendMouse(_ action: MouseEvent.Action, _ button: MouseEvent.Button, _ event: NSEvent) {
        guard tracking else { return }
        let c = cell(for: event)
        session.send(.mouse(MouseEvent(action, button, column: c.column, row: c.row, modifiers: Self.modifiers(event.modifierFlags))))
    }

    override func mouseDown(with event: NSEvent) {
        sendMouse(.press, .left, event)
    }

    override func mouseUp(with event: NSEvent) {
        sendMouse(.release, .left, event)
    }

    override func mouseDragged(with event: NSEvent) {
        sendMouse(.motion, .left, event)
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
