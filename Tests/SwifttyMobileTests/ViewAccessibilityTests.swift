import TestSupport
#if canImport(UIKit)
import SwifttyCore
@testable import SwifttyMobile
import Testing
import UIKit

extension ViewLifecycleTests {
  @Test(.enabled(if: hasMetal), arguments: [false, true])
  func `reading hit tests distinguish rows from terminal padding`(
    _ scaled: Bool
  ) throws {
    let configuration = Configuration.parse(
      "window-padding-x=7\nwindow-padding-y=9"
    )
    let view = try TerminalUIView(
      session: TerminalSession(),
      configuration: configuration
    )
    let window = makeWindow()
    window.frame.size = CGSize(width: 640, height: 640)
    let controller = UIViewController()
    window.rootViewController = controller
    let container = UIView(frame: CGRect(x: 37, y: 71, width: 400, height: 320))
    container.bounds.origin = CGPoint(x: 9, y: 17)
    if scaled { container.transform = CGAffineTransform(scaleX: 0.9, y: 1.1) }
    controller.view.addSubview(container)
    view.frame = CGRect(x: 31, y: 47, width: 320, height: 180)
    container.addSubview(view)
    window.makeKeyAndVisible()
    defer {
      view.removeFromSuperview();
      window.isHidden = true
    }
    view.layoutIfNeeded()
    view.session.feed(Array("one\r\ntwo\r\nthree".utf8))
    view.accessibilityScreen = AccessibilityText(view.session.snapshot())
    let lines = try #require(view.accessibilityScreen?.lines)
    try #require(lines.count >= 3)
    let reading = view.accessibilityTerminal
    for row in lines.indices {
      let frame = view.geometry.rect(column: 0, row: row)
      try #require(frame.width > 0 && frame.height > 0)
      let point = CGPoint(x: frame.midX, y: frame.midY)
      let hit = reading.accessibilityLineNumber(for: point)
      #expect(hit == row)
      #expect(
        TestFixture(reading.accessibilityContent(forLineNumber: hit))
          == TestFixture(lines[row])
      )
    }
    for point in [
      CGPoint(x: 1, y: view.bounds.midY), CGPoint(x: view.bounds.midX, y: 1),
      CGPoint(x: view.bounds.midX, y: view.bounds.maxY - 1),
    ] { #expect(reading.accessibilityLineNumber(for: point) == NSNotFound) }
  }
}
#endif
