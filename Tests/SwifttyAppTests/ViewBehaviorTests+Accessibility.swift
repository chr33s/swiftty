import AppKit
import Metal
@testable import Swiftty
@testable import SwifttyMac
import SwifttyCore
import Synchronization
import Testing
import TestSupport

/// VoiceOver throttling and text caching, and render options surviving a
/// configuration reload, in the macOS view.
extension ViewBehaviorTests {
  @Test(.enabled(if: hasMetal))
  func `accessibility point queries exclude the search overlay`() throws {
    let view = try makeView()
    let window = InteractionTestWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 240),
      styleMask: [.titled],
      backing: .buffered,
      defer: false,
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = view
    view.session.feed(Array(String(repeating: "x", count: 200).utf8))
    view.draw(in: view)
    view.showSearch(text: "x")
    let bar = try #require(view.searchBar)
    let covered = view.convert(
      NSPoint(x: bar.field.bounds.midX, y: bar.field.bounds.midY),
      from: bar.field
    )
    func screen(_ point: NSPoint) -> NSPoint {
      window.convertPoint(toScreen: view.convert(point, to: nil))
    }
    #expect(
      view.accessibilityRange(for: screen(covered))
        == NSRange(location: NSNotFound, length: 0)
    )
    let exposed = NSPoint(x: 20, y: covered.y)
    #expect(
      view.accessibilityRange(for: screen(exposed)).location != NSNotFound
    )
    view.closeSearch()
    #expect(
      view.accessibilityRange(for: screen(covered)).location != NSNotFound
    )
  }

  @Test(.enabled(if: hasMetal))
  func
    `accessibility notifications distinguish text selection and unchanged frames`()
    throws
  {
    let view = try makeView()
    view.session.feed(Array("abc".utf8))
    view.draw(in: view)
    #expect(
      view.accessibilityChanges() == [.valueChanged, .selectedTextChanged]
    )
    view.draw(in: view)
    #expect(view.accessibilityChanges().isEmpty)
    view.session.feed(Array("\u{1B}[2G".utf8))
    view.draw(in: view)
    #expect(view.accessibilityChanges() == [.selectedTextChanged])
    view.session.mutate {
      $0.setSelection(
        Selection(
          anchor: TerminalPoint(row: 0, column: 0),
          head: TerminalPoint(row: 0, column: 1)
        )
      )
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
    #expect(
      view.accessibilityChanges() == [.valueChanged, .selectedTextChanged]
    )
  }

  @Test(.enabled(if: hasMetal))
  func `accessibility throttle preserves both pending notification kinds`()
    async throws
  {
    let view = try makeView()
    view.accessibilityThrottle = NotificationThrottle(interval: 0.05)
    var posts: [NSAccessibility.Notification] = []
    let post: @MainActor (NSAccessibility.Notification) -> Void = {
      posts.append($0)
    }
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
  func `accessibility selection ranges match visible Unicode text`(
    _ rectangle: Bool
  ) throws {
    let view = try makeView()
    view.session.feed(Array("A😀e\u{301}中Z\r\nnext".utf8))
    view.session.mutate {
      $0.setSelection(
        Selection(
          anchor: TerminalPoint(row: 0, column: rectangle ? 1 : 3),
          head: TerminalPoint(row: 1, column: rectangle ? 3 : 1),
          rectangle: rectangle,
        )
      )
    }
    view.draw(in: view)
    let expected =
      rectangle
      ? [NSRange(location: 1, length: 4), NSRange(location: 9, length: 3)]
      : [NSRange(location: 3, length: 7)]
    #expect(view.accessibilitySelectedTextRange() == expected[0])
    #expect(
      view.accessibilitySelectedTextRanges()?.map(\.rangeValue) == expected
    )
    #expect(
      TestFixture(view.accessibilitySelectedText())
        == TestFixture(rectangle ? "😀e\u{301}\next" : "e\u{301}中Z\nne")
    )
  }

  @Test(.enabled(if: hasMetal))
  func
    `accessibility selection includes exposed soft wrap separators and clears to the cursor`()
    throws
  {
    let view = try makeView()
    view.session.mutate { $0.resize(columns: 3, rows: 2) }
    view.session.feed(Array("ABCDEF".utf8))
    view.session.mutate { $0.selectAll() }
    view.draw(in: view)
    #expect(view.session.withState { $0.selectionText } == "ABCDEF")
    #expect(
      TestFixture(view.accessibilitySelectedText()) == TestFixture("ABC\nDEF")
    )
    #expect(
      view.accessibilitySelectedTextRange() == NSRange(location: 0, length: 7)
    )
    view.session.mutate { $0.setSelection(nil) }
    view.draw(in: view)
    let cursor = view.accessibilitySelectedTextRange()
    #expect(cursor.length == 0)
    #expect(
      view.accessibilitySelectedTextRanges()?.map(\.rangeValue) == [cursor]
    )
    #expect(view.accessibilitySelectedText() == "")
  }

  @Test(.enabled(if: hasMetal), arguments: [1, 2])
  func `accessibility selection includes either half of a wide glyph`(
    _ column: Int
  ) throws {
    let view = try makeView()
    view.session.feed(Array("A😀e\u{301}中Z".utf8))
    view.session.mutate {
      $0.setSelection(
        Selection(
          anchor: TerminalPoint(row: 0, column: column),
          head: TerminalPoint(row: 0, column: 4)
        )
      )
    }
    view.draw(in: view)
    #expect(
      view.accessibilitySelectedTextRange() == NSRange(location: 1, length: 5)
    )
    #expect(view.accessibilitySelectedText() == "😀e\u{301}中")
  }

  @Test(.enabled(if: hasMetal))
  func `accessibility selection is clipped to the exposed viewport`() throws {
    let view = try makeView()
    view.session.mutate { $0.resize(columns: 20, rows: 2) }
    view.session.feed(Array("row0\r\nrow1\r\nrow2\r\nrow3".utf8))
    view.session.mutate {
      $0.setSelection(
        Selection(
          anchor: TerminalPoint(row: 0, column: 0),
          head: TerminalPoint(row: 2, column: 1)
        )
      )
    }
    view.draw(in: view)
    #expect(
      view.accessibilitySelectedTextRange() == NSRange(location: 0, length: 2)
    )
    #expect(view.accessibilitySelectedText() == "ro")
  }
}
