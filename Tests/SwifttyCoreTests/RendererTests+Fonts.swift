import CoreText
import Metal
@testable import SwifttyCore
@testable import SwifttyEngine
import Testing
import TestSupport

extension RendererTests {
  /// The system's variable font is available on fresh Macs without the
  /// separately installed SF Pro developer download.
  private static func systemFontFamily() throws -> String {
    let font = try #require(CTFontCreateUIFontForLanguage(.system, 26, nil))
    return CTFontCopyFamilyName(font) as String
  }

  @Test(.enabled(if: device != nil), arguments: [0, 1, 2])
  func
    `font changes rebuild clean shaped and grapheme rows like a fresh renderer`(
      _ change: Int
    ) throws
  {
    let device = try #require(Self.device)
    var original = FontDescriptor(size: 13, scale: 2)
    original.features = ["liga"]
    let renderer = try MetalRenderer(
      device: device,
      fontManager: CoreTextFontManager(),
      font: original
    )
    let session = TerminalSession(columns: 16, rows: 2)
    session.feed(
      Array("\u{1B}[?2027h\u{1B}[?25lffi aำ\r\n\u{1B}[1mA漢 👩‍💻\u{1B}[0m".utf8)
    )
    var snapshot = session.snapshot()
    _ = try render(
      renderer,
      snapshot,
      width: Int(renderer.cellSize.width) * 16 + 16,
      height: Int(renderer.cellSize.height) * 2 + 16
    )
    snapshot.damage = .none
    var changed = original
    switch change {
    case 0: changed.size = 19
    case 1: changed.family = "Helvetica"
    default: changed.features = ["-liga"]
    }
    for descriptor in [changed, original] {
      renderer.setFont(descriptor)
      let fresh = try MetalRenderer(
        device: device,
        fontManager: CoreTextFontManager(),
        font: descriptor
      )
      #expect(renderer.cellSize == fresh.cellSize)
      let width = Int(fresh.cellSize.width) * 16 + 16
      let height = Int(fresh.cellSize.height) * 2 + 16
      let actual = try render(renderer, snapshot, width: width, height: height)
      let expected = try render(fresh, snapshot, width: width, height: height)
      #expect(actual.pixels == expected.pixels)
    }
  }

  @Test(arguments: [FontStyle(), .bold, .italic, [.bold, .italic]])
  func `primary color fonts preserve the glyph color classification`(
    _ style: FontStyle
  ) throws {
    var descriptor = FontDescriptor()
    descriptor.family = "Apple Color Emoji"
    let font = ResolvedFont(descriptor: descriptor)
    let lookup = try #require(
      CoreTextFontManager().lookup("©", style: style, in: font)
    )
    #expect(CTFontGetSymbolicTraits(lookup.font).contains(.traitColorGlyphs))
    #expect(lookup.isColor)
  }

  @Test(
    arguments: ["Menlo-Bold", "Menlo Bold"],
    ["primary", "bold", "italic", "combined", "fallback"]
  )
  func `specific font names are preserved`(
    _ name: String,
    _ destination: String
  ) throws {
    let expected = CTFontCreateWithName(name as CFString, 26, nil)
    #expect(CTFontCopyPostScriptName(expected) as String == "Menlo-Bold")
    var descriptor = FontDescriptor()
    var style: FontStyle = []
    switch destination {
    case "primary": descriptor.family = name
    case "bold":
      descriptor.boldFamily = name;
      style = .bold
    case "italic":
      descriptor.italicFamily = name;
      style = .italic
    case "combined":
      descriptor.boldItalicFamily = name;
      style = [.bold, .italic]
    default:
      descriptor.family = "Apple Color Emoji"
      descriptor.fallbackFamilies = [name]
    }
    let font = ResolvedFont(descriptor: descriptor)
    if destination == "fallback" {
      let fallback = try #require(font.fallbacks.first)
      #expect(CTFontCopyPostScriptName(fallback) as String == "Menlo-Bold")
      let lookup = try #require(
        CoreTextFontManager().lookup("A", style: [], in: font)
      )
      #expect(CTFontCopyPostScriptName(lookup.font) as String == "Menlo-Bold")
    } else {
      #expect(
        CTFontCopyPostScriptName(font.face(style)) as String == "Menlo-Bold"
      )
    }
  }

  @Test(arguments: [FontStyle.bold, .italic, [.bold, .italic]])
  func `configured fallback fonts use native styles`(_ style: FontStyle) throws
  {
    var descriptor = FontDescriptor()
    descriptor.fallbackFamilies = [try Self.systemFontFamily()]
    descriptor.features = ["ss01"]
    let font = ResolvedFont(descriptor: descriptor)
    let scalar: Unicode.Scalar = "₺"
    let lookup = try #require(
      CoreTextFontManager().lookup(scalar, style: style, in: font)
    )
    let traits: CTFontSymbolicTraits =
      style == .bold
      ? .traitBold
      : style == .italic ? .traitItalic : [.traitBold, .traitItalic]
    #expect(CTFontGetSymbolicTraits(lookup.font).contains(traits))
    #expect(!font.shouldEmbolden(lookup.font, style: style))
    let shaped = Shaper()
      .shape([scalar.value, scalar.value], style: style, font: font)
    #expect(shaped.count == 2)
    for glyph in shaped {
      #expect(CTFontGetSymbolicTraits(glyph.font).contains(traits))
    }
  }

  @Test(arguments: [true, false])
  func `single face fallback fonts honor synthetic styles`(
    _ synthesize: Bool
  ) throws {
    var descriptor = FontDescriptor(family: "Apple Color Emoji")
    descriptor.fallbackFamilies = ["Monaco"]
    descriptor.synthesizeBold = synthesize
    descriptor.synthesizeItalic = synthesize
    descriptor.synthesizeBoldItalic = synthesize
    let font = ResolvedFont(descriptor: descriptor)
    let manager = CoreTextFontManager()
    let scalar: Unicode.Scalar = "A"
    #expect(manager.glyph(for: scalar, in: font) == nil)
    for style: FontStyle in [.bold, .italic, [.bold, .italic]] {
      let lookup = try #require(manager.lookup(scalar, style: style, in: font))
      #expect(CTFontCopyFamilyName(lookup.font) as String == "Monaco")
      #expect(
        font.shouldEmbolden(lookup.font, style: style)
          == (synthesize && style.contains(.bold))
      )
      #expect(
        CTFontGetMatrix(lookup.font).c
          == (synthesize && style.contains(.italic) ? 0.2 : 0)
      )
      let shaped = Shaper()
        .shape([scalar.value, scalar.value], style: style, font: font)
      #expect(shaped.count == 2)
      for glyph in shaped {
        #expect(CTFontCopyFamilyName(glyph.font) as String == "Monaco")
        #expect(
          font.shouldEmbolden(glyph.font, style: style)
            == (synthesize && style.contains(.bold))
        )
        #expect(
          CTFontGetMatrix(glyph.font).c
            == (synthesize && style.contains(.italic) ? 0.2 : 0)
        )
      }
    }
  }

  @Test(.enabled(if: device != nil))
  func
    `native fallback glyphs are not stroked because the primary font needs synthesis`()
    throws
  {
    var descriptor = FontDescriptor(family: "Monaco")
    descriptor.fallbackFamilies = [try Self.systemFontFamily()]
    let font = ResolvedFont(descriptor: descriptor)
    #expect(font.emboldened[1])
    let manager = CoreTextFontManager()
    let scalar: Unicode.Scalar = "₺"
    let lookup = try #require(manager.lookup(scalar, style: .bold, in: font))
    #expect(CTFontGetSymbolicTraits(lookup.font).contains(.traitBold))
    let atlas = try GlyphAtlas(device: #require(Self.device))
    let actual = atlas.entry(
      scalar: scalar,
      style: .bold,
      font: font,
      manager: manager
    )
    let expected = atlas.entry(
      glyph: lookup.glyph,
      in: lookup.font,
      isColor: false,
      embolden: false,
      font: font
    )
    func pixels(_ entry: GlyphAtlas.Entry) -> [UInt8] {
      let width = Int(entry.size.x)
      let height = Int(entry.size.y)
      var bytes = [UInt8](repeating: 0, count: width * height * 4)
      atlas.texture.getBytes(
        &bytes,
        bytesPerRow: width * 4,
        from: MTLRegionMake2D(
          Int(entry.position.x),
          Int(entry.position.y),
          width,
          height
        ),
        mipmapLevel: 0,
      )
      return bytes
    }
    #expect(actual.size.x > 0 && actual.size.y > 0)
    #expect(actual.size == expected.size)
    #expect(actual.offset == expected.offset)
    #expect(pixels(actual) == pixels(expected))
    // Grapheme rendering uses a CoreText line even with row shaping
    // disabled. Its configured cascade must also use native bold.
    let cluster = atlas.entry(
      cluster: [scalar.value, 0xFE0E],
      style: .bold,
      font: font
    )
    #expect(cluster.size == expected.size)
    #expect(cluster.offset == expected.offset)
    #expect(pixels(cluster) == pixels(expected))
  }

  @Test
  func `configured fallback fonts receive features and variations`() throws {
    var descriptor = FontDescriptor()
    descriptor.fallbackFamilies = [try Self.systemFontFamily()]
    descriptor.features = ["ss01=2"]
    descriptor.variations = ["wdth": 120]
    let font = ResolvedFont(descriptor: descriptor)
    let fallback = try #require(font.fallbacks.first)
    let settings = try #require(
      CTFontCopyAttribute(fallback, kCTFontFeatureSettingsAttribute)
        as? [[String: Any]]
    )
    #expect(
      settings.contains {
        ($0[kCTFontOpenTypeFeatureTag as String] as? String) == "ss01"
          && ($0[kCTFontOpenTypeFeatureValue as String] as? Int) == 2
      }
    )
    let variation = try #require(
      CTFontCopyVariation(fallback) as? [NSNumber: Double]
    )
    #expect(variation[NSNumber(value: UInt32(0x7764_7468))] == 120)
    let cascade = try #require(
      CTFontCopyAttribute(font.faces[0], kCTFontCascadeListAttribute)
        as? [CTFontDescriptor]
    )
    let first = try #require(cascade.first)
    let cascadeFont = CTFontCreateWithFontDescriptor(
      first,
      CTFontGetSize(fallback),
      nil
    )
    #expect(CFEqual(cascadeFont, fallback))
    // The lira sign is absent from Menlo, so both renderer paths must
    // resolve it through the configured system font fallback.
    let scalar: Unicode.Scalar = "₺"
    let manager = CoreTextFontManager()
    #expect(manager.glyph(for: scalar, in: font) == nil)
    let lookup = try #require(manager.lookup(scalar, style: [], in: font))
    #expect(CFEqual(lookup.font, fallback))
    let shaped = Shaper()
      .shape([scalar.value, scalar.value], style: [], font: font)
    #expect(shaped.count == 2)
    for glyph in shaped {
      let shapedVariation = try #require(
        CTFontCopyVariation(glyph.font) as? [NSNumber: Double]
      )
      #expect(shapedVariation[NSNumber(value: UInt32(0x7764_7468))] == 120)
    }
  }

  @Test(arguments: [
    "+liga", "liga on", "liga=1", "liga=2", "liga = 3", "liga 4", "\"liga\" 2",
    "'liga' 2",
  ])
  func `font feature syntax reaches CoreText`(_ feature: String) throws {
    let config = Configuration.configured([("font-feature", "\(feature)")])
    let font = ResolvedFont(descriptor: config.fontDescriptor(scale: 2))
    #expect(font.shapes)
    let settings = try #require(
      CTFontCopyAttribute(font.faces[0], kCTFontFeatureSettingsAttribute)
        as? [[String: Any]]
    )
    let setting = try #require(
      settings.first {
        ($0[kCTFontOpenTypeFeatureTag as String] as? String) == "liga"
      }
    )
    let expected =
      feature.contains("2")
      ? 2 : feature.contains("3") ? 3 : feature.contains("4") ? 4 : 1
    #expect(setting[kCTFontOpenTypeFeatureValue as String] as? Int == expected)
  }

  @Test(arguments: ["-liga", "liga off", "liga=0", "\"liga\" off"])
  func `later font features override earlier settings`(_ feature: String) throws
  {
    let config = Configuration.configured([
      ("font-family", "\(try Self.systemFontFamily())"),
      ("font-feature", "liga"), ("font-feature", "\(feature)"),
    ])
    let font = ResolvedFont(descriptor: config.fontDescriptor(scale: 2))
    #expect(!font.shapes)
    let settings = try #require(
      CTFontCopyAttribute(font.faces[0], kCTFontFeatureSettingsAttribute)
        as? [[String: Any]]
    )
    let values = settings.filter {
      ($0[kCTFontOpenTypeFeatureTag as String] as? String) == "liga"
    }
    #expect(values.count == 1)
    #expect(values.first?[kCTFontOpenTypeFeatureValue as String] as? Int == 0)
  }

  @Test(arguments: ["\"ss01\", \"cv01\"", "'ss01', 'cv01'", "ss01, cv01"])
  func `feature lists preserve each tag`(_ list: String) throws {
    let config = Configuration.configured([
      ("font-family", "\(try Self.systemFontFamily())"),
      ("font-feature", "\(list)"),
    ])
    let font = ResolvedFont(descriptor: config.fontDescriptor(scale: 2))
    let settings = try #require(
      CTFontCopyAttribute(font.faces[0], kCTFontFeatureSettingsAttribute)
        as? [[String: Any]]
    )
    #expect(
      settings.compactMap { $0[kCTFontOpenTypeFeatureTag as String] as? String }
        == ["ss01", "cv01"]
    )
  }

  @Test(arguments: [0.7, 1.3])
  func `cell metrics use the configured variable font face`(
    _ width: Double
  ) throws {
    var descriptor = FontDescriptor(family: "Skia")
    descriptor.variations = ["wdth": width]
    descriptor.cellWidthAdjust = 0.1
    descriptor.cellWidthOffset = 2
    let font = ResolvedFont(descriptor: descriptor)
    let face = font.faces[0]
    let variation = try #require(
      CTFontCopyVariation(face) as? [NSNumber: Double]
    )
    #expect(variation[NSNumber(value: UInt32(0x7764_7468))] == width)
    var character: UniChar = 0x4D
    var glyph = CGGlyph(0)
    #expect(CTFontGetGlyphsForCharacters(face, &character, &glyph, 1))
    var advance = CGSize.zero
    CTFontGetAdvancesForGlyphs(face, .horizontal, &glyph, &advance, 1)
    #expect(font.cellWidth == ceil(advance.width * 1.1 + 4))
    let ascent = ceil(CTFontGetAscent(face))
    let descent = ceil(CTFontGetDescent(face))
    let height = ascent + descent + ceil(CTFontGetLeading(face))
    #expect(font.cellHeight == height)
    #expect(font.ascent == ascent)
    #expect(font.descent == descent)
    #expect(font.underlinePosition == ascent - CTFontGetUnderlinePosition(face))
    #expect(
      font.underlineThickness
        == max(1, round(CTFontGetUnderlineThickness(face)))
    )
  }

  @Test
  func `named font styles select faces and disabled styles use regular`() {
    let config = Configuration.configured([
      ("font-family", "Menlo"), ("font-style", "Bold"),
      ("font-style-italic", "false"),
    ])
    let font = ResolvedFont(descriptor: config.fontDescriptor(scale: 2))
    #expect(
      CTFontCopyName(font.faces[0], kCTFontStyleNameKey) as String? == "Bold"
    )
    #expect(font.faces[2] == font.faces[0])
  }

  @Test
  func `disabling synthesis preserves native font styles`() {
    let config = Configuration.configured([
      ("font-family", "Menlo"), ("font-synthetic-style", "false"),
    ])
    let font = ResolvedFont(descriptor: config.fontDescriptor(scale: 2))
    #expect(font.emboldened == [false, false, false, false])
    #expect(CTFontGetSymbolicTraits(font.faces[1]).contains(.traitBold))
    #expect(CTFontGetSymbolicTraits(font.faces[2]).contains(.traitItalic))
    #expect(
      CTFontGetSymbolicTraits(font.faces[3])
        .contains([.traitBold, .traitItalic])
    )
  }

  @Test(arguments: ["no-bold-italic", "no-bold,no-italic"])
  func `synthetic bold italic is independent of the other styles`(
    _ setting: String
  ) {
    let config = Configuration.configured([
      ("font-family", "Monaco"), ("font-synthetic-style", "\(setting)"),
    ])
    let font = ResolvedFont(descriptor: config.fontDescriptor(scale: 2))
    let regular = font.faces[0]
    for traits: CTFontSymbolicTraits in [
      .traitBold, .traitItalic, [.traitBold, .traitItalic],
    ] {
      // Monaco is a single-face font; this test must exercise synthesis.
      #expect(
        CTFontCreateCopyWithSymbolicTraits(
          regular,
          CTFontGetSize(regular),
          nil,
          traits,
          traits
        ) == nil
      )
    }
    let combined = setting == "no-bold,no-italic"
    #expect(font.emboldened == [false, !combined, false, combined])
    #expect(CTFontGetMatrix(font.faces[2]).c == (combined ? 0 : 0.2))
    #expect(CTFontGetMatrix(font.faces[3]).c == (combined ? 0.2 : 0))
  }

  @Test(arguments: [
    ["bogus"], [""], ["-liga", "bogus"],
    [
      "calt=", "calt=-1", "calt=4294967296", "calt=on off", "calt=+2", "éabc",
      "\"cal\" 1", "calt junk", "cal", "calt==2",
    ],
  ])
  func `ignored font features do not activate shaping`(_ features: [String]) {
    var descriptor = FontDescriptor()
    descriptor.features = features
    #expect(!ResolvedFont(descriptor: descriptor).shapes)
    descriptor.features.append("calt")
    #expect(ResolvedFont(descriptor: descriptor).shapes)
  }
}
