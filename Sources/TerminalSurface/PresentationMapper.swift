import ScreenProtocol
import SessionCore
import SwifttyEngine

/// Maps a validated RST/1 `ScreenSnapshot` to a Swiftty `PresentationFrame`
/// (spec §6, §A.4.3). Pure and `Sendable`-safe: run it off the UI
/// executor, alongside decoding.
///
/// Cell widths and continuations are preserved exactly; nothing is
/// reflowed or re-measured. Styles keep their table indices.
public enum PresentationMapper {
  /// Validates, then maps. Rejects anything `ScreenSnapshot.validate()`
  /// rejects, before allocating the frame.
  public static func frame(
    from snapshot: ScreenSnapshot
  ) throws(SnapshotValidationError) -> PresentationFrame {
    try snapshot.validate()
    return map(snapshot)
  }

  /// Maps a snapshot already validated by `SnapshotFrame.decode`.
  public static func map(_ snapshot: ScreenSnapshot) -> PresentationFrame {
    var cells: [PresentationFrame.Cell] = []
    cells.reserveCapacity(snapshot.columns * snapshot.rows)
    for row in snapshot.cells {
      for cell in row {
        cells.append(
          PresentationFrame.Cell(
            text: cell.text,
            width: cell.width,
            style: cell.style
          )
        )
      }
    }
    let cursor = snapshot.cursor
    return PresentationFrame(
      columns: snapshot.columns,
      rows: snapshot.rows,
      cells: cells,
      wrapped: snapshot.wrapped,
      styles: snapshot.styles.map(style),
      cursorX: cursor.column,
      cursorY: cursor.row,
      cursorVisible: cursor.visible,
      cursorStyle: cursorStyle(cursor.shape),
      cursorBlinking: cursor.blinking,
      reverseVideo: snapshot.reverseVideo,
      alternateScreen: snapshot.activeBuffer == .alternate,
      title: snapshot.title
    )
  }

  public static func style(_ style: CellStyle) -> PresentationFrame.Style {
    PresentationFrame.Style(
      foreground: style.foreground?.rgb,
      background: style.background?.rgb,
      underlineColor: style.underlineColor?.rgb,
      flags: flags(style.attributes)
    )
  }

  public static func cursorStyle(_ shape: CursorShape) -> CursorStyle {
    switch shape {
    case .block: .block
    case .underline: .underline
    case .bar: .bar
    }
  }

  /// RST/1 attributes to Swiftty presentation flags. Underline variants
  /// use Swiftty's SGR 4:n encoding: curly sets style bit A, dotted B,
  /// dashed both. Structural flags are never set.
  public static func flags(_ attributes: TextAttributes) -> CellFlags {
    var out = CellFlags()
    let direct: [(TextAttributes, CellFlags)] = [
      (.bold, .bold), (.faint, .faint), (.italic, .italic), (.blink, .blink),
      (.inverse, .inverse), (.invisible, .invisible),
      (.strikethrough, .strikethrough), (.overline, .overline),
    ]
    for (attribute, flag) in direct where attributes.contains(attribute) {
      out.insert(flag)
    }
    if attributes.contains(.doubleUnderline) {
      out.insert(.doubleUnderline)
    } else if attributes.contains(.dashedUnderline) {
      out.formUnion([.underline, .underlineStyleA, .underlineStyleB])
    } else if attributes.contains(.dottedUnderline) {
      out.formUnion([.underline, .underlineStyleB])
    } else if attributes.contains(.curlyUnderline) {
      out.formUnion([.underline, .underlineStyleA])
    } else if attributes.contains(.underline) {
      out.insert(.underline)
    }
    return out
  }
}
