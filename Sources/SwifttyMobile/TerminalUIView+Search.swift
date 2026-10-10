#if canImport(UIKit)
import SwifttyCore
import UIKit

/// Find bar floating at the top of the terminal: a field, previous and
/// next buttons, a match count, and Done.
@MainActor
final class TerminalSearchBar: UIView, UITextFieldDelegate {
  let field = UITextField()
  let count = UILabel()
  private var buttons: [UIButton] = []
  var onChange: ((String) -> Void)?
  var onNavigate: ((Bool) -> Void)?
  var onDone: (() -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    let blur = UIVisualEffectView(
      effect: UIBlurEffect(style: .systemThickMaterial)
    )
    blur.frame = bounds
    blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    blur.layer.cornerRadius = 12
    blur.clipsToBounds = true
    addSubview(blur)

    field.placeholder = "Find"
    field.accessibilityLabel = "Find"
    field.autocorrectionType = .no
    field.autocapitalizationType = .none
    field.spellCheckingType = .no
    field.returnKeyType = .search
    field.clearButtonMode = .whileEditing
    field.delegate = self
    field.addAction(
      UIAction { [weak self] _ in self?.onChange?(self?.field.text ?? "") },
      for: .editingChanged
    )

    count.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    count.textColor = .secondaryLabel

    func button(
      _ symbol: String,
      _ label: String,
      _ action: @escaping () -> Void
    ) -> UIButton {
      var config = UIButton.Configuration.plain()
      config.image = UIImage(systemName: symbol)
      config.contentInsets = NSDirectionalEdgeInsets(
        top: 8,
        leading: 8,
        bottom: 8,
        trailing: 8
      )
      let button = UIButton(
        configuration: config,
        primaryAction: UIAction { _ in action() }
      )
      button.accessibilityLabel = label
      return button
    }
    buttons = [
      button("chevron.up", "Previous match") { [weak self] in
        self?.onNavigate?(false)
      },
      button("chevron.down", "Next match") { [weak self] in
        self?.onNavigate?(true)
      }, button("xmark.circle.fill", "Done") { [weak self] in self?.onDone?() },
    ]
    for control in [field, count] + buttons {
      blur.contentView.addSubview(control)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  private func isCompact(width: CGFloat) -> Bool {
    // 120-point query, three 44-point buttons, four gaps and margins.
    width < 120 + 3 * 44 + 4 * 4 + 12 + 4
      + max(0, count.intrinsicContentSize.width)
  }

  /// Narrow surfaces use a separate navigation row so every action
  /// remains available without replacing the focused text field.
  func position(in available: CGRect) {
    let margin = min(8, max(0, available.width / 4))
    let width = min(420, max(0, available.width - 2 * margin))
    let top = min(8, max(0, available.height / 4))
    let height = min(
      isCompact(width: width) ? 80 : 44,
      max(0, available.height - top)
    )
    frame = CGRect(
      x: available.maxX - width - margin,
      y: available.minY + top,
      width: width,
      height: height
    )
    setNeedsLayout()
    layoutIfNeeded()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let compact = isCompact(width: bounds.width)
    let inset = min(compact ? 2 : 12, bounds.width / 2)
    let trailing = min(compact ? 2 : 4, bounds.width / 2)
    let width = max(0, bounds.width - inset - trailing)
    let gap = min(4, width / 10)
    let buttonWidth = min(44, max(0, (width - 2 * gap) / 3))
    let navigationWidth = 3 * buttonWidth + 2 * gap
    let top = min(4, bounds.height / 4)
    let rowHeight = max(
      0,
      (bounds.height - (compact ? 3 : 2) * top) / (compact ? 2 : 1)
    )
    let queryWidth = max(0, width - (compact ? 0 : navigationWidth + gap))
    let countWidth = min(
      max(0, count.intrinsicContentSize.width),
      max(0, queryWidth - 40 - gap)
    )
    let fieldHeight = min(22, rowHeight)
    field.frame = CGRect(
      x: inset,
      y: top + (rowHeight - fieldHeight) / 2,
      width: max(0, queryWidth - countWidth - gap),
      height: fieldHeight,
    )
    count.frame = CGRect(
      x: inset + queryWidth - countWidth,
      y: top,
      width: countWidth,
      height: rowHeight
    )
    let navigationX =
      compact
      ? (bounds.width - navigationWidth) / 2
      : bounds.width - trailing - navigationWidth
    for (i, button) in buttons.enumerated() {
      button.frame = CGRect(
        x: navigationX + CGFloat(i) * (buttonWidth + gap),
        y: compact ? 2 * top + rowHeight : top,
        width: buttonWidth,
        height: rowHeight,
      )
    }
  }

  /// "3/12", or "0" when nothing matches.
  func showCount(selected: Int?, total: Int) {
    let text =
      field.text?.isEmpty ?? true
      ? "" : total == 0 ? "0" : "\((selected ?? 0) + 1)/\(total)"
    guard count.text != text else { return }
    count.text = text
    if let parent = superview {
      position(in: parent.safeAreaLayoutGuide.layoutFrame)
    }
  }

  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    onNavigate?(true)
    return false
  }

  override var keyCommands: [UIKeyCommand]? {
    let escape = UIKeyCommand(
      input: UIKeyCommand.inputEscape,
      modifierFlags: [],
      action: #selector(done)
    )
    escape.wantsPriorityOverSystemBehavior = true
    return [escape]
  }

  @objc
  private func done() { onDone?() }
}

extension TerminalUIView {
  func makeSearchBar() -> TerminalSearchBar {
    let bar = TerminalSearchBar()
    bar.isHidden = true
    bar.onChange = { [weak self] text in self?.search(text) }
    bar.onNavigate = { [weak self] next in self?.navigateSearch(next: next) }
    bar.onDone = { [weak self] in self?.hideSearch() }
    addSubview(bar)
    return bar
  }

  /// Shows the find bar, optionally searching for `text` at once.
  func showSearch(text: String?) {
    let wasVisible = isSearchVisible
    isSearchVisible = true
    searchBar.isHidden = false
    updateAccessibilityElements()
    if let text, !text.isEmpty {
      searchBar.field.text = text
      search(text)
    } else if !wasVisible {
      // Closing ends the search but retains the field's text.
      // Reopen against current output; refocusing keeps navigation.
      search(searchBar.field.text ?? "")
    }
    searchBar.position(in: safeAreaLayoutGuide.layoutFrame)
    searchBar.field.becomeFirstResponder()
    searchBar.field.selectAll(nil)
    if !wasVisible {
      UIAccessibility.post(
        notification: .layoutChanged,
        argument: searchBar.field
      )
    }
  }

  func search(_ text: String) {
    stopMomentum()
    let result = session.mutate { state in
      state.search(text)
      // Start from the newest match, nearest the prompt.
      let selected = state.selectSearchMatch(forward: false)
      return (selected, state.searchMatches.count)
    }
    searchBar.showCount(selected: result.0, total: result.1)
  }

  /// Moves between matches; "next" goes towards older output, as
  /// searching starts at the newest.
  @discardableResult
  func navigateSearch(next: Bool) -> Bool {
    stopMomentum()
    let result = session.mutate { state in
      (state.selectSearchMatch(forward: !next), state.searchMatches.count)
    }
    searchBar.showCount(selected: result.0, total: result.1)
    return result.0 != nil
  }

  func hideSearch() {
    isSearchVisible = false
    session.mutate { $0.endSearch() }
    guard !searchBar.isHidden else { return }
    searchBar.isHidden = true
    updateAccessibilityElements()
    searchBar.field.resignFirstResponder()
    becomeFirstResponder()
    UIAccessibility.post(
      notification: .layoutChanged,
      argument: accessibilityTerminal
    )
  }
}
#endif
