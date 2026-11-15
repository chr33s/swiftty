import SwifttyEngine
import TTYKit

// Host presentation frames onto the outer terminal's cell buffer.

extension OuterStyle {
  /// Presentation attributes; structural engine bits never reach the TTY.
  static let presentationFlags: UInt16 = ~CellFlags.structural.rawValue

  public init(_ style: PresentationFrame.Style, reverseVideo: Bool = false) {
    self.init(
      foreground: style.foreground.map(OuterColor.rgb) ?? .default,
      background: style.background.map(OuterColor.rgb) ?? .default,
      underlineColor: style.underlineColor.map(OuterColor.rgb) ?? .default,
      flags: style.flags.rawValue & Self.presentationFlags
    )
    // DECSCNM inverts every cell, which the outer terminal expresses
    // per cell.
    if reverseVideo { self = toggling(Self.inverse) }
  }
}

extension ScreenBuffer {
  /// Draws `frame` at the top left of a `columns` × `rows` buffer.
  ///
  /// The host grid is authoritative: a frame larger than the outer
  /// terminal is clipped, a smaller one leaves the rest blank. A wide cell
  /// cut by the right edge becomes a blank, never half a glyph.
  public init(_ frame: PresentationFrame, columns: Int, rows: Int) {
    self.init(columns: columns, rows: rows)
    let styles = frame.styles.map {
      OuterStyle($0, reverseVideo: frame.reverseVideo)
    }
    let shownRows = min(frame.rows, self.rows)
    let shownColumns = min(frame.columns, self.columns)
    for y in 0 ..< shownRows {
      let base = y * frame.columns
      for x in 0 ..< shownColumns {
        let cell = frame.cells[base + x]
        guard cell.width != 0 else { continue }
        let style =
          styles.indices.contains(cell.style) ? styles[cell.style] : .plain
        put(
          ScreenCell(
            text: cell.text.isEmpty ? " " : cell.text,
            width: cell.width,
            style: style
          ),
          x: x,
          y: y
        )
      }
    }
    if frame.cursorVisible, frame.cursorX < self.columns,
      frame.cursorY < self.rows
    {
      cursor = (frame.cursorX, frame.cursorY, frame.cursorStyle.rawValue)
    }
  }
}
