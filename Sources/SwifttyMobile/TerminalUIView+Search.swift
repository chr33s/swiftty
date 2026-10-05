#if canImport(UIKit)
    import SwifttyCore
    import UIKit

    /// Find bar floating at the top of the terminal: a field, previous and
    /// next buttons, a match count, and Done.
    @MainActor
    final class TerminalSearchBar: UIView, UITextFieldDelegate {
        let field = UITextField()
        private let count = UILabel()
        var onChange: ((String) -> Void)?
        var onNavigate: ((Bool) -> Void)?
        var onDone: (() -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
            blur.translatesAutoresizingMaskIntoConstraints = false
            blur.layer.cornerRadius = 12
            blur.clipsToBounds = true
            addSubview(blur)

            field.placeholder = "Find"
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.spellCheckingType = .no
            field.returnKeyType = .search
            field.clearButtonMode = .whileEditing
            field.delegate = self
            field.addAction(UIAction { [weak self] _ in self?.onChange?(self?.field.text ?? "") }, for: .editingChanged)

            count.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            count.textColor = .secondaryLabel
            count.setContentHuggingPriority(.required, for: .horizontal)

            func button(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> UIButton {
                var config = UIButton.Configuration.plain()
                config.image = UIImage(systemName: symbol)
                let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
                button.accessibilityLabel = label
                return button
            }
            let stack = UIStackView(arrangedSubviews: [
                field, count,
                button("chevron.up", "Previous match") { [weak self] in self?.onNavigate?(false) },
                button("chevron.down", "Next match") { [weak self] in self?.onNavigate?(true) },
                button("xmark.circle.fill", "Done") { [weak self] in self?.onDone?() },
            ])
            stack.spacing = 4
            stack.alignment = .center
            stack.translatesAutoresizingMaskIntoConstraints = false
            blur.contentView.addSubview(stack)
            NSLayoutConstraint.activate([
                blur.leadingAnchor.constraint(equalTo: leadingAnchor),
                blur.trailingAnchor.constraint(equalTo: trailingAnchor),
                blur.topAnchor.constraint(equalTo: topAnchor),
                blur.bottomAnchor.constraint(equalTo: bottomAnchor),
                stack.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor, constant: 12),
                stack.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor, constant: -4),
                stack.topAnchor.constraint(equalTo: blur.contentView.topAnchor, constant: 4),
                stack.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor, constant: -4),
                field.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
                heightAnchor.constraint(equalToConstant: 44),
            ])
        }

        @available(*, unavailable) required init?(coder: NSCoder) {
            fatalError()
        }

        /// "3/12", or "0" when nothing matches.
        func showCount(selected: Int?, total: Int) {
            count.text = field.text?.isEmpty ?? true ? "" : total == 0 ? "0" : "\((selected ?? 0) + 1)/\(total)"
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            onNavigate?(true)
            return false
        }

        override var keyCommands: [UIKeyCommand]? {
            let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(done))
            escape.wantsPriorityOverSystemBehavior = true
            return [escape]
        }

        @objc private func done() {
            onDone?()
        }
    }

    extension TerminalUIView {
        func makeSearchBar() -> TerminalSearchBar {
            let bar = TerminalSearchBar()
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.isHidden = true
            bar.onChange = { [weak self] text in self?.search(text) }
            bar.onNavigate = { [weak self] next in self?.navigateSearch(next: next) }
            bar.onDone = { [weak self] in self?.hideSearch() }
            addSubview(bar)
            NSLayoutConstraint.activate([
                bar.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8),
                bar.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -8),
                bar.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: 8),
                bar.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            ])
            let preferred = bar.widthAnchor.constraint(equalToConstant: 420)
            preferred.priority = .defaultHigh
            preferred.isActive = true
            return bar
        }

        /// Shows the find bar, optionally searching for `text` at once.
        func showSearch(text: String?) {
            searchBar.isHidden = false
            if let text, !text.isEmpty {
                searchBar.field.text = text
                search(text)
            }
            searchBar.field.becomeFirstResponder()
            searchBar.field.selectAll(nil)
        }

        func search(_ text: String) {
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
        func navigateSearch(next: Bool) {
            let result = session.mutate { state in
                (state.selectSearchMatch(forward: !next), state.searchMatches.count)
            }
            searchBar.showCount(selected: result.0, total: result.1)
        }

        func hideSearch() {
            session.mutate { $0.endSearch() }
            guard !searchBar.isHidden else { return }
            searchBar.isHidden = true
            searchBar.field.resignFirstResponder()
            becomeFirstResponder()
        }
    }
#endif
