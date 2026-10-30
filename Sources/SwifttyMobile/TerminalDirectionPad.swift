#if canImport(UIKit)
import UIKit

/// One circular control for the four arrow keys. It rests at the size of
/// the other accessory keys and enlarges its artwork only while a slide
/// holds a direction; its frame, transform and hit region never change
/// (spec.keyboard.md §3, §4 and §6).
@MainActor
final class TerminalDirectionPad: UIControl {
  /// Returns whether the terminal admitted an activation; a refused
  /// activation suppresses the touch until it ends.
  var onIntent: ((PadIntent) -> Bool)?
  /// A discrete accessible arrow: one press and release, no repeat.
  var onArrow: ((PadDirection) -> Void)?
  /// Primary accessibility activation: show Keys → Navigate.
  var onShowNavigate: (() -> Void)?

  private(set) var model = DirectionPadModel()
  private weak var trackedTouch: UITouch?
  private let artwork = DirectionPadArtwork()
  /// Spoken modifier state, such as "Control next key".
  var modifierDescription = "" { didSet { updateAccessibility() } }

  /// Expansion and collapse durations (ease-out, no overshoot).
  static let expandDuration: TimeInterval = 0.12
  static let collapseDuration: TimeInterval = 0.10

  var keySize: CGFloat = 44 {
    didSet {
      guard keySize != oldValue else { return }
      cancelGesture()
      model.geometry.keySize = Double(keySize)
      invalidateIntrinsicContentSize()
      setNeedsLayout()
    }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    #if !os(tvOS)
    isMultipleTouchEnabled = false
    #endif
    clipsToBounds = false
    artwork.isUserInteractionEnabled = false
    artwork.isAccessibilityElement = false
    artwork.accessibilityElementsHidden = true
    addSubview(artwork)

    isAccessibilityElement = true
    accessibilityLabel = String(localized: "Arrow keys")
    accessibilityHint = String(
      localized: "Slide to move; additional actions send individual arrows"
    )
    accessibilityCustomActions = PadDirection.allCases.map { direction in
      UIAccessibilityCustomAction(name: direction.actionName) { [weak self] _ in
        guard let self, self.isEnabled else { return false }
        self.onArrow?(direction)
        return true
      }
    }
    updateAccessibility()

    #if os(iOS)
    addInteraction(UIPointerInteraction(delegate: self))
    #endif
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(reduceMotionChanged),
      name: UIAccessibility.reduceMotionStatusDidChangeNotification,
      object: nil
    )
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override var intrinsicContentSize: CGSize {
    CGSize(width: keySize, height: keySize)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // Bounds and centre are stable; only the transform animates.
    let size = bounds.size
    if artwork.bounds.size != size {
      artwork.bounds = CGRect(origin: .zero, size: size)
    }
    artwork.center = CGPoint(x: bounds.midX, y: bounds.midY)
  }

  override var isEnabled: Bool {
    didSet {
      guard isEnabled != oldValue else { return }
      if !isEnabled { abandon(suppressing: true) }
      artwork.isDisabled = !isEnabled
      updateAccessibility()
    }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil { cancelGesture() }
  }

  // MARK: Tracking

  /// The artwork never takes touches: only the resting bounds hit.
  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    bounds.contains(point)
  }

  override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
    guard isEnabled else { return false }
    // One initiating touch: UIControl tracks a single touch at a time.
    trackedTouch = touch
    model.begin(at: offset(of: touch))
    present(animated: true)
    return true
  }

  override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool
  {
    guard touch === trackedTouch else {
      // A hard cancellation discarded this touch; ignore it to the end.
      return model.isTracking
    }
    if let intent = model.move(to: offset(of: touch)) { deliver(intent) }
    return true
  }

  override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
    if touch == nil || touch === trackedTouch {
      trackedTouch = nil
      let intent = model.end()
      present(animated: true)
      if let intent { _ = onIntent?(intent) }
    }
    super.endTracking(touch, with: event)
  }

  override func cancelTracking(with event: UIEvent?) {
    cancelGesture()
    super.cancelTracking(with: event)
  }

  /// Hard cancellation from UIKit, removal or a geometry change: returns
  /// to Idle at once and reports a held direction's end. Idempotent.
  func cancelGesture() {
    trackedTouch = nil
    let intent = model.cancel()
    restoreIdentity()
    if let intent { _ = onIntent?(intent) }
  }

  /// The terminal stopped this gesture's key itself (another input
  /// source preempted it, or its lifecycle ended): nothing is reported.
  /// A suppressed touch is ignored until it ends.
  func abandon(suppressing: Bool) {
    if suppressing {
      model.suppress()
    } else {
      trackedTouch = nil
      model.reset()
    }
    restoreIdentity()
  }

  private func deliver(_ intent: PadIntent) {
    let admitted = onIntent?(intent) ?? false
    if case .activate = intent, !admitted, model.isTracking { model.suppress() }
    present(animated: true)
  }

  private func offset(of touch: UITouch) -> CGPoint {
    // Untransformed bounds; the scaled artwork never enters this.
    let point = touch.location(in: self)
    return CGPoint(x: point.x - bounds.midX, y: point.y - bounds.midY)
  }

  // MARK: Presentation

  private var isExpandedOnScreen = false

  private func present(animated: Bool) {
    // The sector follows the logical direction immediately.
    artwork.direction = model.activeDirection
    artwork.isPressed = model.isPressed
    updateAccessibility()
    let expanded = model.isExpanded
    guard expanded != isExpandedOnScreen else { return }
    isExpandedOnScreen = expanded
    let scale = CGFloat(DirectionPadGeometry.activeScale)
    let target: CGAffineTransform =
      expanded ? CGAffineTransform(scaleX: scale, y: scale) : .identity
    guard animated, !UIAccessibility.isReduceMotionEnabled, window != nil else {
      artwork.layer.removeAllAnimations()
      artwork.transform = target
      return
    }
    // Retargets from the current presentation; completion does nothing.
    UIView.animate(
      withDuration: expanded ? Self.expandDuration : Self.collapseDuration,
      delay: 0,
      options: [.beginFromCurrentState, .curveEaseOut, .allowUserInteraction],
      animations: { self.artwork.transform = target }
    )
  }

  private func restoreIdentity() {
    isExpandedOnScreen = false
    artwork.layer.removeAllAnimations()
    artwork.transform = .identity
    artwork.direction = nil
    artwork.isPressed = model.isPressed
    updateAccessibility()
  }

  @objc
  private func reduceMotionChanged() {
    guard UIAccessibility.isReduceMotionEnabled else { return }
    artwork.layer.removeAllAnimations()
    let scale = CGFloat(DirectionPadGeometry.activeScale)
    artwork.transform =
      isExpandedOnScreen
      ? CGAffineTransform(scaleX: scale, y: scale) : .identity
  }

  /// The artwork's visual scale, for tests.
  var artworkScale: CGFloat { artwork.transform.a }

  // MARK: Accessibility

  private func updateAccessibility() {
    accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
    var parts: [String] = []
    if let direction = model.activeDirection { parts.append(direction.name) }
    if !modifierDescription.isEmpty { parts.append(modifierDescription) }
    accessibilityValue = parts.isEmpty ? nil : parts.joined(separator: ", ")
  }

  override func accessibilityActivate() -> Bool {
    guard isEnabled, let onShowNavigate else { return false }
    onShowNavigate()
    return true
  }
}

#if os(iOS)
extension TerminalDirectionPad: UIPointerInteractionDelegate {
  /// Hover tints without enlarging: only a slide expands the pad.
  func pointerInteraction(
    _ interaction: UIPointerInteraction,
    styleFor region: UIPointerRegion
  ) -> UIPointerStyle? {
    guard window != nil else { return nil }
    let preview = UITargetedPreview(view: self)
    return UIPointerStyle(
      effect: .hover(
        preview,
        preferredTintMode: .overlay,
        prefersShadow: false,
        prefersScaledContent: false
      ),
      shape: .roundedRect(bounds, radius: bounds.width / 2)
    )
  }
}
#endif

extension PadDirection {
  var name: String {
    switch self {
    case .left: String(localized: "Left")
    case .down: String(localized: "Down")
    case .up: String(localized: "Up")
    case .right: String(localized: "Right")
    }
  }

  var actionName: String {
    switch self {
    case .left: String(localized: "Move left")
    case .down: String(localized: "Move down")
    case .up: String(localized: "Move up")
    case .right: String(localized: "Move right")
    }
  }

  var symbolName: String {
    switch self {
    case .left: "arrow.left"
    case .down: "arrow.down"
    case .up: "arrow.up"
    case .right: "arrow.right"
    }
  }
}

// MARK: - Artwork

/// The noninteractive, accessibility-hidden circular glyph: a ring, four
/// arrowheads around a neutral hub, and one highlighted 90° sector while
/// a direction is held.
@MainActor
final class DirectionPadArtwork: UIView {
  var direction: PadDirection? {
    didSet { if direction != oldValue { updateShapes() } }
  }
  var isPressed = false {
    didSet { if isPressed != oldValue { updateColors() } }
  }
  var isDisabled = false {
    didSet { if isDisabled != oldValue { updateColors() } }
  }

  private let disc = CAShapeLayer()
  private let sector = CAShapeLayer()
  private let ring = CAShapeLayer()
  private let hub = CAShapeLayer()
  private var arrows: [PadDirection: CAShapeLayer] = [:]

  override init(frame: CGRect) {
    super.init(frame: frame)
    for layer in [disc, sector, ring] { self.layer.addSublayer(layer) }
    for direction in PadDirection.allCases {
      let arrow = CAShapeLayer()
      arrows[direction] = arrow
      layer.addSublayer(arrow)
    }
    layer.addSublayer(hub)
    ring.fillColor = nil
    ring.lineWidth = 1.5
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(accessibilityDisplayChanged),
      name: UIAccessibility.reduceTransparencyStatusDidChangeNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(accessibilityDisplayChanged),
      name: UIAccessibility.darkerSystemColorsStatusDidChangeNotification,
      object: nil
    )
    registerForTraitChanges(
      UITraitCollection.systemTraitsAffectingColorAppearance
    ) { (self: Self, _: UITraitCollection) in self.updateColors() }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func tintColorDidChange() {
    super.tintColorDidChange()
    updateColors()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    for layer in [disc, sector, ring, hub] + Array(arrows.values) {
      layer.frame = bounds
      layer.contentsScale =
        max(1, traitCollection.displayScale)
        * CGFloat(DirectionPadGeometry.activeScale)
    }
    updateShapes()
    updateColors()
  }

  @objc
  private func accessibilityDisplayChanged() { updateColors() }

  private var glyphRadius: CGFloat { bounds.width * 10 / 44 }

  private func updateShapes() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    let center = CGPoint(x: bounds.midX, y: bounds.midY)
    let outer = bounds.width / 2
    disc.path =
      UIBezierPath(
        arcCenter: center,
        radius: outer,
        startAngle: 0,
        endAngle: 2 * .pi,
        clockwise: true
      )
      .cgPath
    ring.path =
      UIBezierPath(
        arcCenter: center,
        radius: glyphRadius,
        startAngle: 0,
        endAngle: 2 * .pi,
        clockwise: true
      )
      .cgPath
    let hubRadius = glyphRadius * 0.3
    hub.path =
      UIBezierPath(
        arcCenter: center,
        radius: hubRadius,
        startAngle: 0,
        endAngle: 2 * .pi,
        clockwise: true
      )
      .cgPath
    for (direction, layer) in arrows {
      layer.path = arrowhead(direction, center: center).cgPath
    }
    if let direction {
      let wedge = UIBezierPath()
      let angle = CGFloat(direction.angle)
      wedge.addArc(
        withCenter: center,
        radius: outer - 1,
        startAngle: angle - .pi / 4,
        endAngle: angle + .pi / 4,
        clockwise: true
      )
      wedge.addArc(
        withCenter: center,
        radius: hubRadius + 1.5,
        startAngle: angle + .pi / 4,
        endAngle: angle - .pi / 4,
        clockwise: false
      )
      wedge.close()
      sector.path = wedge.cgPath
    } else {
      sector.path = nil
    }
    updateColors()
  }

  /// A small triangle pointing outward on the glyph ring.
  private func arrowhead(
    _ direction: PadDirection,
    center: CGPoint
  ) -> UIBezierPath {
    let angle = CGFloat(direction.angle)
    let tip = glyphRadius * 0.85
    let base = glyphRadius * 0.45
    let half = glyphRadius * 0.32
    func point(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
      CGPoint(
        x: center.x + along * cos(angle) - across * sin(angle),
        y: center.y + along * sin(angle) + across * cos(angle)
      )
    }
    let path = UIBezierPath()
    path.move(to: point(tip, 0))
    path.addLine(to: point(base, half))
    path.addLine(to: point(base, -half))
    path.close()
    return path
  }

  #if os(tvOS)
  static let opaqueFill = UIColor.darkGray
  static let restingFill = UIColor.label.withAlphaComponent(0.12)
  static let pressedFill = UIColor.label.withAlphaComponent(0.24)
  #else
  static let opaqueFill = UIColor.secondarySystemBackground
  static let restingFill = UIColor.tertiarySystemFill
  static let pressedFill = UIColor.systemFill
  #endif

  func updateColors() {
    let traits = traitCollection
    func resolved(_ color: UIColor) -> CGColor {
      color.resolvedColor(with: traits).cgColor
    }
    let opaque = UIAccessibility.isReduceTransparencyEnabled
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    let base = opaque ? Self.opaqueFill : Self.restingFill
    disc.fillColor = resolved(
      isPressed && direction == nil ? Self.pressedFill : base
    )
    let foreground: UIColor = isDisabled ? .tertiaryLabel : .label
    ring.strokeColor = resolved(foreground.withAlphaComponent(0.55))
    sector.fillColor = resolved(tintColor.withAlphaComponent(0.85))
    // The hub stays neutral, distinct from the highlighted sector.
    hub.fillColor = resolved(foreground)
    for (direction, layer) in arrows {
      let active = direction == self.direction
      layer.fillColor = resolved(active ? .white : foreground)
    }
  }
}
#endif
