#if canImport(UIKit)
import Foundation
import Metal
import SwifttyCore
import SwifttyMobile
import Testing
import UIKit

/// Kitty graphics in a live `TerminalUIView` (spec.graphics.md KG28):
/// memory warnings drop textures not on screen, and the animation clock
/// follows Reduce Motion. Public API only, so the iPad run
/// (`Scripts/test-ipad-frame-time.sh`) can link it from a Release build.
@MainActor
@Suite(.serialized)
struct KittyDeviceViewTests {
  nonisolated static let hasMetal = MTLCreateSystemDefaultDevice() != nil

  private static func image(id: Int, rgba: [UInt8]) -> [UInt8] {
    let pixels = Array([[UInt8]](repeating: rgba, count: 4).joined())
    return Array(
      "\u{1B}[H\u{1B}_Ga=T,f=32,s=2,v=2,i=\(id),c=4,r=2,C=1,q=2;\(Data(pixels).base64EncodedString())\u{1B}\\"
        .utf8
    )
  }

  private func shown(
    _ body: @MainActor (TerminalUIView) async throws -> Void
  ) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    var scene: UIWindowScene?
    repeat {
      scene = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first { $0.activationState == .foregroundActive }
      if scene != nil { break }
      try await Task.sleep(for: .milliseconds(10))
    } while ContinuousClock.now < deadline
    let window = UIWindow(windowScene: try #require(scene))
    window.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
    let session = TerminalSession()
    session.setCellPixelSize(width: 8, height: 16)
    let view = try TerminalUIView(session: session)
    view.frame = window.bounds
    window.addSubview(view)
    window.makeKeyAndVisible()
    defer {
      view.removeFromSuperview()
      window.isHidden = true
    }
    try await body(view)
  }

  private func eventually(_ what: String, _ ok: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !ok(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(ok(), Comment(rawValue: what))
  }

  @Test(.enabled(if: hasMetal))
  func `memory warnings drop image textures not on screen`() async throws {
    try await shown { view in
      view.session.feed(Self.image(id: 1, rgba: [255, 0, 0, 255]))
      try await eventually("first texture") { view.residentImageTextures == 1 }
      print(
        "kitty-device textures after first=\(view.residentImageTextures) images=\(view.session.snapshot().images.count)"
      )
      view.session.feed(Array("\u{1B}_Ga=d,d=I,i=1,q=2\u{1B}\\".utf8))
      view.session.feed(Self.image(id: 2, rgba: [0, 255, 0, 255]))
      try await eventually("second texture") { view.residentImageTextures == 2 }
      print(
        "kitty-device textures after second=\(view.residentImageTextures) images=\(view.session.snapshot().images.count)"
      )
      NotificationCenter.default.post(
        name: UIApplication.didReceiveMemoryWarningNotification,
        object: nil
      )
      #expect(view.residentImageTextures == 1)
    }
  }

  @Test(.enabled(if: hasMetal))
  func `the animation clock follows Reduce Motion`() async throws {
    try await shown { view in
      view.session.feed(Self.image(id: 3, rgba: [255, 0, 0, 255]))
      let blue = Data(
        Array([[UInt8]](repeating: [0, 0, 255, 255], count: 4).joined())
      )
      view.session.feed(
        Array(
          ("\u{1B}_Ga=f,i=3,s=2,v=2,z=50,q=2;\(blue.base64EncodedString())\u{1B}\\"
            + "\u{1B}_Ga=a,i=3,s=3,v=1,q=2\u{1B}\\")
            .utf8
        )
      )
      try await eventually("drawn") { view.residentImageTextures >= 1 }
      try await Task.sleep(for: .milliseconds(200))
      // Whatever the device's setting is, the clock must match it.
      #expect(view.isAnimatingImages == !UIAccessibility.isReduceMotionEnabled)
      print(
        "kitty-device reduce_motion=\(UIAccessibility.isReduceMotionEnabled) animating=\(view.isAnimatingImages)"
      )
    }
  }
}
#endif
