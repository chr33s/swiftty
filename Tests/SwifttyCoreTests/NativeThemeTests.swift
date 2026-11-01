#if os(macOS)
import AppKit
@testable import SwifttyCore
import Testing

struct NativeThemeTests {
  @Test(arguments: [false, true])
  func defaultsFollowSystemColors(dark: Bool) throws {
    let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
    let palette = Configuration().palette(for: dark ? .dark : .light)
    appearance.performAsCurrentDrawingAppearance {
      func matches(_ value: UInt32?, _ system: NSColor) -> Bool {
        guard let value, let rgb = system.usingColorSpace(.sRGB) else {
          return false
        }
        let actual = NSColor(
          srgbRed: CGFloat((value >> 16) & 255) / 255,
          green: CGFloat((value >> 8) & 255) / 255,
          blue: CGFloat(value & 255) / 255,
          alpha: 1
        )
        return abs(actual.redComponent - rgb.redComponent) <= 1 / 255
          && abs(actual.greenComponent - rgb.greenComponent) <= 1 / 255
          && abs(actual.blueComponent - rgb.blueComponent) <= 1 / 255
      }
      #expect(matches(palette.background, .textBackgroundColor))
      #expect(matches(palette.foreground, .textColor))
      #expect(
        matches(palette.selectionBackground, .selectedTextBackgroundColor)
      )
      #expect(matches(palette.selectionForeground, .selectedTextColor))
      #expect(matches(palette.colors[1], .systemRed))
      #expect(matches(palette.colors[5], .systemPurple))
      #expect(matches(palette.colors[6], .systemCyan))
      #expect(palette.cursor == palette.foreground)
      #expect(palette.cursorText == palette.background)
    }
  }

  @Test
  func explicitColorsOverrideNativeTheme() {
    var config = Configuration()
    config.colors.background = 0x123456
    config.colors.selectionBackground = 0x654321
    config.colors.palette[1] = 0xABCDEF
    for scheme in [ColorScheme.light, .dark] {
      let palette = config.palette(for: scheme)
      #expect(palette.background == 0x123456)
      #expect(palette.selectionBackground == 0x654321)
      #expect(palette.colors[1] == 0xABCDEF)
    }
  }
}
#endif
