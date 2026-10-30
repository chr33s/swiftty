import Foundation
@testable import RoamingApp
import SwiftUI
import Testing

/// spec.apple.md A02: shared owners follow the scenes' combined phase.
struct ScenePhasesTests {
  @Test
  func `one of two windows going to the background changes nothing`() {
    var scenes = ScenePhases()
    let first = UUID()
    let second = UUID()
    #expect(scenes.set(.active, for: first) == .init(old: nil, new: .active))
    #expect(scenes.set(.active, for: second) == nil)
    #expect(scenes.set(.background, for: first) == nil)
    #expect(
      scenes.set(.background, for: second)
        == .init(old: .active, new: .background)
    )
  }

  @Test
  func `transient inactivity is not backgrounding`() {
    var scenes = ScenePhases()
    let scene = UUID()
    _ = scenes.set(.active, for: scene)
    #expect(
      scenes.set(.inactive, for: scene) == .init(old: .active, new: .inactive)
    )
    #expect(
      scenes.set(.active, for: scene) == .init(old: .inactive, new: .active)
    )
  }

  @Test
  func `closing the foreground window leaves the background one in charge`() {
    var scenes = ScenePhases()
    let foreground = UUID()
    let background = UUID()
    _ = scenes.set(.active, for: foreground)
    _ = scenes.set(.background, for: background)
    #expect(
      scenes.set(nil, for: foreground) == .init(old: .active, new: .background)
    )
    #expect(
      scenes.set(nil, for: background) == .init(old: .background, new: nil)
    )
    #expect(scenes.aggregate == nil)
  }
}
