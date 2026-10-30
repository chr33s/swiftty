import AppKit
import SwifttyCore

extension DisplayAccommodations {
  /// Replaces the system choices when set, so tests behave the same on
  /// hosts (CI runners) that report Reduce Transparency or Reduce Motion.
  @MainActor
  public static var override: DisplayAccommodations?

  /// The current System Settings › Accessibility › Display choices.
  @MainActor
  public static var current: DisplayAccommodations {
    if let override { return override }
    let workspace = NSWorkspace.shared
    return DisplayAccommodations(
      reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
      reduceTransparency: workspace
        .accessibilityDisplayShouldReduceTransparency,
      increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast
    )
  }

  /// Posted on `NSWorkspace.shared.notificationCenter` when any of them
  /// changes.
  public static let didChangeNotification = NSWorkspace
    .accessibilityDisplayOptionsDidChangeNotification
}
