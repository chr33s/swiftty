#if canImport(UIKit)
import SwifttyCore
import UIKit

/// Accessory keys above the software keyboard or below the hardware-keyboard
/// view: Esc, Tab, Ctrl, Alt, Paste, Keys and the directional pad, with
/// iPad keys promoted as width allows (spec.keyboard.md §2).
@MainActor
final class TerminalAccessoryBar: UIInputView, UIInputViewAudioFeedback {
  var onKey: ((AccessoryKey) -> Void)?
  /// Navigate and function keys from the Keys panel: one press each.
  var onDiscreteKey: ((Key) -> Void)?
  var onPaste: (() -> Void)?
  var onDismiss: (() -> Void)?
  /// Gesture intents from the pad; returns whether a press was admitted.
  var onPadIntent: ((PadIntent) -> Bool)? {
    didSet { directionPad.onIntent = onPadIntent }
  }

  let directionPad = TerminalDirectionPad()
  private var buttons: [AccessoryItem: UIButton] = [:]
  private var lockBadges: [AccessoryKey: UIImageView] = [:]
  private let chordLabel = UILabel()
  private var heightConstraint: NSLayoutConstraint!
  private(set) var layout: AccessoryRowLayout?
  private var layoutOrigin = CGPoint.zero
  #if !os(tvOS)
  private lazy var navigateMenu = UIEditMenuInteraction(delegate: self)
  #endif

  /// Ordinary keys, promoted iPad keys and the menus, in layout order.
  private static let buttonItems: [AccessoryItem] =
    AccessoryRowLayout.core + AccessoryRowLayout.promoted + [.paste, .keys]

  init() {
    let height = AccessoryRowLayout(width: 352).height
    super
      .init(
        frame: CGRect(x: 0, y: 0, width: 0, height: height),
        inputViewStyle: .keyboard
      )
    allowsSelfSizing = true
    translatesAutoresizingMaskIntoConstraints = false

    for item in Self.buttonItems {
      let button = makeButton(item)
      button.isHidden = true
      buttons[item] = button
      addSubview(button)
    }

    directionPad.onArrow = { [weak self] direction in
      self?.onDiscreteKey?(direction.key)
    }
    directionPad.onShowNavigate = { [weak self] in self?.showNavigate() }
    addSubview(directionPad)

    // Shown over the leading keys while a modified pad run is held.
    chordLabel.isUserInteractionEnabled = false
    chordLabel.isAccessibilityElement = false
    chordLabel.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
    chordLabel.textColor = .label
    chordLabel.textAlignment = .center
    chordLabel.backgroundColor = DirectionPadArtwork.opaqueFill
    chordLabel.layer.cornerRadius = 8
    chordLabel.layer.masksToBounds = true
    chordLabel.isHidden = true
    addSubview(chordLabel)

    #if !os(tvOS)
    addInteraction(navigateMenu)
    #endif
    updateKeysMenu()

    heightConstraint = heightAnchor.constraint(equalToConstant: height)
    heightConstraint.isActive = true
    registerForTraitChanges([
      UITraitPreferredContentSizeCategory.self, UITraitHorizontalSizeClass.self,
    ]) { (self: Self, _: UITraitCollection) in self.setNeedsLayout() }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil {
      stopRepeating()
      directionPad.cancelGesture()
    }
  }

  #if !os(visionOS)
  var enableInputClicksWhenVisible: Bool { true }
  #endif

  // MARK: Layout

  /// Shared key size: 44 pt, growing with larger text.
  var keySize: CGFloat {
    let scaled = UIFontMetrics(forTextStyle: .body)
      .scaledValue(for: 44, compatibleWith: traitCollection)
    return min(66, max(44, scaled.rounded()))
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let insets = safeAreaInsets
    let width = bounds.width - insets.left - insets.right
    guard width > 0 else { return }
    let next = AccessoryRowLayout(
      width: width,
      keySize: keySize,
      promotesKeys: traitCollection.userInterfaceIdiom == .pad
    )
    let origin = CGPoint(x: insets.left, y: 0)
    guard next != layout || origin != layoutOrigin else { return }
    // Geometry never changes under a gesture.
    directionPad.cancelGesture()
    let pasteChanged = next.showsPaste != layout?.showsPaste
    layout = next
    layoutOrigin = origin
    if heightConstraint.constant != next.height {
      heightConstraint.constant = next.height
    }
    for (item, button) in buttons {
      guard let frame = next.frames[item] else {
        button.isHidden = true
        continue
      }
      button.isHidden = false
      button.frame = frame.offsetBy(dx: origin.x, dy: origin.y)
      restyle(button, item: item, size: next.keySize)
    }
    for (key, badge) in lockBadges {
      guard let button = buttons[.key(key)] else { continue }
      let side = next.keySize * 0.3
      badge.frame = CGRect(
        x: button.bounds.maxX - side - 2,
        y: 2,
        width: side,
        height: side
      )
    }
    directionPad.keySize = next.keySize
    if let frame = next.frames[.pad] {
      directionPad.isHidden = false
      directionPad.frame = frame.offsetBy(dx: origin.x, dy: origin.y)
    } else {
      directionPad.isHidden = true
    }
    if pasteChanged { updateKeysMenu() }
    layoutChord()
  }

  // MARK: Modifiers

  /// Shows each modifier's state: Off, Next key (tinted) or Locked
  /// (filled, with a lock).
  func update(_ sticky: StickyModifiers) {
    var spoken: [String] = []
    for key in [AccessoryKey.control, .alt] {
      guard let button = buttons[.key(key)], let modifier = key.modifier else {
        continue
      }
      var config = button.configuration ?? Self.keyConfiguration
      let state = sticky.state(of: modifier)
      switch state {
      case .off:
        config.baseBackgroundColor = nil
        config.baseForegroundColor = .label
      case .latched:
        config.baseBackgroundColor = .tintColor.withAlphaComponent(0.35)
        config.baseForegroundColor = .label
      case .locked:
        config.baseBackgroundColor = .tintColor
        config.baseForegroundColor = .white
      }
      button.configuration = config
      lockBadges[key]?.isHidden = state != .locked
      button.accessibilityValue = Self.stateName(state)
      if state != .off {
        spoken.append("\(Self.name(of: key)) \(Self.stateName(state))")
      }
    }
    directionPad.modifierDescription = spoken.joined(separator: ", ")
  }

  static func stateName(_ state: StickyModifiers.State) -> String {
    switch state {
    case .off: String(localized: "Off")
    case .latched: String(localized: "Next key")
    case .locked: String(localized: "Locked")
    }
  }

  private static func name(of key: AccessoryKey) -> String {
    switch key {
    case .escape: String(localized: "Escape")
    case .tab: String(localized: "Tab")
    case .control: String(localized: "Control")
    case .alt: String(localized: "Alt")
    case .left: PadDirection.left.name
    case .down: PadDirection.down.name
    case .up: PadDirection.up.name
    case .right: PadDirection.right.name
    case let .symbol(s): s
    }
  }

  /// A concise chord, such as "Ctrl + Left", while a modified pad run is
  /// held; nil hides it.
  func showChord(_ chord: String?) {
    chordLabel.text = chord.map { " \($0) " }
    chordLabel.isHidden = chord == nil
    layoutChord()
  }

  private func layoutChord() {
    guard !chordLabel.isHidden else { return }
    let size = chordLabel.intrinsicContentSize
    let pad = directionPad.frame
    let gap = AccessoryRowLayout.padGap(keySize: pad.width)
    chordLabel.frame = CGRect(
      x: max(AccessoryRowLayout.inset, pad.minX - gap - size.width),
      y: pad.midY - (size.height + 6) / 2,
      width: size.width,
      height: size.height + 6
    )
  }

  // MARK: Buttons

  private func makeButton(_ item: AccessoryItem) -> UIButton {
    let button = UIButton(configuration: Self.keyConfiguration)
    switch item {
    case let .key(key):
      button.accessibilityLabel =
        key.symbolName == nil ? key.title : Self.name(of: key)
      if key.modifier == nil {
        // Keys fire on touch down and repeat while held.
        button.addTarget(self, action: #selector(keyDown(_:)), for: .touchDown)
        button.addTarget(
          self,
          action: #selector(keyUp(_:)),
          for: [.touchUpInside, .touchUpOutside, .touchCancel]
        )
      } else {
        button.addAction(
          UIAction { [weak self] _ in self?.press(key) },
          for: .primaryActionTriggered
        )
        let badge = UIImageView(image: UIImage(systemName: "lock.fill"))
        badge.contentMode = .scaleAspectFit
        badge.tintColor = .white
        badge.isHidden = true
        badge.isUserInteractionEnabled = false
        button.addSubview(badge)
        lockBadges[key] = badge
      }
    case .paste:
      button.accessibilityLabel = String(localized: "Paste")
      button.addAction(
        UIAction { [weak self] _ in self?.onPaste?() },
        for: .primaryActionTriggered
      )
    case .keys:
      button.accessibilityLabel = String(localized: "More keys")
      button.showsMenuAsPrimaryAction = true
    case .symbols:
      button.accessibilityLabel = String(localized: "Symbols")
      button.showsMenuAsPrimaryAction = true
      button.menu = symbolsMenu()
    case .function:
      button.accessibilityLabel = String(localized: "Function keys")
      button.showsMenuAsPrimaryAction = true
      button.menu = functionMenu()
    case .pad: break
    }
    restyle(button, item: item, size: 44)
    return button
  }

  private func restyle(_ button: UIButton, item: AccessoryItem, size: CGFloat) {
    var config = button.configuration ?? Self.keyConfiguration
    let pointSize = (15 * size / 44).rounded()
    config.contentInsets = .zero
    config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
      pointSize: pointSize,
      weight: .medium
    )
    config.titleTextAttributesTransformer =
      UIConfigurationTextAttributesTransformer { attributes in
        var attributes = attributes
        attributes.font = .monospacedSystemFont(
          ofSize: pointSize,
          weight: .medium
        )
        return attributes
      }
    if config.baseForegroundColor == nil { config.baseForegroundColor = .label }
    switch item {
    case let .key(key):
      if let symbol = key.symbolName {
        config.image = UIImage(systemName: symbol)
      } else {
        config.title = key.title
      }
    case .paste: config.image = UIImage(systemName: "doc.on.clipboard")
    case .keys: config.image = UIImage(systemName: "ellipsis")
    case .symbols: config.image = UIImage(systemName: "number")
    case .function: config.title = "fn"
    case .pad: break
    }
    button.configuration = config
  }

  private static var keyConfiguration: UIButton.Configuration {
    #if os(visionOS)
    var config = UIButton.Configuration.gray()
    #else
    var config = UIButton.Configuration.glass()
    #endif
    config.cornerStyle = .capsule
    return config
  }

  // MARK: Keys panel

  private func updateKeysMenu() {
    buttons[.keys]?.menu = keysMenu(includingPaste: layout?.showsPaste == false)
  }

  /// Navigate, Symbols, F1–F12, Paste when collapsed, and Hide Keyboard.
  func keysMenu(includingPaste: Bool) -> UIMenu {
    var children: [UIMenuElement] = [
      navigateMenuContent(), symbolsMenu(), functionMenu(),
    ]
    if includingPaste {
      children.append(
        UIAction(
          title: String(localized: "Paste"),
          image: UIImage(systemName: "doc.on.clipboard")
        ) { [weak self] _ in self?.onPaste?() }
      )
    }
    children.append(
      UIAction(
        title: String(localized: "Hide Keyboard"),
        image: UIImage(systemName: "keyboard.chevron.compact.down")
      ) { [weak self] _ in self?.onDismiss?() }
    )
    return UIMenu(children: children)
  }

  /// Discrete arrows for Switch Control and tapping, plus paging keys.
  func navigateMenuContent() -> UIMenu {
    var actions: [UIAction] = PadDirection.allCases.map { direction in
      UIAction(
        title: direction.name,
        image: UIImage(systemName: direction.symbolName)
      ) { [weak self] _ in self?.onDiscreteKey?(direction.key) }
    }
    let paging: [(String, Key)] = [
      (String(localized: "Home"), .home), (String(localized: "End"), .end),
      (String(localized: "Page Up"), .pageUp),
      (String(localized: "Page Down"), .pageDown),
    ]
    actions += paging.map { title, key in
      UIAction(title: title) { [weak self] _ in self?.onDiscreteKey?(key) }
    }
    return UIMenu(
      title: String(localized: "Navigate"),
      image: UIImage(systemName: "arrow.up.and.down.and.arrow.left.and.right"),
      children: actions
    )
  }

  private func symbolsMenu() -> UIMenu {
    let symbols = AccessoryKey.standard.compactMap { key -> String? in
      if case let .symbol(s) = key { return s }
      return nil
    }
    return UIMenu(
      title: String(localized: "Symbols"),
      image: UIImage(systemName: "number"),
      children: symbols.map { symbol in
        UIAction(title: symbol) { [weak self] _ in self?.press(.symbol(symbol))
        }
      }
    )
  }

  private func functionMenu() -> UIMenu {
    UIMenu(
      title: String(localized: "Function Keys"),
      image: UIImage(systemName: "f.cursive"),
      children: (1 ... 12)
        .map { n in
          UIAction(title: "F\(n)") { [weak self] _ in
            self?.onDiscreteKey?(.function(n))
          }
        }
    )
  }

  /// Keys → Navigate, for the pad's primary accessibility activation.
  func showNavigate() {
    #if !os(tvOS)
    let configuration = UIEditMenuConfiguration(
      identifier: "navigate" as NSString,
      sourcePoint: CGPoint(
        x: directionPad.frame.midX,
        y: directionPad.frame.minY
      )
    )
    navigateMenu.presentEditMenu(with: configuration)
    #endif
  }

  // MARK: Key repeat

  private var repeatTimer: Timer?
  private weak var repeatingButton: UIButton?

  private func press(_ key: AccessoryKey) {
    #if !os(visionOS)
    UIDevice.current.playInputClick()
    #endif
    onKey?(key)
  }

  @objc
  private func keyDown(_ sender: UIButton) {
    guard let item = buttons.first(where: { $0.value === sender })?.key,
      case let .key(key) = item
    else { return }
    repeatTimer?.invalidate()
    repeatingButton = sender
    repeatTimer = Self.trackingTimer(interval: 0.45, repeats: false) {
      [weak self] in
      guard let self else { return false }
      self.repeatTimer = Self.trackingTimer(interval: 0.06, repeats: true) {
        [weak self] in
        guard let self else { return false }
        self.onKey?(key)
        return true
      }
      return true
    }
    // The handler may cancel repeats or detach the bar synchronously.
    press(key)
  }

  /// Timers in the common modes keep firing while a touch is tracked.
  private static func trackingTimer(
    interval: TimeInterval,
    repeats: Bool,
    _ body: @escaping @MainActor () -> Bool
  ) -> Timer {
    let timer = Timer(timeInterval: interval, repeats: repeats) { timer in
      // Returns false once the bar is gone.
      if !MainActor.assumeIsolated(body) { timer.invalidate() }
    }
    RunLoop.main.add(timer, forMode: .common)
    return timer
  }

  @objc
  private func keyUp(_ sender: UIButton) {
    guard repeatingButton === sender else { return }
    stopRepeating()
  }

  func stopRepeating() {
    repeatTimer?.invalidate()
    repeatTimer = nil
    repeatingButton = nil
  }
}

#if !os(tvOS)
extension TerminalAccessoryBar: @MainActor UIEditMenuInteractionDelegate {
  func editMenuInteraction(
    _ interaction: UIEditMenuInteraction,
    menuFor configuration: UIEditMenuConfiguration,
    suggestedActions: [UIMenuElement]
  ) -> UIMenu? { UIMenu(children: navigateMenuContent().children) }
}
#endif
#endif
