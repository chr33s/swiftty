import AppKit
import Metal
@testable import Swiftty
import SwifttyCore
import Synchronization
import Testing
import TestSupport

/// VoiceOver throttling and text caching, and render options surviving a
/// configuration reload, in the macOS view.
@MainActor
@Suite(.serialized) struct ViewBehaviorTests {
    nonisolated static let hasMetal = MTLCreateSystemDefaultDevice() != nil

    func makeView(configuration: Configuration = Configuration()) throws -> TerminalView {
        _ = NSApplication.shared
        return try TerminalView(configuration: configuration)
    }

    @Test(.enabled(if: hasMetal), arguments: [false, true], [false, true])
    func `clipboard paste clears selection and filters controls through both actions`(_ binding: Bool, _ bracketed: Bool) throws {
        let view = try makeView()
        let clipboard = NSPasteboard.withUniqueName()
        view.pasteboard = clipboard
        defer { clipboard.releaseGlobally() }
        clipboard.setString("漢\u{15}text\u{03}end", forType: .string)
        view.session.feed(Array(("abc" + (bracketed ? "\u{1B}[?2004h" : "")).utf8))
        view.selectAll(nil)
        #expect(view.hasSelection)
        #expect(view.session.withState { $0.selection != nil })
        let writes = Mutex<[UInt8]>([])
        view.session.onWrite = { bytes in writes.withLock { $0.append(contentsOf: bytes) } }
        if binding {
            #expect(view.perform(.pasteFromClipboard))
        } else {
            view.paste(nil)
        }
        _ = view.session.snapshot()
        #expect(!view.hasSelection)
        #expect(view.session.withState { $0.selection == nil })
        let expected = bracketed ? "\u{1B}[200~漢 text end\u{1B}[201~" : "漢 text end"
        #expect(TestFixture(writes.withLock { String(decoding: $0, as: UTF8.self) }) == TestFixture(expected))
    }

    @Test(.enabled(if: hasMetal), arguments: [false, true])
    func `an unavailable clipboard paste retains selection`(_ binding: Bool) throws {
        let view = try makeView()
        let clipboard = NSPasteboard.withUniqueName()
        view.pasteboard = clipboard
        defer { clipboard.releaseGlobally() }
        view.session.feed(Array("abc".utf8))
        view.selectAll(nil)
        let writes = Mutex<[UInt8]>([])
        view.session.onWrite = { bytes in writes.withLock { $0.append(contentsOf: bytes) } }
        if binding {
            #expect(!view.perform(.pasteFromClipboard))
        } else {
            view.paste(nil)
        }
        _ = view.session.snapshot()
        #expect(view.hasSelection)
        #expect(view.session.withState { $0.selection != nil })
        #expect(writes.withLock { $0.isEmpty })
    }

    @Test(.enabled(if: hasMetal)) func `accessibility point queries exclude the search overlay`() throws {
        let view = try makeView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 240), styleMask: [.titled], backing: .buffered, defer: false,
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        view.session.feed(Array(String(repeating: "x", count: 200).utf8))
        view.draw(in: view)
        view.showSearch(text: "x")
        let bar = try #require(view.searchBar)
        let covered = view.convert(NSPoint(x: bar.field.frame.midX, y: bar.field.frame.midY), from: bar)
        func screen(_ point: NSPoint) -> NSPoint {
            window.convertPoint(toScreen: view.convert(point, to: nil))
        }
        #expect(view.accessibilityRange(for: screen(covered)) == NSRange(location: NSNotFound, length: 0))
        let exposed = NSPoint(x: 20, y: covered.y)
        #expect(view.accessibilityRange(for: screen(exposed)).location != NSNotFound)
        view.closeSearch()
        #expect(view.accessibilityRange(for: screen(covered)).location != NSNotFound)
    }

    @Test(.enabled(if: hasMetal), arguments: [
        CGFloat.nan, .infinity, -.infinity, .greatestFiniteMagnitude, CGFloat(Int.max), CGFloat(Int.min),
    ], [false, true])
    func `invalid wheel distances preserve progress in both scroll routes`(_ distance: CGFloat, _ tracking: Bool) throws {
        let view = try makeView()
        view.session.resize(columns: 10, rows: 2)
        view.session.feed(Array("row0\r\nrow1\r\nrow2\r\nrow3".utf8))
        if tracking {
            view.session.feed(Array("\u{1B}[?1000h\u{1B}[?1006h".utf8))
        }
        view.draw(in: view)
        let writes = Mutex<[[UInt8]]>([])
        view.session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
        let event = ReviewScrollEvent()
        event.distance = 0.4
        view.scrollWheel(with: event)
        event.distance = distance
        view.scrollWheel(with: event)
        #expect(view.scrollAccumulator.remainder == 0.4)
        #expect(view.horizontalScrollAccumulator.remainder == (tracking ? 0.4 : 0))
        _ = view.session.snapshot()
        #expect(writes.withLock { $0.isEmpty })
        event.distance = 0.6
        view.scrollWheel(with: event)
        let snapshot = view.session.snapshot()
        if tracking {
            #expect(writes.withLock { $0.count } == 2)
        } else {
            #expect(snapshot.viewportOffset == 1)
        }
    }

    @Test(.enabled(if: hasMetal), arguments: [
        (Double(-20), Double(1)), (0, 1), (0.5, 1), (201, 200),
        (.greatestFiniteMagnitude, 200), (.infinity, 200), (-.infinity, 1), (.nan, 13),
    ])
    func `programmatic font sizes remain bounded across reload and reset`(_ input: Double, _ expected: Double) throws {
        var configuration = Configuration()
        configuration.fontSize = input
        let view = try makeView(configuration: configuration)
        #expect(view.fontSize == CGFloat(expected) && view.renderer.font.descriptor.size == CGFloat(expected))
        view.setFontSize(40)
        #expect(view.fontSize == 40)
        view.setFontSize(nil)
        #expect(view.fontSize == CGFloat(expected) && view.renderer.font.descriptor.size == CGFloat(expected))
        view.apply(Configuration.parse("font-size=20"))
        #expect(view.fontSize == 20 && view.renderer.font.descriptor.size == 20)
        view.apply(configuration)
        #expect(view.fontSize == CGFloat(expected) && view.renderer.font.descriptor.size == CGFloat(expected))
        view.setFontSize(CGFloat(input))
        #expect(view.fontSize == CGFloat(expected) && view.renderer.font.descriptor.size == CGFloat(expected))
    }

    @Test(.enabled(if: hasMetal)) func `search controls hide terminal links and mouse motion reports`() throws {
        let view = try makeView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 240), styleMask: [.titled], backing: .buffered, defer: false,
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        view.session.feed(Array(("\u{1B}]8;;https://a.test\u{1B}\\" + String(repeating: "x", count: 200)).utf8))
        view.draw(in: view)
        view.showSearch(text: "x")
        let bar = try #require(view.searchBar)
        let location = view.convert(NSPoint(x: bar.field.frame.midX, y: bar.field.frame.midY), from: bar)
        let hit = try #require(view.hitTest(location))
        #expect(hit === bar.field || hit.isDescendant(of: bar.field))
        let event = try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: view.convert(location, to: nil), modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0,
        ))
        #expect(view.link(for: event) != nil)
        view.mouseMoved(with: event)
        #expect(view.hoveredLink == nil && view.renderer.options.hoveredLink == 0)
        let writes = Mutex<[[UInt8]]>([])
        view.session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
        view.session.feed(Array("\u{1B}[?1003h\u{1B}[?1006h".utf8))
        view.draw(in: view)
        view.mouseMoved(with: event)
        _ = view.session.snapshot()
        #expect(writes.withLock { $0.isEmpty })
        let exposed = try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: NSPoint(x: 20, y: location.y), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0,
        ))
        view.mouseMoved(with: exposed)
        _ = view.session.snapshot()
        #expect(writes.withLock { !$0.isEmpty })
    }

    @Test(.enabled(if: hasMetal), arguments: [false, true])
    func `modifier changes preserve the pointer location with terminal or search focus`(_ searching: Bool) throws {
        _ = NSApplication.shared
        var config = Configuration()
        config.command = "/bin/sleep 30"
        let controller = try TerminalWindowController(configuration: config)
        let window = try #require(controller.window)
        defer { window.close() }
        let view = try #require(window.contentView as? TerminalView)
        if searching {
            view.showSearch(text: "link")
        }
        let responder = try #require(window.firstResponder)
        view.session.feed(Array("https://a.test".utf8))
        view.draw(in: view)
        let scale = window.backingScaleFactor
        let location = NSPoint(
            x: (view.renderer.options.paddingX + view.renderer.cellSize.width / 2) / scale,
            y: view.bounds.height - (view.renderer.options.paddingY + view.renderer.cellSize.height / 2) / scale,
        )
        let motion = try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: location, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0,
        ))
        view.mouseMoved(with: motion)
        #expect(view.hoveredLink == nil)
        for flags: NSEvent.ModifierFlags in [.command, []] {
            let event = try #require(NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: 55,
            ))
            responder.flagsChanged(with: event)
            #expect((view.hoveredLink != nil) == flags.contains(.command))
            #expect(view.hoverEvent?.locationInWindow == location)
            view.draw(in: view)
            #expect((view.hoveredLink != nil) == flags.contains(.command))
        }
        view.mouseExited(with: motion)
        let command = try #require(NSEvent.keyEvent(
            with: .flagsChanged, location: location, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 55,
        ))
        responder.flagsChanged(with: command)
        #expect(view.hoverEvent == nil && view.hoveredLink == nil)
    }

    @Test(.enabled(if: hasMetal), arguments: [false, true])
    func `window deactivation clears command hover even while search owns focus`(_ searching: Bool) throws {
        let view = try makeView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 240), styleMask: [.titled], backing: .buffered, defer: false,
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        #expect(window.makeFirstResponder(view))
        if searching {
            view.showSearch(text: "link")
            #expect(window.firstResponder !== view)
        }
        view.session.feed(Array("https://a.test".utf8))
        view.draw(in: view)
        let scale = window.backingScaleFactor
        let event = try #require(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(
                x: (view.renderer.options.paddingX + view.renderer.cellSize.width / 2) / scale,
                y: view.bounds.height - (view.renderer.options.paddingY + view.renderer.cellSize.height / 2) / scale,
            ),
            modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0,
        ))
        view.updateHover(event)
        #expect(view.hoveredLink != nil)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(view.hoveredLink == nil && view.hoverEvent == nil && view.renderer.options.underlinedSpan == nil)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        view.draw(in: view)
        #expect(view.hoveredLink == nil)
        view.updateHover(event)
        #expect(view.hoveredLink != nil)
        if searching {
            view.closeSearch()
        } else {
            view.showSearch(text: "link")
        }
        #expect(view.hoveredLink == nil && view.hoverEvent == nil)
    }

    @Test(.enabled(if: hasMetal)) func `inactive views do not change the current pointer while refreshing hover`() throws {
        let view = try makeView()
        view.setFrameSize(NSSize(width: 320, height: 240))
        view.session.feed(Array("https://a.test".utf8))
        view.draw(in: view)
        let event = try #require(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(
                x: (view.renderer.options.paddingX + view.renderer.cellSize.width / 2) / 2,
                y: view.bounds.height - (view.renderer.options.paddingY + view.renderer.cellSize.height / 2) / 2,
            ),
            modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0,
        ))
        let previous = NSCursor.current
        defer { previous.set() }
        NSCursor.crosshair.set()
        view.updateHover(event)
        #expect(view.hoveredLink != nil)
        #expect(NSCursor.current === NSCursor.crosshair)
    }

    @Test(.enabled(if: hasMetal)) func `accessibility notifications distinguish text selection and unchanged frames`() throws {
        let view = try makeView()
        view.session.feed(Array("abc".utf8))
        view.draw(in: view)
        #expect(view.accessibilityChanges() == [.valueChanged, .selectedTextChanged])
        view.draw(in: view)
        #expect(view.accessibilityChanges().isEmpty)
        view.session.feed(Array("\u{1B}[2G".utf8))
        view.draw(in: view)
        #expect(view.accessibilityChanges() == [.selectedTextChanged])
        view.session.mutate {
            $0.setSelection(Selection(anchor: TerminalPoint(row: 0, column: 0), head: TerminalPoint(row: 0, column: 1)))
        }
        view.draw(in: view)
        #expect(view.accessibilityChanges() == [.selectedTextChanged])
        view.session.feed(Array("\u{1B}[31m".utf8))
        view.draw(in: view)
        #expect(view.accessibilityChanges().isEmpty)
        view.session.mutate { $0.setSelection(nil) }
        view.draw(in: view)
        #expect(view.accessibilityChanges() == [.selectedTextChanged])
        view.session.feed(Array("Z".utf8))
        view.draw(in: view)
        #expect(view.accessibilityChanges() == [.valueChanged, .selectedTextChanged])
    }

    @Test(.enabled(if: hasMetal)) func `accessibility throttle preserves both pending notification kinds`() async throws {
        let view = try makeView()
        view.accessibilityThrottle = NotificationThrottle(interval: 0.05)
        var posts: [NSAccessibility.Notification] = []
        let post: @MainActor (NSAccessibility.Notification) -> Void = { posts.append($0) }
        view.requestAccessibilityNotifications([.valueChanged], post: post)
        #expect(posts == [.valueChanged])
        posts.removeAll()
        view.requestAccessibilityNotifications([.selectedTextChanged], post: post)
        view.requestAccessibilityNotifications([.valueChanged], post: post)
        view.requestAccessibilityNotifications([.selectedTextChanged], post: post)
        #expect(posts.isEmpty)
        let deadline = CACurrentMediaTime() + 2
        while posts.count < 2, CACurrentMediaTime() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(posts == [.valueChanged, .selectedTextChanged])
        view.requestAccessibilityNotifications([], post: post)
        #expect(posts.count == 2)
    }

    @Test(.enabled(if: hasMetal), arguments: [false, true])
    func `accessibility selection ranges match visible Unicode text`(_ rectangle: Bool) throws {
        let view = try makeView()
        view.session.feed(Array("A😀e\u{301}中Z\r\nnext".utf8))
        view.session.mutate {
            $0.setSelection(Selection(
                anchor: TerminalPoint(row: 0, column: rectangle ? 1 : 3),
                head: TerminalPoint(row: 1, column: rectangle ? 3 : 1), rectangle: rectangle,
            ))
        }
        view.draw(in: view)
        let expected = rectangle ? [NSRange(location: 1, length: 4), NSRange(location: 9, length: 3)]
            : [NSRange(location: 3, length: 7)]
        #expect(view.accessibilitySelectedTextRange() == expected[0])
        #expect(view.accessibilitySelectedTextRanges()?.map(\.rangeValue) == expected)
        #expect(TestFixture(view.accessibilitySelectedText()) == TestFixture(rectangle ? "😀e\u{301}\next" : "e\u{301}中Z\nne"))
    }

    @Test(.enabled(if: hasMetal)) func `accessibility selection includes exposed soft wrap separators and clears to the cursor`() throws {
        let view = try makeView()
        view.session.mutate { $0.resize(columns: 3, rows: 2) }
        view.session.feed(Array("ABCDEF".utf8))
        view.session.mutate { $0.selectAll() }
        view.draw(in: view)
        #expect(view.session.withState { $0.selectionText } == "ABCDEF")
        #expect(TestFixture(view.accessibilitySelectedText()) == TestFixture("ABC\nDEF"))
        #expect(view.accessibilitySelectedTextRange() == NSRange(location: 0, length: 7))
        view.session.mutate { $0.setSelection(nil) }
        view.draw(in: view)
        let cursor = view.accessibilitySelectedTextRange()
        #expect(cursor.length == 0)
        #expect(view.accessibilitySelectedTextRanges()?.map(\.rangeValue) == [cursor])
        #expect(view.accessibilitySelectedText() == "")
    }

    @Test(.enabled(if: hasMetal), arguments: [1, 2])
    func `accessibility selection includes either half of a wide glyph`(_ column: Int) throws {
        let view = try makeView()
        view.session.feed(Array("A😀e\u{301}中Z".utf8))
        view.session.mutate {
            $0.setSelection(Selection(anchor: TerminalPoint(row: 0, column: column), head: TerminalPoint(row: 0, column: 4)))
        }
        view.draw(in: view)
        #expect(view.accessibilitySelectedTextRange() == NSRange(location: 1, length: 5))
        #expect(view.accessibilitySelectedText() == "😀e\u{301}中")
    }

    @Test(.enabled(if: hasMetal)) func `accessibility selection is clipped to the exposed viewport`() throws {
        let view = try makeView()
        view.session.mutate { $0.resize(columns: 20, rows: 2) }
        view.session.feed(Array("row0\r\nrow1\r\nrow2\r\nrow3".utf8))
        view.session.mutate {
            $0.setSelection(Selection(anchor: TerminalPoint(row: 0, column: 0), head: TerminalPoint(row: 2, column: 1)))
        }
        view.draw(in: view)
        #expect(view.accessibilitySelectedTextRange() == NSRange(location: 0, length: 2))
        #expect(view.accessibilitySelectedText() == "ro")
    }

    @Test(.enabled(if: hasMetal), arguments: [Int.min, -1, 0, Int.max])
    func `unknown find menu tags open the find bar without trapping`(_ tag: Int) throws {
        let view = try makeView()
        let item = NSMenuItem(title: "Find", action: #selector(TerminalView.performFindPanelAction(_:)), keyEquivalent: "")
        item.tag = tag
        view.performFindPanelAction(item)
        let bar = try #require(view.searchBar)
        view.showSearch(text: "needle")
        view.performFindPanelAction(item)
        #expect(view.searchBar === bar)
        #expect(TestFixture(bar.text) == TestFixture("needle"))
    }

    @Test(.enabled(if: hasMetal), arguments: [false, true])
    func `find menu navigation reaches the terminal while its query field is editing`(_ next: Bool) throws {
        _ = NSApplication.shared
        let controller = try TerminalWindowController(configuration: Configuration.parse("command=/bin/sleep 30"))
        let window = try #require(controller.window)
        let view = try #require(window.contentView as? TerminalView)
        defer { window.close() }
        view.session.feed(Array("needle0\r\nneedle1\r\nneedle2".utf8))
        view.showSearch(text: "needle")
        let editor = try #require(view.searchBar?.field.currentEditor())
        #expect(window.fieldEditor(true, for: nil) !== editor)
        #expect(view.session.snapshot().searchSelectedIndex == 2)
        let item = NSMenuItem(title: "Find Next", action: #selector(TerminalView.performFindPanelAction(_:)), keyEquivalent: "g")
        item.tag = Int((next ? NSFindPanelAction.next : .previous).rawValue)
        let action = try #require(item.action)
        #expect(NSApp.sendAction(action, to: window.firstResponder, from: item))
        #expect(view.session.snapshot().searchSelectedIndex == (next ? 1 : 0))
        #expect(editor.string == "needle")
        let textView = try #require(editor as? NSTextView)
        textView.insertText("needle1", replacementRange: NSRange(location: 0, length: 6))
        #expect(TestFixture(view.searchBar?.text) == TestFixture("needle1"))
        #expect(view.session.snapshot().searchMatchCount == 1)
    }

    @Test(.enabled(if: hasMetal)) func `configuration reload preserves search focus across background layouts`() throws {
        _ = NSApplication.shared
        var config = Configuration()
        config.command = "/bin/sleep 30"
        let controller = try TerminalWindowController(configuration: config)
        let window = try #require(controller.window)
        defer { window.close() }
        let view = try #require(window.contentView as? TerminalView)
        view.showSearch(text: "needle")
        let field = try #require(view.searchBar?.field)
        let editor = try #require(field.currentEditor())
        try #require(editor.string == "needle")
        let selection = NSRange(location: 2, length: 2)
        editor.selectedRange = selection
        try #require(editor.selectedRange == selection)
        #expect(window.firstResponder === editor)
        controller.apply(config)
        #expect(field.currentEditor() != nil && window.firstResponder === field.currentEditor())
        #expect(field.currentEditor()?.selectedRange == selection)
        config.backgroundOpacity = 0.5
        config.backgroundBlur = 20
        controller.apply(config)
        #expect(window.contentView is NSVisualEffectView)
        #expect(field.currentEditor() != nil && window.firstResponder === field.currentEditor())
        #expect(field.currentEditor()?.selectedRange == selection)
        config.backgroundOpacity = 1
        controller.apply(config)
        #expect(window.contentView === view)
        #expect(field.currentEditor() != nil && window.firstResponder === field.currentEditor())
        #expect(field.currentEditor()?.selectedRange == selection)
    }

    @Test(.enabled(if: hasMetal)) func `stationary command hover follows output settings and pointer exit`() throws {
        let view = try makeView()
        view.setFrameSize(NSSize(width: 400, height: 200))
        view.session.feed(Array("\u{1B}]8;;https://example.com\u{1B}\\link\u{1B}]8;;\u{1B}\\".utf8))
        view.draw(in: view)
        let event = try #require(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(
                x: (view.renderer.options.paddingX + view.renderer.cellSize.width / 2) / 2,
                y: view.bounds.height - (view.renderer.options.paddingY + view.renderer.cellSize.height / 2) / 2,
            ),
            modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0,
        ))
        view.updateHover(event)
        #expect(view.hoveredLink != nil && view.renderer.options.hoveredLink != 0)
        view.session.feed(Array("\r\u{1B}[2Khttps://a.test".utf8))
        view.draw(in: view)
        #expect(view.hoveredLink?.url == "https://a.test" && view.renderer.options.underlinedSpan != nil)
        view.apply(Configuration.parse("link-url=false"))
        #expect(view.hoveredLink == nil && view.renderer.options.underlinedSpan == nil)
        view.apply(Configuration.parse("link-url=true"))
        #expect(view.hoveredLink?.url == "https://a.test")
        view.mouseExited(with: event)
        #expect(view.hoveredLink == nil && view.renderer.options.underlinedSpan == nil)
    }

    @Test(.enabled(if: hasMetal)) func `command hover updates a wrapped URL span as the viewport moves`() throws {
        let view = try makeView()
        view.setFrameSize(NSSize(width: 400, height: 200))
        view.session.mutate { $0.resize(columns: 10, rows: 2) }
        let url = "https://example.com/abcdefghijklmno"
        view.session.feed(Array(url.utf8))
        view.draw(in: view)
        let event = try #require(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(
                x: (view.renderer.options.paddingX + view.renderer.cellSize.width / 2) / 2,
                y: view.bounds.height - (view.renderer.options.paddingY + view.renderer.cellSize.height / 2) / 2,
            ),
            modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0,
        ))
        view.updateHover(event)
        #expect(view.hoveredLink?.url == url)
        let link = try #require(view.hoveredLink)
        let before = try #require(view.renderer.options.underlinedSpan)
        view.session.scrollViewport(by: 1)
        view.draw(in: view)
        #expect(view.hoveredLink == link)
        let after = try #require(view.renderer.options.underlinedSpan)
        #expect(after.startRow == before.startRow + 1)
        #expect(after.endRow == before.endRow + 1)
    }

    @Test(.enabled(if: hasMetal), arguments: [false, true])
    func `selection reaches the mouse up cell while plain clicks remain unselected`(_ dragged: Bool) throws {
        let view = try makeView()
        view.setFrameSize(NSSize(width: 400, height: 200))
        view.session.feed(Array("abcdef".utf8))
        view.draw(in: view)
        func event(_ type: NSEvent.EventType, column: Int) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type,
                location: NSPoint(
                    x: (view.renderer.options.paddingX + (CGFloat(column) + 0.5) * view.renderer.cellSize.width) / 2,
                    y: view.bounds.height - (view.renderer.options.paddingY + view.renderer.cellSize.height / 2) / 2,
                ),
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0,
            ))
        }
        try view.mouseDown(with: event(.leftMouseDown, column: 0))
        if dragged {
            try view.mouseDragged(with: event(.leftMouseDragged, column: 1))
            #expect(view.session.withState { $0.selectionText } == "ab")
        }
        try view.mouseUp(with: event(.leftMouseUp, column: dragged ? 4 : 0))
        #expect(view.session.withState { $0.selectionText } == (dragged ? "abcde" : nil))
        #expect(view.selectionOrigin == nil)
    }

    @Test(.enabled(if: hasMetal)) func `releasing an edge drag does not add an automatic scroll step`() throws {
        let view = try makeView()
        view.setFrameSize(NSSize(width: 400, height: 200))
        view.session.mutate { $0.resize(columns: 10, rows: 2) }
        view.session.feed(Array("row0\r\nrow1\r\nrow2\r\nrow3\r\nrow4".utf8))
        view.draw(in: view)
        func event(_ type: NSEvent.EventType, outside: Bool) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type,
                location: NSPoint(
                    x: (view.renderer.options.paddingX + view.renderer.cellSize.width / 2) / 2,
                    y: outside ? view.bounds.height + view.renderer.cellSize.height
                        : view.bounds.height - (view.renderer.options.paddingY + view.renderer.cellSize.height / 2) / 2,
                ),
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0,
            ))
        }
        try view.mouseDown(with: event(.leftMouseDown, outside: false))
        try view.mouseDragged(with: event(.leftMouseDragged, outside: true))
        let offset = view.session.snapshot().viewportOffset
        try #require(offset > 0)
        try view.mouseUp(with: event(.leftMouseUp, outside: true))
        #expect(view.session.snapshot().viewportOffset == offset)
    }

    @Test(.enabled(if: hasMetal), arguments: [-3, 3], [0, 2])
    func `horizontal wheel reports reach mouse tracking applications`(_ horizontal: Int32, _ vertical: Int32) throws {
        let view = try makeView()
        let writes = Mutex<[[UInt8]]>([])
        view.session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
        view.session.feed(Array("\u{1B}[?1000h\u{1B}[?1006h".utf8))
        view.draw(in: view)
        let cg = try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0,
        ))
        cg.location = .zero
        let event = try #require(NSEvent(cgEvent: cg))
        #expect(event.scrollingDeltaX == CGFloat(horizontal))
        #expect(event.scrollingDeltaY == CGFloat(vertical))
        view.scrollWheel(with: event)
        _ = view.session.snapshot()
        let sent = writes.withLock { $0.map { String(decoding: $0, as: UTF8.self) } }
        let verticalReports = Array(repeating: "\u{1B}[<64;1;1M", count: Int(vertical))
        let horizontalReports = Array(repeating: "\u{1B}[<\(horizontal > 0 ? 66 : 67);1;1M", count: Int(abs(horizontal)))
        #expect(sent == verticalReports + horizontalReports)
    }

    @Test(.enabled(if: hasMetal), arguments: [-1, 1])
    func `precise horizontal wheel movement accumulates and clears outside tracking`(_ direction: Int32) throws {
        let view = try makeView()
        let writes = Mutex<[[UInt8]]>([])
        view.session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
        view.session.feed(Array("\u{1B}[?1000h\u{1B}[?1006h".utf8))
        view.draw(in: view)
        let cg = try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: direction, wheel3: 0,
        ))
        cg.location = .zero
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(direction))
        let event = try #require(NSEvent(cgEvent: cg))
        #expect(event.hasPreciseScrollingDeltas)
        #expect(event.scrollingDeltaX == CGFloat(direction))
        let width = view.renderer.cellSize.width / (view.window?.backingScaleFactor ?? 2)
        try #require(width > 1)
        view.scrollWheel(with: event)
        _ = view.session.snapshot()
        #expect(writes.withLock { $0.isEmpty })
        #expect(view.horizontalScrollAccumulator.remainder == CGFloat(direction) / width)
        for _ in 1 ..< Int(ceil(width)) {
            view.scrollWheel(with: event)
        }
        _ = view.session.snapshot()
        #expect(TestFixture(writes.withLock { $0.map { String(decoding: $0, as: UTF8.self) } }) ==
            TestFixture(["\u{1B}[<\(direction > 0 ? 66 : 67);1;1M"]))
        view.session.feed(Array("\u{1B}[?1000l".utf8))
        view.draw(in: view)
        view.scrollWheel(with: event)
        #expect(view.horizontalScrollAccumulator.remainder == 0)
    }

    @Test(.enabled(if: hasMetal), arguments: [1000, 1002, 1003], [false, true])
    func `right and middle drags report motion in the requested tracking mode`(_ mode: Int, _ middle: Bool) throws {
        let view = try makeView()
        let writes = Mutex<[[UInt8]]>([])
        view.session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
        view.session.feed(Array("\u{1B}[?\(mode)h\u{1B}[?1006h".utf8))
        view.draw(in: view)
        func event(_ type: CGEventType) throws -> NSEvent {
            let cg = try #require(CGEvent(
                mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: middle ? .center : .right,
            ))
            return try #require(NSEvent(cgEvent: cg))
        }
        if middle {
            try view.otherMouseDown(with: event(.otherMouseDown))
            try view.otherMouseDragged(with: event(.otherMouseDragged))
            try view.otherMouseUp(with: event(.otherMouseUp))
        } else {
            try view.rightMouseDown(with: event(.rightMouseDown))
            try view.rightMouseDragged(with: event(.rightMouseDragged))
            try view.rightMouseUp(with: event(.rightMouseUp))
        }
        _ = view.session.snapshot()
        let code = middle ? 1 : 2
        var expected = ["\u{1B}[<\(code);1;1M"]
        if mode != 1000 {
            expected.append("\u{1B}[<\(code + 32);1;1M")
        }
        expected.append("\u{1B}[<\(code);1;1m")
        #expect(writes.withLock { $0 } == expected.map { Array($0.utf8) })
    }

    @Test(.enabled(if: hasMetal), arguments: [3, 4, 5])
    func `unsupported mouse buttons do not emit middle button reports`(_ button: Int) throws {
        let view = try makeView()
        let writes = Mutex<[[UInt8]]>([])
        view.session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
        view.session.feed(Array("\u{1B}[?1003h\u{1B}[?1006h".utf8))
        view.draw(in: view)
        for type in [CGEventType.otherMouseDown, .otherMouseDragged, .otherMouseUp] {
            let cg = try #require(CGEvent(
                mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .center,
            ))
            cg.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
            let event = try #require(NSEvent(cgEvent: cg))
            #expect(event.buttonNumber == button)
            switch type {
            case .otherMouseDown: view.otherMouseDown(with: event)
            case .otherMouseDragged: view.otherMouseDragged(with: event)
            default: view.otherMouseUp(with: event)
            }
        }
        _ = view.session.snapshot()
        #expect(writes.withLock { $0.isEmpty })
    }

    @Test(.enabled(if: hasMetal)) func `detached blinking text stays visible through restart`() throws {
        let view = try makeView(configuration: Configuration.parse("command=/bin/sleep 30"))
        defer { view.stop() }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 256, height: 128, mipmapped: false,
        )
        descriptor.usage = [.renderTarget]
        let texture = try #require(view.device?.makeTexture(descriptor: descriptor))
        view.session.feed(Array("\u{1B}[5mX".utf8))
        let command = view.renderer.render(view.session.snapshot(), to: texture)
        command.waitUntilCompleted()
        try #require(command.status == .completed, Comment(rawValue: escapedTestText("\(String(describing: command.error))")))
        #expect(view.renderer.hasBlinkingText)
        view.draw(in: view)

        RunLoop.main.run(until: Date().addingTimeInterval(0.65))
        view.draw(in: view)
        #expect(view.renderer.options.textBlinkVisible)
        view.stop()
        view.draw(in: view)
        #expect(view.renderer.options.textBlinkVisible)
        try view.start()
        view.draw(in: view)
        RunLoop.main.run(until: Date().addingTimeInterval(0.65))
        view.draw(in: view)
        #expect(view.renderer.options.textBlinkVisible)
    }

    @Test(.enabled(if: hasMetal)) func `detached animated shader frames stay suspended through restart`() throws {
        let view = try makeView(configuration: Configuration.parse("command=/bin/sleep 30"))
        defer { view.stop() }
        try view.renderer.setPostProcessShader("""
        float4 postprocess(float2 position, texture2d<float> source, constant PostUniforms &u) {
            return float4(sin(u.time), 0, 0, 1);
        }
        """)
        view.draw(in: view)
        #expect(view.isPaused && view.enableSetNeedsDisplay)
        view.stop()
        #expect(view.isPaused && view.enableSetNeedsDisplay)
        view.draw(in: view) // An update already queued before stop can still draw.
        #expect(view.isPaused && view.enableSetNeedsDisplay)
        try view.start()
        view.draw(in: view)
        #expect(view.isPaused && view.enableSetNeedsDisplay)
    }

    @Test(.enabled(if: hasMetal)) func `select command output finds output whose prompt has left history`() throws {
        let view = try makeView(configuration: Configuration.parse("scrollback-limit=0"))
        view.session.resize(columns: 20, rows: 3)
        let prompt = "\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}"
        let output = "\r\n\u{1B}]133;C\u{7}"
        let done = "\u{1B}]133;D;0\u{7}"
        view.session.feed(Array((prompt + "first" + output + "first output\r\n" + done + prompt + "true" + output + done + prompt).utf8))
        #expect(view.session.withState { $0.firstAbsoluteRow } > 0)
        view.selectCommandOutput(nil)
        #expect(view.session.withState { $0.selectionText } == "first output")
        #expect(view.hasSelection)
    }

    @Test(.enabled(if: hasMetal), arguments: [1, 3])
    func `select command output skips intervening commands without output`(_ emptyCommands: Int) throws {
        let view = try makeView()
        view.session.resize(columns: 20, rows: 10)
        let prompt = "\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}"
        let output = "\r\n\u{1B}]133;C\u{7}"
        let done = "\u{1B}]133;D;0\u{7}"
        view.session.feed(Array((prompt + "first" + output + "first output\r\n" + done).utf8))
        for _ in 0 ..< emptyCommands {
            view.session.feed(Array((prompt + "true" + output + done).utf8))
        }
        view.session.feed(Array(prompt.utf8))
        view.selectCommandOutput(nil)
        #expect(view.session.withState { $0.selectionText } == "first output")
        #expect(view.hasSelection)
    }

    @Test(.enabled(if: hasMetal), arguments: ["resize", "reset", "evict"])
    func `select command output ignores a click whose coordinates are no longer valid`(_ change: String) throws {
        let view = try makeView(configuration: Configuration.parse("scrollback-limit=0"))
        view.session.resize(columns: 20, rows: change == "evict" ? 5 : 8)
        let prompt = "\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}"
        let output = "\r\n\u{1B}]133;C\u{7}"
        let done = "\r\n\u{1B}]133;D;0\u{7}"
        view.session.feed(Array((prompt + "first" + output + "first output" + done + prompt).utf8))
        view.lastClick = (TerminalPoint(row: 0, column: 0), view.session.withState { $0.addressingGeneration })
        if change == "reset" {
            view.session.reset()
            view.session
                .feed(Array((prompt + "first" + output + "new first" + done + prompt + "second" + output + "new last" + done + prompt)
                        .utf8))
        } else {
            view.session
                .feed(Array(("second" + output + "second output" + done + prompt + "third" + output + "third output" + done + prompt).utf8))
            if change == "resize" {
                view.session.resize(columns: 30, rows: 8)
            }
        }
        view.selectCommandOutput(nil)
        #expect(view.session.withState { $0.selectionText } == (change == "reset" ? "new last" : "third output"))
    }

    @Test(.enabled(if: hasMetal), arguments: [false, true])
    func `select command output chooses the most recent available output`(_ editingNextPrompt: Bool) throws {
        let view = try makeView()
        let prompt = "\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}"
        let output = "\r\n\u{1B}]133;C\u{7}"
        let done = "\r\n\u{1B}]133;D;0\u{7}"
        view.session.feed(Array((prompt + "first" + output + "first output" + done + prompt + "second" + output + "second output").utf8))
        if editingNextPrompt {
            view.session.feed(Array((done + prompt).utf8))
        }
        view.selectCommandOutput(nil)
        #expect(view.session.withState { $0.selectionText } == "second output")
        #expect(view.hasSelection)
        // An explicit click continues to select that command's output.
        view.lastClick = (TerminalPoint(row: 0, column: 0), view.session.withState { $0.addressingGeneration })
        view.selectCommandOutput(nil)
        #expect(view.session.withState { $0.selectionText } == "first output")
    }

    @Test(.enabled(if: hasMetal)) func `unavailable performable prompt navigation sends the key to the application`() throws {
        let configuration = Configuration.parse("keybind=performable:ctrl+arrow_down=jump_to_prompt:1")
        let view = try makeView(configuration: configuration)
        let writes = Mutex<[UInt8]>([])
        view.session.onWrite = { bytes in writes.withLock { $0.append(contentsOf: bytes) } }
        view.session.feed(Array("\u{1B}]133;A\u{7}first\r\n\u{1B}]133;A\u{7}second".utf8))
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125,
        ))
        view.keyDown(with: event)
        _ = view.session.snapshot()
        #expect(TestFixture(writes.withLock { $0 }) == TestFixture(Array("\u{1B}[1;5B".utf8)))
        #expect(view.session.withState { $0.viewportOffset } == 0)
    }

    @Test(.enabled(if: hasMetal), arguments: ["crosshair", "none"])
    func `terminal reset restores the frontend pointer cursor`(_ shape: String) async throws {
        let view = try makeView()
        func waitForCursor(_ cursor: NSCursor) async throws {
            let deadline = Date().addingTimeInterval(2)
            while view.applicationCursor !== cursor, Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(view.applicationCursor === cursor)
        }
        view.session.feed(Array("\u{1B}]22;\(shape)\u{7}".utf8))
        _ = view.session.snapshot()
        try await waitForCursor(TerminalView.cursor(named: shape))
        view.session.reset()
        _ = view.session.snapshot()
        try await waitForCursor(.iBeam)
    }

    @Test(.enabled(if: hasMetal), arguments: ["plain", "attributed", "composition"])
    func `text system commits clear terminal selection`(_ route: String) throws {
        let view = try makeView()
        let writes = Mutex<[UInt8]>([])
        view.session.onWrite = { bytes in writes.withLock { $0.append(contentsOf: bytes) } }
        view.session.feed(Array("selected output".utf8))
        view.selectAll(nil)
        let replacement = NSRange(location: NSNotFound, length: 0)
        view.insertText("", replacementRange: replacement)
        #expect(view.hasSelection)
        #expect(view.session.withState { $0.selection != nil })
        #expect(writes.withLock { $0.isEmpty })
        let text = "漢e\u{301}"
        switch route {
        case "composition":
            view.setMarkedText(text, selectedRange: NSRange(location: 0, length: 0), replacementRange: replacement)
            view.unmarkText()
        case "attributed":
            view.insertText(NSAttributedString(string: text), replacementRange: replacement)
        default:
            view.insertText(text, replacementRange: replacement)
        }
        _ = view.session.snapshot()
        #expect(!view.hasSelection)
        #expect(view.session.withState { $0.selection == nil })
        #expect(writes.withLock { $0 } == Array(text.utf8))
    }

    @Test(.enabled(if: hasMetal)) func `IME selection follows marked text updates and clears on commit`() throws {
        let view = try makeView()
        let writes = Mutex<[UInt8]>([])
        view.session.onWrite = { bytes in writes.withLock { $0.append(contentsOf: bytes) } }
        let replacement = NSRange(location: NSNotFound, length: 0)
        view.setMarkedText("😀ab", selectedRange: NSRange(location: 2, length: 1), replacementRange: replacement)
        #expect(view.markedRange() == NSRange(location: 0, length: 4))
        #expect(view.selectedRange() == NSRange(location: 2, length: 1))
        #expect(view.renderer.options.preeditSelection == NSRange(location: 2, length: 1))
        // IMEs can move the selection without changing the composition.
        view.setMarkedText("😀ab", selectedRange: NSRange(location: 3, length: 0), replacementRange: replacement)
        #expect(view.selectedRange() == NSRange(location: 3, length: 0))
        #expect(view.renderer.options.preeditSelection == NSRange(location: 3, length: 0))
        view.unmarkText()
        _ = view.session.snapshot()
        #expect(writes.withLock { $0 } == Array("😀ab".utf8))
        #expect(!view.hasMarkedText() && view.renderer.options.preedit.isEmpty)
        #expect(view.renderer.options.preeditSelection == nil)
        #expect(view.selectedRange() == replacement)
        #expect(view.markedRange() == replacement)
        view.unmarkText()
        _ = view.session.snapshot()
        #expect(writes.withLock { $0 } == Array("😀ab".utf8))
    }

    @Test(.enabled(if: hasMetal), arguments: [
        ("e\u{301}", 1), ("中", 2), ("👩‍💻", 2), ("🇻🇳", 2), ("❤\u{FE0F}", 2), ("⌚\u{FE0E}", 1),
    ])
    func `IME candidate rectangles follow composition ranges`(_ prefix: String, _ columns: Int) throws {
        let view = try makeView()
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        view.session.feed(Array("\u{1B}[2;4H".utf8))
        view.lastSnapshot = view.session.snapshot()
        view.setMarkedText(
            prefix + "X",
            selectedRange: NSRange(location: prefix.utf16.count, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0),
        )
        let cellWidth = view.renderer.cellSize.width / view.renderer.font.descriptor.scale
        let origin = view.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        #expect(origin.width == 0)
        var actual = NSRange(location: NSNotFound, length: 0)
        let suffixRange = NSRange(location: prefix.utf16.count, length: 1)
        let suffix = view.firstRect(forCharacterRange: suffixRange, actualRange: &actual)
        #expect(abs(suffix.minX - (origin.minX + CGFloat(columns) * cellWidth)) < 0.001)
        #expect(abs(suffix.width - cellWidth) < 0.001 && suffix.minY == origin.minY)
        #expect(actual == suffixRange)
        let partial = view.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: &actual)
        #expect(abs(partial.width - CGFloat(columns) * cellWidth) < 0.001)
        #expect(actual == NSRange(location: 0, length: prefix.utf16.count))
        let caretRange = NSRange(location: prefix.utf16.count, length: 0)
        let caret = view.firstRect(forCharacterRange: caretRange, actualRange: &actual)
        #expect(caret.minX == suffix.minX && caret.width == 0)
        #expect(actual == caretRange)
        let whole = view.firstRect(forCharacterRange: NSRange(location: 0, length: .max), actualRange: &actual)
        #expect(abs(whole.width - CGFloat(columns + 1) * cellWidth) < 0.001)
        #expect(actual == NSRange(location: 0, length: prefix.utf16.count + 1))
    }

    @Test(.enabled(if: hasMetal)) func `IME candidate rectangles convert nested view coordinates to screen`() throws {
        let view = try makeView()
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 120, width: 640, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        window.contentView = container
        view.frame = NSRect(x: 40, y: 50, width: 500, height: 300)
        container.addSubview(view)
        view.session.feed(Array("\u{1B}[2;4H".utf8))
        view.lastSnapshot = view.session.snapshot()
        view.setMarkedText(
            "👩‍💻X",
            selectedRange: NSRange(location: 5, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0),
        )
        let scale = window.backingScaleFactor, cell = view.renderer.cellSize
        let expected = window.convertToScreen(NSRect(
            x: 40 + (view.renderer.options.paddingX + 5 * cell.width) / scale,
            y: 50 + view.bounds.height - (view.renderer.options.paddingY + 2 * cell.height) / scale,
            width: cell.width / scale, height: cell.height / scale,
        ))
        let actual = view.firstRect(forCharacterRange: NSRange(location: 5, length: 1), actualRange: nil)
        #expect(actual == expected)
    }

    @Test(.enabled(if: hasMetal)) func `extreme cell sizes and padding remain safe during layout and pointer input`() throws {
        let view = try makeView(configuration: Configuration.parse("adjust-cell-height = 1e308\nwindow-padding-x = 1e308"))
        let preferred = view.preferredSize(columns: 100, rows: 30)
        #expect(preferred.width.isFinite && preferred.height.isFinite)
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        view.updateGrid()
        let size = view.session.withState { ($0.columns, $0.rows, $0.cellPixelSize.height) }
        #expect(size.0 == 1 && size.1 == 1 && size.2 == Int.max)
        let cell = view.unclampedCell(at: .zero)
        #expect(cell.column == -Int(UInt16.max) && cell.row == 0)
    }

    @Test(.enabled(if: hasMetal)) func `all surface bindings reach other terminals and exclude stopped views`() throws {
        let first = try makeView(configuration: Configuration.parse("keybind = all:unconsumed:ctrl+a=text:X"))
        let second = try makeView()
        let firstWrites = Mutex<[UInt8]>([]), secondWrites = Mutex<[UInt8]>([])
        first.session.onWrite = { bytes in firstWrites.withLock { $0.append(contentsOf: bytes) } }
        second.session.onWrite = { bytes in secondWrites.withLock { $0.append(contentsOf: bytes) } }
        let event = try #require(TestFixture(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{1}", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0,
        )).value)
        first.keyDown(with: event)
        _ = first.session.snapshot()
        _ = second.session.snapshot()
        #expect(firstWrites.withLock { $0 } == [0x58])
        #expect(secondWrites.withLock { $0 } == [0x58])
        #expect(first.heldKeys.isEmpty)
        second.stop()
        secondWrites.withLock { $0.removeAll() }
        first.keyDown(with: event)
        _ = first.session.snapshot()
        _ = second.session.snapshot()
        #expect(firstWrites.withLock { $0 } == [0x58, 0x58])
        #expect(secondWrites.withLock { $0.isEmpty })
    }

    @Test(.enabled(if: hasMetal)) func `performable copy consumes the key when a selection exists`() throws {
        let view = try makeView(configuration: Configuration.parse("keybind = performable:ctrl+c=copy_to_clipboard"))
        let clipboard = NSPasteboard.withUniqueName()
        view.pasteboard = clipboard
        defer { clipboard.releaseGlobally() }
        view.session.feed(Array("abc".utf8))
        view.session.mutate {
            $0.setSelection(Selection(anchor: TerminalPoint(row: 0, column: 0), head: TerminalPoint(row: 0, column: 2)))
        }
        let writes = Mutex<[UInt8]>([])
        view.session.onWrite = { bytes in writes.withLock { $0.append(contentsOf: bytes) } }
        let event = try #require(TestFixture(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{3}", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8,
        )).value)
        view.keyDown(with: event)
        _ = view.session.snapshot()
        #expect(clipboard.string(forType: .string) == "abc")
        #expect(writes.withLock { $0.isEmpty })
        #expect(view.session.withState { $0.selection != nil })
    }

    @Test(.enabled(if: hasMetal)) func `navigation actions report whether they can run`() throws {
        let view = try makeView()
        #expect(!view.perform(.scrollPageUp))
        #expect(!view.perform(.jumpToPrompt(-1)))
        #expect(!view.perform(.navigateSearch(next: true)))
        #expect(!view.perform(.searchSelection))
        #expect(!view.perform(.endSearch))
        view.session.feed(Array(String(repeating: "row\r\n", count: 30).utf8))
        #expect(view.perform(.scrollPageUp))
        #expect(view.perform(.scrollToBottom))
        #expect(!view.perform(.scrollToBottom))
    }

    @Test(.enabled(if: hasMetal), arguments: [false, true])
    func `unavailable performable copy bindings pass the key through`(_ keyEquivalent: Bool) throws {
        let config = Configuration.parse("keybind = performable:ctrl+c=copy_to_clipboard")
        let view = try makeView(configuration: config)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        #expect(window.makeFirstResponder(view))
        let writes = Mutex<[UInt8]>([])
        view.session.onWrite = { bytes in writes.withLock { $0.append(contentsOf: bytes) } }
        let event = try #require(TestFixture(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "\u{3}", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8,
        )).value)
        if keyEquivalent {
            #expect(!view.performKeyEquivalent(with: event))
        }
        view.keyDown(with: event)
        _ = view.session.snapshot()
        #expect(writes.withLock { $0 } == [0x03])
    }

    @Test(.enabled(if: hasMetal), arguments: [false, true], [false, true])
    func `unconsumed bindings send the action and original key once`(_ keyEquivalent: Bool, _ control: Bool) throws {
        let config = Configuration.parse("keybind = unconsumed:\(control ? "ctrl+" : "")a=text:X")
        let view = try makeView(configuration: config)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        #expect(window.makeFirstResponder(view))
        let writes = Mutex<[UInt8]>([])
        view.session.onWrite = { bytes in writes.withLock { $0.append(contentsOf: bytes) } }
        let event = try #require(TestFixture(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: control ? .control : [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: control ? "\u{1}" : "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0,
        )).value)
        if keyEquivalent {
            #expect(view.performKeyEquivalent(with: event))
        } else {
            view.keyDown(with: event)
        }
        _ = view.session.snapshot()
        #expect(writes.withLock { $0 } == [0x58, control ? 0x01 : 0x61])
        #expect(view.heldKeys.count == (control ? 1 : 0))
    }

    @Test(.enabled(if: hasMetal), arguments: [false, true])
    func `output clearing selection ends its drag`(_ extendBeforeFrame: Bool) throws {
        let view = try makeView()
        view.session.feed(Array("abc".utf8))
        view.selectAll(nil)
        let point = TerminalPoint(row: 0, column: 0)
        view.selectionOrigin = (point, point, view.session.withState { $0.addressingGeneration })
        #expect(view.hasSelection)
        view.session.feed(Array("\u{1B}[H\u{1B}[2J".utf8))
        if extendBeforeFrame {
            let event = try #require(NSEvent.mouseEvent(
                with: .leftMouseDragged, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0,
            ))
            view.mouseDragged(with: event)
            #expect(view.session.withState { $0.selection == nil })
        }
        view.draw(in: view)
        #expect(!view.hasSelection)
        #expect(view.selectionOrigin == nil)
        // A single click has a drag origin but no core selection yet.
        view.selectionOrigin = (point, point, view.session.withState { $0.addressingGeneration })
        view.draw(in: view)
        #expect(view.selectionOrigin != nil)
    }

    @Test(.enabled(if: hasMetal)) func `responder changes in inactive windows do not report focus`() throws {
        let view = try makeView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false,
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        #expect(!window.isKeyWindow)
        let writes = Mutex<[[UInt8]]>([])
        view.session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
        view.session.feed(Array("\u{1B}[?1004h".utf8))
        #expect(window.makeFirstResponder(view))
        _ = view.session.snapshot()
        #expect(writes.withLock { $0.isEmpty })
    }

    @Test(.enabled(if: hasMetal)) func `window key notifications release keys while retaining the responder`() throws {
        let view = try makeView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false,
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        #expect(window.makeFirstResponder(view))
        let writes = Mutex<[[UInt8]]>([])
        view.session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
        view.session.feed(Array("\u{1B}[=10u\u{1B}[?1004h".utf8))
        _ = view.session.snapshot()
        view.heldKeys = [0: KeyEvent(.character("a"), modifiers: .shift)]
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(window.firstResponder === view)
        #expect(view.heldKeys.isEmpty)
        _ = view.session.snapshot()
        #expect(TestFixture(writes.withLock { $0.map { String(decoding: $0, as: UTF8.self) } }) == TestFixture([
            "\u{1B}[97;2:3u",
            "\u{1B}[O",
        ]))
        writes.withLock { $0.removeAll() }
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        _ = view.session.snapshot()
        #expect(TestFixture(writes.withLock { $0.map { String(decoding: $0, as: UTF8.self) } }) == TestFixture(["\u{1B}[I"]))
    }

    @Test(.enabled(if: hasMetal)) func `moving a view releases keys and removes old window observers`() throws {
        let view = try makeView()
        let first = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false,
        )
        let second = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false,
        )
        first.isReleasedWhenClosed = false
        second.isReleasedWhenClosed = false
        defer { first.close(); second.close() }
        first.contentView = view
        #expect(first.makeFirstResponder(view))
        let writes = Mutex<[[UInt8]]>([])
        view.session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
        view.session.feed(Array("\u{1B}[=10u\u{1B}[?1004h".utf8))
        _ = view.session.snapshot()
        view.heldKeys = [0: KeyEvent(.character("a"))]
        view.removeFromSuperview()
        _ = view.session.snapshot()
        #expect(view.heldKeys.isEmpty)
        let releases = writes.withLock { $0.filter { $0 == Array("\u{1B}[97;1:3u".utf8) } }
        #expect(releases.count == 1)
        second.contentView = view
        #expect(second.makeFirstResponder(view))
        _ = view.session.snapshot()
        writes.withLock { $0.removeAll() }
        view.heldKeys = [0: KeyEvent(.character("a"))]
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: first)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: first)
        _ = view.session.snapshot()
        #expect(writes.withLock { $0.isEmpty })
        #expect(view.heldKeys.count == 1)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: second)
        _ = view.session.snapshot()
        #expect(view.heldKeys.isEmpty)
        #expect(TestFixture(writes.withLock { $0.last }) == TestFixture(Array("\u{1B}[O".utf8)))
    }

    @Test(.enabled(if: hasMetal)) func `raw text actions preserve every byte`() throws {
        let view = try makeView()
        let writes = Mutex<[UInt8]>([])
        view.session.onWrite = { bytes in writes.withLock { $0.append(contentsOf: bytes) } }
        view.session.feed(Array("\u{1B}[?2004h\u{1B}[=31u".utf8))
        view.perform(.textBytes([0, 0x80, 0xFF]))
        _ = view.session.snapshot()
        #expect(writes.withLock { $0 } == [0, 0x80, 0xFF])
    }

    @Test(.enabled(if: hasMetal)) func `negative font size steps stay within view bounds`() throws {
        let view = try makeView()
        view.perform(.increaseFontSize(-1000))
        #expect(view.fontSize == 1)
        view.perform(.decreaseFontSize(-1000))
        #expect(view.fontSize == 200)
    }

    @Test(.enabled(if: hasMetal), arguments: [1, 3, 100, 200])
    func `zoom actions follow their direction throughout the configured font range`(_ size: Int) throws {
        let view = try makeView(configuration: Configuration.parse("font-size=\(size)"))
        view.perform(.increaseFontSize(1))
        #expect(view.fontSize == CGFloat(min(size + 1, 200)))
        view.perform(.resetFontSize)
        view.perform(.decreaseFontSize(1))
        #expect(view.fontSize == CGFloat(max(size - 1, 1)))
    }

    @Test(.enabled(if: hasMetal), arguments: [false, true])
    func `font configuration reload preserves manual zoom and reset follows new settings`(_ zoomed: Bool) throws {
        let view = try makeView(configuration: Configuration.parse("font-size=14"))
        if zoomed {
            view.perform(.increaseFontSize(5))
        }
        view.apply(Configuration.parse("font-size=20\nfont-feature=-liga"))
        #expect(view.fontSize == (zoomed ? 19 : 20))
        #expect(view.renderer.font.descriptor.size == view.fontSize)
        #expect(view.renderer.font.descriptor.features == ["-liga"])
        view.perform(.resetFontSize)
        #expect(view.fontSize == 20)
        view.apply(Configuration.parse("font-size=22\nfont-feature=-liga"))
        #expect(view.fontSize == 22)
        #expect(view.renderer.font.descriptor.size == 22)
    }

    @Test(.enabled(if: hasMetal)) func `reset action clears incomplete output sequences`() throws {
        let view = try makeView()
        view.session.feed(Array("\u{1B}]2;pending".utf8))
        view.perform(.reset)
        view.session.receive(Array("ok".utf8))
        #expect(TestFixture(view.session.snapshot().text.first) == TestFixture("ok"))
    }

    @Test(.enabled(if: hasMetal)) func `refinement flags keep hardware commits as text`() throws {
        let view = try makeView()
        let writes = Mutex<[UInt8]>([])
        view.session.onWrite = { bytes in writes.withLock { $0.append(contentsOf: bytes) } }
        view.interpretingEvent = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0, windowNumber: 0, context: nil,
            characters: "å", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0,
        ))
        for flags in [0, 2, 4, 16, 6, 18, 20, 22] {
            view.session.feed(Array("\u{1B}[=\(flags)u".utf8))
            writes.withLock { $0.removeAll() }
            view.insertText("å", replacementRange: NSRange(location: NSNotFound, length: 0))
            _ = view.session.snapshot() // Drain the queued send.
            #expect(writes.withLock { $0 } == Array("å".utf8))
        }
    }

    @Test(.enabled(if: hasMetal), arguments: [UInt8(0), 10])
    func `focus loss releases held hardware keys once`(_ flags: UInt8) throws {
        let view = try makeView()
        let writes = Mutex<[[UInt8]]>([])
        view.session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
        view.session.feed(Array("\u{1B}[=\(flags)u\u{1B}[?1004h".utf8))
        let press = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0, windowNumber: 0, context: nil,
            characters: "A", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0,
        ))
        let repeated = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0, windowNumber: 0, context: nil,
            characters: "A", charactersIgnoringModifiers: "a", isARepeat: true, keyCode: 0,
        ))
        let up = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{F700}", charactersIgnoringModifiers: "\u{F700}", isARepeat: false, keyCode: 126,
        ))
        let letter = KeyEvent(.character("a"), modifiers: .shift)
        view.sendHardwareKey(letter, event: press)
        view.sendHardwareKey(letter, event: repeated)
        view.sendHardwareKey(KeyEvent(.up), event: up)
        _ = view.session.snapshot() // Drain the queued presses before measuring releases.
        #expect(view.heldKeys.count == 2)
        writes.withLock { $0.removeAll() }

        #expect(view.resignFirstResponder())
        #expect(view.heldKeys.isEmpty)
        _ = view.session.snapshot()
        let sent = writes.withLock { $0.map { String(decoding: $0, as: UTF8.self) } }
        #expect(TestFixture(sent.last) == TestFixture("\u{1B}[O")) // Releases precede the focus report.
        if flags == 10 {
            #expect(TestFixture(sent.dropLast().sorted()) == TestFixture(["\u{1B}[97;2:3u", "\u{1B}[1;1:3A"].sorted()))
        } else {
            #expect(TestFixture(sent) == TestFixture(["\u{1B}[O"]))
        }

        #expect(view.becomeFirstResponder())
        _ = view.session.snapshot()
        writes.withLock { $0.removeAll() }
        // A delayed key-up after focus returns must not release a stale press.
        for (code, characters) in [(UInt16(0), "a"), (126, "\u{F700}")] {
            let release = try #require(NSEvent.keyEvent(
                with: .keyUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code,
            ))
            view.keyUp(with: release)
        }
        _ = view.session.snapshot()
        #expect(writes.withLock { $0.isEmpty })
    }

    // MARK: Render options

    @Test func `merging keeps what the view drives`() {
        var current = RenderOptions()
        current.preedit = ["x"]
        current.preeditSelection = NSRange(location: 1, length: 0)
        current.hoveredLink = 3
        current.underlinedSpan = HighlightSpan(startRow: 0, startColumn: 1, endRow: 0, endColumn: 4)
        current.textBlinkVisible = false
        current.cursorVisible = false
        current.isFocused = false
        var configured = RenderOptions()
        configured.paddingX = 20
        configured.minimumContrast = 3
        let merged = TerminalView.merge(configured: configured, current: current)
        #expect(merged.paddingX == 20 && merged.minimumContrast == 3)
        #expect(merged.preedit == ["x"] && merged.hoveredLink == 3 && merged.underlinedSpan == current.underlinedSpan)
        #expect(merged.preeditSelection == current.preeditSelection)
        #expect(!merged.textBlinkVisible && !merged.cursorVisible && !merged.isFocused)
    }

    @Test(.enabled(if: hasMetal)) func `reloading the configuration keeps the hovered link underlined`() throws {
        let view = try makeView()
        let span = HighlightSpan(startRow: 0, startColumn: 2, endRow: 0, endColumn: 9)
        view.renderer.options.hoveredLink = 0
        view.renderer.options.underlinedSpan = span
        var config = Configuration()
        _ = config.set("window-padding-x", "12")
        _ = config.set("minimum-contrast", "2")
        view.apply(config)
        #expect(view.renderer.options.underlinedSpan == span)
        #expect(view.renderer.options.minimumContrast == 2)
        #expect(view.renderer.options.paddingX == 24) // points at the default 2x scale
    }
}

private final class ReviewScrollEvent: NSEvent {
    var distance: CGFloat = 0
    override var scrollingDeltaX: CGFloat {
        distance
    }

    override var scrollingDeltaY: CGFloat {
        distance
    }

    override var hasPreciseScrollingDeltas: Bool {
        false
    }

    override var locationInWindow: NSPoint {
        .zero
    }

    override var modifierFlags: NSEvent.ModifierFlags {
        []
    }
}
