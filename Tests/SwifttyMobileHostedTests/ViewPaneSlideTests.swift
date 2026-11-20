#if canImport(UIKit)
import MetalKit
import SwifttyCore
import SwifttyEngine
@testable import SwifttyMobile
import Testing
import UIKit

/// Pane switches slide the terminal out holding its picture, then in once
/// the new pane's screen is drawn.
@MainActor
@Suite(.serialized)
struct ViewPaneSlideTests {
  nonisolated static let hasMetal = MTLCreateSystemDefaultDevice() != nil

  @Test
  func `most rows damaged means a new screen`() {
    var some = DamageRegion.none
    some.insert(rows: 0 ..< 3)
    #expect(!TerminalUIView.redrawsMostRows(some, rows: 24))
    var most = DamageRegion.none
    most.insert(rows: 0 ..< 12)
    #expect(TerminalUIView.redrawsMostRows(most, rows: 24))
    #expect(TerminalUIView.redrawsMostRows(.full, rows: 24))
    #expect(!TerminalUIView.redrawsMostRows(.none, rows: 0))
  }

  private func foregroundScene() async throws -> UIWindowScene {
    let deadline = ContinuousClock.now + .seconds(2)
    var scene: UIWindowScene?
    repeat {
      scene = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first { $0.activationState == .foregroundActive }
      if scene != nil { break }
      try await Task.sleep(for: .milliseconds(10))
    } while ContinuousClock.now < deadline
    return try #require(scene)
  }

  @Test(.enabled(if: hasMetal))
  func `a held screen reports its replacement once released`() async throws {
    let scene = try await foregroundScene()
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
    let view = try TerminalUIView(session: TerminalSession())
    view.frame = window.bounds
    window.addSubview(view)
    window.makeKeyAndVisible()
    defer {
      view.removeFromSuperview()
      window.isHidden = true
    }
    // Let the first full frame draw before watching for replacements.
    try await Task.sleep(for: .milliseconds(300))
    var replaced = 0
    view.holdsFrames = true
    view.onScreenReplaced = { replaced += 1 }
    // Every row changes, as when another pane's screen is installed.
    view.session.feed(
      Array(
        ("\u{1B}[H\u{1B}[2J"
          + (1 ... 30).map { "row \($0)" }.joined(separator: "\r\n"))
          .utf8
      )
    )
    try await Task.sleep(for: .milliseconds(300))
    #expect(replaced == 0)
    view.holdsFrames = false
    let deadline = ContinuousClock.now + .seconds(2)
    while replaced == 0, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(replaced == 1)
    #expect(view.onScreenReplaced == nil)
  }
}
#endif
