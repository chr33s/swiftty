@testable import SwifttyMobile
import Testing
import UIKit

/// Included by test-ios-simulator.sh, where UIKit has an application host.
extension ViewLifecycleTests {
  @Test
  func `hosted control events preserve the newest held key repeat`()
    async throws
  {
    let bar = TerminalAccessoryBar()
    let window = makeWindow()
    window.addSubview(bar)
    defer {
      bar.stopRepeating();
      bar.removeFromSuperview()
    }
    func findButton(_ title: String, in view: UIView) -> UIButton? {
      if let button = view as? UIButton, button.accessibilityLabel == title {
        return button
      }
      return view.subviews.lazy.compactMap { findButton(title, in: $0) }.first
    }
    let up = try #require(findButton(AccessoryKey.up.title, in: bar))
    let left = try #require(findButton(AccessoryKey.left.title, in: bar))
    var delivered: [AccessoryKey] = []
    bar.onKey = { delivered.append($0) }
    up.sendActions(for: .touchDown)
    left.sendActions(for: .touchDown)
    up.sendActions(for: .touchUpInside)
    #expect(delivered == [.up, .left])
    let deadline = ContinuousClock.now + .seconds(2)
    while delivered.count < 3, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(delivered.count >= 3)
    #expect(delivered.dropFirst().allSatisfy { $0 == .left })
    left.sendActions(for: .touchUpInside)
    let stoppedCount = delivered.count
    try await Task.sleep(for: .milliseconds(150))
    #expect(delivered.count == stoppedCount)
  }
}
