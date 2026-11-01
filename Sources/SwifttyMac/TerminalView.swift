import AppKit
import MetalKit
import QuartzCore
import SwifttyCore

/// An MTKView that renders a session on demand at the display refresh rate.
/// Standalone view input has a 64 KiB admission budget; refusal beeps rather
/// than accumulating unbounded pending input. Explicit transport backends keep
/// their admission policy. Public `session.send` retains its embedding contract.
@MainActor
public final class TerminalView: MTKView, MTKViewDelegate {
  private static let surfaces = NSHashTable<TerminalView>.weakObjects()
  public let session: TerminalSession
  let renderer: MetalRenderer
  /// The configuration as presented (`DisplayAccommodations` applied).
  private(set) var config: Configuration
  /// The configuration as given, restored when a preference turns off.
  private var configured: Configuration
  /// Manual zoom, or nil to follow the configured point size.
  private var explicitFontSize: CGFloat?
  var fontSize: CGFloat {
    explicitFontSize ?? CGFloat(Configuration.boundedFontSize(config.fontSize))
  }

  /// Modes of the last drawn frame, as `capabilities` lets the view act
  /// on them (mouse tracking is masked without mouse reporting).
  var lastModes: Modes = .initial
  let pointer = TerminalPointer()
  var scrollAccumulator: ScrollAccumulator { pointer.vertical }
  var horizontalScrollAccumulator: ScrollAccumulator { pointer.horizontal }
  var gridSize = (columns: 0, rows: 0)
  /// The last drawn frame: the cursor for the IME candidate window, the
  /// text for accessibility.
  var lastSnapshot: RenderSnapshot?
  var colorScheme: ColorScheme

  typealias SelectionUnit = TerminalPointer.SelectionUnit
  var selectionUnit = SelectionUnit.cell
  /// Span the gesture started on (one cell, word or line).
  var selectionOrigin:
    (start: TerminalPoint, end: TerminalPoint, generation: UInt64)?
  var selectionDragged = false
  /// Later drag/release reports belong to the terminal only when it
  /// received this gesture's initial press.
  var reportsLeftMouseGesture: Bool {
    get { pointer.reportsLeftGesture }
    set { pointer.reportsLeftGesture = newValue }
  }
  var hasSelection = false
  var pasteboard = NSPasteboard.general
  /// What this surface offers for its session (`.full` by default; a
  /// remote presentation uses `.roaming`). Unavailable actions are hidden
  /// or disabled: program clipboard writes (OSC 52), link opening, search,
  /// scrollback, mouse reporting, paste and local terminal resets.
  public var capabilities = SurfaceCapabilities.full {
    didSet { capabilitiesChanged() }
  }
  /// Where the last click landed, for "Select Command Output".
  var lastClick: (point: TerminalPoint, generation: UInt64)?

  var hoveredLink: TerminalLink?
  var hoverEvent: NSEvent?
  var hoverModifiers: NSEvent.ModifierFlags = []
  var hoverCell: (column: Int, row: Int)?
  /// The pointer the application asked for (OSC 22).
  var applicationCursor = NSCursor.iBeam

  let composition = TerminalComposition()
  var markedText: String { composition.text }
  /// The key event being interpreted, for commands the input system does not handle.
  private let keyboard = TerminalKeyboard()
  var interpretingEvent: NSEvent? {
    get { keyboard.interpretingEvent }
    set { keyboard.interpretingEvent = newValue }
  }
  var heldKeys: [UInt16: KeyEvent] = [:]

  private lazy var display = TerminalDisplay(view: self, renderer: renderer)

  package var searchBar: SearchBar?
  var accessibilityThrottle = NotificationThrottle(interval: 0.5)
  private var lastAccessibilityValue: String?
  private var lastAccessibilityRanges: [NSRange]?
  private var pendingAccessibilityNotifications:
    Set<NSAccessibility.Notification> = []
  /// Screen text for VoiceOver, rebuilt once per snapshot.
  var accessibilityCache = AccessibilityTextCache()

  public var onTitle: ((String) -> Void)?
  public var onExit: (() -> Void)?
  /// Passive terminal events forwarded on the main actor after the view's
  /// built-in handling. Programs may forge these; they are not execution receipts.
  public var onTerminalEvent: ((TerminalEvent) -> Void)?

  public convenience init(configuration: Configuration) throws {
    let scheme = Self.scheme(of: NSApp.effectiveAppearance)
    try self.init(
      configuration: configuration,
      session: TerminalSession(
        configuration: configuration.sessionConfiguration(scheme: scheme)
      )
    )
  }

  /// Hosts `session`: a local PTY session to `start()`, an external
  /// transport's, or a presentation session showing remote frames.
  public init(configuration: Configuration, session: TerminalSession) throws {
    configured = configuration
    config = configuration.accommodating(.current)
    colorScheme = Self.scheme(of: NSApp.effectiveAppearance)
    self.session = session
    renderer = try TerminalDisplay.makeRenderer(configuration: configuration)
    super.init(frame: .zero, device: renderer.device)
    TerminalDisplay.prepare(self)
    delegate = self
    applyRenderOptions(scale: 2)
    loadShader()

    session.onUpdate = { [weak self] in
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.needsDisplay = true }
      }
    }
    session.onEvent = { [weak self] event in
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.handle(event) }
      }
    }
    Self.surfaces.add(self)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(systemColorsChanged),
      name: NSColor.systemColorsDidChangeNotification,
      object: nil
    )
    installKittyClipboard()
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(accommodationsChanged),
      name: DisplayAccommodations.didChangeNotification,
      object: nil
    )
  }

  @objc
  private func systemColorsChanged() {
    let palette = config.palette(for: colorScheme)
    session.mutate { $0.setDefaultPalette(palette) }
    needsDisplay = true
  }

  /// Reduce Motion, Reduce Transparency or Increase Contrast changed.
  @objc
  private func accommodationsChanged() { apply(configured) }

  @available(*, unavailable)
  required init(coder: NSCoder) { fatalError() }

  public func start() throws {
    try start(config.sessionConfiguration(scheme: colorScheme))
  }

  /// Starts an exact launch configuration through the complete view lifecycle.
  /// The owner calls this once per session, outside repeated UI updates.
  public func start(_ configuration: SessionConfiguration) throws {
    updateGrid()
    try session.start(configuration)
    display.isStopped = false
    Self.surfaces.add(self)
    session.mutate { $0.setColorScheme(colorScheme) }
    updateFrameDriving()
  }

  public func stop() {
    Self.surfaces.remove(self)
    display.isStopped = true
    resetBlink()
    isPaused = true
    enableSetNeedsDisplay = true
    session.stop()
  }

  public func preferredSize(columns: Int, rows: Int) -> NSSize {
    let scale = renderer.font.descriptor.scale
    let maximum =
      (window?.screen ?? NSScreen.main)?.visibleFrame.size
      ?? NSSize(width: 1024, height: 768)
    return NSSize(
      width: min(
        maximum.width,
        (CGFloat(columns) * renderer.cellSize.width + 2
          * renderer.options.paddingX) / scale
      ),
      height: min(
        maximum.height,
        (CGFloat(rows) * renderer.cellSize.height + 2
          * renderer.options.paddingY) / scale
      ),
    )
  }

  private func handle(_ event: TerminalEvent) {
    switch event {
    case let .title(title): onTitle?(title)
    case .bell: NSSound.beep()
    case let .clipboard(text):
      // Program-initiated writes pass the policy gate (spec §A.7).
      guard capabilities.remoteClipboardWrites else { break }
      pasteboard.clearContents()
      pasteboard.setString(text, forType: .string)
    case .dragAndDrop(.registration): dragAndDropRegistrationChanged()
    case let .pointerShape(name):
      applicationCursor = Self.cursor(named: name)
      window?.invalidateCursorRects(for: self)
    case .exited: onExit?()
    default: break
    }
    onTerminalEvent?(event)
  }

  // MARK: Configuration

  /// Applies a reloaded configuration. The scrollback limit and command
  /// only take effect in new windows.
  public func apply(_ configuration: Configuration) {
    configured = configuration
    let configuration = configuration.accommodating(.current)
    let fontChanged =
      configuration.fontDescriptor(scale: 1) != config.fontDescriptor(scale: 1)
    let paletteChanged =
      configuration.palette(for: colorScheme)
      != config.palette(for: colorScheme)
    config = configuration
    if fontChanged { applyFont() }
    applyRenderOptions(scale: window?.backingScaleFactor ?? 2)
    loadShader()
    if paletteChanged {
      let palette = configuration.palette(for: colorScheme)
      session.mutate { $0.setDefaultPalette(palette) }
    }
    updateGrid()
    if hoverEvent != nil { refreshHover() }
    needsDisplay = true
  }

  /// Replaces the configured options, keeping the ones the view drives
  /// (composition, link hover, blink phase, focus).
  private func applyRenderOptions(scale: CGFloat) {
    display.apply(configuration: config, scale: scale)
  }

  static func merge(
    configured: RenderOptions,
    current: RenderOptions
  ) -> RenderOptions {
    TerminalDisplay.merge(configured: configured, current: current)
  }

  private func loadShader() { display.loadShader(config.customShader) }

  package static func scheme(of appearance: NSAppearance) -> ColorScheme {
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua ? .light : .dark
  }

  public override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    let scheme = Self.scheme(of: effectiveAppearance)
    guard scheme != colorScheme else { return }
    let themeChanges =
      config.palette(for: scheme) != config.palette(for: colorScheme)
    colorScheme = scheme
    let palette = config.palette(for: scheme)
    session.mutate { state in
      if themeChanges { state.setDefaultPalette(palette) }
      state.setColorScheme(scheme)
    }
  }

  // MARK: Layout

  public override func viewWillMove(toWindow newWindow: NSWindow?) {
    if window !== newWindow {
      clearHover()
      discardComposition()
    }
    if let window, window !== newWindow, window.firstResponder === self {
      _ = resignFirstResponder()
    }
    super.viewWillMove(toWindow: newWindow)
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    observeVisibility()
    let center = NotificationCenter.default
    center.removeObserver(
      self,
      name: NSWindow.didBecomeKeyNotification,
      object: nil
    )
    center.removeObserver(
      self,
      name: NSWindow.didResignKeyNotification,
      object: nil
    )
    center.removeObserver(
      self,
      name: NSWindow.didChangeOcclusionStateNotification,
      object: nil
    )
    center.removeObserver(
      self,
      name: NSWindow.didChangeScreenNotification,
      object: nil
    )
    updateFrameDriving()
    guard let window else { return }
    for name in [
      NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
    ] {
      center.addObserver(
        self,
        selector: #selector(windowKeyChanged(_:)),
        name: name,
        object: window
      )
    }
    for name in [
      NSWindow.didChangeOcclusionStateNotification,
      NSWindow.didChangeScreenNotification,
    ] {
      center.addObserver(
        self,
        selector: #selector(windowVisibilityChanged),
        name: name,
        object: window
      )
    }
  }

  public override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    observeVisibility()
    windowVisibilityChanged()
  }

  @objc
  private func windowVisibilityChanged() {
    updateFrameDriving()
    if isSurfaceVisible { needsDisplay = true }
  }

  public override func viewDidHide() {
    super.viewDidHide()
    updateFrameDriving()
  }

  public override func viewDidUnhide() {
    super.viewDidUnhide()
    updateFrameDriving()
    needsDisplay = true
  }

  @objc
  private func windowKeyChanged(_ notification: Notification) {
    if notification.name == NSWindow.didResignKeyNotification { clearHover() }
    // A window keeps its first responder when another window becomes key.
    if window?.firstResponder === self {
      if notification.name == NSWindow.didBecomeKeyNotification {
        submitInput(.focus(true))
      } else {
        _ = resignFirstResponder()
      }
    }
    needsDisplay = true
  }

  public override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    applyRenderOptions(scale: window?.backingScaleFactor ?? 2)
    applyFont()
  }

  public override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    updateGrid()
    searchBar?.position(in: bounds)
    updateFrameDriving()
  }

  func applyFont() {
    let scale = window?.backingScaleFactor ?? 2
    renderer.setFont(
      config.fontDescriptor(scale: scale, size: Double(fontSize))
    )
    updateGrid()
    needsDisplay = true
  }

  func setFontSize(_ size: CGFloat?) {
    explicitFontSize = size.map {
      CGFloat(Configuration.boundedFontSize(Double($0)))
    }
    applyFont()
  }

  func updateGrid() {
    let scale = window?.backingScaleFactor ?? renderer.font.descriptor.scale
    let pixels = CGSize(
      width: bounds.width * scale,
      height: bounds.height * scale
    )
    let size = renderer.gridSize(for: pixels)
    session.setCellPixelSize(
      width: TerminalGeometry.pixelExtent(renderer.cellSize.width),
      height: TerminalGeometry.pixelExtent(renderer.cellSize.height),
    )
    guard size != gridSize else { return }
    gridSize = size
    session.resize(columns: size.columns, rows: size.rows)
  }

  @objc
  public func increaseFontSize(_ sender: Any?) { perform(.increaseFontSize(1)) }

  @objc
  public func decreaseFontSize(_ sender: Any?) { perform(.decreaseFontSize(1)) }

  @objc
  public func resetFontSize(_ sender: Any?) { perform(.resetFontSize) }

  // MARK: Drawing

  public override var needsDisplay: Bool {
    get { super.needsDisplay }
    set {
      if !newValue {
        super.needsDisplay = newValue
        return
      }
      if display.shouldInvalidate() { super.needsDisplay = true }
    }
  }

  public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  public func draw(in view: MTKView) {
    let snapshot = session.snapshot()
    let needsHoverRefresh =
      hoverEvent.map { event in
        !snapshot.damage.isEmpty
          || lastSnapshot?.viewportOffset != snapshot.viewportOffset
          || (hoverCell.map { $0 != cell(for: event) } ?? true)
      } ?? false
    let result = display.submit(
      snapshot,
      focused: window?.isKeyWindow == true && window?.firstResponder === self,
      cursorBlink: config.cursorStyleBlink
    )
    guard result == .submitted else { return }
    lastModes = capabilities.effectiveModes(snapshot.modes)
    lastSnapshot = snapshot
    if needsHoverRefresh { refreshHover() }
    if hasSelection, snapshot.selection == nil {
      hasSelection = false
      selectionOrigin = nil
    }
    postAccessibilityChange()
  }

  private var isSurfaceVisible: Bool { display.isSurfaceVisible }
  private func observeVisibility() { display.observeVisibility() }
  private func updateFrameDriving() { display.updateFrameDriving() }
  func resetBlink() { display.resetBlink() }

  /// Tells VoiceOver the text changed, at most twice a second; a change
  /// inside that window is posted when it ends, so the last output is
  /// never missed.
  private func postAccessibilityChange() {
    guard NSWorkspace.shared.isVoiceOverEnabled else { return }
    requestAccessibilityNotifications(accessibilityChanges()) {
      [weak self] notification in
      guard let self else { return }
      NSAccessibility.post(element: self, notification: notification)
    }
  }

  /// Only text or selection changes need an accessibility notification.
  func accessibilityChanges() -> [NSAccessibility.Notification] {
    let value = accessibilityText?.string ?? ""
    let ranges = accessibilitySelectedTextRanges()?.map(\.rangeValue) ?? []
    var changes: [NSAccessibility.Notification] = []
    if value != lastAccessibilityValue { changes.append(.valueChanged) }
    if ranges != lastAccessibilityRanges {
      changes.append(.selectedTextChanged)
    }
    lastAccessibilityValue = value
    lastAccessibilityRanges = ranges
    return changes
  }

  /// Coalesces each kind of change until the next permitted post.
  func requestAccessibilityNotifications(
    _ changes: [NSAccessibility.Notification],
    post: @escaping @MainActor (NSAccessibility.Notification) -> Void,
  ) {
    guard !changes.isEmpty else { return }
    pendingAccessibilityNotifications.formUnion(changes)
    requestAccessibilityPost { [weak self] in
      guard let self else { return }
      let pending = self.pendingAccessibilityNotifications
      self.pendingAccessibilityNotifications.removeAll(keepingCapacity: true)
      for notification in [
        NSAccessibility.Notification.valueChanged, .selectedTextChanged,
      ] where pending.contains(notification) { post(notification) }
    }
  }

  /// Runs `post` now, or when the throttle window ends.
  func requestAccessibilityPost(_ post: @escaping @MainActor () -> Void) {
    switch accessibilityThrottle.request(at: CACurrentMediaTime()) {
    case .post: post()
    case let .schedule(after: wait):
      DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
        MainActor.assumeIsolated {
          self?.accessibilityThrottle.fire(at: CACurrentMediaTime())
          post()
        }
      }
    case .skip: break
    }
  }

  /// The visible text for VoiceOver, cached per snapshot.
  var accessibilityText: AccessibilityText? {
    lastSnapshot.map { accessibilityCache.text(for: $0) }
  }

  // MARK: Keyboard

  public override var acceptsFirstResponder: Bool { true }

  public override func becomeFirstResponder() -> Bool {
    clearHover()
    if window == nil || window?.isKeyWindow == true {
      submitInput(.focus(true))
    }
    needsDisplay = true
    return true
  }

  public override func resignFirstResponder() -> Bool {
    clearHover()
    releaseHeldKeys()
    submitInput(.focus(false))
    needsDisplay = true
    return true
  }

  func releaseHeldKeys() {
    // Key-up may go to the next responder after focus moves away.
    for var key in heldKeys.values {
      key.action = .release
      submitInput(.key(key))
    }
    heldKeys.removeAll()
  }

  /// Key bindings run before the menu's key equivalents.
  public override func performKeyEquivalent(with event: NSEvent) -> Bool {
    keyboard.keyEquivalent(
      in: self,
      composing: hasMarkedText(),
      binding: binding(for: event),
      perform: performBinding,
      sendUnbound: { handleTerminalInput(event) }
    ) ?? super.performKeyEquivalent(with: event)
  }

  @discardableResult
  func submitInput(_ input: TerminalInput) -> Bool {
    guard session.submitViewInput(input) else {
      NSSound.beep()
      return false
    }
    return true
  }

  public override func keyDown(with event: NSEvent) {
    resetBlink()
    if keyboard.consumesKeyDown(
      hideMouse: config.mouseHideWhileTyping,
      composing: hasMarkedText(),
      binding: binding(for: event),
      perform: performBinding
    ) {
      return
    }
    handleTerminalInput(event)
  }

  private func handleTerminalInput(_ event: NSEvent) {
    guard capabilities.textInput else { return }
    clearSelection()
    keyboard.interpret(event, in: self, composing: hasMarkedText()) {
      sendKey(event)
    }
  }

  public override func keyUp(with event: NSEvent) {
    if var key = heldKeys.removeValue(forKey: event.keyCode) {
      key.action = .release
      submitInput(.key(key))
    }
  }

  private func binding(for event: NSEvent) -> Keybindings.Binding? {
    Self.trigger(for: event).flatMap { config.keybindings.binding(for: $0) }
  }

  private func performBinding(_ binding: Keybindings.Binding) -> Bool {
    guard binding.appliesToAll else { return perform(binding.action) }
    let surfaces = Self.surfaces.allObjects
    for surface in surfaces { surface.perform(binding.action) }
    return !surfaces.isEmpty
  }

  /// The key and modifiers a binding is matched against.
  package static func trigger(for event: NSEvent) -> KeyEvent? {
    guard
      let key = specialKeys[event.keyCode]
        ?? event.charactersIgnoringModifiers?.unicodeScalars.first
        .map(Key.character)
    else { return nil }
    return KeyEvent(key, modifiers: modifiers(event.modifierFlags))
  }

  /// Sends keys the terminal encodes itself (specials, control
  /// combinations); returns false for text, which goes through the
  /// input method.
  func sendKey(_ event: NSEvent) -> Bool {
    guard capabilities.textInput else { return true }
    let flags =
      !event.modifierFlags.isDisjoint(with: [.command, .control])
      ? session.keyboardFlags : 0
    guard let key = Self.terminalKey(for: event, keyboardFlags: flags) else {
      return false
    }
    sendHardwareKey(key, event: event)
    return true
  }

  func sendHardwareKey(_ key: KeyEvent, event: NSEvent) {
    guard capabilities.textInput else { return }
    var key = key
    key.action = event.isARepeat ? .repeat : .press
    if submitInput(.key(key)) { heldKeys[event.keyCode] = key }
  }

  /// The key event for keys the terminal encodes itself, or nil for text.
  static func terminalKey(
    for event: NSEvent,
    keyboardFlags: UInt8 = 0
  ) -> KeyEvent? {
    let mods = modifiers(event.modifierFlags)
    let kittyActive = InputEncoder.isKittyKeyboardActive(keyboardFlags)
    if let key = specialKeys[event.keyCode] {
      return KeyEvent(key, modifiers: mods)
    }
    // AppKit's charactersIgnoringModifiers retains Shift. Translate without
    // modifiers using the active layout so punctuation keeps its base key.
    let base =
      kittyActive
      ? event.characters(byApplyingModifiers: [])
      : event.charactersIgnoringModifiers
    if mods.contains(.control) || kittyActive,
      let scalar = base?.unicodeScalars.first
    {
      return KeyEvent(
        .character(scalar),
        modifiers: kittyActive ? mods : mods.subtracting(.shift),
        action: event.isARepeat ? .repeat : .press,
        text: event.characters,
        shiftedKey: mods.contains(.shift)
          ? event.characters(byApplyingModifiers: [.shift])?.unicodeScalars
            .first : nil,
        baseLayoutKey: usLayout[event.keyCode],
      )
    }
    return nil
  }

  static func modifiers(_ flags: NSEvent.ModifierFlags) -> KeyModifiers {
    var mods: KeyModifiers = []
    if flags.contains(.shift) { mods.insert(.shift) }
    if flags.contains(.control) { mods.insert(.control) }
    if flags.contains(.option) { mods.insert(.alt) }
    if flags.contains(.command) { mods.insert(.command) }
    if flags.contains(.capsLock) { mods.insert(.capsLock) }
    return mods
  }

  package static let specialKeys: [UInt16: Key] = [
    36: .enter, 76: .keypad(.enter), 48: .tab, 51: .backspace, 53: .escape,
    123: .left, 124: .right, 125: .down, 126: .up, 115: .home, 119: .end,
    116: .pageUp, 121: .pageDown, 117: .delete, 114: .insert, 122: .function(1),
    120: .function(2), 99: .function(3), 118: .function(4), 96: .function(5),
    97: .function(6), 98: .function(7), 100: .function(8), 101: .function(9),
    109: .function(10), 103: .function(11), 111: .function(12),
    // Mac keypads have no NumLock: their keys always type.
    82: .keypad(.zero), 83: .keypad(.one), 84: .keypad(.two),
    85: .keypad(.three), 86: .keypad(.four), 87: .keypad(.five),
    88: .keypad(.six), 89: .keypad(.seven), 91: .keypad(.eight),
    92: .keypad(.nine), 65: .keypad(.decimal), 75: .keypad(.divide),
    67: .keypad(.multiply), 78: .keypad(.subtract), 69: .keypad(.add),
    81: .keypad(.equal),
  ]

  /// Keys of the US layout by virtual key code (kitty's base layout key).
  static let usLayout: [UInt16: Unicode.Scalar] = {
    let keys: [(UInt16, Unicode.Scalar)] = [
      (0, "a"), (11, "b"), (8, "c"), (2, "d"), (14, "e"), (3, "f"), (5, "g"),
      (4, "h"), (34, "i"), (38, "j"), (40, "k"), (37, "l"), (46, "m"),
      (45, "n"), (31, "o"), (35, "p"), (12, "q"), (15, "r"), (1, "s"),
      (17, "t"), (32, "u"), (9, "v"), (13, "w"), (7, "x"), (16, "y"), (6, "z"),
      (29, "0"), (18, "1"), (19, "2"), (20, "3"), (21, "4"), (23, "5"),
      (22, "6"), (26, "7"), (28, "8"), (25, "9"), (27, "-"), (24, "="),
      (33, "["), (30, "]"), (42, "\\"), (41, ";"), (39, "'"), (43, ","),
      (47, "."), (44, "/"), (50, "`"),
    ]
    return Dictionary(uniqueKeysWithValues: keys)
  }()

  private static let hiddenPointerCursor = NSCursor(
    image: NSImage(size: NSSize(width: 1, height: 1), flipped: false) { _ in
      true
    },
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
