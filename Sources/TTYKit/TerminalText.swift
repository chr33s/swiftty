import SwiftMuxProtocol
import SwifttyEngine

/// Chrome uses the same segmentation and display widths as pane text.
/// Native UI character-count truncation stays in `DisplayText`.
package enum TerminalText {
  package static func glyphs(_ text: String) -> [(text: String, width: Int)] {
    var result: [(text: String, width: Int)] = []
    for character in text {
      guard DisplayText.draws(character) else {
        result.append(("?", 1))
        continue
      }
      let scalars = Array(character.unicodeScalars)
      let values = scalars.map(\.value)
      var offset = 0
      while offset < values.count {
        let (length, width) = UnicodeWidth.graphemeWidth(values[offset...])
        // An isolated combining/format scalar must not join adjacent chrome.
        let shown =
          width == 0
          ? "?"
          : String(
            String.UnicodeScalarView(scalars[offset ..< offset + length])
          )
        result.append((shown, max(1, width)))
        offset += length
      }
    }
    return result
  }

  package static func width(_ text: String) -> Int {
    glyphs(text).reduce(0) { $0 + $1.width }
  }

  package static func head(_ text: String, width: Int) -> String {
    clipped(text, width: width, keepingEnd: false)
  }

  package static func tail(_ text: String, width: Int) -> String {
    clipped(text, width: width, keepingEnd: true)
  }

  private static func clipped(
    _ text: String,
    width: Int,
    keepingEnd: Bool
  ) -> String {
    guard width > 0 else { return "" }
    let glyphs = glyphs(text)
    guard glyphs.reduce(0, { $0 + $1.width }) > width else {
      return glyphs.map(\.text).joined()
    }
    var room = width - 1  // ellipsis
    var kept: [String] = []
    for glyph in keepingEnd ? Array(glyphs.reversed()) : glyphs {
      guard glyph.width <= room else { break }
      kept.append(glyph.text)
      room -= glyph.width
    }
    return keepingEnd ? "…" + kept.reversed().joined() : kept.joined() + "…"
  }
}
