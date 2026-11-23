import AppKit
import SwiftMuxProtocol

/// When a window may take a workspace's control without asking. Typing
/// into a window that lost control asks for it back; the prompt is kept
/// for a holder that may be in use elsewhere right now.
enum MuxTakeControl {
  /// A holder whose last input is older than this is treated as idle.
  static let idleInterval: TimeInterval = 30

  enum Decision: Equatable {
    /// Nobody holds it: attach (a takeover at this generation also works).
    case attach(UInt64)
    /// Take over at this lease generation without asking.
    case take(UInt64)
    /// Ask before taking over at this lease generation.
    case ask(UInt64)

    var generation: UInt64 {
      switch self {
      case let .attach(g), let .take(g), let .ask(g): g
      }
    }
  }

  /// Another native window on this Mac is the same person and loses
  /// nothing; any other holder is displaced silently only once idle.
  static func decide(
    _ ws: WorkspaceSummary,
    now: Date = Date(),
    idle: TimeInterval = idleInterval
  ) -> Decision {
    let generation = ws.leaseGeneration
    guard ws.isAttached else { return .attach(generation) }
    guard let holder = ws.leaseHolder else { return .ask(generation) }
    if holder.transport == .local, holder.frontend == .native {
      return .take(generation)
    }
    let last = holder.lastInput ?? holder.since
    return now.timeIntervalSince(last) >= idle
      ? .take(generation) : .ask(generation)
  }

  /// Names the holder for the takeover prompt and the control bar.
  static func describe(_ holder: LeaseHolder?) -> String {
    switch (holder?.transport, holder?.frontend) {
    case (.local, .native): "another window on this Mac"
    case (.local, .terminal): "swmux in a terminal on this Mac"
    case (.remote, _): "another device"
    default: "another window or device"
    }
  }

  /// The control bar's message for a window that lost control.
  static func message(reason: String) -> String {
    switch reason {
    case "another frontend took control":
      "Controlled elsewhere — type to take control"
    case "took over another workspace", "detached":
      "Not controlling this workspace — type to take control"
    default:
      "Disconnected (\(DisplayText.sanitize(reason))) — type to reconnect"
    }
  }
}

/// A floating capsule over a window that lost control: what happened and
/// a button to take control back. Typing in a pane does the same.
@MainActor
final class MuxControlBar: NSGlassEffectView {
  let label = NSTextField(labelWithString: "")
  let button = NSButton(title: "Take Control", target: nil, action: nil)
  private let spinner = NSProgressIndicator()
  var onTakeControl: (() -> Void)?

  var isBusy = false {
    didSet {
      button.isEnabled = !isBusy
      spinner.isHidden = !isBusy
      if isBusy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    cornerRadius = 16
    label.font = .systemFont(ofSize: 12, weight: .medium)
    label.textColor = .labelColor
    label.lineBreakMode = .byTruncatingTail
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    button.bezelStyle = .push
    button.controlSize = .small
    button.target = self
    button.action = #selector(takeControl)
    button.setAccessibilityIdentifier("takeControl")
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isHidden = true
    spinner.isDisplayedWhenStopped = false
    let stack = NSStackView(views: [label, spinner, button])
    stack.orientation = .horizontal
    stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 4, right: 6)
    stack.translatesAutoresizingMaskIntoConstraints = false
    let host = NSView()
    host.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
      stack.topAnchor.constraint(equalTo: host.topAnchor),
      stack.bottomAnchor.constraint(equalTo: host.bottomAnchor),
      stack.heightAnchor.constraint(equalToConstant: 32),
    ])
    contentView = host
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityIdentifier("controlBar")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  var message: String {
    get { label.stringValue }
    set {
      label.stringValue = newValue
      setAccessibilityLabel(newValue)
    }
  }

  @objc private func takeControl() { onTakeControl?() }
}
