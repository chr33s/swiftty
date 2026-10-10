import CoreGraphics
import CoreText
import Foundation
@testable import SwifttyCore
import Testing

@Suite(.serialized)
struct FontManagerTests {
  @Test(arguments: ["Menlo", "Helvetica", "Apple Color Emoji"])
  func `scalar glyphs match CoreText at UTF16 boundaries`(
    _ family: String
  ) throws {
    let font = ResolvedFont(descriptor: FontDescriptor(family: family))
    let values: [UInt32] = [
      0, 0x1B, 0x20, 0x41, 0xE9, 0x301, 0xD7FF, 0xE000, 0xFFFD, 0xFFFF, 0x10000,
      0x10001, 0x1F600, 0x20000, 0x10FFFF,
    ]
    for face in font.faces + [font.emoji] {
      for value in values {
        let scalar = try #require(Unicode.Scalar(value))
        let utf16 = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        let mapped = CTFontGetGlyphsForCharacters(
          face,
          utf16,
          &glyphs,
          utf16.count
        )
        let expected = mapped && glyphs[0] != 0 ? glyphs[0] : nil
        #expect(CoreTextFontManager.glyph(scalar, in: face) == expected)
      }
    }
  }

  @Test(arguments: [Double.nan, .infinity, -.infinity])
  func `nonfinite variation values leave valid axes and font metrics intact`(
    _ value: Double
  ) throws {
    var expectedDescriptor = FontDescriptor(family: "Skia")
    expectedDescriptor.variations = ["wght": 1.3]
    let manager = CoreTextFontManager()
    let expected = manager.resolve(expectedDescriptor)
    var descriptor = expectedDescriptor
    descriptor.variations["wdth"] = value
    let actual = ResolvedFont(descriptor: descriptor)
    #expect(actual.descriptor == expectedDescriptor)
    #expect(manager.resolve(descriptor) === expected)
    #expect(actual.cellWidth == expected.cellWidth)
    #expect(actual.cellHeight == expected.cellHeight)
    #expect(actual.ascent == expected.ascent)
    #expect(actual.descent == expected.descent)
    #expect(actual.underlinePosition == expected.underlinePosition)
    #expect(actual.underlineThickness == expected.underlineThickness)
    for face in actual.faces {
      let variations = try #require(
        CTFontCopyVariation(face) as? [NSNumber: Double]
      )
      let finite = variations.values.allSatisfy(\.isFinite)
      #expect(finite)
      #expect(variations[NSNumber(value: UInt32(0x7767_6874))] == 1.3)
    }
  }

  @Test(arguments: ["Menlo", "Helvetica", "Times New Roman"])
  func `finite extreme font sizes keep all exposed metrics finite`(
    _ family: String
  ) {
    let descriptor = FontDescriptor(
      family: family,
      size: .greatestFiniteMagnitude,
      scale: 1
    )
    let font = CoreTextFontManager().resolve(descriptor)
    #expect(font.descriptor == descriptor)
    #expect(font.cellWidth.isFinite && font.cellHeight.isFinite)
    #expect(font.ascent.isFinite && font.descent.isFinite)
    #expect(font.underlinePosition.isFinite && font.underlineThickness.isFinite)
  }

  @Test
  func
    `font dimension normalization preserves valid values and handles underflow`()
  {
    let manager = CoreTextFontManager()
    let valid = FontDescriptor(size: 20, scale: 3)
    let font = manager.resolve(valid)
    #expect(font.descriptor == valid)
    #expect(manager.resolve(valid) === font)
    let partial = manager.resolve(FontDescriptor(size: .nan, scale: 3))
    #expect(partial === manager.resolve(FontDescriptor(size: 13, scale: 3)))
    let tiny = FontDescriptor(
      size: .leastNonzeroMagnitude,
      scale: .leastNonzeroMagnitude
    )
    #expect(manager.resolve(tiny) === manager.resolve(FontDescriptor()))
    let direct = ResolvedFont(
      descriptor: FontDescriptor(size: .nan, scale: .infinity)
    )
    #expect(direct.descriptor == FontDescriptor())
    #expect(direct.cellWidth.isFinite && direct.cellHeight.isFinite)
  }

  @Test(arguments: [
    CGFloat.nan, .infinity, -.infinity, 0, -1, .greatestFiniteMagnitude,
  ])
  func `invalid font sizes and scales resolve to reusable finite defaults`(
    _ value: CGFloat
  ) {
    let manager = CoreTextFontManager()
    let baseline = manager.resolve(FontDescriptor())
    for field in 0 ..< 2 {
      var descriptor = FontDescriptor()
      if field == 0 {
        descriptor.size = value
      } else {
        descriptor.scale = value
      }
      let font = manager.resolve(descriptor)
      #expect(
        font.cellWidth == baseline.cellWidth
          && font.cellHeight == baseline.cellHeight
      )
      #expect(font.ascent.isFinite && font.descent.isFinite)
      #expect(font === baseline)
    }
  }

  @Test
  func `invalid width adjustments preserve valid height adjustments`() {
    let manager = CoreTextFontManager()
    var descriptor = FontDescriptor()
    descriptor.cellHeightAdjust = 0.2
    descriptor.cellHeightOffset = 3
    let expected = manager.resolve(descriptor)
    descriptor.cellWidthAdjust = .nan
    descriptor.cellWidthOffset = .infinity
    let actual = manager.resolve(descriptor)
    #expect(actual.cellWidth == expected.cellWidth)
    #expect(actual.cellHeight == expected.cellHeight)
    #expect(actual.ascent == expected.ascent)
  }

  @Test(arguments: [CGFloat.nan, .infinity, -.infinity])
  func `invalid cell adjustments preserve finite font metrics`(_ value: CGFloat)
  {
    let manager = CoreTextFontManager()
    let baseline = manager.resolve(FontDescriptor())
    for field in 0 ..< 4 {
      var descriptor = FontDescriptor()
      switch field {
      case 0: descriptor.cellWidthAdjust = value
      case 1: descriptor.cellHeightAdjust = value
      case 2: descriptor.cellWidthOffset = value
      default: descriptor.cellHeightOffset = value
      }
      let font = manager.resolve(descriptor)
      #expect(font.cellWidth.isFinite && font.cellHeight.isFinite)
      #expect(font.ascent.isFinite && font.underlinePosition.isFinite)
      #expect(
        font.cellWidth == baseline.cellWidth
          && font.cellHeight == baseline.cellHeight
      )
    }
  }

  @Test
  func `overflowing finite adjustments keep oversized cells finite`() {
    let manager = CoreTextFontManager()
    var descriptor = FontDescriptor()
    descriptor.cellWidthAdjust = .greatestFiniteMagnitude
    descriptor.cellHeightOffset = .greatestFiniteMagnitude
    let font = manager.resolve(descriptor)
    #expect(font.cellWidth == .greatestFiniteMagnitude)
    #expect(font.cellHeight == .greatestFiniteMagnitude)
    #expect(font.ascent.isFinite && font.underlinePosition.isFinite)
  }

  @Test
  func `distinct glyph streams keep lookup storage bounded`() throws {
    let manager = CoreTextFontManager()
    let font = manager.resolve(FontDescriptor())
    let first = try #require(manager.lookup("A", style: [], in: font))
    for value in 0x4000 ..< 0x4000 + CoreTextFontManager.glyphCacheLimit + 100 {
      let scalar = try #require(Unicode.Scalar(value))
      _ = manager.lookup(scalar, style: [], in: font)
    }
    #expect(manager.cachedGlyphCount <= CoreTextFontManager.glyphCacheLimit)
    let repeated = try #require(manager.lookup("A", style: [], in: font))
    #expect(repeated.glyph == first.glyph)
    #expect(repeated.isColor == first.isColor)
  }

  @Test
  func `fallback glyph results are cached`() throws {
    let manager = CoreTextFontManager()
    let font = manager.resolve(FontDescriptor())
    let scalar = try #require(Unicode.Scalar(0x10FFFF))
    let initial = try #require(manager.lookup(scalar, style: [], in: font))
    #expect(manager.cachedGlyphCount == 1)
    let repeated = try #require(manager.lookup(scalar, style: [], in: font))
    #expect(repeated.font === initial.font && repeated.glyph == initial.glyph)
    #expect(manager.cachedGlyphCount == 1)
  }

  @Test
  func `glyph cache retains its font until another font replaces it`() {
    let manager = CoreTextFontManager()
    weak var cached: ResolvedFont?
    do {
      let font = manager.resolve(FontDescriptor(size: 13))
      cached = font
      #expect(manager.lookup("A", style: [], in: font) != nil)
    }
    for size in 20 ... 120 {
      _ = manager.resolve(FontDescriptor(size: CGFloat(size)))
    }
    #expect(cached != nil)
    let replacement = manager.resolve(FontDescriptor(size: 120))
    #expect(manager.lookup("A", style: [], in: replacement) != nil)
    #expect(cached == nil)
  }

  @Test
  func `evicting a cached font preserves externally held fonts`() {
    let manager = CoreTextFontManager()
    let retained = manager.resolve(FontDescriptor(size: 13))
    for size in 20 ... 120 {
      _ = manager.resolve(FontDescriptor(size: CGFloat(size)))
    }
    #expect(manager.glyph(for: "A", in: retained) != nil)
    #expect(manager.lookup("A", style: .bold, in: retained) != nil)
  }

  @Test
  func `zoom churn releases old resolved fonts and reuses recent ones`() {
    let manager = CoreTextFontManager()
    weak var old: ResolvedFont?
    do {
      let font = manager.resolve(FontDescriptor(size: 13))
      old = font
    }
    for size in 20 ... 120 {
      _ = manager.resolve(FontDescriptor(size: CGFloat(size)))
    }
    #expect(old == nil)
    let recent = manager.resolve(FontDescriptor(size: 120))
    #expect(manager.resolve(FontDescriptor(size: 120)) === recent)
  }

  @Test
  func `font cache keeps a recently reused size when evicting older sizes`() {
    let manager = CoreTextFontManager()
    weak let reused = manager.resolve(FontDescriptor(size: 13))
    weak let oldest = manager.resolve(FontDescriptor(size: 14))
    for size in 15 ... 28 {
      _ = manager.resolve(FontDescriptor(size: CGFloat(size)))
    }
    _ = manager.resolve(FontDescriptor(size: 13))
    _ = manager.resolve(FontDescriptor(size: 29))
    #expect(oldest == nil)
    #expect(reused != nil)
  }
}
