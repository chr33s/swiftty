#if canImport(UIKit)
    import SwifttyCore
    import UIKit

    // MARK: - Responder and hardware keyboard

    public extension TerminalUIView {
        override var canBecomeFirstResponder: Bool {
            true
        }

        #if !os(visionOS)
            override var inputAccessoryView: UIView? {
                isSearchVisible ? nil : accessoryBar
            }
        #endif

        @discardableResult
        override func becomeFirstResponder() -> Bool {
            guard super.becomeFirstResponder() else { return false }
            updateFocus()
            return true
        }

        @discardableResult
        override func resignFirstResponder() -> Bool {
            guard super.resignFirstResponder() else { return false }
            releaseHardwareKeys()
            updateFocus()
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
            keyDown(
                usage: key.keyCode.rawValue, modifiers: Self.modifiers(key.modifierFlags),
                base: key.charactersIgnoringModifiers, characters: key.characters,
            )
        }

        func keyDown(usage: Int, modifiers: KeyModifiers, base: String, characters: String) -> Bool {
            if !KeyTranslator.isModifier(usage) {
                stopKeyRepeat()
                hardwareTextInput.cancel()
            }
            let mods = modifiers.union(sticky.active)
            // While composing, every key belongs to the input method.
            guard markedText.isEmpty else {
                return false
            }
            if let identity = KeyTranslator.identity(usage: usage, modifiers: mods, base: base, characters: characters),
               let binding = configuration.keybindings.binding(for: identity) {
                let performed = performBinding(binding)
                if binding.consumesInput, !binding.requiresPerformable || performed {
                    _ = consumeSticky()
                    handledPresses.insert(usage)
                    return true
                }
            }
            guard let event = KeyTranslator.keyEvent(
                usage: usage, modifiers: mods, charactersIgnoringModifiers: base, characters: characters,
                keyboardFlags: session.keyboardFlags,
            ) else {
                if let identity = KeyTranslator.identity(usage: usage, modifiers: mods, base: base, characters: characters) {
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
            startKeyRepeat(event, usage: usage)
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
                    if keyRepeatUsage == usage {
                        stopKeyRepeat()
                    }
                } else {
                    forwarded.insert(press)
                }
            }
            return forwarded
        }

        /// UIKit does not repeat presses it does not deliver to the text
        /// system, so keys sent directly (arrows, Ctrl combinations) repeat
        /// here.
        private func startKeyRepeat(_ event: KeyEvent, usage: Int) {
            stopKeyRepeat()
            keyRepeatUsage = usage
            var repeated = event
            repeated.action = .repeat
            let sent = repeated
            keyRepeat = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.keyRepeat = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
                        guard let self else { timer.invalidate(); return }
                        MainActor.assumeIsolated { self.session.send(.key(sent)) }
                    }
                }
            }
        }

        internal func stopKeyRepeat() {
            keyRepeat?.invalidate()
            keyRepeat = nil
            keyRepeatUsage = nil
        }

        /// Focus changes may prevent UIKit from delivering the key-up.
        /// Release each press once and abandon pending hardware commits.
        internal func releaseHardwareKeys() {
            stopKeyRepeat()
            loadedAccessoryBar?.stopRepeating()
            hardwareTextInput.cancel()
            for release in heldKeys.values {
                session.send(.key(release))
            }
            heldKeys.removeAll()
            handledPresses.removeAll()
        }

        // MARK: Key bindings

        /// The configured bindings as key commands, so they show in the
        /// discoverability HUD (hold Cmd) and take priority over the system.
        override var keyCommands: [UIKeyCommand]? {
            if let cached = keyCommandCache {
                return cached
            }
            var commands: [UIKeyCommand] = []
            var commandBindings: [String: Keybindings.Binding] = [:]
            let bindings = configuration.keybindings.bindings.sorted {
                ActionDispatch.title(for: $0.value) < ActionDispatch.title(for: $1.value)
            }
            for (trigger, action) in bindings {
                // Key commands consume the press. Unconsumed bindings need
                // pressesBegan so the terminal receives the original key too.
                guard let binding = configuration.keybindings.binding(for: trigger),
                      binding.consumesInput, !binding.requiresPerformable else { continue }
                // Plain keys stay with the terminal; they are matched in pressesBegan.
                guard !trigger.modifiers.isDisjoint(with: [.command, .control, .alt]) || Self.isNonText(trigger.key),
                      let input = Self.keyCommandInput(trigger.key) else { continue }
                // Only the preferred trigger is titled, so the HUD lists each action once.
                let title = configuration.keybindings.trigger(for: action) == trigger ? ActionDispatch.title(for: action) : ""
                let identifier = UUID().uuidString
                let command = UIKeyCommand(
                    title: title, action: #selector(performKeyCommand(_:)), input: input,
                    modifierFlags: Self.flags(trigger.modifiers), propertyList: identifier,
                )
                command.wantsPriorityOverSystemBehavior = true
                commands.append(command)
                commandBindings[identifier] = binding
            }
            keyCommandBindings = commandBindings
            keyCommandCache = commands
            return commands
        }

        @objc internal func performKeyCommand(_ command: UIKeyCommand) {
            guard let identifier = command.propertyList as? String, let binding = keyCommandBindings[identifier] else { return }
            stopKeyRepeat()
            hardwareTextInput.cancel()
            _ = consumeSticky()
            _ = performBinding(binding)
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
        @discardableResult
        func perform(_ action: KeyAction) -> Bool {
            if ActionDispatch.viewportDelta(for: action, rows: 0, history: 0) != nil {
                stopMomentum()
                return session.mutate { state in
                    let before = state.viewportOffset
                    let history = state.addressableRows - state.rows
                    if let delta = ActionDispatch.viewportDelta(for: action, rows: state.rows, history: history) {
                        state.scrollViewport(by: delta)
                    }
                    return state.viewportOffset != before
                }
            }
            switch action {
            case .copyToClipboard: return copySelection()
            case .pasteFromClipboard: return pasteClipboard()
            case let .increaseFontSize(n): setFontSize(fontSize + CGFloat(n))
            case let .decreaseFontSize(n): setFontSize(fontSize - CGFloat(n))
            case .resetFontSize: setFontSize(nil)
            case .selectAll: selectAll(nil)
            case let .jumpToPrompt(n):
                stopMomentum()
                return session.mutate { $0.jumpToPrompt(n) }
            case .startSearch: showSearch(text: nil)
            case .searchSelection:
                guard let text = session.withState({ $0.selectionText }), !text.isEmpty else { return false }
                showSearch(text: text)
            case let .navigateSearch(next): return navigateSearch(next: next)
            case .endSearch:
                guard isSearchVisible else { return false }
                hideSearch()
            case .clearScreen:
                stopMomentum()
                clearSelection()
                session.mutate { $0.clearScreenKeepingCursorLine() }
            case .reset:
                stopMomentum()
                clearSelection()
                session.reset()
            case .text, .textBytes, .csi, .esc:
                if let bytes = action.bytes {
                    send([.bytes(bytes)])
                }
            case .ignore, .scrollToTop, .scrollToBottom, .scrollPageUp, .scrollPageDown, .scrollPageLines: break
            }
            return true
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
            stopKeyRepeat()
            noteInput()
            for input in inputs {
                session.send(input)
            }
        }

        // MARK: Edit actions

        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            switch action {
            case #selector(copy(_:)): hasSelection && session.withState { $0.selection != nil }
            case #selector(paste(_:)): pasteboard.hasStrings
            case #selector(selectAll(_:)), #selector(performKeyCommand(_:)): true
            default: false
            }
        }

        override func copy(_ sender: Any?) {
            _ = copySelection()
        }

        private func copySelection() -> Bool {
            guard let text = session.withState({ $0.selectionText }), !text.isEmpty else { return false }
            pasteboard.string = text
            return true
        }

        override func paste(_ sender: Any?) {
            _ = pasteClipboard()
        }

        private func pasteClipboard() -> Bool {
            guard let text = pasteboard.string else { return false }
            clearSelection()
            send([.paste(text)])
            return true
        }

        override func selectAll(_ sender: Any?) {
            stopMomentum()
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

    final class TerminalTextSelectionRect: UITextSelectionRect {
        private let bounds: CGRect

        init(_ bounds: CGRect) {
            self.bounds = bounds
            super.init()
        }

        override var rect: CGRect {
            bounds
        }

        override var writingDirection: NSWritingDirection {
            .leftToRight
        }

        override var containsStart: Bool {
            true
        }

        override var containsEnd: Bool {
            true
        }

        override var isVertical: Bool {
            false
        }
    }

    extension TerminalUIView: UITextInput {
        public var hasText: Bool {
            true // so the keyboard's delete key always reaches deleteBackward
        }

        public func insertText(_ text: String) {
            let committed = hardwareTextInput.commit(text, keyboardFlags: session.keyboardFlags)
            setPreedit("", selection: NSRange(location: 0, length: 0))
            guard !text.isEmpty else { return }
            clearSelection()
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
            if !markedText.isEmpty {
                let start = min(documentLength, max(0, markedSelection.location))
                let length = min(documentLength - start, max(0, markedSelection.length))
                if length > 0 {
                    replace(TerminalTextRange(NSRange(location: start, length: length)), withText: "")
                } else if start > 0 {
                    let scalars = renderer.options.preedit
                    let previous = TerminalGeometry.compositionPosition(in: scalars, atUTF16Offset: start - 1)
                    let end = TerminalGeometry.compositionPosition(in: scalars, atUTF16Offset: start, roundUp: true)
                    replace(TerminalTextRange(NSRange(
                        location: previous.utf16Offset, length: end.utf16Offset - previous.utf16Offset,
                    )), withText: "")
                }
                return
            }
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
            stopKeyRepeat()
            stopMomentum()
            hardwareTextInput.cancel()
            setPreedit(markedText ?? "", selection: selectedRange)
        }

        public func unmarkText() {
            guard !markedText.isEmpty else { return }
            insertText(markedText)
        }

        private func setPreedit(_ text: String, selection: NSRange) {
            let length = text.utf16.count
            let start = min(length, max(0, selection.location))
            markedSelection = NSRange(location: start, length: min(length - start, max(0, selection.length)))
            let renderedSelection = text.isEmpty ? nil : markedSelection
            guard text != markedText || renderer.options.preeditSelection != renderedSelection else { return }
            markedText = text
            renderer.options.preedit = Array(text.unicodeScalars)
            renderer.options.preeditSelection = renderedSelection
            setNeedsDisplay()
        }

        // Document model: the composition only.

        public var selectedTextRange: UITextRange? {
            get { TerminalTextRange(markedText.isEmpty ? NSRange(location: 0, length: 0) : markedSelection) }
            set {
                guard let range = (newValue as? TerminalTextRange)?.range, isDocumentRange(range) else { return }
                markedSelection = range
                renderer.options.preeditSelection = markedText.isEmpty ? nil : range
                setNeedsDisplay()
            }
        }

        private var documentLength: Int {
            markedText.utf16.count
        }

        private func offset(_ position: UITextPosition) -> Int {
            (position as? TerminalTextPosition)?.offset ?? 0
        }

        public func text(in range: UITextRange) -> String? {
            guard let range = (range as? TerminalTextRange)?.range,
                  let r = compositionRange(range) else { return nil }
            return String(markedText[r])
        }

        private func compositionRange(_ range: NSRange) -> Range<String.Index>? {
            guard isDocumentRange(range), let bounds = Range(range, in: markedText),
                  bounds.lowerBound.samePosition(in: markedText.unicodeScalars) != nil,
                  bounds.upperBound.samePosition(in: markedText.unicodeScalars) != nil else { return nil }
            return bounds
        }

        private func isDocumentRange(_ range: NSRange) -> Bool {
            range.location >= 0 && range.location <= documentLength && range.length >= 0
                && range.length <= documentLength - range.location
        }

        public func replace(_ range: UITextRange, withText text: String) {
            guard let range = (range as? TerminalTextRange)?.range,
                  let substring = compositionRange(range) else { return }
            guard !markedText.isEmpty else {
                insertText(text)
                return
            }
            let start = min(documentLength, max(0, markedSelection.location))
            let length = min(documentLength - start, max(0, markedSelection.length))
            let inserted = text.utf16.count
            let selection = if start >= range.location + range.length {
                NSRange(location: start - range.length + inserted, length: length)
            } else if start + length <= range.location {
                NSRange(location: start, length: length)
            } else {
                NSRange(location: range.location + inserted, length: 0)
            }
            var composition = markedText
            composition.replaceSubrange(substring, with: text)
            hardwareTextInput.cancel()
            setPreedit(composition, selection: selection)
        }

        public var beginningOfDocument: UITextPosition {
            TerminalTextPosition(0)
        }

        public var endOfDocument: UITextPosition {
            TerminalTextPosition(documentLength)
        }

        public func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
            guard let a = (fromPosition as? TerminalTextPosition)?.offset,
                  let b = (toPosition as? TerminalTextPosition)?.offset,
                  (0 ... documentLength).contains(a), (0 ... documentLength).contains(b) else { return nil }
            return TerminalTextRange(NSRange(location: min(a, b), length: max(a, b) - min(a, b)))
        }

        public func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
            guard let start = (position as? TerminalTextPosition)?.offset,
                  (0 ... documentLength).contains(start) else { return nil }
            let (target, overflow) = start.addingReportingOverflow(offset)
            guard !overflow, (0 ... documentLength).contains(target) else { return nil }
            return TerminalTextPosition(target)
        }

        public func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
            switch direction {
            case .left:
                guard offset != .min else { return nil }
                return self.position(from: position, offset: -offset)
            case .right: return self.position(from: position, offset: offset)
            default: return nil
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
            guard let bounds = (range as? TerminalTextRange)?.range, isDocumentRange(bounds) else { return nil }
            return switch direction {
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
            guard let range = (range as? TerminalTextRange)?.range else { return cell }
            let (end, overflow) = range.location.addingReportingOverflow(max(0, range.length))
            let startColumn = TerminalGeometry.compositionColumn(in: renderer.options.preedit, atUTF16Offset: range.location)
            let endColumn = TerminalGeometry.compositionColumn(
                in: renderer.options.preedit, atUTF16Offset: overflow ? .max : end, roundUp: range.length > 0,
            )
            return CGRect(
                x: cell.minX + CGFloat(startColumn) * cell.width, y: cell.minY,
                width: cell.width * CGFloat(max(1, endColumn - startColumn)), height: cell.height,
            )
        }

        public func caretRect(for position: UITextPosition) -> CGRect {
            let cell = cursorRect
            let column = TerminalGeometry.compositionColumn(in: renderer.options.preedit, atUTF16Offset: offset(position))
            return CGRect(x: cell.minX + CGFloat(column) * cell.width, y: cell.minY, width: 2, height: cell.height)
        }

        public func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
            guard let bounds = (range as? TerminalTextRange)?.range,
                  isDocumentRange(bounds), bounds.length > 0 else { return [] }
            return [TerminalTextSelectionRect(firstRect(for: range))]
        }

        public func closestPosition(to point: CGPoint) -> UITextPosition? {
            guard let column = compositionColumn(at: point) else { return nil }
            let hit = TerminalGeometry.compositionRange(in: renderer.options.preedit, atColumn: column)
            let midpoint = (CGFloat(hit.columns.lowerBound) + CGFloat(hit.columns.upperBound)) / 2
            return TerminalTextPosition(column < midpoint ? hit.utf16.lowerBound : hit.utf16.upperBound)
        }

        public func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
            guard let bounds = (range as? TerminalTextRange)?.range, isDocumentRange(bounds),
                  let position = closestPosition(to: point) as? TerminalTextPosition else { return nil }
            return TerminalTextPosition(min(bounds.location + bounds.length, max(bounds.location, position.offset)))
        }

        public func characterRange(at point: CGPoint) -> UITextRange? {
            guard let column = compositionColumn(at: point),
                  point.y >= cursorRect.minY, point.y < cursorRect.maxY else { return nil }
            let hit = TerminalGeometry.compositionRange(in: renderer.options.preedit, atColumn: column)
            guard !hit.utf16.isEmpty else { return nil }
            return TerminalTextRange(NSRange(location: hit.utf16.lowerBound, length: hit.utf16.count))
        }

        private func compositionColumn(at point: CGPoint) -> CGFloat? {
            let cell = cursorRect
            guard point.x.isFinite, point.y.isFinite, cell.minX.isFinite,
                  cell.width.isFinite, cell.width > 0 else { return nil }
            return (point.x - cell.minX) / cell.width
        }
    }
#endif
