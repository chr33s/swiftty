import AppKit
@testable import Swiftty
import SwifttyCore
import Testing
import TestSupport

extension ViewBehaviorTests {
  // MARK: Throttle

  func wait(_ decision: NotificationThrottle.Decision) -> CFTimeInterval? {
    if case let .schedule(after) = decision { after } else { nil }
  }

  @Test
  func `throttle posts at once, then once at the end of the window`() {
    var t = NotificationThrottle(interval: 0.5)
    #expect(t.request(at: 10) == .post)
    #expect(wait(t.request(at: 10.2)).map { abs($0 - 0.3) < 1e-9 } == true)
    #expect(t.request(at: 10.3) == .skip)  // covered by the scheduled one
    t.fire(at: 10.5)
    #expect(!t.pending)
    #expect(wait(t.request(at: 10.6)).map { abs($0 - 0.4) < 1e-9 } == true)
    t.fire(at: 11)
    #expect(t.request(at: 11.6) == .post)
  }

  @Test(.enabled(if: hasMetal))
  func `a change inside the window is still delivered`() async throws {
    let view = try makeView()
    var posts: [Double] = []
    let start = CACurrentMediaTime()
    view.requestAccessibilityPost { posts.append(CACurrentMediaTime() - start) }
    // final output
    view.requestAccessibilityPost { posts.append(CACurrentMediaTime() - start) }
    #expect(posts.count == 1)
    let deadline = Date().addingTimeInterval(2)
    while posts.count < 2, Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(posts.count == 2)
    #expect((posts.last ?? 0) >= 0.45)
  }

  // MARK: Text cache

  @Test(
    .enabled(if: hasMetal),
    arguments: [
      (0, NSRange(location: 0, length: 1)),
      (1, NSRange(location: 1, length: 2)),
      (2, NSRange(location: 1, length: 2)),
      (3, NSRange(location: 3, length: 2)),
      (4, NSRange(location: 3, length: 2)),
      (5, NSRange(location: 5, length: 5)),
      (7, NSRange(location: 5, length: 5)),
      (9, NSRange(location: 5, length: 5)),
      (10, NSRange(location: 10, length: 1)),
      (11, NSRange(location: 11, length: 1)),
      (12, NSRange(location: 12, length: 1)),
    ]
  )
  func `accessibility character queries include the entire terminal glyph`(
    _ index: Int,
    _ expected: NSRange
  ) throws {
    let view = try makeView()
    view.session.feed(Array("A😀e\u{301}👩‍💻Z\r\nnext".utf8))
    view.draw(in: view)
    #expect(view.accessibilityRange(for: index) == expected)
    for invalid in [-1, Int.max, view.accessibilityNumberOfCharacters()] {
      #expect(
        view.accessibilityRange(for: invalid)
          == NSRange(location: NSNotFound, length: 0)
      )
    }
  }

  @Test(
    .enabled(if: hasMetal),
    arguments: [
      (0, NSRange(location: 0, length: 1)),
      (1, NSRange(location: 1, length: 2)),
      (2, NSRange(location: 1, length: 2)),
      (3, NSRange(location: 3, length: 2)),
      (4, NSRange(location: 5, length: 5)),
      (5, NSRange(location: 5, length: 5)),
      (6, NSRange(location: 10, length: 1)),
    ]
  )
  func `accessibility hit testing includes either half of wide glyphs`(
    _ column: Int,
    _ expected: NSRange
  ) throws {
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
    view.session.feed(Array("A😀e\u{301}👩‍💻Z".utf8))
    view.lastSnapshot = view.session.snapshot()
    let scale = window.backingScaleFactor
    func screenPoint(column: Int) -> NSPoint {
      window.convertPoint(
        toScreen: view.convert(
          NSPoint(
            x: (view.renderer.options.paddingX + (CGFloat(column) + 0.5)
              * view.renderer.cellSize.width)
              / scale,
            y: view.bounds.height
              - (view.renderer.options.paddingY + view.renderer.cellSize.height
                / 2) / scale,
          ),
          to: nil
        )
      )
    }
    #expect(
      view.accessibilityRange(for: screenPoint(column: column)) == expected
    )
    #expect(
      view.accessibilityRange(for: screenPoint(column: 9))
        == NSRange(location: NSNotFound, length: 0)
    )
    #expect(
      view.accessibilityRange(for: NSPoint(x: CGFloat.infinity, y: 0))
        == NSRange(location: NSNotFound, length: 0)
    )
  }

  @Test(
    .enabled(if: hasMetal),
    arguments: [
      (NSRange(location: 0, length: 1), 0, 1, 0, 1),
      (NSRange(location: 2, length: 1), 1, 2, 0, 1),
      (NSRange(location: 4, length: 1), 3, 1, 0, 1),
      (NSRange(location: 7, length: 1), 4, 2, 0, 1),
      (NSRange(location: 10, length: 1), 6, 1, 0, 1),
      (NSRange(location: 3, length: 0), 3, 0, 0, 1),
      (NSRange(location: 8, length: 0), 4, 0, 0, 1),
      (NSRange(location: 11, length: 0), 7, 0, 0, 1),
      (NSRange(location: 13, length: 1), 1, 1, 1, 1),
      (NSRange(location: 10, length: 4), 0, 7, 0, 2),
    ]
  )
  func `accessibility frames follow glyph cells and caret positions`(
    _ range: NSRange,
    _ column: Int,
    _ columns: Int,
    _ row: Int,
    _ rows: Int,
  ) throws {
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
    view.session.feed(Array("A😀e\u{301}👩‍💻Z\r\nnext".utf8))
    view.lastSnapshot = view.session.snapshot()
    let scale = window.backingScaleFactor
    let cell = view.renderer.cellSize
    let expected = NSRect(
      x: (view.renderer.options.paddingX + CGFloat(column) * cell.width)
        / scale,
      y: view.bounds.height
        - (view.renderer.options.paddingY + CGFloat(row + rows) * cell.height)
          / scale,
      width: CGFloat(columns) * cell.width / scale,
      height: CGFloat(rows) * cell.height / scale,
    )
    let actual = view.convert(
      window.convertFromScreen(view.accessibilityFrame(for: range)),
      from: nil
    )
    #expect(abs(actual.minX - expected.minX) < 0.001)
    #expect(abs(actual.minY - expected.minY) < 0.001)
    #expect(abs(actual.width - expected.width) < 0.001)
    #expect(abs(actual.height - expected.height) < 0.001)
  }

  @Test(.enabled(if: hasMetal))
  func `invalid accessibility frame ranges return zero`() throws {
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
    view.session.feed(Array("ab\r\ncd".utf8))
    view.lastSnapshot = view.session.snapshot()
    #expect(
      view.accessibilityFrame(for: NSRange(location: 0, length: 2)) != .zero
    )
    for range in [
      NSRange(location: -1, length: 1), NSRange(location: 1, length: -1),
      NSRange(location: 0, length: Int.max),
      NSRange(location: Int.max, length: Int.max),
    ] { #expect(view.accessibilityFrame(for: range) == .zero) }
  }

  @Test(.enabled(if: hasMetal))
  func `invalid accessibility string ranges return nil`() throws {
    let view = try makeView()
    view.session.feed(Array("ab\r\ncd".utf8))
    view.lastSnapshot = view.session.snapshot()
    let length = view.accessibilityNumberOfCharacters()
    #expect(
      view.accessibilityString(for: NSRange(location: 0, length: 2)) == "ab"
    )
    #expect(
      view.accessibilityString(for: NSRange(location: length, length: 0)) == ""
    )
    for range in [
      NSRange(location: -1, length: 1), NSRange(location: 1, length: -1),
      NSRange(location: Int.max, length: Int.max),
      NSRange(location: 1, length: Int.max),
      NSRange(location: length + 1, length: 0),
      NSRange(location: 0, length: length + 1),
    ] { #expect(view.accessibilityString(for: range) == nil) }
  }

  @Test
  func `accessibility text is built once per snapshot`() {
    let session = TerminalSession(columns: 10, rows: 2)
    session.feed(Array("hello".utf8))
    var cache = AccessibilityTextCache()
    let first = session.snapshot()
    #expect(
      TestFixture(cache.text(for: first).string) == TestFixture("hello\n")
    )
    _ = cache.text(for: first)
    #expect(cache.builds == 1)
    session.feed(Array(" you".utf8))
    #expect(
      TestFixture(cache.text(for: session.snapshot()).string)
        == TestFixture("hello you\n")
    )
    #expect(cache.builds == 2)
  }

  @Test(.enabled(if: hasMetal))
  func `queries from VoiceOver share one build`() throws {
    let view = try makeView()
    view.session.feed(Array("ab\r\ncd".utf8))
    view.lastSnapshot = view.session.snapshot()
    #expect(
      TestFixture((view.accessibilityValue() as? String)?.hasPrefix("ab\ncd\n"))
        == TestFixture(true)
    )
    _ = view.accessibilityNumberOfCharacters()
    _ = view.accessibilitySelectedTextRange()
    _ = view.accessibilityRange(forLine: 1)
    _ = view.accessibilityString(for: NSRange(location: 0, length: 2))
    _ = view.accessibilityInsertionPointLineNumber()
    #expect(view.accessibilityCache.builds == 1)
  }
}
