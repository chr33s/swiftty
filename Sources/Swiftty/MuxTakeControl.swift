import AppKit
import SwiftMuxProtocol

/// When a window may take a workspace's control without asking. Typing
/// into a window that lost control asks for it back; the prompt is kept
/// for a holder that may be in use elsewhere right now.
enum MuxTakeControl {
  /// A holder whose last input is older than this is treated as idle.
  static let idleInterval: TimeInterval = 30
  /// The service's detach reason when another frontend took over.
  static let takenOverReason = "another frontend took control"

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

  /// The control bar's message for a window that lost control, before
  /// the current holder is known.
  static func message(reason: String) -> String {
    switch reason {
    case takenOverReason: "Controlled elsewhere — type to take control"
    case "took over another workspace", "detached":
      "Not controlling this workspace — type to take control"
    default:
      "Disconnected (\(DisplayText.sanitize(reason))) — type to reconnect"
    }
  }

  /// The control bar's message once the workspace's holder is listed.
  static func message(for ws: WorkspaceSummary) -> String {
    ws.isAttached
      ? "In use on \(describe(ws.leaseHolder)) — type to take control"
      : "No one is controlling this workspace — type to take control"
  }
}

/// A floating capsule over a window that lost control: who has it and a
/// button to take it back (typing in a pane does the same). It also asks
/// before displacing a holder in use, in place of a sheet.
@MainActor
final class MuxControlBar: NSGlassEffectView {
  let label = NSTextField(labelWithString: "")
  let button = NSButton(title: "Take Control", target: nil, action: nil)
  let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
  private let spinner = NSProgressIndicator()
  var onTakeControl: (() -> Void)?
  /// Set while asking: the bar's buttons answer it.
  private var question: (confirm: () -> Void, decline: () -> Void)?
  private var info = ""

  var isBusy = false { didSet { refresh() } }
  /// Whether the bar is asking before a takeover.
  var isAsking: Bool { question != nil }

  override init(frame: NSRect) {
    super.init(frame: frame)
    cornerRadius = 16
    label.font = .systemFont(ofSize: 12, weight: .medium)
    label.textColor = .labelColor
    label.lineBreakMode = .byTruncatingTail
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    for b in [button, cancelButton] {
      b.bezelStyle = .push
      b.controlSize = .small
      b.target = self
    }
    button.action = #selector(primary)
    button.setAccessibilityIdentifier("takeControl")
    cancelButton.action = #selector(cancel)
    cancelButton.setAccessibilityIdentifier("declineTakeControl")
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false
    let stack = NSStackView(views: [label, spinner, cancelButton, button])
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
    refresh()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  /// What happened and how to take control; shown whenever not asking.
  var message: String {
    get { question == nil ? info : label.stringValue }
    set {
      info = newValue
      if question == nil { refresh() }
    }
  }

  /// Asks before a takeover; the previous message returns once answered.
  func ask(
    _ prompt: String,
    confirm: @escaping () -> Void,
    decline: @escaping () -> Void
  ) {
    question?.decline()
    question = (confirm, decline)
    label.stringValue = prompt
    setAccessibilityLabel(prompt)
    refresh()
  }

  /// Answers an open question (tests, and the buttons).
  func answer(_ confirmed: Bool) {
    guard let question else { return }
    self.question = nil
    refresh()
    if confirmed { question.confirm() } else { question.decline() }
  }

  private func refresh() {
    let asking = question != nil
    if !asking {
      label.stringValue = info
      setAccessibilityLabel(info)
    }
    button.title = asking ? "Take Over" : "Take Control"
    cancelButton.isHidden = !asking
    button.isEnabled = asking || !isBusy
    let spinning = isBusy && !asking
    if spinning {
      spinner.startAnimation(nil)
    } else {
      spinner.stopAnimation(nil)
    }
  }

  @objc
  private func primary() {
    if question != nil { answer(true) } else { onTakeControl?() }
  }

  @objc
  private func cancel() { answer(false) }
}
