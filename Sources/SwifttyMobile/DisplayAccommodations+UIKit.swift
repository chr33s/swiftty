#if canImport(UIKit)
import SwifttyCore
import UIKit

extension DisplayAccommodations {
  /// The current Settings › Accessibility › Display & Text Size (and
  /// Motion) choices.
  @MainActor
  public static var current: DisplayAccommodations {
    DisplayAccommodations(
      reduceMotion: UIAccessibility.isReduceMotionEnabled,
      reduceTransparency: UIAccessibility.isReduceTransparencyEnabled,
      increaseContrast: UIAccessibility.isDarkerSystemColorsEnabled
    )
  }

  /// Posted on `NotificationCenter.default` when one of them changes.
  public static let changeNotifications: [Notification.Name] = [
    UIAccessibility.reduceMotionStatusDidChangeNotification,
    UIAccessibility.reduceTransparencyStatusDidChangeNotification,
    UIAccessibility.darkerSystemColorsStatusDidChangeNotification,
  ]
}
#endif
