#if os(macOS)
import AppKit

/// Resolve system colors in the requested appearance, even when a theme is
/// explicitly pinned to light or dark independently of the app's appearance.
enum NativeTheme {
  static func colors(named name: String) -> ColorSet? {
    let appearanceName: NSAppearance.Name
    switch name {
    case "Swiftty Light": appearanceName = .aqua
    case "Swiftty Dark": appearanceName = .darkAqua
    default: return nil
    }
    guard let appearance = NSAppearance(named: appearanceName) else {
      return nil
    }
    var colors = ColorSet()
    appearance.performAsCurrentDrawingAppearance {
      colors.background = rgb(.textBackgroundColor)
      colors.foreground = rgb(.textColor)
      colors.cursor = rgb(.textColor)
      colors.cursorText = rgb(.textBackgroundColor)
      colors.selectionBackground = rgb(.selectedTextBackgroundColor)
      colors.selectionForeground = rgb(.selectedTextColor)

      // Keep ANSI color identities (especially magenta and cyan) while using
      // the same adaptive hues as native controls and status indicators.
      let normal: [NSColor] = [
        .black, .systemRed, .systemGreen, .systemYellow, .systemBlue,
        .systemPurple, .systemCyan, .lightGray,
      ]
      let bright: [NSColor] = [
        .systemGray, .systemRed, .systemGreen, .systemYellow, .systemBlue,
        .systemPurple, .systemCyan, .white,
      ]
      for (index, color) in (normal + bright).enumerated() {
        colors.palette[index] = rgb(color)
      }
    }
    return colors
  }

  private static func rgb(_ color: NSColor) -> UInt32? {
    guard let color = color.usingColorSpace(.sRGB) else { return nil }
    func byte(_ component: CGFloat) -> UInt32 {
      UInt32((min(1, max(0, component)) * 255).rounded())
    }
    return byte(color.redComponent) << 16 | byte(color.greenComponent) << 8
      | byte(color.blueComponent)
  }
}
#endif
