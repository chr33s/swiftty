import SwiftMuxProtocol
import TTYKit

// SwiftMux frame styles and layout rectangles onto the shared TTY screen.

extension OuterStyle {
  init(_ s: FrameStyle, palette: FramePalette, underlineColors: [UInt32]) {
    self.init()
    func resolve(_ raw: UInt32, defaultColor: UInt32) -> OuterColor {
      switch OuterColor(raw: raw) {
      case .default: .rgb(defaultColor)
      case let .palette(index): .rgb(palette.colors[Int(index)])
      case let .rgb(value): .rgb(value)
      }
    }
    foreground = resolve(s.foreground, defaultColor: palette.foreground)
    background = resolve(s.background, defaultColor: palette.background)
    if s.underlineColor != 0 {
      underlineColor = resolve(
        underlineColors[Int(s.underlineColor) - 1],
        defaultColor: palette.foreground
      )
    }
    flags = s.flags
  }
}

extension ScreenBuffer {
  public mutating func fill(_ rect: LayoutRect, style: OuterStyle = .plain) {
    let firstY = max(0, rect.y)
    let lastY = min(rows, rect.maxY)
    let firstX = max(0, rect.x)
    let lastX = min(columns, rect.maxX)
    guard firstY < lastY, firstX < lastX else { return }
    for y in firstY ..< lastY {
      for x in firstX ..< lastX {
        cells[y * columns + x] = ScreenCell(text: " ", style: style)
      }
    }
  }
}
