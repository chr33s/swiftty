#if canImport(UIKit)
import SwifttyCore
import UIKit

/// Accessory keys above the software keyboard or below the hardware-keyboard
/// view.
@MainActor
final class TerminalAccessoryBar: UIInputView, UIInputViewAudioFeedback {
  var onKey: ((AccessoryKey) -> Void)?
  var onDismiss: (() -> Void)?
  private var buttons: [AccessoryKey: UIButton] = [:]

  init() {
    super
      .init(
        frame: CGRect(x: 0, y: 0, width: 0, height: 44),
        inputViewStyle: .keyboard
      )
    allowsSelfSizing = true
    translatesAutoresizingMaskIntoConstraints = false

    let stack = UIStackView()
    stack.axis = .horizontal
    stack.spacing = 6
    stack.translatesAutoresizingMaskIntoConstraints = false
    for key in AccessoryKey.standard {
      let button = makeButton(key.title)
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
      }
      buttons[key] = button
      stack.addArrangedSubview(button)
    }

    let scroll = UIScrollView()
    scroll.showsHorizontalScrollIndicator = false
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.addSubview(stack)

    var dismiss = UIButton.Configuration.plain()
    dismiss.image = UIImage(systemName: "keyboard.chevron.compact.down")
    let dismissButton = UIButton(
      configuration: dismiss,
      primaryAction: UIAction { [weak self] _ in self?.onDismiss?() }
    )
    dismissButton.accessibilityLabel = "Hide keyboard"
    dismissButton.translatesAutoresizingMaskIntoConstraints = false

    addSubview(scroll)
    addSubview(dismissButton)
    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: 44),
      scroll.leadingAnchor.constraint(
        equalTo: safeAreaLayoutGuide.leadingAnchor
      ), scroll.topAnchor.constraint(equalTo: topAnchor),
      scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
      scroll.trailingAnchor.constraint(equalTo: dismissButton.leadingAnchor),
      dismissButton.trailingAnchor.constraint(
        equalTo: safeAreaLayoutGuide.trailingAnchor,
        constant: -4
      ), dismissButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      stack.leadingAnchor.constraint(
        equalTo: scroll.contentLayoutGuide.leadingAnchor,
        constant: 6
      ),
      stack.trailingAnchor.constraint(
        equalTo: scroll.contentLayoutGuide.trailingAnchor,
        constant: -6
      ),
      stack.topAnchor.constraint(
        equalTo: scroll.contentLayoutGuide.topAnchor,
        constant: 5
      ),
      stack.bottomAnchor.constraint(
        equalTo: scroll.contentLayoutGuide.bottomAnchor,
        constant: -5
      ),
      stack.heightAnchor.constraint(
        equalTo: scroll.frameLayoutGuide.heightAnchor,
        constant: -10
      ),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil { stopRepeating() }
  }

  #if !os(visionOS)
  var enableInputClicksWhenVisible: Bool { true }
  #endif

  /// Shows each modifier's state: latched tinted, locked filled.
  func update(_ sticky: StickyModifiers) {
    for key in [AccessoryKey.control, .alt] {
      guard let button = buttons[key], let modifier = key.modifier else {
        continue
      }
      var config = button.configuration ?? .gray()
      switch sticky.state(of: modifier) {
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
      button.accessibilityValue =
        sticky.state(of: modifier) == .off ? "off" : "on"
    }
  }

  private func makeButton(_ title: String) -> UIButton {
    var config = UIButton.Configuration.gray()
    config.title = title
    config.baseForegroundColor = .label
    config.contentInsets = NSDirectionalEdgeInsets(
      top: 4,
      leading: 10,
      bottom: 4,
      trailing: 10
    )
    config.titleTextAttributesTransformer =
      UIConfigurationTextAttributesTransformer { attributes in
        var attributes = attributes
        attributes.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
        return attributes
      }
    let button = UIButton(configuration: config)
    button.accessibilityLabel = title
    button.widthAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive =
      true
    return button
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
    guard let key = buttons.first(where: { $0.value === sender })?.key else {
      return
    }
    repeatTimer?.invalidate()
    repeatingButton = sender
    repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) {
      [weak self] _ in
      MainActor.assumeIsolated {
        self?.repeatTimer = Timer.scheduledTimer(
          withTimeInterval: 0.06,
          repeats: true
        ) { [weak self] timer in
          guard let self else {
            timer.invalidate();
            return
          }
          MainActor.assumeIsolated { self.onKey?(key) }
        }
      }
    }
    // The handler may cancel repeats or detach the bar synchronously.
    press(key)
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
#endif
