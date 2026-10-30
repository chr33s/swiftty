import AppKit
import SwifttyCore

extension DisplayAccommodations {
  /// The current System Settings › Accessibility › Display choices.
  @MainActor
  public static var current: DisplayAccommodations {
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
