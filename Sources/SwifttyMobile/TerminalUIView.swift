#if canImport(UIKit)
    import MetalKit
    import os
    import SwifttyCore
    import UIKit

    /// An MTKView hosting one terminal session on iOS and iPadOS.
    ///
    /// The app creates and connects the session (an SSH channel, the demo
    /// source); the view renders it, turns touches, the pointer and both
    /// keyboards into terminal input, and resizes the grid with the view
    /// and the software keyboard. Draws on demand: the session's update
    /// callback marks the view dirty, and nothing renders while idle or
    /// while the scene is in the background. Only blinking (a 0.6 s timer)
    /// and an animated custom shader (the display link) draw on their own.
    @MainActor
    public final class TerminalUIView: MTKView, MTKViewDelegate {
        public let session: TerminalSession
        public private(set) var configuration: Configuration
        let renderer: MetalRenderer
        /// Point size set by the user (pinch, key bindings); nil follows
        /// the configuration, or Dynamic Type when it sets no size.
        private var explicitFontSize: CGFloat?
        var lastModes: Modes = .initial
        /// Cursor of the last drawn frame, for placing IME candidates.
        var lastCursor: CursorState?
        private(set) var gridSize = (columns: 0, rows: 0)
        /// Height of the view covered by the docked keyboard and its
        /// accessory bar, in points.
        private var keyboardInset: CGFloat = 0
        /// Set while the scene is in the background: no frames are drawn.
        private(set) var isRenderingPaused = false
        /// Appearance last reported to the terminal (mode 2031) and used
        /// for the palette.
        private var colorScheme: ColorScheme?

        // Keyboard input.
        var sticky = StickyModifiers()
        lazy var accessoryBar: TerminalAccessoryBar = {
            let bar = TerminalAccessoryBar()
            bar.onKey = { [weak self] key in self?.accessoryKey(key) }
            bar.onDismiss = { [weak self] in _ = self?.resignFirstResponder() }
            return bar
        }()

        /// IME composition, drawn as the renderer's preedit.
        var markedText = ""
        /// Selection inside `markedText`, in UTF-16 units.
        var markedSelection = NSRange(location: 0, length: 0)
        public weak var inputDelegate: UITextInputDelegate?
        /// Releases owed for keys that are down, by HID usage.
        var heldKeys: [Int: KeyEvent] = [:]
        var hardwareTextInput = HardwareTextInput()
        /// Usages of presses handled here rather than by the text system.
        var handledPresses: Set<Int> = []
        var keyRepeat: Timer?
        /// Key commands built from the bindings, and their actions by index.
        var keyCommandCache: [UIKeyCommand]?
        var keyCommandActions: [KeyAction] = []

        // Selection gesture in progress.
        enum SelectionUnit { case cell, word, line }
        var selectionUnit = SelectionUnit.cell
        /// Span the gesture started on (one cell, word or line).
        var selectionOrigin: (start: TerminalPoint, end: TerminalPoint)?
        var hasSelection = false
        lazy var editMenu = UIEditMenuInteraction(delegate: self)
        lazy var searchBar: TerminalSearchBar = makeSearchBar()

        // Scrolling.
        var scrollAccumulator = ScrollAccumulator()
        var momentum = ScrollMomentum()
        var momentumLink: CADisplayLink?
        /// Where the fling started, for wheel events it reports.
        var momentumPoint = CGPoint.zero
        var pinchStartSize: CGFloat = 0

        /// Pointer.
        /// Last cell the pointer hovered over.
        var hoverCell: (column: Int, row: Int)?
        /// The pointer is over a link.
        var overLink = false
        /// OSC 22 shape the application asked for; empty for the default.
        var pointerShapeName = ""
        var pointerInteraction: UIPointerInteraction?

        // Blinking.
        private var blink = BlinkState()
        private var blinkTimer: Timer?
        /// The cursor blinks (DECSCUSR / mode 12, or `cursor-style-blink`).
        private var cursorBlinks = false

        // Accessibility.
        /// Screen text for VoiceOver; kept only while VoiceOver runs.
        var accessibilityScreen: AccessibilityText?
        private var lastAccessibilityPost: CFTimeInterval = 0
        private var accessibilityPostPending = false

        public var onTitle: ((String) -> Void)?
        public var onExit: (() -> Void)?
        /// The palette's default background changed (for filling the
        /// safe-area margins around the view); its alpha is the configured
        /// background opacity.
        public var onBackgroundColor: ((UIColor) -> Void)?
        private var lastBackground: UInt32?

        // Text input traits: a terminal wants keys as typed.
        public var autocorrectionType = UITextAutocorrectionType.no
        public var autocapitalizationType = UITextAutocapitalizationType.none
        public var spellCheckingType = UITextSpellCheckingType.no
        public var smartQuotesType = UITextSmartQuotesType.no
        public var smartDashesType = UITextSmartDashesType.no
        public var smartInsertDeleteType = UITextSmartInsertDeleteType.no
        public var inlinePredictionType = UITextInlinePredictionType.no
        public var keyboardType = UIKeyboardType.default
        public var keyboardAppearance = UIKeyboardAppearance.dark
        public var returnKeyType = UIReturnKeyType.default

        static let log = Logger(subsystem: "swiftty", category: "TerminalUIView")

        /// Takes over `session`'s `onUpdate` and `onEvent` callbacks; its
        /// transport (`receive`/`onWrite`) stays with the app. The session's
        /// default palette is replaced by the configuration's for the
        /// current appearance.
        /// - Parameter fontSize: point size overriding the configuration;
        ///   by default its `font-size`, or 13 pt scaled for Dynamic Type
        ///   when it sets none.
        public init(session: TerminalSession, configuration: Configuration = Configuration(), fontSize: CGFloat? = nil) throws {
            self.session = session
            self.configuration = configuration
            explicitFontSize = fontSize
            guard let device = MTLCreateSystemDefaultDevice() else { throw RendererError.setup("no Metal device") }
            let traits = UITraitCollection.current
            let scale = max(traits.displayScale, 1)
            let size = fontSize ?? Self.baseFontSize(configuration, traits)
            renderer = try MetalRenderer(
                device: device, fontManager: CoreTextFontManager(),
                font: configuration.fontDescriptor(scale: scale, size: Double(size)),
            )
            super.init(frame: .zero, device: device)
            colorPixelFormat = .bgra8Unorm
            framebufferOnly = true
            isPaused = true
            enableSetNeedsDisplay = true
            autoResizeDrawable = true
            delegate = self
            contentScaleFactor = scale
            applyRenderOptions()
            applyTranslucency()
            loadShader()

            session.onUpdate = { [weak self] in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.setNeedsDisplay() } }
            }
            session.onEvent = { [weak self] event in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(event) } }
            }

            installGestures()
            isAccessibilityElement = true
            accessibilityLabel = "Terminal"
            accessibilityTraits = [.causesPageTurn, .allowsDirectInteraction]

            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(keyboardFrameChanged(_:)),
                name: UIResponder.keyboardWillChangeFrameNotification,
                object: nil,
            )
            center.addObserver(
                self,
                selector: #selector(keyboardFrameChanged(_:)),
                name: UIResponder.keyboardWillHideNotification,
                object: nil,
            )
            center.addObserver(
                self,
                selector: #selector(voiceOverChanged),
                name: UIAccessibility.voiceOverStatusDidChangeNotification,
                object: nil,
            )
            registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitDisplayScale.self]) { (view: TerminalUIView, _) in
                view.applyFont()
            }
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: TerminalUIView, _) in
                view.applyColorScheme()
            }
            applyColorScheme()
        }

        @available(*, unavailable) required init(coder: NSCoder) {
            fatalError()
        }

        private func handle(_ event: TerminalEvent) {
            switch event {
            case let .title(title): onTitle?(title)
            case .bell: UIImpactFeedbackGenerator(style: .light, view: self).impactOccurred()
            case let .clipboard(text): UIPasteboard.general.string = text
            case .exited: onExit?()
            case let .pointerShape(name):
                pointerShapeName = name
                pointerInteraction?.invalidate()
            default: break
            }
        }

        // MARK: Configuration

        /// Applies a new configuration (font, colors, render options,
        /// shader) to the running view.
        public func apply(_ configuration: Configuration) {
            self.configuration = configuration
            keyCommandCache = nil
            colorScheme = nil
            applyColorScheme()
            applyTranslucency()
            loadShader()
            applyFont()
        }

        private func loadShader() {
            var source: String?
            if let path = configuration.customShader {
                do {
                    source = try String(contentsOfFile: path, encoding: .utf8)
                } catch {
                    Self.log.error("custom-shader \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            do {
                try renderer.setPostProcessShader(source)
            } catch {
                Self.log.error("custom-shader failed to compile: \(String(describing: error), privacy: .public)")
                try? renderer.setPostProcessShader(nil)
            }
            updateFrameDriving()
        }

        /// The configuration's options with the view's own state kept.
        private func applyRenderOptions() {
            let current = renderer.options
            var options = configuration.renderOptions(scale: contentScaleFactor)
            options.isFocused = current.isFocused
            options.preedit = current.preedit
            options.hoveredLink = current.hoveredLink
            options.underlinedSpan = current.underlinedSpan
            options.cursorVisible = blink.cursorVisible
            options.textBlinkVisible = blink.textVisible
            renderer.options = options
        }

        private var isTranslucent: Bool {
            configuration.backgroundOpacity < 1
        }

        private func applyTranslucency() {
            isOpaque = !isTranslucent
            layer.isOpaque = !isTranslucent
            lastBackground = nil // recolor on the next frame
            backgroundColor = isTranslucent ? .clear : .black
            setNeedsDisplay()
        }

        /// Palette and mode 2031 report for the current appearance.
        func applyColorScheme() {
            let scheme: ColorScheme = traitCollection.userInterfaceStyle == .light ? .light : .dark
            keyboardAppearance = scheme == .light ? .light : .dark
            guard scheme != colorScheme else { return }
            colorScheme = scheme
            let palette = configuration.palette(for: scheme)
            session.mutateAsync { state in
                state.setDefaultPalette(palette)
                state.setColorScheme(scheme)
            }
        }

        // MARK: Layout

        /// Maps view points to grid cells with the current font.
        var geometry: GridGeometry {
            GridGeometry(
                scale: contentScaleFactor,
                padding: CGPoint(x: renderer.options.paddingX, y: renderer.options.paddingY),
                cellSize: renderer.cellSize,
            )
        }

        override public func layoutSubviews() {
            super.layoutSubviews()
            updateGrid()
        }

        override public func didMoveToWindow() {
            super.didMoveToWindow()
            let center = NotificationCenter.default
            center.removeObserver(self, name: UIScene.didEnterBackgroundNotification, object: nil)
            center.removeObserver(self, name: UIScene.willEnterForegroundNotification, object: nil)
            guard let scene = window?.windowScene else {
                stopMomentum()
                stopKeyRepeat()
                stopBlinking()
                return
            }
            center.addObserver(
                self,
                selector: #selector(sceneDidEnterBackground),
                name: UIScene.didEnterBackgroundNotification,
                object: scene,
            )
            center.addObserver(
                self,
                selector: #selector(sceneWillEnterForeground),
                name: UIScene.willEnterForegroundNotification,
                object: scene,
            )
            isRenderingPaused = scene.activationState == .background
            applyFont()
            updateFrameDriving()
        }

        @objc private func sceneDidEnterBackground() {
            isRenderingPaused = true
            stopMomentum()
            stopKeyRepeat()
            stopBlinking()
            updateFrameDriving()
        }

        @objc private func sceneWillEnterForeground() {
            isRenderingPaused = false
            updateFrameDriving()
            setNeedsDisplay() // updates that arrived meanwhile are still pending
        }

        /// Follows the docked keyboard: rows it covers leave the grid. A
        /// floating or undocked keyboard covers nothing.
        @objc private func keyboardFrameChanged(_ notification: Notification) {
            var inset: CGFloat = 0
            if notification.name != UIResponder.keyboardWillHideNotification,
               let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
               let screen = window?.windowScene?.screen {
                let local = convert(frame, from: screen.coordinateSpace)
                if local.maxY >= bounds.maxY - 1, local.intersects(bounds) {
                    inset = max(0, bounds.maxY - local.minY)
                }
            }
            guard inset != keyboardInset else { return }
            keyboardInset = inset
            updateGrid()
        }

        /// The configured size, or 13 pt scaled for Dynamic Type when the
        /// configuration leaves `font-size` at its default.
        private static func baseFontSize(_ configuration: Configuration, _ traits: UITraitCollection) -> CGFloat {
            if configuration.fontSize != Configuration().fontSize {
                return CGFloat(configuration.fontSize)
            }
            return UIFontMetrics(forTextStyle: .body).scaledValue(for: 13, compatibleWith: traits).rounded()
        }

        public var fontSize: CGFloat {
            explicitFontSize ?? Self.baseFontSize(configuration, traitCollection)
        }

        func applyFont() {
            let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : renderer.font.descriptor.scale
            contentScaleFactor = scale
            let descriptor = configuration.fontDescriptor(scale: scale, size: Double(fontSize))
            if descriptor != renderer.font.descriptor {
                renderer.setFont(descriptor)
            }
            applyRenderOptions() // padding is in pixels
            updateGrid()
            setNeedsDisplay()
        }

        private func updateGrid() {
            let scale = contentScaleFactor
            let pixels = CGSize(width: bounds.width * scale, height: max(0, bounds.height - keyboardInset) * scale)
            guard pixels.width > 0, pixels.height > 0 else { return }
            let size = renderer.gridSize(for: pixels)
            session.setCellPixelSize(width: Int(renderer.cellSize.width), height: Int(renderer.cellSize.height))
            guard size != gridSize else { return }
            gridSize = size
            session.resize(columns: size.columns, rows: size.rows)
        }

        func setFontSize(_ size: CGFloat?) {
            explicitFontSize = size.map { min(max($0, 6), 72) }
            applyFont()
        }

        // MARK: Drawing

        public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        public func draw(in view: MTKView) {
            guard !isRenderingPaused else { return }
            let snapshot = session.snapshot()
            lastModes = snapshot.modes
            lastCursor = snapshot.cursor
            if snapshot.palette.background != lastBackground {
                let rgb = snapshot.palette.background
                lastBackground = rgb
                let color = UIColor(
                    red: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255,
                    alpha: CGFloat(configuration.backgroundOpacity),
                )
                if !isTranslucent {
                    backgroundColor = color
                }
                onBackgroundColor?(color)
            }
            renderer.draw(snapshot, in: self)
            cursorBlinks = configuration.cursorStyleBlink ?? snapshot.cursor.isBlinking
            updateBlinkTimer()
            if UIAccessibility.isVoiceOverRunning {
                let text = AccessibilityText(snapshot)
                if text != accessibilityScreen {
                    accessibilityScreen = text
                    accessibilityValue = text.lines.indices.contains(text.cursorLine) ? text.lines[text.cursorLine] : nil
                    postAccessibilityChange()
                }
            }
        }

        /// An animated custom shader draws every display frame; otherwise
        /// frames are drawn only on demand.
        private func updateFrameDriving() {
            let animate = renderer.isAnimating && !isRenderingPaused && window != nil
            enableSetNeedsDisplay = !animate
            isPaused = !animate
        }

        // MARK: Blinking

        /// Starts or stops the blink timer to match what is on screen.
        func updateBlinkTimer() {
            let needed = BlinkState.needsTimer(
                cursorBlinks: cursorBlinks, textBlinks: renderer.hasBlinkingText,
                focused: renderer.options.isFocused, background: isRenderingPaused,
            )
            if needed, blinkTimer == nil {
                blinkTimer = Timer.scheduledTimer(withTimeInterval: BlinkState.interval, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.blinkTick() }
                }
            } else if !needed, blinkTimer != nil {
                stopBlinking()
            }
        }

        private func blinkTick() {
            blink.tick(cursorBlinks: cursorBlinks && renderer.options.isFocused, textBlinks: renderer.hasBlinkingText)
            showBlinkPhase()
        }

        private func showBlinkPhase() {
            guard renderer.options.cursorVisible != blink.cursorVisible || renderer.options.textBlinkVisible != blink.textVisible
            else { return }
            renderer.options.cursorVisible = blink.cursorVisible
            renderer.options.textBlinkVisible = blink.textVisible
            setNeedsDisplay()
        }

        func stopBlinking() {
            blinkTimer?.invalidate()
            blinkTimer = nil
            blink.reset()
            showBlinkPhase()
        }

        /// Input shows the cursor and restarts its phase.
        func noteInput() {
            guard blinkTimer != nil else { return }
            stopBlinking()
            updateBlinkTimer()
        }

        // MARK: Accessibility notifications

        @objc private func voiceOverChanged() {
            accessibilityScreen = nil
            setNeedsDisplay()
        }

        /// Tells VoiceOver the screen changed, at most twice a second.
        private func postAccessibilityChange() {
            let now = CACurrentMediaTime()
            let wait = 0.5 - (now - lastAccessibilityPost)
            guard wait > 0 else {
                lastAccessibilityPost = now
                UIAccessibility.post(notification: .layoutChanged, argument: nil)
                return
            }
            guard !accessibilityPostPending else { return }
            accessibilityPostPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.accessibilityPostPending = false
                    self.lastAccessibilityPost = CACurrentMediaTime()
                    UIAccessibility.post(notification: .layoutChanged, argument: nil)
                }
            }
        }
    }
#endif
