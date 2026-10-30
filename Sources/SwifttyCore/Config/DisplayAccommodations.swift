/// System accessibility display preferences that change how a configuration
/// is presented, never what the configuration file says (spec.apple.md
/// A05). Frontends read them from AppKit/UIKit and pass the result through
/// `Configuration.accommodating(_:)`.
public struct DisplayAccommodations: Equatable, Sendable {
  /// Nonessential animation, including animated custom shaders, is static.
  public var reduceMotion = false
  /// Translucent and blurred terminal backgrounds are drawn opaque.
  public var reduceTransparency = false
  /// Text keeps at least `increasedMinimumContrast` against its background.
  public var increaseContrast = false

  /// WCAG AA for normal text.
  public static let increasedMinimumContrast = 4.5

  public init(
    reduceMotion: Bool = false,
    reduceTransparency: Bool = false,
    increaseContrast: Bool = false
  ) {
    self.reduceMotion = reduceMotion
    self.reduceTransparency = reduceTransparency
    self.increaseContrast = increaseContrast
  }
}

extension Configuration {
  /// The configuration as presented under `accommodations`. Values are
  /// only ever made more conservative; the original file values are kept
  /// by the caller, so turning a preference off restores them.
  public func accommodating(
    _ accommodations: DisplayAccommodations
  ) -> Configuration {
    var c = self
    c.accommodations = accommodations
    if accommodations.reduceTransparency {
      c.backgroundOpacity = 1
      c.backgroundBlur = 0
    }
    if accommodations.increaseContrast {
      c.minimumContrast = max(
        c.minimumContrast,
        DisplayAccommodations.increasedMinimumContrast
      )
    }
    return c
  }
}
