import CoreText
import Metal
@testable import SwifttyCore
import Testing
import TestSupport

@Suite(.serialized)
struct RendererTests {
  @Test(.enabled(if: device != nil), arguments: Array(1 ... 32), [false, true])
  func `a new glyph renders immediately after earlier frames fill the atlas`(
    _ seedCount: Int,
    _ retainRow: Bool
  ) throws {
    let device = try #require(Self.device)
    let descriptor = FontDescriptor()
    let renderer = try MetalRenderer(
      device: device,
      fontManager: CoreTextFontManager(),
      font: descriptor,
      atlasSize: 64,
      atlasMaximumSize: 64,
    )
    let session = TerminalSession(columns: 32, rows: 2)
    let seed = String(
      String.UnicodeScalarView(
        (33 ..< 33 + seedCount).compactMap(Unicode.Scalar.init)
      )
    )
    session.feed(
      Array(("\u{1B}[?25l" + seed + (retainRow ? "\r\nP" : "")).utf8)
    )
    let width = Int(renderer.cellSize.width) * 32 + 16
    let height = Int(renderer.cellSize.height) * 2 + 16
    _ = render(renderer, session.snapshot(), width: width, height: height)
    session.feed(Array("\u{1B}[H\u{1B}[2KZ".utf8))
    let snapshot = session.snapshot()
    #expect(!snapshot.damage.contains(row: 1))
    let actual = render(renderer, snapshot, width: width, height: height)
    let fresh = try MetalRenderer(
      device: device,
      fontManager: CoreTextFontManager(),
      font: descriptor,
      atlasSize: 64,
      atlasMaximumSize: 64,
    )
    let expected = render(fresh, snapshot, width: width, height: height)
    let matches = actual.pixels == expected.pixels
    #expect(
      matches,
      Comment(rawValue: escapedTestText("seedCount=\(seedCount)"))
    )
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
    _ = render(
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
      let actual = render(renderer, snapshot, width: width, height: height)
      let expected = render(fresh, snapshot, width: width, height: height)
      #expect(actual.pixels == expected.pixels)
    }
  }

  @Test(
    .enabled(if: device != nil),
    arguments: [0.0, 0.25, 0.5, 1.0],
    [0.0, 0.25, 0.5, 1.0]
  )
  func `block cursor fades match GPU compositing over translucent backgrounds`(
    _ backgroundOpacity: Double,
    _ cursorOpacity: Double,
  ) throws {
    let renderer = try MetalRenderer(
      device: #require(Self.device),
      fontManager: CoreTextFontManager(),
      font: FontDescriptor()
    )
    renderer.options.backgroundOpacity = backgroundOpacity
    renderer.options.cursorOpacity = cursorOpacity
    renderer.options.cursorColor = 0xD04010
    let session = TerminalSession(columns: 2, rows: 1)
    session.feed(Array("\u{1B}]11;#204060\u{7}".utf8))
    let snapshot = session.snapshot()
    let width = Int(renderer.cellSize.width) * 2 + 16
    let height = Int(renderer.cellSize.height) + 16
    renderer.options.cursorStyle = .block
    let block = render(renderer, snapshot, width: width, height: height)
    renderer.options.cursorStyle = .bar
    let bar = render(renderer, snapshot, width: width, height: height)
    let pixel = ((8 + Int(renderer.cellSize.height) / 2) * width + 8) * 4
    // Cell colors and uniform alpha are quantized separately, so their
    // rounding may differ by one unit from the GPU's floating-point blend.
    for channel in 0 ..< 4 {
      #expect(
        abs(
          Int(block.pixels[pixel + channel]) - Int(bar.pixels[pixel + channel])
        ) <= 1
      )
    }
  }

  @Test(
    .enabled(if: device != nil),
    arguments: [0.25, 0.5, 0.9],
    [false, true]
  )
  func `translucent cell backgrounds match the padding opacity`(
    _ opacity: Double,
    _ postprocess: Bool
  ) throws {
    let renderer = try MetalRenderer(
      device: #require(Self.device),
      fontManager: CoreTextFontManager(),
      font: FontDescriptor()
    )
    if postprocess {
      try renderer.setPostProcessShader(
        """
        float4 postprocess(float2 position, texture2d<float> source, constant PostUniforms &u) {
            constexpr sampler s(coord::pixel);
            return source.sample(s, position);
        }
        """
      )
    }
    renderer.options.backgroundOpacity = opacity
    let session = TerminalSession(columns: 2, rows: 1)
    session.feed(Array("\u{1B}]11;#204060\u{7}\u{1B}[?25l \u{1B}[41m ".utf8))
    let cw = Int(renderer.cellSize.width)
    let ch = Int(renderer.cellSize.height)
    let frame = render(
      renderer,
      session.snapshot(),
      width: cw * 2 + 16,
      height: ch + 16
    )
    let cellIndex = ((8 + ch / 2) * frame.width + 8 + cw / 2) * 4
    let defaultCell = Array(frame.pixels[cellIndex ..< cellIndex + 4])
    let padding = Array(frame.pixels[0 ..< 4])
    #expect(defaultCell == padding)
    #expect(defaultCell[3] == UInt8(opacity * 255))
    let explicitIndex = cellIndex + cw * 4
    #expect(frame.pixels[explicitIndex + 3] == 255)
  }

  @Test(
    .enabled(if: device != nil),
    arguments: [
      (Double.nan, 1.0), (-1, 0), (2, 1), (.infinity, 1), (-.infinity, 0),
    ]
  )
  func `invalid background opacity matches its bounded rendering value`(
    _ sample: (Double, Double)
  ) throws {
    let renderer = try MetalRenderer(
      device: #require(Self.device),
      fontManager: CoreTextFontManager(),
      font: FontDescriptor()
    )
    let session = TerminalSession(columns: 2, rows: 1)
    session.feed(Array("\u{1B}]11;#204060\u{7}\u{1B}[?25l \u{1B}[41m ".utf8))
    let snapshot = session.snapshot()
    let width = Int(renderer.cellSize.width) * 2 + 16
    let height = Int(renderer.cellSize.height) + 16
    renderer.options.backgroundOpacity = sample.0
    let actual = render(renderer, snapshot, width: width, height: height)
    renderer.options.backgroundOpacity = sample.1
    let expected = render(renderer, snapshot, width: width, height: height)
    #expect(actual.pixels == expected.pixels)
  }

  @Test
  func `shaping cache bounds retained runs while preserving glyph output`() {
    let font = ResolvedFont(descriptor: FontDescriptor())
    let shaper = Shaper(memoryLimit: 1024)
    for value: UInt32 in 65 ... 126 {
      let scalars = Array(repeating: value, count: 8)
      let expected = Shaper().shape(scalars, style: [], font: font)
      let actual = shaper.shape(scalars, style: [], font: font)
      #expect(actual.map(\.glyph) == expected.map(\.glyph))
      #expect(actual.map(\.cell) == expected.map(\.cell))
      #expect(shaper.cachedMemoryCost > 0 && shaper.cachedMemoryCost <= 1024)
      let cost = shaper.cachedMemoryCost
      _ = shaper.shape(scalars, style: [], font: font)
      #expect(shaper.cachedMemoryCost == cost)
    }
  }

  @Test
  func `oversized shaping storage renders without evicting cached runs`() {
    let font = ResolvedFont(descriptor: FontDescriptor())
    let shaper = Shaper(memoryLimit: 1024)
    let first = shaper.shape([65], style: [], font: font)
    let cost = shaper.cachedMemoryCost
    let large = shaper.shape(
      Array(repeating: 88, count: 1024),
      style: [],
      font: font
    )
    #expect(large.count == 1024 && large.last?.cell == 1023)
    #expect(shaper.cachedMemoryCost == cost)
    let decomposed = shaper.shape(
      Array(repeating: 0x0E33, count: 32),
      style: [],
      font: font
    )
    #expect(decomposed.count > 32)
    #expect(shaper.cachedMemoryCost == cost)
    var spareCapacity: [UInt32] = [66]
    spareCapacity.reserveCapacity(1024)
    #expect(shaper.shape(spareCapacity, style: [], font: font).count == 1)
    #expect(shaper.cachedMemoryCost == cost)
    #expect(
      shaper.shape([65], style: [], font: font).map(\.glyph)
        == first.map(\.glyph)
    )
    #expect(shaper.cachedMemoryCost == cost)
  }

  @Test(.enabled(if: device != nil))
  func `uncached positioned glyph keys still render their pixels`() throws {
    let atlas = try GlyphAtlas(
      device: #require(Self.device),
      metadataLimit: 128
    )
    let font = ResolvedFont(descriptor: FontDescriptor())
    let glyphs = Shaper().shape([0x0E33], style: [], font: font)
    try #require(glyphs.count > 1)
    let entry = atlas.entry(glyphs: glyphs[...], style: [], font: font)
    #expect(entry.size.x > 0 && entry.size.y > 0)
    #expect(atlas.cachedMetadataCost == 0)
    atlas.prepareForFrame()
    #expect(!atlas.wasReset)
  }

  @Test(.enabled(if: device != nil))
  func
    `empty atlas entries respect metadata limits without altering live pixels`()
    throws
  {
    let atlas = try GlyphAtlas(
      device: #require(Self.device),
      metadataLimit: 256
    )
    let manager = CoreTextFontManager()
    let font = ResolvedFont(descriptor: FontDescriptor())
    let first = atlas.entry(
      scalar: "A",
      style: [],
      font: font,
      manager: manager
    )
    let region = MTLRegionMake2D(
      Int(first.position.x),
      Int(first.position.y),
      Int(first.size.x),
      Int(first.size.y)
    )
    func pixels() -> [UInt8] {
      var bytes = [UInt8](
        repeating: 0,
        count: Int(first.size.x) * Int(first.size.y) * 4
      )
      atlas.texture.getBytes(
        &bytes,
        bytesPerRow: Int(first.size.x) * 4,
        from: region,
        mipmapLevel: 0
      )
      return bytes
    }
    let expected = pixels()
    #expect(atlas.entry(cluster: [0x20], style: [], font: font).size == .zero)
    #expect(atlas.cachedMetadataCost <= 256)
    #expect(!atlas.wasReset && pixels() == expected)
    atlas.prepareForFrame()
    #expect(atlas.wasReset && atlas.cachedMetadataCost == 0)
    #expect(
      atlas.entry(scalar: "A", style: [], font: font, manager: manager).size
        == first.size
    )
  }

  @Test(.enabled(if: device != nil))
  func
    `oversized atlas keys are not retained or allowed to evict ordinary entries`()
    throws
  {
    let atlas = try GlyphAtlas(
      device: #require(Self.device),
      metadataLimit: 256
    )
    let manager = CoreTextFontManager()
    let font = ResolvedFont(descriptor: FontDescriptor())
    let first = atlas.entry(
      scalar: "A",
      style: [],
      font: font,
      manager: manager
    )
    let cost = atlas.cachedMetadataCost
    _ = atlas.entry(
      cluster: Array(repeating: 0xFE0F, count: 100),
      style: [],
      font: font
    )
    #expect(atlas.cachedMetadataCost == cost)
    atlas.prepareForFrame()
    #expect(!atlas.wasReset)
    let repeated = atlas.entry(
      scalar: "A",
      style: [],
      font: font,
      manager: manager
    )
    #expect(repeated.position == first.position && repeated.size == first.size)
  }

  @Test
  func `shaping preserves decomposed glyphs in a single cell`() {
    let font = ResolvedFont(descriptor: FontDescriptor())
    let shaped = Shaper().shape([0x0E33, 0x58], style: [], font: font)
    #expect(shaped.filter { $0.cell == 0 }.count == 2)
    #expect(shaped.filter { $0.cell == 1 }.count == 1)
  }

  @Test(
    .enabled(if: device != nil),
    arguments: [FontStyle(), .bold, .italic, [.bold, .italic]]
  )
  func `decomposed cell bitmaps match complete CoreText lines`(
    _ style: FontStyle
  ) throws {
    let font = ResolvedFont(descriptor: FontDescriptor())
    let glyphs = Shaper().shape([0x0E33, 0x58], style: style, font: font)
      .filter { $0.cell == 0 }
    #expect(glyphs.count == 2)
    let atlas = try GlyphAtlas(device: #require(Self.device))
    let actual = atlas.entry(glyphs: glyphs[...], style: style, font: font)
    let expected = atlas.entry(cluster: [0x0E33], style: style, font: font)
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

  @Test(.enabled(if: device != nil), arguments: [false, true])
  func `atlas capacity preserves existing pixels until the next frame`(
    _ grow: Bool
  ) throws {
    let atlas = try GlyphAtlas(
      device: #require(Self.device),
      size: 64,
      maximumSize: grow ? 256 : 64
    )
    let manager = CoreTextFontManager()
    let font = ResolvedFont(descriptor: FontDescriptor())
    let first = atlas.entry(
      scalar: "A",
      style: [],
      font: font,
      manager: manager
    )
    #expect(first.size.x > 0 && first.size.y > 0)
    func pixels() -> [UInt8] {
      let width = Int(first.size.x)
      let height = Int(first.size.y)
      var bytes = [UInt8](repeating: 0, count: width * height * 4)
      atlas.texture.getBytes(
        &bytes,
        bytesPerRow: width * 4,
        from: MTLRegionMake2D(
          Int(first.position.x),
          Int(first.position.y),
          width,
          height
        ),
        mipmapLevel: 0,
      )
      return bytes
    }
    let expected = pixels()
    var full = false
    for value in 33 ... 126 {
      let entry = try atlas.entry(
        scalar: #require(Unicode.Scalar(value)),
        style: [],
        font: font,
        manager: manager
      )
      full = full || entry.size == .zero
    }
    #expect(pixels() == expected)
    #expect(!atlas.wasReset)
    #expect((atlas.size > 64) == grow)
    if !grow {
      #expect(full)
      atlas.prepareForFrame()
      #expect(atlas.wasReset)
      let fresh = atlas.entry(
        scalar: "A",
        style: [],
        font: font,
        manager: manager
      )
      #expect(fresh.position == .zero && fresh.size == first.size)
    }
  }

  @Test(.enabled(if: device != nil), arguments: [false, true])
  func `large styled frames preserve glyphs packed before the atlas fills`(
    _ incremental: Bool
  ) throws {
    let renderer = try MetalRenderer(
      device: #require(Self.device),
      fontManager: CoreTextFontManager(),
      font: FontDescriptor(size: 120)
    )
    let cellWidth = Int(renderer.cellSize.width)
    let cellHeight = Int(renderer.cellSize.height)
    func firstCell(_ snapshot: RenderSnapshot) throws -> [UInt8] {
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm,
        width: cellWidth * snapshot.columns + 16,
        height: cellHeight * snapshot.rowCount + 16,
        mipmapped: false,
      )
      descriptor.storageMode = .shared
      descriptor.usage = [.renderTarget, .shaderRead]
      let texture = try #require(
        renderer.device.makeTexture(descriptor: descriptor)
      )
      let command = renderer.render(snapshot, to: texture)
      command.waitUntilCompleted()
      try #require(
        command.status == .completed,
        Comment(
          rawValue: escapedTestText("\(String(describing: command.error))")
        )
      )
      var pixels = [UInt8](repeating: 0, count: cellWidth * cellHeight * 4)
      texture.getBytes(
        &pixels,
        bytesPerRow: cellWidth * 4,
        from: MTLRegionMake2D(8, 8, cellWidth, cellHeight),
        mipmapLevel: 0
      )
      return pixels
    }
    let single = TerminalSession(columns: 1, rows: 1)
    single.feed(Array("\u{1B}[?25lA".utf8))
    let expected = try firstCell(single.snapshot())
    let session = TerminalSession(columns: 32, rows: 13)
    session.feed(Array("\u{1B}[?25lA".utf8))
    if incremental {
      #expect(try firstCell(session.snapshot()) == expected)
      session.feed(Array("\u{1B}[2;1H".utf8))
    }
    let alphabet = String(
      String.UnicodeScalarView((33 ... 126).compactMap(Unicode.Scalar.init))
    )
    let styles = ["0", "1", "3", "1;3"].map { "\u{1B}[0;\($0)m\(alphabet)" }
      .joined()
    session.feed(Array(styles.utf8))
    let snapshot = session.snapshot()
    if incremental {
      #expect(!snapshot.damage.isFull && !snapshot.rows[0].isDirty)
    }
    #expect(try firstCell(snapshot) == expected)
  }

  @Test
  func `search row masks preserve overlapping and clipped spans`() {
    let matches = [
      HighlightSpan(startRow: -2, startColumn: 3, endRow: 0, endColumn: 1),
      HighlightSpan(startRow: -1, startColumn: 7, endRow: 0, endColumn: 4),
      HighlightSpan(startRow: 0, startColumn: 4, endRow: 1, endColumn: 2),
      HighlightSpan(startRow: 0, startColumn: 7, endRow: 1, endColumn: 5),
      HighlightSpan(startRow: 1, startColumn: 6, endRow: 1, endColumn: 7),
      HighlightSpan(startRow: 3, startColumn: 0, endRow: 4, endColumn: 1),
    ]
    for columns in [1, 8] {
      for row in -3 ... 5 {
        let mask = MetalRenderer.searchHighlights(
          matches,
          row: row,
          columns: columns
        )
        for column in 0 ..< columns {
          let expected = matches.contains {
            $0.contains(row: row, column: column)
          }
          #expect((!mask.isEmpty && mask[column]) == expected)
        }
      }
    }
    let separated = [1 ... 2, 4 ... 5, 7 ... 7]
      .map {
        HighlightSpan(
          startRow: 0,
          startColumn: $0.lowerBound,
          endRow: 0,
          endColumn: $0.upperBound
        )
      }
    #expect(
      MetalRenderer.searchHighlights(separated, row: 0, columns: 8) == [
        false, true, true, false, true, true, false, true,
      ]
    )
  }

  @Test(
    .enabled(if: device != nil),
    arguments: [
      "adjust-cell-width = 1e308", "adjust-cell-height = 1e308",
      "adjust-cell-height = 100000",
    ]
  )
  func `oversized cells cannot overflow glyph atlas coordinates`(
    _ setting: String
  ) throws {
    let configuration = Configuration.parse(setting)
    #expect(configuration.diagnostics.isEmpty)
    let manager = CoreTextFontManager()
    let font = manager.resolve(configuration.fontDescriptor(scale: 2))
    let atlas = try GlyphAtlas(device: #require(Self.device))
    let box = atlas.entry(scalar: "─", style: [], font: font, manager: manager)
    #expect(box.size == .zero)
    let letter = atlas.entry(
      scalar: "A",
      style: [],
      font: font,
      manager: manager
    )
    #expect((letter.size.x > 0) == setting.contains("width"))
  }

  @Test(.enabled(if: device != nil))
  func `grid sizing clamps before integer conversion`() throws {
    let renderer = try MetalRenderer(
      device: #require(Self.device),
      fontManager: CoreTextFontManager(),
      font: FontDescriptor()
    )
    let normal = renderer.gridSize(for: CGSize(width: 800, height: 600))
    #expect(normal.columns == Int((800 - 16) / renderer.cellSize.width))
    #expect(normal.rows == Int((600 - 16) / renderer.cellSize.height))
    let enormous = renderer.gridSize(
      for: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .infinity)
    )
    #expect(
      enormous.columns == Int(UInt16.max) && enormous.rows == Int(UInt16.max)
    )
    let invalid = renderer.gridSize(
      for: CGSize(width: .nan, height: -.infinity)
    )
    #expect(invalid.columns == 1 && invalid.rows == 1)
    renderer.options.paddingX = 1e308
    renderer.options.paddingY = 1e308
    let padded = renderer.gridSize(for: CGSize(width: 800, height: 600))
    #expect(padded.columns == 1 && padded.rows == 1)
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
    descriptor.fallbackFamilies = ["SF Pro"]
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
    descriptor.fallbackFamilies = ["SF Pro"]
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
    descriptor.fallbackFamilies = ["SF Pro"]
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
    // resolve it through the configured SF Pro fallback.
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
    let config = Configuration.parse("font-feature = \(feature)")
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
    let config = Configuration.parse(
      "font-family = SF Pro\nfont-feature = liga\nfont-feature = \(feature)"
    )
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

  @Test(arguments: ["\"ss01\", \"cv01\"", "'ss01', 'cv01'", "\"ss01, cv01\""])
  func `quoted feature lists preserve each tag`(_ list: String) throws {
    let config = Configuration.parse(
      "font-family = SF Pro\nfont-feature = \(list)"
    )
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
  func `disabling synthesis preserves native font styles`() {
    let config = Configuration.parse(
      "font-family = Menlo\nfont-synthetic-style = false"
    )
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
    let config = Configuration.parse(
      "font-family = Monaco\nfont-synthetic-style = \(setting)"
    )
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

  static let device = MTLCreateSystemDefaultDevice()

  @Test(.enabled(if: device != nil), arguments: [false, true])
  func `IME moves with the live cursor during its hidden phase`(
    _ terminalCursorVisible: Bool
  ) throws {
    let manager = CoreTextFontManager()
    let renderer = try MetalRenderer(
      device: #require(Self.device),
      fontManager: manager,
      font: FontDescriptor()
    )
    let fresh = try MetalRenderer(
      device: #require(Self.device),
      fontManager: manager,
      font: FontDescriptor()
    )
    let session = TerminalSession(columns: 8, rows: 3)
    if !terminalCursorVisible { session.feed(Array("\u{1B}[?25l".utf8)) }
    renderer.options.preedit = Array("abc".unicodeScalars)
    renderer.options.preeditSelection = NSRange(location: 1, length: 0)
    renderer.options.cursorVisible = false
    fresh.options = renderer.options
    let width = Int(renderer.cellSize.width) * 8 + 16
    let height = Int(renderer.cellSize.height) * 3 + 16
    _ = render(renderer, session.snapshot(), width: width, height: height)
    session.feed(Array("\u{1B}[2;3H".utf8))
    let moved = session.snapshot()
    #expect(moved.damage.isEmpty)
    let expected = render(fresh, moved, width: width, height: height)
    #expect(
      render(renderer, moved, width: width, height: height).pixels
        == expected.pixels
    )
  }

  @Test(.enabled(if: device != nil), arguments: [false, true])
  func `IME composition stays off history and returns with the live viewport`(
    _ caret: Bool
  ) throws {
    let renderer = try MetalRenderer(
      device: #require(Self.device),
      fontManager: CoreTextFontManager(),
      font: FontDescriptor()
    )
    let session = TerminalSession(columns: 12, rows: 2)
    session.feed(Array("old0\r\nold1\r\nold2\r\ncurrent".utf8))
    let width = Int(renderer.cellSize.width) * 12 + 16
    let height = Int(renderer.cellSize.height) * 2 + 16
    renderer.options.preedit = Array("XYZ".unicodeScalars)
    renderer.options.preeditSelection =
      caret ? NSRange(location: 1, length: 0) : nil
    let live = render(
      renderer,
      session.snapshot(),
      width: width,
      height: height
    )
    session.scrollViewport(by: 1)
    let history = session.snapshot()
    #expect(history.viewportOffset == 1)
    renderer.options.preedit = []
    renderer.options.preeditSelection = nil
    let expected = render(renderer, history, width: width, height: height)
    renderer.options.preedit = Array("XYZ".unicodeScalars)
    renderer.options.preeditSelection =
      caret ? NSRange(location: 1, length: 0) : nil
    #expect(
      render(renderer, history, width: width, height: height).pixels
        == expected.pixels
    )
    session.scrollViewport(by: -1)
    #expect(
      render(renderer, session.snapshot(), width: width, height: height).pixels
        == live.pixels
    )
  }

  @Test(
    .enabled(if: device != nil),
    arguments: [(0, 0), (1, 1), (3, 1), (6, 3), (7, 4)]
  )
  func `IME caret follows UTF16 selection without changing terminal state`(
    _ offset: Int,
    _ column: Int
  ) throws {
    let renderer = try MetalRenderer(
      device: #require(Self.device),
      fontManager: CoreTextFontManager(),
      font: FontDescriptor()
    )
    renderer.options.cursorStyle = .bar
    let expectedSession = TerminalSession(columns: 12, rows: 2)
    expectedSession.feed(Array("\u{1B}[4mA👩‍💻Z\u{1B}[1;\(column + 1)H".utf8))
    let blank = TerminalSession(columns: 12, rows: 2)
    let width = Int(renderer.cellSize.width) * 12 + 16
    let height = Int(renderer.cellSize.height) * 2 + 16
    let expected = render(
      renderer,
      expectedSession.snapshot(),
      width: width,
      height: height
    )
    renderer.options.preedit = Array("A👩‍💻Z".unicodeScalars)
    renderer.options.preeditSelection = NSRange(location: offset, length: 0)
    renderer.options.cursorVisible = false
    // Composition caret stays steady during terminal cursor blink.
    renderer.options.cursorOpacity = 0
    let actual = render(
      renderer,
      blank.snapshot(),
      width: width,
      height: height
    )
    #expect(actual.pixels == expected.pixels)
    #expect(blank.withState { $0.cursor.x } == 0)
  }

  @Test(.enabled(if: device != nil))
  func `IME selection highlights complete graphemes`() throws {
    let renderer = try MetalRenderer(
      device: #require(Self.device),
      fontManager: CoreTextFontManager(),
      font: FontDescriptor()
    )
    let expectedSession = TerminalSession(columns: 12, rows: 2)
    expectedSession.feed(
      Array("\u{1B}[?25l\u{1B}[4mA\u{1B}[7m👩‍💻\u{1B}[27mZ".utf8)
    )
    let blank = TerminalSession(columns: 12, rows: 2)
    blank.feed(Array("\u{1B}[?25l".utf8))
    let width = Int(renderer.cellSize.width) * 12 + 16
    let height = Int(renderer.cellSize.height) * 2 + 16
    let expected = render(
      renderer,
      expectedSession.snapshot(),
      width: width,
      height: height
    )
    renderer.options.preedit = Array("A👩‍💻Z".unicodeScalars)
    renderer.options.preeditSelection = NSRange(location: 3, length: 1)
    let actual = render(
      renderer,
      blank.snapshot(),
      width: width,
      height: height
    )
    #expect(actual.pixels == expected.pixels)
  }

  @Test(.enabled(if: device != nil))
  func `IME caret at the row edge follows focus and selection-only updates`()
    throws
  {
    let renderer = try MetalRenderer(
      device: #require(Self.device),
      fontManager: CoreTextFontManager(),
      font: FontDescriptor()
    )
    let blank = TerminalSession(columns: 2, rows: 2)
    var snapshot = blank.snapshot()
    snapshot.damage = .none
    renderer.options.preedit = Array("AB".unicodeScalars)
    let width = Int(renderer.cellSize.width) * 2 + 16
    let height = Int(renderer.cellSize.height) * 2 + 16
    let baseline = render(renderer, snapshot, width: width, height: height)
    renderer.options.preeditSelection = NSRange(location: 2, length: 0)
    let actual = render(renderer, snapshot, width: width, height: height)
    let edge = 8 + Int(renderer.cellSize.width) * 2 - 1
    let y = 8 + Int(renderer.cellSize.height) / 2
    let color = snapshot.palette.cursor
    let pixel = actual.pixel(edge, y)
    #expect(
      pixel.r == UInt8(color >> 16 & 0xFF)
        && pixel.g == UInt8(color >> 8 & 0xFF) && pixel.b == UInt8(color & 0xFF)
    )
    #expect(actual.pixels != baseline.pixels)
    renderer.options.isFocused = false
    #expect(
      render(renderer, snapshot, width: width, height: height).pixels
        == baseline.pixels
    )
    renderer.options.isFocused = true
    renderer.options.preeditSelection = NSRange(location: 0, length: 0)
    #expect(
      render(renderer, snapshot, width: width, height: height).pixels
        != actual.pixels
    )
    renderer.options.preeditSelection = nil
    #expect(
      render(renderer, snapshot, width: width, height: height).pixels
        == baseline.pixels
    )
  }

  @Test(
    .enabled(if: device != nil),
    arguments: ["e\u{301}X", "👩‍💻X", "🇻🇳X", "❤\u{FE0F}X", "⌚\u{FE0E}X", "가X"]
  )
  func `IME preedit renders complete graphemes in terminal columns`(
    _ text: String
  ) throws {
    let renderer = try MetalRenderer(
      device: #require(Self.device),
      fontManager: CoreTextFontManager(),
      font: FontDescriptor()
    )
    let composed = TerminalSession(columns: 12, rows: 2)
    composed.feed(Array("\u{1B}[?25l\u{1B}[4m\(text)".utf8))
    let blank = TerminalSession(columns: 12, rows: 2)
    blank.feed(Array("\u{1B}[?25l".utf8))
    let width = Int(renderer.cellSize.width) * 12 + 16
    let height = Int(renderer.cellSize.height) * 2 + 16
    let expected = render(
      renderer,
      composed.snapshot(),
      width: width,
      height: height
    )
    renderer.options.preedit = Array(text.unicodeScalars)
    let actual = render(
      renderer,
      blank.snapshot(),
      width: width,
      height: height
    )
    #expect(actual.pixels == expected.pixels)
  }

  @Test(
    .enabled(if: device != nil),
    arguments: [("e\u{301}X", 4, "e\u{301}"), ("👩‍💻X", 3, "👩‍💻"), ("👩‍💻X", 4, "")]
  )
  func `IME preedit clips whole graphemes at the right edge`(
    _ text: String,
    _ column: Int,
    _ visible: String
  ) throws {
    let renderer = try MetalRenderer(
      device: #require(Self.device),
      fontManager: CoreTextFontManager(),
      font: FontDescriptor()
    )
    let composed = TerminalSession(columns: 5, rows: 2)
    let position = "\u{1B}[?25l\u{1B}[1;\(column + 1)H"
    composed.feed(Array("\(position)\u{1B}[4m\(visible)".utf8))
    let blank = TerminalSession(columns: 5, rows: 2)
    blank.feed(Array(position.utf8))
    let width = Int(renderer.cellSize.width) * 5 + 16
    let height = Int(renderer.cellSize.height) * 2 + 16
    let expected = render(
      renderer,
      composed.snapshot(),
      width: width,
      height: height
    )
    renderer.options.preedit = Array(text.unicodeScalars)
    let actual = render(
      renderer,
      blank.snapshot(),
      width: width,
      height: height
    )
    #expect(actual.pixels == expected.pixels)
  }

  @Test(
    .enabled(if: device != nil),
    arguments: [
      ("中Y", 1, "x"), ("👩‍💻Y", 1, "e\u{301}"), ("Y中Z", 1, "x"), ("Y中Z", 0, "👩‍💻"),
    ]
  )
  func `IME preedit covers intersecting wide glyphs and restores original text`(
    _ base: String,
    _ column: Int,
    _ text: String
  ) throws {
    let renderer = try MetalRenderer(
      device: #require(Self.device),
      fontManager: CoreTextFontManager(),
      font: FontDescriptor()
    )
    let position = "\u{1B}[1;\(column + 1)H"
    let original = TerminalSession(columns: 8, rows: 2)
    original.feed(Array("\u{1B}[?25l\(base)\(position)".utf8))
    var snapshot = original.snapshot()
    let composed = TerminalSession(columns: 8, rows: 2)
    composed.feed(Array("\u{1B}[?25l\(base)\(position)\u{1B}[4m\(text)".utf8))
    let width = Int(renderer.cellSize.width) * 8 + 16
    let height = Int(renderer.cellSize.height) * 2 + 16
    let expected = render(
      renderer,
      composed.snapshot(),
      width: width,
      height: height
    )
    let baseline = render(renderer, snapshot, width: width, height: height)
    // Only the composition changes between these frames.
    snapshot.damage = .none
    renderer.options.preedit = Array(text.unicodeScalars)
    let actual = render(renderer, snapshot, width: width, height: height)
    #expect(actual.pixels == expected.pixels)
    renderer.options.preedit = []
    let restored = render(renderer, snapshot, width: width, height: height)
    #expect(restored.pixels == baseline.pixels)
  }

  @Test(.enabled(if: device != nil))
  func `IME preedit preserves styles outside its columns`() throws {
    let renderer = try MetalRenderer(
      device: #require(Self.device),
      fontManager: CoreTextFontManager(),
      font: FontDescriptor()
    )
    let original = TerminalSession(columns: 8, rows: 2)
    original.feed(
      Array("\u{1B}[?25l\u{1B}[31;44;4m中\u{1B}[0mY\u{1B}[1;2H".utf8)
    )
    let composed = TerminalSession(columns: 8, rows: 2)
    // The uncovered first cell keeps its background and decoration,
    // while the composition replaces only the second cell's style.
    composed.feed(
      Array("\u{1B}[?25l\u{1B}[31;44;4m \u{1B}[0;4mx\u{1B}[0mY".utf8)
    )
    let width = Int(renderer.cellSize.width) * 8 + 16
    let height = Int(renderer.cellSize.height) * 2 + 16
    let expected = render(
      renderer,
      composed.snapshot(),
      width: width,
      height: height
    )
    renderer.options.preedit = ["x"]
    let actual = render(
      renderer,
      original.snapshot(),
      width: width,
      height: height
    )
    #expect(actual.pixels == expected.pixels)
  }

  struct Frame {
    let width: Int, height: Int
    let pixels: [UInt8]  // BGRA

    func pixel(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
      let i = (y * width + x) * 4
      return (pixels[i + 2], pixels[i + 1], pixels[i])
    }

    /// Pixels in a cell that differ from `background`.
    func inkCount(
      column: Int,
      row: Int,
      renderer: MetalRenderer,
      background: UInt32
    ) -> Int {
      let cw = Int(renderer.cellSize.width)
      let ch = Int(renderer.cellSize.height)
      let pad = Int(renderer.padding)
      var count = 0
      for y in pad + row * ch ..< pad + (row + 1) * ch {
        for x in pad + column * cw ..< pad + (column + 1) * cw {
          let p = pixel(x, y)
          if UInt32(p.r) << 16 | UInt32(p.g) << 8 | UInt32(p.b) != background {
            count += 1
          }
        }
      }
      return count
    }
  }

  func render(
    _ renderer: MetalRenderer,
    _ snapshot: RenderSnapshot,
    width: Int,
    height: Int
  ) -> Frame {
    let d = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm,
      width: width,
      height: height,
      mipmapped: false
    )
    d.usage = [.renderTarget, .shaderRead]
    d.storageMode = .shared
    let texture = renderer.device.makeTexture(descriptor: d)!
    let command = renderer.render(snapshot, to: texture)
    command.waitUntilCompleted()
    #expect(
      command.status == .completed,
      Comment(rawValue: escapedTestText("\(String(describing: command.error))"))
    )
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    texture.getBytes(
      &pixels,
      bytesPerRow: width * 4,
      from: MTLRegionMake2D(0, 0, width, height),
      mipmapLevel: 0
    )
    return Frame(width: width, height: height, pixels: pixels)
  }

  @Test(.enabled(if: device != nil))
  func `draws text colors and cursor`() throws {
    let renderer = try MetalRenderer(
      device: #require(Self.device),
      fontManager: CoreTextFontManager(),
      font: FontDescriptor(size: 13, scale: 2),
    )
    let session = TerminalSession(columns: 10, rows: 3)
    session.feed(Array("X \u{1B}[41m \u{1B}[0m中😀e\u{301}".utf8))
    let w = Int(renderer.cellSize.width) * 10 + 16
    let h = Int(renderer.cellSize.height) * 3 + 16
    let frame = render(renderer, session.snapshot(), width: w, height: h)
    let bg = Palette.standard.background

    #expect(
      frame.inkCount(column: 0, row: 0, renderer: renderer, background: bg) > 10
    )  // "X"
    #expect(
      frame.inkCount(column: 1, row: 0, renderer: renderer, background: bg) == 0
    )  // space
    // Red background cell.
    let cw = Int(renderer.cellSize.width)
    let ch = Int(renderer.cellSize.height)
    let red = frame.pixel(8 + 2 * cw + cw / 2, 8 + ch / 2)
    #expect(red.r > 150 && red.g < 120)
    #expect(
      frame.inkCount(column: 3, row: 0, renderer: renderer, background: bg) > 10
    )  // 中
    #expect(
      frame.inkCount(column: 5, row: 0, renderer: renderer, background: bg) > 10
    )  // 😀
    #expect(
      frame.inkCount(column: 7, row: 0, renderer: renderer, background: bg) > 10
    )  // é cluster
    // Block cursor at column 8.
    let cursor = frame.pixel(8 + 8 * cw + cw / 2, 8 + ch / 2)
    #expect(cursor.r > 200 && cursor.g > 200 && cursor.b > 200)
  }

  @Test(.enabled(if: device != nil), arguments: [false, true])
  func `switching snapshot sources rebuilds clean rows`(
    _ equalSequence: Bool
  ) throws {
    let device = try #require(Self.device)
    let renderer = try MetalRenderer(
      device: device,
      fontManager: CoreTextFontManager(),
      font: FontDescriptor()
    )
    let first = TerminalSession(columns: 8, rows: 2)
    let second = TerminalSession(columns: 8, rows: 2)
    first.feed(Array("\u{1B}[?25lAAAA".utf8))
    second.feed(Array("\u{1B}[?25lBBBB".utf8))
    _ = second.snapshot()  // Another consumer already drained its damage.
    var prior = first.snapshot()
    if equalSequence { prior = first.snapshot() }
    let width = Int(renderer.cellSize.width) * 8 + 16
    let height = Int(renderer.cellSize.height) * 2 + 16
    _ = render(renderer, prior, width: width, height: height)
    let next = second.snapshot()
    #expect(next.damage.isEmpty)
    #expect(next.sequence == prior.sequence + (equalSequence ? 0 : 1))
    let actual = render(renderer, next, width: width, height: height)
    let fresh = try MetalRenderer(
      device: device,
      fontManager: CoreTextFontManager(),
      font: FontDescriptor()
    )
    let expected = render(fresh, next, width: width, height: height)
    let framesMatch = actual.pixels == expected.pixels
    #expect(framesMatch)
  }

  @Test(.enabled(if: device != nil))
  func `incremental frames match full redraw`() throws {
    let manager = CoreTextFontManager()
    let incremental = try MetalRenderer(
      device: #require(Self.device),
      fontManager: manager,
      font: FontDescriptor()
    )
    let session = TerminalSession(columns: 20, rows: 5)
    let w = Int(incremental.cellSize.width) * 20 + 16
    let h = Int(incremental.cellSize.height) * 5 + 16
    var last: Frame?
    for i in 0 ..< 8 {
      session.feed(
        Array("\u{1B}[\(i % 5 + 1);\(i + 1)H\u{1B}[3\(i % 7)mrow\(i)".utf8)
      )
      last = render(incremental, session.snapshot(), width: w, height: h)
    }
    // A fresh renderer drawing the final state from scratch must agree.
    let fresh = try MetalRenderer(
      device: #require(Self.device),
      fontManager: manager,
      font: FontDescriptor()
    )
    session.withState { _ in }
    let reference = render(fresh, session.snapshot(), width: w, height: h)
    let final = try #require(last)
    #expect(final.pixels == reference.pixels)
  }

  @Test(
    .enabled(if: device != nil),
    arguments: ["fn main() -> x != y\r\n\u{1B}[1mbold\u{1B}[0m ok", "ำX"]
      .map(TestFixture.init)
  )
  func `shaped text matches unshaped text`(_ text: TestFixture<String>) throws {
    let text = text.value
    let device = try #require(Self.device)
    let session = TerminalSession(columns: 24, rows: 2)
    session.feed(Array(text.utf8))
    var shapedFont = FontDescriptor()
    shapedFont.features = ["calt", "-liga"]
    let plain = try MetalRenderer(
      device: device,
      fontManager: CoreTextFontManager(),
      font: FontDescriptor()
    )
    let shaped = try MetalRenderer(
      device: device,
      fontManager: CoreTextFontManager(),
      font: shapedFont
    )
    #expect(!plain.font.shapes && shaped.font.shapes)
    let w = Int(plain.cellSize.width) * 24 + 16
    let h = Int(plain.cellSize.height) * 2 + 16
    let a = render(plain, session.snapshot(), width: w, height: h)
    let b = render(shaped, session.snapshot(), width: w, height: h)
    // Menlo has no ligatures, so shaping must reproduce the per-cell glyphs.
    let differing = zip(a.pixels, b.pixels)
      .filter { abs(Int($0) - Int($1)) > 8 }.count
    #expect(differing < a.pixels.count / 1000)
  }
}
