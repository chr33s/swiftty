#if canImport(UIKit)
import MetalKit
import os
import SwifttyCore
import UIKit

/// Renders a session and routes touch, pointer, keyboard, and resize events.
/// Draws on demand while active; blinking and animated shaders request extra
/// frames.
@MainActor
public final class TerminalUIView: MTKView, MTKViewDelegate {
  private static let surfaces = NSHashTable<TerminalUIView>.weakObjects()
  public let session: TerminalSession
  public private(set) var configuration: Configuration
  let renderer: MetalRenderer
  private lazy var redraw = DisplayDrawScheduler { [weak self] in
    self?.drawPendingFrame()
  }
  private var drewFrame = false
  private var submittedFrame: UInt64 = 0
  private var visibilityObservers: [NSKeyValueObservation] = []
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
  private var isSceneActive = true
  private var reportedFocus = false
  /// Appearance last reported to the terminal (mode 2031) and used
  /// for the palette.
  private var colorScheme: ColorScheme?
  /// Last configured palette, separate from application OSC overrides.
  private var configuredPalette: Palette?

  var sticky = StickyModifiers()
  private(set) var loadedAccessoryBar: TerminalAccessoryBar?
  var accessoryBar: TerminalAccessoryBar {
    if let bar = loadedAccessoryBar { return bar }
    let bar = TerminalAccessoryBar()
    bar.onKey = { [weak self] key in self?.accessoryKey(key) }
    bar.onDismiss = { [weak self] in _ = self?.resignFirstResponder() }
    loadedAccessoryBar = bar
    return bar
  }

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
  /// HID usage owning the repeat timer; other releases leave it running.
  var keyRepeatUsage: Int?
  /// Key commands and their actions, keyed by unique issued identifiers.
  var keyCommandCache: [UIKeyCommand]?
  var keyCommandBindings: [String: Keybindings.Binding] = [:]
  /// Defaults to the system clipboard; tests can use a local pasteboard.
  var pasteboard = UIPasteboard.general

  enum SelectionUnit { case cell, word, line }
  var selectionUnit = SelectionUnit.cell
  /// Span the gesture started on (one cell, word or line).
  var selectionOrigin:
    (start: TerminalPoint, end: TerminalPoint, generation: UInt64)?
  var hasSelection = false
  /// Whether the active pointer drag reported its initial press.
  var reportsPointerMouseGesture = false
  lazy var editMenu = UIEditMenuInteraction(delegate: self)
  lazy var searchBar: TerminalSearchBar = makeSearchBar()
  var isSearchVisible = false

  var scrollAccumulator = ScrollAccumulator()
  var horizontalScrollAccumulator = ScrollAccumulator()
  var momentum = ScrollMomentum()
  var horizontalMomentum = ScrollMomentum()
  var momentumLink: CADisplayLink?
  /// The previous callback's presentation target, so missed callbacks
  /// still count toward the fling's elapsed time.
  var momentumTimestamp: CFTimeInterval?
  /// Where the fling started, for wheel events it reports.
  var momentumPoint = CGPoint.zero
  var momentumModifiers: KeyModifiers = []
  var pinchStartSize: CGFloat = 0

  /// Pointer.
  /// Last cell the pointer hovered over.
  var hoverCell: (column: Int, row: Int)?
  var hoverPoint: CGPoint?
  var hoverModifiers: KeyModifiers = []
  var hoverModes: Modes?
  var hoverViewportOffset: Int?
  var hoverGeometry: GridGeometry?
  /// The pointer is over a link.
  var overLink = false
  /// OSC 22 shape the application asked for; empty for the default.
  var pointerShapeName = ""
  var pointerInteraction: UIPointerInteraction?

  private var blink = BlinkState()
  private var blinkTimer: Timer?
  /// The cursor blinks (DECSCUSR / mode 12, or `cursor-style-blink`).
  private var cursorBlinks = false

  /// Accessibility.
  /// UIKit's text-input defaults must not turn the container into a
  /// single element that hides its reading element and find controls.
  override public var isAccessibilityElement: Bool {
    get { false }
    set {}
  }

  override public var isHidden: Bool {
    didSet {
      updateFrameDriving()
      if !isHidden { setNeedsDisplay() }
    }
  }

  /// Screen text for VoiceOver; kept only while VoiceOver runs.
  var accessibilityScreen: AccessibilityText?
  lazy var accessibilityTerminal = TerminalAccessibilityElement(terminal: self)
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

  /// Installs view callbacks and the configured palette on the session.
  /// - Parameters:
  ///   - session: Connected terminal session.
  ///   - configuration: Font, appearance, and input settings.
  ///   - fontSize: Point-size override; nil follows configuration or Dynamic Type.
  /// - Throws: Renderer setup errors, including unavailable Metal.
  public init(
    session: TerminalSession,
    configuration: Configuration = Configuration(),
    fontSize: CGFloat? = nil
  ) throws {
    self.session = session
    self.configuration = configuration
    let overrideSize = fontSize.map(Self.boundedFontSize)
    explicitFontSize = overrideSize
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw RendererError.setup("no Metal device")
    }
    let traits = UITraitCollection.current
    let scale = max(traits.displayScale, 1)
    let size = overrideSize ?? Self.baseFontSize(configuration, traits)
    renderer = try MetalRenderer(
      device: device,
      fontManager: CoreTextFontManager(),
      font: configuration.fontDescriptor(scale: scale, size: Double(size)),
    )
    super.init(frame: .zero, device: device)
    colorPixelFormat = .bgra8Unorm
    framebufferOnly = true
    isPaused = true
    enableSetNeedsDisplay = false
    autoResizeDrawable = true
    delegate = self
    renderer.options.isFocused = false
    contentScaleFactor = scale
    applyRenderOptions()
    applyTranslucency()
    loadShader()

    session.onUpdate = { [weak self] in
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.setNeedsDisplay() }
      }
    }
    session.onEvent = { [weak self] event in
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.handle(event) }
      }
    }

    installGestures()
    Self.surfaces.add(self)
    accessibilityLabel = "Terminal"
    accessibilityTraits = [.causesPageTurn, .allowsDirectInteraction]
    updateAccessibilityElements()

    let center = NotificationCenter.default
    #if !os(visionOS)
    // The visionOS keyboard occupies its own window and does
    // not send these screen-coordinate notifications.
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
    #endif
    center.addObserver(
      self,
      selector: #selector(voiceOverChanged),
      name: UIAccessibility.voiceOverStatusDidChangeNotification,
      object: nil,
    )
    registerForTraitChanges([
      UITraitPreferredContentSizeCategory.self, UITraitDisplayScale.self,
    ]) { (view: TerminalUIView, _) in view.applyFont() }
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
      (view: TerminalUIView, _) in view.applyColorScheme()
    }
    applyColorScheme()
  }

  func performBinding(_ binding: Keybindings.Binding) -> Bool {
    guard binding.appliesToAll else { return perform(binding.action) }
    let surfaces = Self.surfaces.allObjects
    for surface in surfaces { surface.perform(binding.action) }
    return !surfaces.isEmpty
  }

  @available(*, unavailable)
  required init(coder: NSCoder) { fatalError() }

  private func handle(_ event: TerminalEvent) {
    switch event {
    case let .title(title): onTitle?(title) #if !os(visionOS)
    case .bell:
      UIImpactFeedbackGenerator(style: .light, view: self).impactOccurred()
    #endif
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
    keyCommandBindings.removeAll()
    applyColorScheme()
    applyTranslucency()
    loadShader()
    applyFont()
  }

  private func loadShader() {
    var source: String?
    if let path = configuration.customShader {
      do { source = try String(contentsOfFile: path, encoding: .utf8) } catch {
        Self.log.error(
          "custom-shader \(path, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
      }
    }
    do { try renderer.setPostProcessShader(source) } catch {
      Self.log.error(
        "custom-shader failed to compile: \(String(describing: error), privacy: .public)"
      )
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
    options.preeditSelection = current.preeditSelection
    options.hoveredLink = current.hoveredLink
    options.underlinedSpan = current.underlinedSpan
    options.cursorVisible = blink.cursorVisible
    options.textBlinkVisible = blink.textVisible
    renderer.options = options
    if let point = hoverPoint { refreshHoveredLink(at: point) }
  }

  private var isTranslucent: Bool { configuration.backgroundOpacity < 1 }

  private func applyTranslucency() {
    isOpaque = !isTranslucent
    layer.isOpaque = !isTranslucent
    lastBackground = nil  // recolor on the next frame
    backgroundColor = isTranslucent ? .clear : .black
    setNeedsDisplay()
  }

  /// Palette and mode 2031 report for the current appearance.
  func applyColorScheme() {
    let scheme: ColorScheme =
      traitCollection.userInterfaceStyle == .light ? .light : .dark
    keyboardAppearance = scheme == .light ? .light : .dark
    let palette = configuration.palette(for: scheme)
    let paletteChanged = palette != configuredPalette
    guard scheme != colorScheme || paletteChanged else { return }
    colorScheme = scheme
    configuredPalette = palette
    session.mutateAsync { state in
      if paletteChanged { state.setDefaultPalette(palette) }
      state.setColorScheme(scheme)
    }
  }

  // MARK: Layout

  /// Maps view points to grid cells with the current font.
  var geometry: GridGeometry {
    GridGeometry(
      scale: contentScaleFactor,
      padding: CGPoint(
        x: renderer.options.paddingX,
        y: renderer.options.paddingY
      ),
      cellSize: renderer.cellSize,
    )
  }

  override public func layoutSubviews() {
    super.layoutSubviews()
    if isSearchVisible {
      searchBar.position(in: safeAreaLayoutGuide.layoutFrame)
    }
    updateGrid()
    updateFrameDriving()
  }

  override public func didMoveToWindow() {
    super.didMoveToWindow()
    observeVisibility()
    let center = NotificationCenter.default
    center.removeObserver(
      self,
      name: UIScene.didEnterBackgroundNotification,
      object: nil
    )
    center.removeObserver(
      self,
      name: UIScene.willEnterForegroundNotification,
      object: nil
    )
    center.removeObserver(
      self,
      name: UIScene.willDeactivateNotification,
      object: nil
    )
    center.removeObserver(
      self,
      name: UIScene.didActivateNotification,
      object: nil
    )
    center.removeObserver(
      self,
      name: UIWindow.didBecomeKeyNotification,
      object: nil
    )
    center.removeObserver(
      self,
      name: UIWindow.didResignKeyNotification,
      object: nil
    )
    if let window {
      center.addObserver(
        self,
        selector: #selector(windowKeyChanged),
        name: UIWindow.didBecomeKeyNotification,
        object: window
      )
      center.addObserver(
        self,
        selector: #selector(windowKeyChanged),
        name: UIWindow.didResignKeyNotification,
        object: window
      )
    }
    isSceneActive =
      window?.windowScene.map { $0.activationState == .foregroundActive }
      ?? true
    isRenderingPaused = window?.windowScene?.activationState == .background
    updateFocus()
    updateFrameDriving()
    guard let scene = window?.windowScene else {
      stopMomentum()
      releaseHardwareKeys()
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
    center.addObserver(
      self,
      selector: #selector(sceneWillDeactivate),
      name: UIScene.willDeactivateNotification,
      object: scene
    )
    center.addObserver(
      self,
      selector: #selector(sceneDidActivate),
      name: UIScene.didActivateNotification,
      object: scene
    )
    applyFont()
  }

  @objc
  func sceneDidEnterBackground() {
    isRenderingPaused = true
    isSceneActive = false
    updateFocus()
    stopMomentum()
    releaseHardwareKeys()
    stopBlinking()
    updateFrameDriving()
  }

  @objc
  func sceneWillEnterForeground() {
    isRenderingPaused = false
    updateFrameDriving()
    setNeedsDisplay()  // updates that arrived meanwhile are still pending
  }

  @objc
  func sceneWillDeactivate() {
    isSceneActive = false
    updateFocus()
  }

  @objc
  func sceneDidActivate() {
    isRenderingPaused = false
    isSceneActive = true
    updateFocus()
    updateFrameDriving()
    setNeedsDisplay()
  }

  @objc
  private func windowKeyChanged() {
    updateFrameDriving()
    updateFocus()
  }

  /// UIKit can retain its responder while the scene is inactive.
  /// Report the terminal's effective focus once for each transition.
  func updateFocus() {
    let focused =
      isFirstResponder && window?.isKeyWindow == true && isSceneActive
      && !isRenderingPaused
    guard focused != reportedFocus else { return }
    if !focused {
      releaseHardwareKeys()
      stopBlinking()
    }
    reportedFocus = focused
    renderer.options.isFocused = focused
    session.send(.focus(focused))
    updateBlinkTimer()
    setNeedsDisplay()
  }

  #if !os(visionOS)
  /// Follows the docked keyboard: rows it covers leave the grid. A
  /// floating or undocked keyboard covers nothing.
  @objc
  private func keyboardFrameChanged(_ notification: Notification) {
    // Keyboard notifications are global, including those for
    // windows on a different display.
    if let screen = notification.object as? UIScreen,
      let windowScreen = window?.windowScene?.screen, screen !== windowScreen
    {
      return
    }
    var inset: CGFloat = 0
    if notification.name != UIResponder.keyboardWillHideNotification,
      let frame =
        (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey]
        as? NSValue)?
        .cgRectValue, let screen = window?.windowScene?.screen
    {
      let local = convert(frame, from: screen.coordinateSpace)
      if local.maxY >= bounds.maxY - 1, local.intersects(bounds) {
        inset = max(0, bounds.maxY - local.minY)
      }
    }
    guard inset != keyboardInset else { return }
    keyboardInset = inset
    updateGrid()
  }
  #endif

  /// The configured size, or 13 pt scaled for Dynamic Type when the
  /// configuration leaves `font-size` at its default.
  private static func baseFontSize(
    _ configuration: Configuration,
    _ traits: UITraitCollection
  ) -> CGFloat {
    if configuration.fontSize != Configuration().fontSize {
      return boundedFontSize(CGFloat(configuration.fontSize))
    }
    return boundedFontSize(
      UIFontMetrics(forTextStyle: .body)
        .scaledValue(for: 13, compatibleWith: traits).rounded()
    )
  }

  private static func boundedFontSize(_ size: CGFloat) -> CGFloat {
    CGFloat(Configuration.boundedFontSize(Double(size)))
  }

  public var fontSize: CGFloat {
    explicitFontSize ?? Self.baseFontSize(configuration, traitCollection)
  }

  func applyFont() {
    let scale =
      traitCollection.displayScale > 0
      ? traitCollection.displayScale : renderer.font.descriptor.scale
    contentScaleFactor = scale
    let descriptor = configuration.fontDescriptor(
      scale: scale,
      size: Double(fontSize)
    )
    if descriptor != renderer.font.descriptor { renderer.setFont(descriptor) }
    applyRenderOptions()  // padding is in pixels
    updateGrid()
    setNeedsDisplay()
  }

  private func updateGrid() {
    let scale = contentScaleFactor
    let pixels = CGSize(
      width: bounds.width * scale,
      height: max(0, bounds.height - keyboardInset) * scale
    )
    guard pixels.width > 0, pixels.height > 0 else { return }
    let size = renderer.gridSize(for: pixels)
    session.setCellPixelSize(
      width: TerminalGeometry.pixelExtent(renderer.cellSize.width),
      height: TerminalGeometry.pixelExtent(renderer.cellSize.height),
    )
    guard size != gridSize else { return }
    gridSize = size
    session.resize(columns: size.columns, rows: size.rows)
  }

  func setFontSize(_ size: CGFloat?) {
    stopMomentum()
    explicitFontSize = size.map(Self.boundedFontSize)
    applyFont()
  }

  // MARK: Drawing

  override public func setNeedsDisplay() { requestRedraw() }

  override public func setNeedsDisplay(_ rect: CGRect) { requestRedraw() }

  private func requestRedraw() {
    // A layer animation can make a transparent surface visible without changing its model alpha.
    if !redraw.isActive, isPaused, !isRenderingPaused,
      surfaceVisibility != .hidden
    {
      updateFrameDriving()
    }
    redraw.request()
  }

  private func drawPendingFrame() {
    guard isSurfaceVisible, !isRenderingPaused else {
      updateFrameDriving()
      redraw.request()
      return
    }
    // Once a fade becomes visible, an animated shader resumes continuous drawing.
    if renderer.isAnimating, isPaused { updateFrameDriving() }
    drewFrame = false
    draw()
    if !drewFrame { redraw.request() }
  }

  public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  public func draw(in view: MTKView) {
    guard !isRenderingPaused else { return }
    let surfaceVisible = isSurfaceVisible
    let snapshot = session.snapshot()
    let modesChanged = lastModes != snapshot.modes
    lastModes = snapshot.modes
    if modesChanged { pointerInteraction?.invalidate() }
    if let point = hoverPoint,
      modesChanged || !snapshot.damage.isEmpty
        || hoverViewportOffset != snapshot.viewportOffset
        || hoverGeometry != geometry
    {
      refreshHoveredLink(at: point)
    }
    hoverViewportOffset = snapshot.viewportOffset
    hoverGeometry = geometry
    lastCursor = snapshot.cursor
    if hasSelection, snapshot.selection == nil {
      hasSelection = false
      selectionOrigin = nil
    }
    if isSearchVisible {
      searchBar.showCount(
        selected: snapshot.searchSelectedIndex,
        total: snapshot.searchMatchCount
      )
    }
    if snapshot.palette.background != lastBackground {
      let rgb = snapshot.palette.background
      lastBackground = rgb
      let color = UIColor(
        red: CGFloat(rgb >> 16 & 0xFF) / 255,
        green: CGFloat(rgb >> 8 & 0xFF) / 255,
        blue: CGFloat(rgb & 0xFF) / 255,
        alpha: CGFloat(configuration.backgroundOpacity),
      )
      if !isTranslucent { backgroundColor = color }
      onBackgroundColor?(color)
    }
    if surfaceVisible, let drawable = currentDrawable,
      currentRenderPassDescriptor != nil
    {
      submittedFrame &+= 1
      #if !targetEnvironment(simulator)
      let frame = submittedFrame
      // A skipped final frame needs another draw even when output stops.
      drawable.addPresentedHandler { [weak self] drawable in
        guard drawable.presentedTime == 0 else { return }
        DispatchQueue.main.async {
          guard let self, self.submittedFrame == frame else { return }
          self.redraw.request()
        }
      }
      #endif
      renderer.draw(snapshot, in: self)
      drewFrame = true
    }
    cursorBlinks = configuration.cursorStyleBlink ?? snapshot.cursor.isBlinking
    if surfaceVisible { updateBlinkTimer() } else { updateFrameDriving() }
    if UIAccessibility.isVoiceOverRunning {
      let text = AccessibilityText(snapshot)
      if text != accessibilityScreen {
        accessibilityScreen = text
        postAccessibilityChange()
      }
    }
  }

  var isSurfaceVisible: Bool { surfaceVisibility == .visible }

  private enum SurfaceVisibility { case hidden, awaitingOpacity, visible }

  private var surfaceVisibility: SurfaceVisibility {
    guard window != nil, bounds.width > 0, bounds.height > 0 else {
      return .hidden
    }
    var awaitingOpacity = false
    var ancestor: UIView? = self
    while let view = ancestor {
      if view.isHidden { return .hidden }
      if view.alpha <= 0 {
        // Presentation opacity can lag a direct change; keep drawing only during an actual fade.
        guard hasOpacityAnimation(view.layer) else { return .hidden }
        if (view.layer.presentation()?.opacity ?? 0) <= 0 {
          guard hasOpacityAnimation(view.layer, awaitingPresentation: true)
          else { return .hidden }
          awaitingOpacity = true
        }
      }
      ancestor = view.superview
    }
    return awaitingOpacity ? .awaitingOpacity : .visible
  }

  private func hasOpacityAnimation(
    _ layer: CALayer,
    awaitingPresentation: Bool = false
  ) -> Bool {
    layer.animationKeys()?
      .contains { key in
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
            let time =
              (layer.convertTime(CACurrentMediaTime(), from: nil)
                - animation.beginTime) * Double(animation.speed)
              + animation.timeOffset
            let cycles =
              animation.repeatCount > 0 ? Double(animation.repeatCount) : 1
            let duration =
              animation.repeatDuration > 0
              ? animation.repeatDuration
              : animation.duration * (animation.autoreverses ? 2 : 1) * cycles
            if speed > 0 ? time >= duration : time <= 0 { return false }
          }
        }
        return Self.animatesOpacity(animation)
      } ?? false
  }

  private static func animatesOpacity(_ animation: CAAnimation) -> Bool {
    if let property = animation as? CAPropertyAnimation {
      return property.keyPath == "opacity"
    }
    return (animation as? CAAnimationGroup)?.animations?
      .contains(where: animatesOpacity) ?? false
  }

  /// An animated custom shader draws every display frame; otherwise
  /// frames are drawn only on demand.
  private func updateFrameDriving() {
    let visibility = surfaceVisibility
    let active = visibility == .visible && !isRenderingPaused
    let animate = renderer.isAnimating && active
    enableSetNeedsDisplay = false
    #if !os(visionOS)
    preferredFramesPerSecond = window?.screen.maximumFramesPerSecond ?? 60
    #endif
    isPaused = !animate
    redraw.configure(
      active: visibility != .hidden && !isRenderingPaused && !animate,
      framesPerSecond: preferredFramesPerSecond > 0
        ? preferredFramesPerSecond : 60,
    )
    if !active { stopMomentum() }
    updateBlinkTimer()
  }

  private func observeVisibility() {
    visibilityObservers.removeAll()
    let refresh: @Sendable () -> Void = { [weak self] in
      DispatchQueue.main.async {
        guard let self else { return }
        self.observeVisibility()
        self.updateFrameDriving()
        self.setNeedsDisplay()
      }
    }
    visibilityObservers.append(layer.observe(\.opacity) { _, _ in refresh() })
    // Watch layer properties; sublayer changes rebuild the ancestor
    // chain when a container moves within the same window.
    var ancestor = superview
    while let view = ancestor {
      visibilityObservers.append(
        view.layer.observe(\.isHidden) { _, _ in refresh() }
      )
      visibilityObservers.append(
        view.layer.observe(\.opacity) { _, _ in refresh() }
      )
      visibilityObservers.append(
        view.layer.observe(\.sublayers) { _, _ in refresh() }
      )
      ancestor = view.superview
    }
  }

  // MARK: Blinking

  /// Starts or stops the blink timer to match what is on screen.
  func updateBlinkTimer() {
    let needed = BlinkState.needsTimer(
      cursorBlinks: cursorBlinks,
      textBlinks: renderer.hasBlinkingText,
      focused: renderer.options.isFocused,
      background: isRenderingPaused || !isSurfaceVisible,
    )
    if needed, blinkTimer == nil {
      blinkTimer = Timer.scheduledTimer(
        withTimeInterval: BlinkState.interval,
        repeats: true
      ) { [weak self] timer in
        guard let self else {
          timer.invalidate();
          return
        }
        let identity = ObjectIdentifier(timer)
        MainActor.assumeIsolated {
          guard self.blinkTimer.map(ObjectIdentifier.init) == identity else {
            return
          }
          guard self.isSurfaceVisible, !self.isRenderingPaused else {
            self.updateFrameDriving();
            return
          }
          self.blinkTick()
        }
      }
    } else if !needed, blinkTimer != nil {
      stopBlinking()
    }
  }

  private func blinkTick() {
    blink.tick(
      cursorBlinks: cursorBlinks && renderer.options.isFocused,
      textBlinks: renderer.hasBlinkingText
    )
    showBlinkPhase()
  }

  private func showBlinkPhase() {
    guard
      renderer.options.cursorVisible != blink.cursorVisible
        || renderer.options.textBlinkVisible != blink.textVisible
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

  /// Input stops momentum scrolling, shows the cursor, and restarts its phase.
  func noteInput() {
    stopMomentum()
    guard blinkTimer != nil else { return }
    stopBlinking()
    updateBlinkTimer()
  }

  // MARK: Accessibility notifications

  @objc
  private func voiceOverChanged() {
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
