import SwiftMuxClient
import Testing
import TestSupport

/// `MuxTextChunks` splits text into bounded records on scalar boundaries.
struct MuxTextChunksPropertyTests {
  struct Input: CustomStringConvertible {
    var scalars: [Unicode.Scalar]
    var maxBytes: Int

    var text: String {
      var view = String.UnicodeScalarView()
      view.append(contentsOf: scalars)
      return String(view)
    }

    var description: String {
      let hex = scalars.map { String($0.value, radix: 16, uppercase: true) }
      return "maxBytes \(maxBytes), scalars [\(hex.joined(separator: " "))]"
    }
  }

  /// ASCII and controls, two-, three- and four-byte scalars, combining
  /// marks, joiners and selectors, so clusters span chunk boundaries.
  static let alphabet: [Unicode.Scalar] = [
    "a", "Z", " ", "\r", "\n", "\u{1B}", "é", "ß", "\u{7FF}", "漢", "€",
    "\u{FFFD}", "\u{FFFF}", "👍", "\u{1F3FD}", "🇳", "🇿", "\u{10FFFF}", "\u{301}",
    "\u{302}", "\u{200D}", "\u{FE0F}",
  ]

  static func generate(_ random: inout PropertyRandom) -> Input {
    let count = random.int(in: 0 ... 60)
    return Input(
      scalars: random.array(count: count) { $0.element(of: alphabet) },
      maxBytes: random.int(in: 1 ... 16)
    )
  }

  static func shrink(_ input: Input) -> [Input] {
    let simpler: (Unicode.Scalar) -> [Unicode.Scalar] = {
      $0 == "a" ? [] : ["a"]
    }
    var out = Property.shrinkList(input.scalars, element: simpler)
      .map { Input(scalars: $0, maxBytes: input.maxBytes) }
    if input.maxBytes > 1 {
      out.append(Input(scalars: input.scalars, maxBytes: input.maxBytes - 1))
    }
    return out
  }

  static func check(_ input: Input) -> String? {
    let chunks = Array(MuxTextChunks(input.text, maxBytes: input.maxBytes))
    var scalars: [Unicode.Scalar] = []
    var bytes: [UInt8] = []
    for (i, chunk) in chunks.enumerated() {
      let width = chunk.utf8.count
      guard width > 0 else { return "chunk \(i) is empty" }
      let own = Array(chunk.unicodeScalars)
      guard width <= input.maxBytes || own.count == 1 else {
        return "chunk \(i) has \(width) bytes in \(own.count) scalars"
      }
      scalars += own
      bytes += chunk.utf8
    }
    guard scalars == input.scalars else {
      return "chunks hold scalars \(scalars.map(\.value)), not the input's"
    }
    guard bytes == Array(input.text.utf8) else {
      return "chunks concatenate to different UTF-8"
    }
    return nil
  }

  @Test
  func chunksConcatenateToTheInputWithinTheBound() {
    let failure = Property.check(
      seeds: Property.seeds(500),
      generate: Self.generate,
      shrink: Self.shrink,
      property: Self.check
    )
    #expect(failure == nil, "\(failure?.description ?? "")")
  }
}
