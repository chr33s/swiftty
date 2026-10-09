import AppKit
import MetalKit
import QuartzCore
import SwifttyCore

/// An MTKView hosting one terminal session.
///
/// Draws on demand: the session's update callback marks the view dirty and
/// AppKit coalesces redraws to the display refresh. Mouse handling, text
/// input, key-binding actions and accessibility live in extensions.
@MainActor
final class TerminalView: MTKView, MTKViewDelegate {
    private static let surfaces = NSHashTable<TerminalView>.weakObjects()
    let session: TerminalSession
    let renderer: MetalRenderer
    private(set) var config: Configuration
    /// Manual zoom, or nil to follow the configured point size.
    private var explicitFontSize: CGFloat?
    var fontSize: CGFloat {
        explicitFontSize ?? CGFloat(Configuration.boundedFontSize(config.fontSize))
    }

    var lastModes: Modes = .initial
    var scrollAccumulator = ScrollAccumulator()
    var horizontalScrollAccumulator = ScrollAccumulator()
    var gridSize = (columns: 0, rows: 0)
    /// The last drawn frame: the cursor for the IME candidate window, the
    /// text for accessibility.
    var lastSnapshot: RenderSnapshot?
    var colorScheme: ColorScheme

    // Selection gesture in progress.
    enum SelectionUnit { case cell, word, line }
    var selectionUnit = SelectionUnit.cell
    /// Span the gesture started on (one cell, word or line).
    var selectionOrigin: (start: TerminalPoint, end: TerminalPoint, generation: UInt64)?
    var selectionDragged = false
    /// Later drag/release reports belong to the terminal only when it
    /// received this gesture's initial press.
    var reportsLeftMouseGesture = false
    var hasSelection = false
    var pasteboard = NSPasteboard.general
    /// Where the last click landed, for "Select Command Output".
    var lastClick: (point: TerminalPoint, generation: UInt64)?

    /// Links and the pointer.
    var hoveredLink: TerminalLink?
    var hoverEvent: NSEvent?
    var hoverModifiers: NSEvent.ModifierFlags = []
    var hoverCell: (column: Int, row: Int)?
    /// The pointer the application asked for (OSC 22).
    var applicationCursor = NSCursor.iBeam

    /// IME composition.
    var markedText = ""
    var markedSelection = NSRange(location: NSNotFound, length: 0)
    /// The key event being interpreted, for commands the input system does not handle.
    var interpretingEvent: NSEvent?
    var heldKeys: [UInt16: KeyEvent] = [:]

    // Blinking: one timer drives the cursor and SGR 5 text.
    private var blinkTimer: Timer?
    private var blinkOn = true
    private var cursorBlinks = false
    private var isStopped = false
    private var submittedFrame: UInt64 = 0
    private var retryScheduled = false
    private var visibilityObservers: [NSKeyValueObservation] = []

    var searchBar: SearchBar?
    var accessibilityThrottle = NotificationThrottle(interval: 0.5)
    private var lastAccessibilityValue: String?
    private var lastAccessibilityRanges: [NSRange]?
    private var pendingAccessibilityNotifications: Set<NSAccessibility.Notification> = []
    /// Screen text for VoiceOver, rebuilt once per snapshot.
    var accessibilityCache = AccessibilityTextCache()

    var onTitle: ((String) -> Void)?
    var onExit: (() -> Void)?

    init(configuration: Configuration) throws {
        config = configuration
        colorScheme = Self.scheme(of: NSApp.effectiveAppearance)
        session = TerminalSession(configuration: configuration.sessionConfiguration(scheme: colorScheme))
        guard let device = MTLCreateSystemDefaultDevice() else { throw RendererError.setup("no Metal device") }
        renderer = try MetalRenderer(device: device, fontManager: CoreTextFontManager(), font: configuration.fontDescriptor(scale: 2))
        super.init(frame: .zero, device: device)
        (layer as? CAMetalLayer)?.maximumDrawableCount = 2
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
        Self.surfaces.add(self)
    }

    @available(*, unavailable) required init(coder: NSCoder) {
        fatalError()
    }

    func start() throws {
        updateGrid()
        try session.start(config.sessionConfiguration(scheme: colorScheme))
        isStopped = false
        Self.surfaces.add(self)
        session.mutate { $0.setColorScheme(colorScheme) }
        updateFrameDriving()
    }

    func stop() {
        Self.surfaces.remove(self)
        isStopped = true
        resetBlink()
        isPaused = true
        enableSetNeedsDisplay = true
        session.stop()
    }

    func preferredSize(columns: Int, rows: Int) -> NSSize {
        let scale = renderer.font.descriptor.scale
        let maximum = (window?.screen ?? NSScreen.main)?.visibleFrame.size ?? NSSize(width: 1024, height: 768)
        return NSSize(
            width: min(maximum.width, (CGFloat(columns) * renderer.cellSize.width + 2 * renderer.options.paddingX) / scale),
            height: min(maximum.height, (CGFloat(rows) * renderer.cellSize.height + 2 * renderer.options.paddingY) / scale),
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
            applyFont()
        }
        applyRenderOptions(scale: window?.backingScaleFactor ?? 2)
        loadShader()
        if paletteChanged {
            let palette = configuration.palette(for: colorScheme)
            session.mutate { $0.setDefaultPalette(palette) }
        }
        updateGrid()
        if hoverEvent != nil {
            refreshHover()
        }
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
        options.preeditSelection = current.preeditSelection
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

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow {
            clearHover()
        }
        if let window, window !== newWindow, window.firstResponder === self {
            _ = resignFirstResponder()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeVisibility()
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: nil)
        updateFrameDriving()
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            center.addObserver(self, selector: #selector(windowKeyChanged(_:)), name: name, object: window)
        }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didChangeScreenNotification] {
            center.addObserver(self, selector: #selector(windowVisibilityChanged), name: name, object: window)
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        observeVisibility()
        windowVisibilityChanged()
    }

    @objc private func windowVisibilityChanged() {
        updateFrameDriving()
        if isSurfaceVisible {
            needsDisplay = true
        }
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateFrameDriving()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateFrameDriving()
        needsDisplay = true
    }

    @objc private func windowKeyChanged(_ notification: Notification) {
        if notification.name == NSWindow.didResignKeyNotification {
            clearHover()
        }
        // A window keeps its first responder when another window becomes key.
        if window?.firstResponder === self {
            if notification.name == NSWindow.didBecomeKeyNotification {
                session.send(.focus(true))
            } else {
                _ = resignFirstResponder()
            }
        }
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyRenderOptions(scale: window?.backingScaleFactor ?? 2)
        applyFont()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGrid()
        searchBar?.position(in: bounds)
        updateFrameDriving()
    }

    func applyFont() {
        let scale = window?.backingScaleFactor ?? 2
        renderer.setFont(config.fontDescriptor(scale: scale, size: Double(fontSize)))
        updateGrid()
        needsDisplay = true
    }

    func setFontSize(_ size: CGFloat?) {
        explicitFontSize = size.map { CGFloat(Configuration.boundedFontSize(Double($0))) }
        applyFont()
    }

    func updateGrid() {
        let scale = window?.backingScaleFactor ?? renderer.font.descriptor.scale
        let pixels = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let size = renderer.gridSize(for: pixels)
        session.setCellPixelSize(
            width: TerminalGeometry.pixelExtent(renderer.cellSize.width), height: TerminalGeometry.pixelExtent(renderer.cellSize.height),
        )
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

    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            if !newValue {
                super.needsDisplay = newValue
                return
            }
            switch surfaceVisibility {
            case .hidden: break
            case .awaitingOpacity: retryDraw(frame: submittedFrame)
            case .visible: super.needsDisplay = true
            }
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let snapshot = session.snapshot()
        if let event = hoverEvent,
           !snapshot.damage.isEmpty || lastSnapshot?.viewportOffset != snapshot.viewportOffset
           || (hoverCell.map { $0 != cell(for: event) } ?? true) {
            refreshHover()
        }
        lastModes = snapshot.modes
        lastSnapshot = snapshot
        if hasSelection, snapshot.selection == nil {
            hasSelection = false
            selectionOrigin = nil
        }
        cursorBlinks = config.cursorStyleBlink ?? snapshot.cursor.isBlinking
        renderer.options.isFocused = window?.isKeyWindow == true && window?.firstResponder === self
        renderer.options.cursorVisible = blinkOn || !cursorBlinks || !renderer.options.isFocused
        renderer.options.textBlinkVisible = blinkOn
        if isSurfaceVisible, let drawable = currentDrawable, currentRenderPassDescriptor != nil {
            submittedFrame &+= 1
            let frame = submittedFrame
            drawable.addPresentedHandler { [weak self] drawable in
                guard drawable.presentedTime == 0 else { return }
                DispatchQueue.main.async { self?.retryDraw(frame: frame) }
            }
            renderer.draw(snapshot, in: self)
        } else {
            retryDraw(frame: submittedFrame)
        }
        updateFrameDriving()
        postAccessibilityChange()
    }

    private var isSurfaceVisible: Bool {
        surfaceVisibility == .visible
    }

    private enum SurfaceVisibility { case hidden, awaitingOpacity, visible }

    private var surfaceVisibility: SurfaceVisibility {
        guard let window, window.isVisible, window.occlusionState.contains(.visible), window.alphaValue > 0,
              !isHiddenOrHasHiddenAncestor, bounds.width > 0, bounds.height > 0 else { return .hidden }
        var awaitingOpacity = false
        var ancestor: NSView? = self
        while let view = ancestor {
            if view.alphaValue <= 0 {
                guard let layer = view.layer, hasOpacityAnimation(layer) else { return .hidden }
                if (layer.presentation()?.opacity ?? 0) <= 0 {
                    guard hasOpacityAnimation(layer, awaitingPresentation: true) else { return .hidden }
                    awaitingOpacity = true
                }
            }
            ancestor = view.superview
        }
        return awaitingOpacity ? .awaitingOpacity : .visible
    }

    private func hasOpacityAnimation(_ layer: CALayer, awaitingPresentation: Bool = false) -> Bool {
        layer.animationKeys()?.contains { key in
            guard let animation = layer.animation(forKey: key) else { return false }
            if awaitingPresentation {
                var speed = animation.speed
                var ancestor: CALayer? = layer
                while let current = ancestor {
                    speed *= current.speed
                    ancestor = current.superlayer
                }
                guard speed != 0 else { return false }
                // Retained animations still run; stop polling only after their active time ends.
                // Core Animation resolves a zero begin time when it commits the animation.
                if !animation.isRemovedOnCompletion, animation.beginTime != 0 {
                    let time = (layer.convertTime(CACurrentMediaTime(), from: nil) - animation.beginTime)
                        * Double(animation.speed) + animation.timeOffset
                    let cycles = animation.repeatCount > 0 ? Double(animation.repeatCount) : 1
                    let duration = animation.repeatDuration > 0 ? animation.repeatDuration
                        : animation.duration * (animation.autoreverses ? 2 : 1) * cycles
                    if speed > 0 ? time >= duration : time <= 0 {
                        return false
                    }
                }
            }
            return Self.animatesOpacity(animation)
        } ?? false
    }

    private static func animatesOpacity(_ animation: CAAnimation) -> Bool {
        if let property = animation as? CAPropertyAnimation {
            return property.keyPath == "opacity"
        }
        return (animation as? CAAnimationGroup)?.animations?.contains(where: animatesOpacity) ?? false
    }

    private func observeVisibility() {
        visibilityObservers.removeAll()
        // Opacity composites the existing frame; redraw only when transparency ends.
        let refresh: @Sendable (Bool) -> Void = { [weak self] becameVisible in
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateFrameDriving()
                if becameVisible, self.isSurfaceVisible {
                    self.needsDisplay = true
                }
            }
        }
        var ancestor: NSView? = self
        while let view = ancestor {
            visibilityObservers.append(view.observe(\.alphaValue, options: [.old, .new]) { _, change in
                refresh(change.oldValue == 0 && (change.newValue ?? 0) > 0)
            })
            ancestor = view.superview
        }
        if let window {
            visibilityObservers.append(window.observe(\.alphaValue, options: [.old, .new]) { _, change in
                refresh(change.oldValue == 0 && (change.newValue ?? 0) > 0)
            })
        }
    }

    private func updateFrameDriving() {
        let rate = window?.screen?.maximumFramesPerSecond ?? 60
        if preferredFramesPerSecond != rate {
            preferredFramesPerSecond = rate
        }
        // A shader that animates needs frames without new output.
        let animating = renderer.isAnimating && !isStopped && isSurfaceVisible
        if animating == isPaused {
            isPaused = !animating
            enableSetNeedsDisplay = !animating
        }
        updateBlinkTimer()
    }

    private func retryDraw(frame: UInt64) {
        guard !retryScheduled, !isStopped, !renderer.isAnimating || isPaused,
              submittedFrame == frame, surfaceVisibility != .hidden else { return }
        retryScheduled = true
        let delay = 1 / Double(max(1, preferredFramesPerSecond))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            retryScheduled = false
            guard !isStopped, !renderer.isAnimating || isPaused, submittedFrame == frame,
                  surfaceVisibility != .hidden else { return }
            if isSurfaceVisible {
                updateFrameDriving()
                needsDisplay = true
            } else {
                retryDraw(frame: frame)
            }
        }
    }

    private func updateBlinkTimer() {
        let needed = !isStopped && isSurfaceVisible && ((cursorBlinks && renderer.options.isFocused) || renderer.hasBlinkingText)
        if needed, blinkTimer == nil {
            blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                let identity = ObjectIdentifier(timer)
                MainActor.assumeIsolated {
                    guard self.blinkTimer.map(ObjectIdentifier.init) == identity else { return }
                    guard self.isSurfaceVisible else { self.updateFrameDriving(); return }
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
        requestAccessibilityNotifications(accessibilityChanges()) { [weak self] notification in
            guard let self else { return }
            NSAccessibility.post(element: self, notification: notification)
        }
    }

    /// Only text or selection changes need an accessibility notification.
    func accessibilityChanges() -> [NSAccessibility.Notification] {
        let value = accessibilityText?.string ?? ""
        let ranges = accessibilitySelectedTextRanges()?.map(\.rangeValue) ?? []
        var changes: [NSAccessibility.Notification] = []
        if value != lastAccessibilityValue {
            changes.append(.valueChanged)
        }
        if ranges != lastAccessibilityRanges {
            changes.append(.selectedTextChanged)
        }
        lastAccessibilityValue = value
        lastAccessibilityRanges = ranges
        return changes
    }

    /// Coalesces each kind of change until the next permitted post.
    func requestAccessibilityNotifications(
        _ changes: [NSAccessibility.Notification], post: @escaping @MainActor (NSAccessibility.Notification) -> Void,
    ) {
        guard !changes.isEmpty else { return }
        pendingAccessibilityNotifications.formUnion(changes)
        requestAccessibilityPost { [weak self] in
            guard let self else { return }
            let pending = self.pendingAccessibilityNotifications
            self.pendingAccessibilityNotifications.removeAll(keepingCapacity: true)
            for notification in [NSAccessibility.Notification.valueChanged, .selectedTextChanged] where pending.contains(notification) {
                post(notification)
            }
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
        clearHover()
        if window == nil || window?.isKeyWindow == true {
            session.send(.focus(true))
        }
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        clearHover()
        // Key-up may go to the next responder after focus moves away.
        for var key in heldKeys.values {
            key.action = .release
            session.send(.key(key))
        }
        heldKeys.removeAll()
        session.send(.focus(false))
        needsDisplay = true
        return true
    }

    /// Key bindings run before the menu's key equivalents.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, !hasMarkedText(), let binding = binding(for: event) else {
            return super.performKeyEquivalent(with: event)
        }
        let performed = performBinding(binding)
        if binding.requiresPerformable, !performed {
            return false
        }
        if !binding.consumesInput {
            handleTerminalInput(event)
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        resetBlink()
        if config.mouseHideWhileTyping {
            NSCursor.setHiddenUntilMouseMoves(true)
        }
        if !hasMarkedText(), let binding = binding(for: event) {
            let performed = performBinding(binding)
            if binding.consumesInput, !binding.requiresPerformable || performed {
                return
            }
        }
        handleTerminalInput(event)
    }

    private func handleTerminalInput(_ event: NSEvent) {
        clearSelection()
        // While composing, every key belongs to the input method.
        if !hasMarkedText(), sendKey(event) {
            return
        }
        interpretingEvent = event
        interpretKeyEvents([event])
        interpretingEvent = nil
    }

    override func keyUp(with event: NSEvent) {
        if var key = heldKeys.removeValue(forKey: event.keyCode) {
            key.action = .release
            session.send(.key(key))
        }
    }

    private func binding(for event: NSEvent) -> Keybindings.Binding? {
        Self.trigger(for: event).flatMap { config.keybindings.binding(for: $0) }
    }

    private func performBinding(_ binding: Keybindings.Binding) -> Bool {
        guard binding.appliesToAll else { return perform(binding.action) }
        let surfaces = Self.surfaces.allObjects
        for surface in surfaces {
            surface.perform(binding.action)
        }
        return !surfaces.isEmpty
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
        let flags = !event.modifierFlags.isDisjoint(with: [.command, .control]) ? session.keyboardFlags : 0
        guard let key = Self.terminalKey(for: event, keyboardFlags: flags) else { return false }
        sendHardwareKey(key, event: event)
        return true
    }

    func sendHardwareKey(_ key: KeyEvent, event: NSEvent) {
        var key = key
        key.action = event.isARepeat ? .repeat : .press
        heldKeys[event.keyCode] = key
        session.send(.key(key))
    }

    /// The key event for keys the terminal encodes itself, or nil for text.
    static func terminalKey(for event: NSEvent, keyboardFlags: UInt8 = 0) -> KeyEvent? {
        let mods = modifiers(event.modifierFlags)
        let kittyActive = InputEncoder.isKittyKeyboardActive(keyboardFlags)
        if let key = specialKeys[event.keyCode] {
            return KeyEvent(key, modifiers: mods)
        }
        // AppKit's charactersIgnoringModifiers retains Shift. Translate without
        // modifiers using the active layout so punctuation keeps its base key.
        let base = kittyActive ? event.characters(byApplyingModifiers: []) : event.charactersIgnoringModifiers
        if mods.contains(.control) || kittyActive, let scalar = base?.unicodeScalars.first {
            return KeyEvent(
                .character(scalar), modifiers: kittyActive ? mods : mods.subtracting(.shift),
                action: event.isARepeat ? .repeat : .press,
                text: event.characters,
                shiftedKey: mods.contains(.shift) ? event.characters(byApplyingModifiers: [.shift])?.unicodeScalars.first : nil,
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

    private static let hiddenPointerCursor = NSCursor(
        image: NSImage(size: NSSize(width: 1, height: 1), flipped: false) { _ in true },
        hotSpot: .zero,
    )

    static func cursor(named name: String) -> NSCursor {
        switch name {
        case "default": .arrow
        case "none": hiddenPointerCursor
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
