import ScreenProtocol
import SessionCore
import SwifttyEngine

/// How RST/1 presents cell text, titles and attributes (spec.roaming.md
/// §6), shared by the host's legacy snapshot export and the client's
/// mapping of shared frames, so both show the same screen.
public enum RSTPresentation {
  /// Complete grapheme text without control scalars; clusters over the
  /// grapheme limit display as `RSTLimits.graphemePlaceholder`.
  public static func text(_ scalars: [UInt32]) -> String {
    var view = String.UnicodeScalarView()
    var bytes = 0
    for value in scalars {
      guard let scalar = Unicode.Scalar(value), !isControl(scalar) else {
        continue
      }
      bytes += UTF8.width(scalar)
      guard bytes <= RSTLimits.maxGraphemeBytes else {
        return RSTLimits.graphemePlaceholder
      }
      view.append(scalar)
    }
    return String(view)
  }

  /// At most `RSTLimits.maxTitleBytes` UTF-8 bytes, cut on a character
  /// boundary, without control characters. Presentation only.
  public static func boundedTitle(_ title: String) -> String {
    var out = ""
    var bytes = 0
    for character in title {
      let filtered = String(
        String.UnicodeScalarView(
          character.unicodeScalars.filter { !isControl($0) }
        )
      )
      let size = filtered.utf8.count
      guard bytes + size <= RSTLimits.maxTitleBytes else { break }
      out += filtered
      bytes += size
    }
    return out
  }

  public static func isControl(_ scalar: Unicode.Scalar) -> Bool {
    scalar.value < 0x20 || (0x7F ... 0x9F).contains(scalar.value)
  }

  /// Presentation attributes only: hyperlinks and protection are dropped.
  public static func attributes(_ flags: CellFlags) -> TextAttributes {
    var out: TextAttributes = []
    if flags.contains(.bold) { out.insert(.bold) }
    if flags.contains(.faint) { out.insert(.faint) }
    if flags.contains(.italic) { out.insert(.italic) }
    if flags.contains(.blink) { out.insert(.blink) }
    if flags.contains(.inverse) { out.insert(.inverse) }
    if flags.contains(.invisible) { out.insert(.invisible) }
    if flags.contains(.strikethrough) { out.insert(.strikethrough) }
    if flags.contains(.overline) { out.insert(.overline) }
    if flags.contains(.doubleUnderline) {
      out.insert(.doubleUnderline)
    } else if flags.contains(.underline) {
      let a = flags.contains(.underlineStyleA)
      let b = flags.contains(.underlineStyleB)
      switch (a, b) {
      case (true, true): out.insert(.dashedUnderline)
      case (true, false): out.insert(.curlyUnderline)
      case (false, true): out.insert(.dottedUnderline)
      case (false, false): out.insert(.underline)
      }
    }
    return out
  }
}
