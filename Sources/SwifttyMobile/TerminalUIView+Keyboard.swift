#if canImport(UIKit)
    import SwifttyCore
    import UIKit

    // MARK: - Responder and hardware keyboard

    public extension TerminalUIView {
        override var canBecomeFirstResponder: Bool {
            true
        }

        override var inputAccessoryView: UIView? {
            accessoryBar
        }

        @discardableResult
        override func becomeFirstResponder() -> Bool {
            guard super.becomeFirstResponder() else { return false }
            session.send(.focus(true))
            renderer.options.isFocused = true
            updateBlinkTimer()
            setNeedsDisplay()
            return true
        }

        @discardableResult
        override func resignFirstResponder() -> Bool {
            guard super.resignFirstResponder() else { return false }
            session.send(.focus(false))
            renderer.options.isFocused = false
            stopKeyRepeat()
            hardwareTextInput.cancel()
            stopBlinking()
            updateBlinkTimer()
            setNeedsDisplay()
            return true
        }

        internal static func modifiers(_ flags: UIKeyModifierFlags) -> KeyModifiers {
            var mods: KeyModifiers = []
            if flags.contains(.shift) {
                mods.insert(.shift)
            }
            if flags.contains(.control) {
                mods.insert(.control)
            }
            if flags.contains(.alternate) {
                mods.insert(.alt)
            }
            if flags.contains(.command) {
                mods.insert(.command)
            }
            return mods
        }

        /// Key bindings run first; keys the terminal encodes itself go
        /// straight to the session; the rest (text) continue to the text
        /// system and arrive through `insertText`, so input methods and
        /// dead keys work.
        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            var unhandled = Set<UIPress>()
            for press in presses {
                guard let key = press.key, !keyDown(key) else { continue }
                unhandled.insert(press)
            }
            if !unhandled.isEmpty {
                super.pressesBegan(unhandled, with: event)
            }
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            super.pressesEnded(keyUp(presses), with: event)
        }

        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            super.pressesCancelled(keyUp(presses), with: event)
        }

        /// Returns true when the press was handled here.
        private func keyDown(_ key: UIKey) -> Bool {
            hardwareTextInput.cancel()
            let usage = key.keyCode.rawValue
            let mods = Self.modifiers(key.modifierFlags).union(sticky.active)
            let base = key.charactersIgnoringModifiers
            // While composing, every key belongs to the input method.
            guard markedText.isEmpty else {
                return false
            }
            if let identity = KeyTranslator.identity(usage: usage, modifiers: mods, base: base, characters: key.characters),
               let action = configuration.keybindings.action(for: identity) {
                _ = consumeSticky()
                handledPresses.insert(usage)
                perform(action)
                return true
            }
            guard let event = KeyTranslator.keyEvent(
                usage: usage, modifiers: mods, charactersIgnoringModifiers: base, characters: key.characters,
                keyboardFlags: session.keyboardFlags,
            ) else {
                if let identity = KeyTranslator.identity(usage: usage, modifiers: mods, base: base, characters: key.characters) {
                    hardwareTextInput.begin(usage: usage, event: identity)
                }
                return false
            }
            _ = consumeSticky()
            clearSelection()
            noteInput()
            session.send(.key(event))
            var release = event
            release.action = .release
            heldKeys[usage] = release
            handledPresses.insert(usage)
            startKeyRepeat(event)
            return true
        }

        /// Sends releases and returns the presses the text system saw begin.
        private func keyUp(_ presses: Set<UIPress>) -> Set<UIPress> {
            var forwarded = Set<UIPress>()
            for press in presses {
                guard let key = press.key else { forwarded.insert(press); continue }
                let usage = key.keyCode.rawValue
                hardwareTextInput.cancel(usage: usage)
                if let release = heldKeys.removeValue(forKey: usage) {
                    session.send(.key(release))
                }
                if handledPresses.remove(usage) != nil {
                    stopKeyRepeat()
                } else {
                    forwarded.insert(press)
                }
            }
            return forwarded
        }

        /// UIKit does not repeat presses it does not deliver to the text
        /// system, so keys sent directly (arrows, Ctrl combinations) repeat
        /// here.
        private func startKeyRepeat(_ event: KeyEvent) {
            stopKeyRepeat()
            var repeated = event
            repeated.action = .repeat
            let sent = repeated
            keyRepeat = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.keyRepeat = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
                        MainActor.assumeIsolated { self?.session.send(.key(sent)) }
                    }
                }
            }
        }

        internal func stopKeyRepeat() {
            keyRepeat?.invalidate()
            keyRepeat = nil
        }

        // MARK: Key bindings

        /// The configured bindings as key commands, so they show in the
        /// discoverability HUD (hold Cmd) and take priority over the system.
        override var keyCommands: [UIKeyCommand]? {
            if let cached = keyCommandCache {
                return cached
            }
            var commands: [UIKeyCommand] = []
            var actions: [KeyAction] = []
            let bindings = configuration.keybindings.bindings.sorted {
                ActionDispatch.title(for: $0.value) < ActionDispatch.title(for: $1.value)
            }
            for (trigger, action) in bindings {
                // Plain keys stay with the terminal; they are matched in pressesBegan.
                guard !trigger.modifiers.isDisjoint(with: [.command, .control, .alt]) || Self.isNonText(trigger.key),
                      let input = Self.keyCommandInput(trigger.key) else { continue }
                // Only the preferred trigger is titled, so the HUD lists each action once.
                let title = configuration.keybindings.trigger(for: action) == trigger ? ActionDispatch.title(for: action) : ""
                let command = UIKeyCommand(
                    title: title, action: #selector(performKeyCommand(_:)), input: input,
                    modifierFlags: Self.flags(trigger.modifiers), propertyList: actions.count,
                )
                command.wantsPriorityOverSystemBehavior = true
                commands.append(command)
                actions.append(action)
            }
            keyCommandActions = actions
            keyCommandCache = commands
            return commands
        }

        @objc internal func performKeyCommand(_ command: UIKeyCommand) {
            guard let index = command.propertyList as? Int, keyCommandActions.indices.contains(index) else { return }
            perform(keyCommandActions[index])
        }

        private static func isNonText(_ key: Key) -> Bool {
            if case .character = key {
                return false
            }
            return true
        }

        private static func flags(_ mods: KeyModifiers) -> UIKeyModifierFlags {
            var flags: UIKeyModifierFlags = []
            if mods.contains(.shift) {
                flags.insert(.shift)
            }
            if mods.contains(.control) {
                flags.insert(.control)
            }
            if mods.contains(.alt) {
                flags.insert(.alternate)
            }
            if mods.contains(.command) {
                flags.insert(.command)
            }
            return flags
        }

        private static func keyCommandInput(_ key: Key) -> String? {
            switch key {
            case let .character(c): String(c)
            case .enter: "\r"
            case .tab: "\t"
            case .backspace: "\u{8}"
            case .escape: UIKeyCommand.inputEscape
            case .up: UIKeyCommand.inputUpArrow
            case .down: UIKeyCommand.inputDownArrow
            case .left: UIKeyCommand.inputLeftArrow
            case .right: UIKeyCommand.inputRightArrow
            case .home: UIKeyCommand.inputHome
            case .end: UIKeyCommand.inputEnd
            case .pageUp: UIKeyCommand.inputPageUp
            case .pageDown: UIKeyCommand.inputPageDown
            case .delete: UIKeyCommand.inputDelete
            case .insert: nil
            case let .function(n):
                [
                    UIKeyCommand.f1,
                    UIKeyCommand.f2,
                    UIKeyCommand.f3,
                    UIKeyCommand.f4,
                    UIKeyCommand.f5,
                    UIKeyCommand.f6,
                    UIKeyCommand.f7,
                    UIKeyCommand.f8,
                    UIKeyCommand.f9,
                    UIKeyCommand.f10,
                    UIKeyCommand.f11,
                    UIKeyCommand.f12,
                ][safe: n - 1]
            }
        }

        /// Runs a key-binding action.
        func perform(_ action: KeyAction) {
            if ActionDispatch.viewportDelta(for: action, rows: 0, history: 0) != nil {
                session.mutate { state in
                    let history = state.addressableRows - state.rows
                    if let delta = ActionDispatch.viewportDelta(for: action, rows: state.rows, history: history) {
                        state.scrollViewport(by: delta)
                    }
                }
                return
            }
            switch action {
            case .copyToClipboard: copy(nil)
            case .pasteFromClipboard: paste(nil)
            case let .increaseFontSize(n): setFontSize(fontSize + CGFloat(n))
            case let .decreaseFontSize(n): setFontSize(fontSize - CGFloat(n))
            case .resetFontSize: setFontSize(nil)
            case .selectAll: selectAll(nil)
            case let .jumpToPrompt(n): session.mutate { _ = $0.jumpToPrompt(n) }
            case .startSearch: showSearch(text: nil)
            case .searchSelection: showSearch(text: session.withState { $0.selectionText })
            case let .navigateSearch(next): navigateSearch(next: next)
            case .endSearch: hideSearch()
            case .clearScreen:
                clearSelection()
                session.mutate { $0.clearScreenKeepingCursorLine() }
            case .reset:
                clearSelection()
                session.mutate { $0.reset() }
            case .text, .csi, .esc:
                if let bytes = action.bytes {
                    send([.bytes(bytes)])
                }
            case .ignore, .scrollToTop, .scrollToBottom, .scrollPageUp, .scrollPageDown, .scrollPageLines: break
            }
        }

        // MARK: Accessory bar

        internal func accessoryKey(_ key: AccessoryKey) {
            if let modifier = key.modifier {
                sticky.tap(modifier)
                accessoryBar.update(sticky)
                return
            }
            clearSelection()
            send(key.inputs(modifiers: consumeSticky()))
        }

        /// Modifiers for the next key, releasing latched accessory toggles.
        internal func consumeSticky() -> KeyModifiers {
            let before = sticky
            let mods = sticky.consume()
            if sticky != before {
                accessoryBar.update(sticky)
            }
            return mods
        }

        internal func send(_ inputs: [TerminalInput]) {
            guard !inputs.isEmpty else { return }
            noteInput()
            for input in inputs {
                session.send(input)
            }
        }

        // MARK: Edit actions

        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            switch action {
            case #selector(copy(_:)): hasSelection
            case #selector(paste(_:)): UIPasteboard.general.hasStrings
            case #selector(selectAll(_:)), #selector(performKeyCommand(_:)): true
            default: false
            }
        }

        override func copy(_ sender: Any?) {
            guard let text = session.withState({ $0.selectionText }), !text.isEmpty else { return }
            UIPasteboard.general.string = text
        }

        override func paste(_ sender: Any?) {
            guard let text = UIPasteboard.general.string else { return }
            clearSelection()
            send([.paste(text)])
        }

        override func selectAll(_ sender: Any?) {
            session.mutate { $0.selectAll() }
            hasSelection = true
        }
    }

    extension Array {
        subscript(safe index: Int) -> Element? {
            indices.contains(index) ? self[index] : nil
        }
    }

    // MARK: - Text input (software keyboard, dictation, IME)

    /// Positions index the only editable text: the IME composition.
    final class TerminalTextPosition: UITextPosition {
        let offset: Int

        init(_ offset: Int) {
            self.offset = offset
        }
    }

    final class TerminalTextRange: UITextRange {
        let range: NSRange

        init(_ range: NSRange) {
            self.range = range
        }

        override var start: UITextPosition {
            TerminalTextPosition(range.location)
        }

        override var end: UITextPosition {
            TerminalTextPosition(NSMaxRange(range))
        }

        override var isEmpty: Bool {
            range.length == 0
        }
    }

    extension TerminalUIView: UITextInput {
        public var hasText: Bool {
            true // so the keyboard's delete key always reaches deleteBackward
        }

        public func insertText(_ text: String) {
            clearSelection()
            let committed = hardwareTextInput.commit(text, keyboardFlags: session.keyboardFlags)
            setPreedit("", selection: NSRange(location: 0, length: 0))
            let modifiers = consumeSticky()
            if let committed {
                send([.key(committed.event)])
                var release = committed.event
                release.action = .release
                heldKeys[committed.usage] = release
            } else {
                send(KeyTranslator.inputs(forText: text, modifiers: modifiers))
            }
        }

        public func deleteBackward() {
            clearSelection()
            send([.key(KeyEvent(.backspace, modifiers: consumeSticky()))])
        }

        public func insertDictationResult(_ dictationResult: [UIDictationPhrase]) {
            hardwareTextInput.cancel()
            insertText(dictationResult.map(\.text).joined())
        }

        // Marked text

        public var markedTextRange: UITextRange? {
            markedText.isEmpty ? nil : TerminalTextRange(NSRange(location: 0, length: markedText.utf16.count))
        }

        public var markedTextStyle: [NSAttributedString.Key: Any]? {
            get { nil }
            set {} // swiftlint:disable:this unused_setter_value
        }

        public func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
            hardwareTextInput.cancel()
            setPreedit(markedText ?? "", selection: selectedRange)
        }

        public func unmarkText() {
            guard !markedText.isEmpty else { return }
            insertText(markedText)
        }

        private func setPreedit(_ text: String, selection: NSRange) {
            markedSelection = selection
            guard text != markedText else { return }
            markedText = text
            renderer.options.preedit = Array(text.unicodeScalars)
            setNeedsDisplay()
        }

        // Document model: the composition only.

        public var selectedTextRange: UITextRange? {
            get { TerminalTextRange(markedText.isEmpty ? NSRange(location: 0, length: 0) : markedSelection) }
            set { markedSelection = (newValue as? TerminalTextRange)?.range ?? markedSelection }
        }

        private var documentLength: Int {
            markedText.utf16.count
        }

        private func offset(_ position: UITextPosition) -> Int {
            (position as? TerminalTextPosition)?.offset ?? 0
        }

        public func text(in range: UITextRange) -> String? {
            guard let range = (range as? TerminalTextRange)?.range,
                  let r = Range(range, in: markedText) else { return nil }
            return String(markedText[r])
        }

        public func replace(_ range: UITextRange, withText text: String) {
            insertText(text)
        }

        public var beginningOfDocument: UITextPosition {
            TerminalTextPosition(0)
        }

        public var endOfDocument: UITextPosition {
            TerminalTextPosition(documentLength)
        }

        public func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
            let a = offset(fromPosition), b = offset(toPosition)
            return TerminalTextRange(NSRange(location: min(a, b), length: abs(b - a)))
        }

        public func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
            let target = self.offset(position) + offset
            return (0 ... documentLength).contains(target) ? TerminalTextPosition(target) : nil
        }

        public func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
            switch direction {
            case .left: self.position(from: position, offset: -offset)
            case .right: self.position(from: position, offset: offset)
            default: nil
            }
        }

        public func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
            let a = offset(position), b = offset(other)
            return a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
        }

        public func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
            offset(toPosition) - offset(from)
        }

        public var tokenizer: UITextInputTokenizer {
            UITextInputStringTokenizer(textInput: self)
        }

        public func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
            switch direction {
            case .left, .up: range.start
            default: range.end
            }
        }

        public func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
            switch direction {
            case .left, .up: textRange(from: beginningOfDocument, to: position)
            default: textRange(from: position, to: endOfDocument)
            }
        }

        public func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection {
            .leftToRight
        }

        public func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

        // Geometry: everything sits at the terminal cursor, where the
        // composition is drawn and the candidate bar should appear.

        private var cursorRect: CGRect {
            geometry.rect(column: lastCursor?.x ?? 0, row: lastCursor?.y ?? 0)
        }

        public func firstRect(for range: UITextRange) -> CGRect {
            let cell = cursorRect
            let columns = max(1, (range as? TerminalTextRange)?.range.length ?? 1)
            return CGRect(x: cell.minX, y: cell.minY, width: cell.width * CGFloat(columns), height: cell.height)
        }

        public func caretRect(for position: UITextPosition) -> CGRect {
            let cell = cursorRect
            return CGRect(x: cell.minX + CGFloat(offset(position)) * cell.width, y: cell.minY, width: 2, height: cell.height)
        }

        public func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
            []
        }

        public func closestPosition(to point: CGPoint) -> UITextPosition? {
            endOfDocument
        }

        public func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
            range.end
        }

        public func characterRange(at point: CGPoint) -> UITextRange? {
            nil
        }
    }
#endif
