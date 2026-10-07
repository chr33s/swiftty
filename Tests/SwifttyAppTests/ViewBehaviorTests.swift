import AppKit
import Metal
@testable import Swiftty
import SwifttyCore
import Synchronization
import Testing

/// VoiceOver throttling and text caching, and render options surviving a
/// configuration reload, in the macOS view.
@MainActor
@Suite(.serialized) struct ViewBehaviorTests {
    nonisolated static let hasMetal = MTLCreateSystemDefaultDevice() != nil

    func makeView() throws -> TerminalView {
        _ = NSApplication.shared
        return try TerminalView(configuration: Configuration())
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

    // MARK: Throttle

    func wait(_ decision: NotificationThrottle.Decision) -> CFTimeInterval? {
        if case let .schedule(after) = decision {
            after
        } else {
            nil
        }
    }

    @Test func `throttle posts at once, then once at the end of the window`() {
        var t = NotificationThrottle(interval: 0.5)
        #expect(t.request(at: 10) == .post)
        #expect(wait(t.request(at: 10.2)).map { abs($0 - 0.3) < 1e-9 } == true)
        #expect(t.request(at: 10.3) == .skip) // covered by the scheduled one
        t.fire(at: 10.5)
        #expect(!t.pending)
        #expect(wait(t.request(at: 10.6)).map { abs($0 - 0.4) < 1e-9 } == true)
        t.fire(at: 11)
        #expect(t.request(at: 11.6) == .post)
    }

    @Test(.enabled(if: hasMetal)) func `a change inside the window is still delivered`() async throws {
        let view = try makeView()
        var posts: [Double] = []
        let start = CACurrentMediaTime()
        view.requestAccessibilityPost { posts.append(CACurrentMediaTime() - start) }
        view.requestAccessibilityPost { posts.append(CACurrentMediaTime() - start) } // final output
        #expect(posts.count == 1)
        let deadline = Date().addingTimeInterval(2)
        while posts.count < 2, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(posts.count == 2)
        #expect((posts.last ?? 0) >= 0.45)
    }

    // MARK: Text cache

    @Test func `accessibility text is built once per snapshot`() {
        let session = TerminalSession(columns: 10, rows: 2)
        session.feed(Array("hello".utf8))
        var cache = AccessibilityTextCache()
        let first = session.snapshot()
        #expect(cache.text(for: first).string == "hello\n")
        _ = cache.text(for: first)
        #expect(cache.builds == 1)
        session.feed(Array(" you".utf8))
        #expect(cache.text(for: session.snapshot()).string == "hello you\n")
        #expect(cache.builds == 2)
    }

    @Test(.enabled(if: hasMetal)) func `queries from VoiceOver share one build`() throws {
        let view = try makeView()
        view.session.feed(Array("ab\r\ncd".utf8))
        view.lastSnapshot = view.session.snapshot()
        #expect((view.accessibilityValue() as? String)?.hasPrefix("ab\ncd\n") == true)
        _ = view.accessibilityNumberOfCharacters()
        _ = view.accessibilitySelectedTextRange()
        _ = view.accessibilityRange(forLine: 1)
        _ = view.accessibilityString(for: NSRange(location: 0, length: 2))
        _ = view.accessibilityInsertionPointLineNumber()
        #expect(view.accessibilityCache.builds == 1)
    }

    // MARK: Render options

    @Test func `merging keeps what the view drives`() {
        var current = RenderOptions()
        current.preedit = ["x"]
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
