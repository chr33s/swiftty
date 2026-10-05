import AppKit
import MetalKit
import SwifttyCore

/// An MTKView hosting one terminal session.
///
/// Draws on demand: the session's update callback marks the view dirty and
/// AppKit coalesces redraws to the display refresh. Mouse handling, text
/// input, key-binding actions and accessibility live in extensions.
@MainActor
final class TerminalView: MTKView, MTKViewDelegate {
    let session: TerminalSession
    let renderer: MetalRenderer
    private(set) var config: Configuration
    var fontSize: CGFloat
    var lastModes: Modes = .initial
    var scrollAccumulator: CGFloat = 0
    var gridSize = (columns: 0, rows: 0)
    /// The last drawn frame: the cursor for the IME candidate window, the
    /// text for accessibility.
    var lastSnapshot: RenderSnapshot?
    var colorScheme: ColorScheme

    // Selection gesture in progress.
    enum SelectionUnit { case cell, word, line }
    var selectionUnit = SelectionUnit.cell
    /// Span the gesture started on (one cell, word or line).
    var selectionOrigin: (start: TerminalPoint, end: TerminalPoint)?
    var selectionDragged = false
    var hasSelection = false
    /// Where the last click landed, for "Select Command Output".
    var lastClick: TerminalPoint?

    /// Links and the pointer.
    var hoveredLink: TerminalLink?
    /// The pointer the application asked for (OSC 22).
    var applicationCursor = NSCursor.iBeam

    /// IME composition.
    var markedText = ""
    /// The key event being interpreted, for commands the input system does not handle.
    var interpretingEvent: NSEvent?

    // Blinking: one timer drives the cursor and SGR 5 text.
    private var blinkTimer: Timer?
    private var blinkOn = true
    private var cursorBlinks = false

    var searchBar: SearchBar?
    var accessibilityThrottle = NotificationThrottle(interval: 0.5)
    /// Screen text for VoiceOver, rebuilt once per snapshot.
    var accessibilityCache = AccessibilityTextCache()

    var onTitle: ((String) -> Void)?
    var onExit: (() -> Void)?

    init(configuration: Configuration) throws {
        config = configuration
        fontSize = CGFloat(configuration.fontSize)
        colorScheme = Self.scheme(of: NSApp.effectiveAppearance)
        session = TerminalSession(configuration: configuration.sessionConfiguration(scheme: colorScheme))
        guard let device = MTLCreateSystemDefaultDevice() else { throw RendererError.setup("no Metal device") }
        renderer = try MetalRenderer(device: device, fontManager: CoreTextFontManager(), font: configuration.fontDescriptor(scale: 2))
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = true
        autoResizeDrawable = true
        delegate = self
        applyRenderOptions(scale: 2)
        loadShader()

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
        try session.start(config.sessionConfiguration(scheme: colorScheme))
        session.mutate { $0.setColorScheme(colorScheme) }
    }

    func stop() {
        blinkTimer?.invalidate()
        session.stop()
    }

    func preferredSize(columns: Int, rows: Int) -> NSSize {
        let scale = renderer.font.descriptor.scale
        return NSSize(
            width: (CGFloat(columns) * renderer.cellSize.width + 2 * renderer.options.paddingX) / scale,
            height: (CGFloat(rows) * renderer.cellSize.height + 2 * renderer.options.paddingY) / scale,
        )
    }

    private func handle(_ event: TerminalEvent) {
        switch event {
        case let .title(title): onTitle?(title)
        case .bell: NSSound.beep()
        case let .clipboard(text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case let .pointerShape(name):
            applicationCursor = Self.cursor(named: name)
            window?.invalidateCursorRects(for: self)
        case .exited: onExit?()
        default: break
        }
    }

    // MARK: Configuration

    /// Applies a reloaded configuration. The scrollback limit and command
    /// only take effect in new windows.
    func apply(_ configuration: Configuration) {
        let fontChanged = configuration.fontDescriptor(scale: 1) != config.fontDescriptor(scale: 1)
        let paletteChanged = configuration.palette(for: colorScheme) != config.palette(for: colorScheme)
        config = configuration
        if fontChanged {
            fontSize = CGFloat(configuration.fontSize)
            applyFont()
        }
        applyRenderOptions(scale: window?.backingScaleFactor ?? 2)
        loadShader()
        if paletteChanged {
            let palette = configuration.palette(for: colorScheme)
            session.mutate { $0.setDefaultPalette(palette) }
        }
        updateGrid()
        needsDisplay = true
    }

    /// Replaces the configured options, keeping the ones the view drives
    /// (composition, link hover, blink phase, focus).
    private func applyRenderOptions(scale: CGFloat) {
        renderer.options = Self.merge(configured: config.renderOptions(scale: scale), current: renderer.options)
    }

    static func merge(configured: RenderOptions, current: RenderOptions) -> RenderOptions {
        var options = configured
        options.preedit = current.preedit
        options.hoveredLink = current.hoveredLink
        options.underlinedSpan = current.underlinedSpan
        options.textBlinkVisible = current.textBlinkVisible
        options.cursorVisible = current.cursorVisible
        options.isFocused = current.isFocused
        return options
    }

    private func loadShader() {
        do {
            try renderer.setPostProcessShader(config.customShader.map { try String(contentsOfFile: $0, encoding: .utf8) })
        } catch {
            FileHandle.standardError.write(Data("swiftty: custom-shader: \(error)\n".utf8))
            try? renderer.setPostProcessShader(nil)
        }
    }

    static func scheme(of appearance: NSAppearance) -> ColorScheme {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua ? .light : .dark
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let scheme = Self.scheme(of: effectiveAppearance)
        guard scheme != colorScheme else { return }
        let themeChanges = config.palette(for: scheme) != config.palette(for: colorScheme)
        colorScheme = scheme
        let palette = config.palette(for: scheme)
        session.mutate { state in
            if themeChanges {
                state.setDefaultPalette(palette)
            }
            state.setColorScheme(scheme)
        }
    }

    // MARK: Layout

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyRenderOptions(scale: window?.backingScaleFactor ?? 2)
        applyFont()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGrid()
        searchBar?.position(in: bounds)
    }

    func applyFont() {
        let scale = window?.backingScaleFactor ?? 2
        renderer.setFont(config.fontDescriptor(scale: scale, size: Double(fontSize)))
        updateGrid()
        needsDisplay = true
    }

    func updateGrid() {
        let scale = window?.backingScaleFactor ?? renderer.font.descriptor.scale
        let pixels = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let size = renderer.gridSize(for: pixels)
        session.setCellPixelSize(width: Int(renderer.cellSize.width), height: Int(renderer.cellSize.height))
        guard size != gridSize else { return }
        gridSize = size
        session.resize(columns: size.columns, rows: size.rows)
    }

    @objc func increaseFontSize(_ sender: Any?) {
        perform(.increaseFontSize(1))
    }

    @objc func decreaseFontSize(_ sender: Any?) {
        perform(.decreaseFontSize(1))
    }

    @objc func resetFontSize(_ sender: Any?) {
        perform(.resetFontSize)
    }

    // MARK: Drawing

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let snapshot = session.snapshot()
        lastModes = snapshot.modes
        lastSnapshot = snapshot
        cursorBlinks = config.cursorStyleBlink ?? snapshot.cursor.isBlinking
        renderer.options.isFocused = window?.isKeyWindow == true && window?.firstResponder === self
        renderer.options.cursorVisible = blinkOn || !cursorBlinks || !renderer.options.isFocused
        renderer.options.textBlinkVisible = blinkOn
        renderer.draw(snapshot, in: self)
        updateBlinkTimer()
        // A shader that animates needs frames without new output.
        let animating = renderer.isAnimating
        if animating == isPaused {
            isPaused = !animating
            enableSetNeedsDisplay = !animating
        }
        postAccessibilityChange()
    }

    private func updateBlinkTimer() {
        let needed = (cursorBlinks && renderer.options.isFocused) || renderer.hasBlinkingText
        if needed, blinkTimer == nil {
            blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.blinkOn.toggle()
                    self.needsDisplay = true
                }
            }
        } else if !needed, let timer = blinkTimer {
            timer.invalidate()
            blinkTimer = nil
            if !blinkOn {
                blinkOn = true
                needsDisplay = true
            }
        }
    }

    /// Input shows the cursor at once and restarts its blink.
    func resetBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        if !blinkOn {
            blinkOn = true
            needsDisplay = true
        }
    }

    /// Tells VoiceOver the text changed, at most twice a second; a change
    /// inside that window is posted when it ends, so the last output is
    /// never missed.
    private func postAccessibilityChange() {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        requestAccessibilityPost { [weak self] in
            guard let self else { return }
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    /// Runs `post` now, or when the throttle window ends.
    func requestAccessibilityPost(_ post: @escaping @MainActor () -> Void) {
        switch accessibilityThrottle.request(at: CACurrentMediaTime()) {
        case .post:
            post()
        case let .schedule(after: wait):
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                MainActor.assumeIsolated {
                    self?.accessibilityThrottle.fire(at: CACurrentMediaTime())
                    post()
                }
            }
        case .skip:
            break
        }
    }

    /// The visible text for VoiceOver, cached per snapshot.
    var accessibilityText: AccessibilityText? {
        lastSnapshot.map { accessibilityCache.text(for: $0) }
    }

    // MARK: Keyboard

    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        session.send(.focus(true))
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        session.send(.focus(false))
        needsDisplay = true
        return true
    }

    /// Key bindings run before the menu's key equivalents.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, !hasMarkedText(), let action = binding(for: event) else {
            return super.performKeyEquivalent(with: event)
        }
        perform(action)
        return true
    }

    override func keyDown(with event: NSEvent) {
        resetBlink()
        if config.mouseHideWhileTyping {
            NSCursor.setHiddenUntilMouseMoves(true)
        }
        if !hasMarkedText(), let action = binding(for: event) {
            perform(action)
            return
        }
        clearSelection()
        // While composing, every key belongs to the input method.
        if !hasMarkedText(), sendKey(event) {
            return
        }
        interpretingEvent = event
        interpretKeyEvents([event])
        interpretingEvent = nil
    }

    private func binding(for event: NSEvent) -> KeyAction? {
        Self.trigger(for: event).flatMap { config.keybindings.action(for: $0) }
    }

    /// The key and modifiers a binding is matched against.
    static func trigger(for event: NSEvent) -> KeyEvent? {
        guard let key = specialKeys[event.keyCode]
            ?? event.charactersIgnoringModifiers?.unicodeScalars.first.map(Key.character) else { return nil }
        return KeyEvent(key, modifiers: modifiers(event.modifierFlags))
    }

    /// Sends keys the terminal encodes itself (specials, control
    /// combinations); returns false for text, which goes through the
    /// input method.
    func sendKey(_ event: NSEvent) -> Bool {
        guard let key = Self.terminalKey(for: event) else { return false }
        session.send(.key(key))
        return true
    }

    /// The key event for keys the terminal encodes itself, or nil for text.
    static func terminalKey(for event: NSEvent) -> KeyEvent? {
        let mods = modifiers(event.modifierFlags)
        if let key = specialKeys[event.keyCode] {
            return KeyEvent(key, modifiers: mods)
        }
        if mods.contains(.control), let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first {
            return KeyEvent(
                .character(scalar), modifiers: mods.subtracting(.shift),
                shiftedKey: event.characters?.unicodeScalars.first,
                baseLayoutKey: usLayout[event.keyCode],
            )
        }
        return nil
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

    /// Keys of the US layout by virtual key code (kitty's base layout key).
    static let usLayout: [UInt16: Unicode.Scalar] = {
        let keys: [(UInt16, Unicode.Scalar)] = [
            (0, "a"), (11, "b"), (8, "c"), (2, "d"), (14, "e"), (3, "f"), (5, "g"), (4, "h"), (34, "i"),
            (38, "j"), (40, "k"), (37, "l"), (46, "m"), (45, "n"), (31, "o"), (35, "p"), (12, "q"), (15, "r"),
            (1, "s"), (17, "t"), (32, "u"), (9, "v"), (13, "w"), (7, "x"), (16, "y"), (6, "z"),
            (29, "0"), (18, "1"), (19, "2"), (20, "3"), (21, "4"), (23, "5"), (22, "6"), (26, "7"), (28, "8"),
            (25, "9"), (27, "-"), (24, "="), (33, "["), (30, "]"), (42, "\\"), (41, ";"), (39, "'"),
            (43, ","), (47, "."), (44, "/"), (50, "`"),
        ]
        return Dictionary(uniqueKeysWithValues: keys)
    }()

    static func cursor(named name: String) -> NSCursor {
        switch name {
        case "default", "": .arrow
        case "pointer": .pointingHand
        case "crosshair", "cell": .crosshair
        case "not-allowed", "no-drop": .operationNotAllowed
        case "grab": .openHand
        case "grabbing": .closedHand
        case "ew-resize", "col-resize", "e-resize", "w-resize": .resizeLeftRight
        case "ns-resize", "row-resize", "n-resize", "s-resize": .resizeUpDown
        case "vertical-text": .iBeamCursorForVerticalLayout
        case "context-menu": .contextualMenu
        case "copy": .dragCopy
        case "alias": .dragLink
        default: .iBeam
        }
    }
}

/// Rate limit for change notifications: at most one per `interval`, and a
/// request inside the window is delivered when it ends rather than dropped.
struct NotificationThrottle {
    enum Decision: Equatable {
        case post
        case schedule(after: CFTimeInterval)
        /// One is already scheduled and will cover this change.
        case skip
    }

    let interval: CFTimeInterval
    private(set) var last = -CFTimeInterval.infinity
    private(set) var pending = false

    mutating func request(at now: CFTimeInterval) -> Decision {
        guard !pending else { return .skip }
        let wait = last + interval - now
        guard wait > 0 else {
            last = now
            return .post
        }
        pending = true
        return .schedule(after: wait)
    }

    /// The scheduled post went out.
    mutating func fire(at now: CFTimeInterval) {
        pending = false
        last = now
    }
}

/// `AccessibilityText` for the latest snapshot, built once per snapshot
/// however many accessibility queries read it.
struct AccessibilityTextCache {
    private var cached: (sequence: UInt64, text: AccessibilityText)?
    private(set) var builds = 0

    mutating func text(for snapshot: RenderSnapshot) -> AccessibilityText {
        if let cached, cached.sequence == snapshot.sequence {
            return cached.text
        }
        let text = AccessibilityText(snapshot)
        builds += 1
        cached = (snapshot.sequence, text)
        return text
    }
}
