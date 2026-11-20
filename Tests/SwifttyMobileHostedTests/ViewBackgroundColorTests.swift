#if canImport(UIKit)
import MetalKit
import SwifttyCore
@testable import SwifttyMobile
import Testing
import UIKit

/// The terminal reports its background so the app can paint the bars and
/// safe areas to match (`TerminalChromeBackground`).
@MainActor
@Suite(.serialized)
struct ViewBackgroundColorTests {
  nonisolated static let hasMetal = MTLCreateSystemDefaultDevice() != nil

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

  @Test(.enabled(if: hasMetal), arguments: [false, true])
  func `a handler set after creation receives the background`(
    presentation: Bool
  ) async throws {
    let scene = try await foregroundScene()
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
    let session =
      presentation
      ? TerminalSession(
        presentationColumns: 80,
        rows: 24,
        configuration: Configuration().sessionConfiguration()
      ) : TerminalSession()
    // As `TerminalDisplayView.makeUIView` does: create, then attach.
    let view = try TerminalUIView(session: session)
    var reported: [UIColor] = []
    view.onBackgroundColor = { reported.append($0) }
    view.frame = window.bounds
    window.addSubview(view)
    window.makeKeyAndVisible()
    defer {
      view.removeFromSuperview()
      window.isHidden = true
    }
    let deadline = ContinuousClock.now + .seconds(3)
    while reported.isEmpty, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(!reported.isEmpty)
  }
}
#endif
