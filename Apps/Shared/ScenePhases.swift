import Foundation
import SwiftUI

/// The phases of every scene sharing one owner (the app model, or a
/// terminal controller shown in more than one window), combined the way
/// SwiftUI combines an app's phase: active if any scene is active,
/// otherwise inactive if any is inactive, otherwise background.
///
/// A scene going to the background therefore never suspends something
/// another foreground scene still shows (spec.apple.md A02).
struct ScenePhases {
  struct Change: Equatable {
    /// Nil before the first scene reported.
    var old: ScenePhase?
    /// Nil once the last scene went away.
    var new: ScenePhase?
  }

  private var phases: [UUID: ScenePhase] = [:]

  var aggregate: ScenePhase? {
    if phases.values.contains(.active) { return .active }
    if phases.values.contains(.inactive) { return .inactive }
    return phases.isEmpty ? nil : .background
  }

  /// Records `scene`'s phase, nil when the scene went away. Returns the
  /// aggregate change, or nil when the aggregate is unchanged.
  mutating func set(_ phase: ScenePhase?, for scene: UUID) -> Change? {
    let old = aggregate
    phases[scene] = phase
    let new = aggregate
    return old == new ? nil : Change(old: old, new: new)
  }
}
