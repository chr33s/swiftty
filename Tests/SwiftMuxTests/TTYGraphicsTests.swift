import Foundation
@testable import SwifttyEngine
import Testing
@testable import TTYKit

/// Kitty graphics in terminal clients (spec.graphics.md §16.5, KG25):
/// detection, placeholder emission and clipping, tmux wrapping, the
/// half-block raster, and outer replies never reaching the program.
struct TTYGraphicsTests {
  private func placement(
    _ rgba: [UInt8],
    width: Int,
    height: Int,
    columns: Int,
    rows: Int,
    row: Int = 0,
    column: Int = 0,
    layer: KittyGraphics.Layer = .aboveText
  ) -> KittyGraphics.Placement {
    let pixels = KittyImagePixels(
      receivedWidth: width,
      height: height,
      bytesPerPixel: 4,
      bytes: rgba
    )!
    return KittyGraphics.Placement(
      imageID: 1,
      generation: 1,
      pixels: pixels,
      layer: layer,
      z: 0,
      row: row,
      column: column,
      columns: columns,
      rows: rows,
      offsetX: 0,
      offsetY: 0,
      width: width,
      height: height,
      sourceX: 0,
      sourceY: 0,
      sourceWidth: width,
      sourceHeight: height,
      isPlaceholder: false
    )
  }

  private func solid(_ w: Int, _ h: Int, _ px: [UInt8]) -> [UInt8] {
    Array([[UInt8]](repeating: px, count: w * h).joined())
  }

  @Test
  func `detection reads the graphics reply before DA1`() {
    let g = TTYGraphics(mode: .off)
    #expect(String(decoding: g.probe, as: UTF8.self).hasPrefix("\u{1B}_Gi=31,"))
    #expect(g.detect(.graphics("Gi=31;OK")))
    #expect(g.mode == .kitty)
    let h = TTYGraphics(mode: .off)
    #expect(h.detect(.deviceAttributes("?62;22")))
    #expect(h.mode == .halfBlocks)
    let other = TTYGraphics(mode: .off)
    #expect(!other.detect(.graphics("Gi=7;OK")))
  }

  @Test
  func `outer replies are decoded and never become input`() {
    var decoder = InputDecoder()
    let events = decoder.feed(
      Array("a\u{1B}_Gi=31;OK\u{1B}\\\u{1B}[?62;22cb".utf8)
    )
    #expect(
      events == [
        .text("a"), .reply(.graphics("Gi=31;OK")),
        .reply(.deviceAttributes("?62;22")), .text("b"),
      ]
    )
  }

  @Test
  func `kitty mode transmits once and draws clipped placeholders`() throws {
    let g = TTYGraphics(mode: .kitty)
    var screen = ScreenBuffer(columns: 4, rows: 2)
    let p = placement(
      solid(2, 2, [255, 0, 0, 255]),
      width: 2,
      height: 2,
      columns: 3,
      rows: 2,
      column: 2
    )
    let bytes = String(
      decoding: g.compose([p], hostCell: .zero, into: &screen),
      as: UTF8.self
    )
    #expect(bytes.contains("a=t,f=32,s=2,v=2,i=1,q=2,m=0;"))
    #expect(bytes.contains("a=p,U=1,i=1,c=3,r=2,q=2"))
    let d = KittyGraphics.diacritics
    let cell = screen[2, 1]
    #expect(cell.text.unicodeScalars.map(\.value) == [0x10EEEE, d[1], d[0]])
    #expect(cell.style.foreground == .rgb(1))
    #expect(
      screen[3, 0].text.unicodeScalars.map(\.value) == [0x10EEEE, d[0], d[1]]
    )
    #expect(screen[1, 0].text == " ")
    var again = ScreenBuffer(columns: 4, rows: 2)
    #expect(g.compose([p], hostCell: .zero, into: &again).isEmpty)
    g.invalidate()
    var redrawn = ScreenBuffer(columns: 4, rows: 2)
    #expect(!g.compose([p], hostCell: .zero, into: &redrawn).isEmpty)
  }

  @Test
  func `tmux passthrough doubles escapes`() {
    let g = TTYGraphics(mode: .kitty, tmux: true)
    let probe = String(decoding: g.probe, as: UTF8.self)
    #expect(probe.hasPrefix("\u{1B}Ptmux;\u{1B}\u{1B}_G"))
    #expect(probe.contains("\u{1B}\u{1B}\\\u{1B}\\"))
  }

  @Test
  func `below-text placements keep text`() {
    let g = TTYGraphics(mode: .halfBlocks)
    var screen = ScreenBuffer(columns: 2, rows: 1)
    screen.write("x", x: 0, y: 0, style: .plain)
    let p = placement(
      solid(2, 2, [0, 255, 0, 255]),
      width: 2,
      height: 2,
      columns: 2,
      rows: 1,
      layer: .belowText
    )
    _ = g.compose([p], hostCell: .zero, into: &screen)
    #expect(screen[0, 0].text == "x")
    #expect(screen[1, 0].text == "\u{2580}")
    #expect(screen[1, 0].style.foreground == .rgb(0x00FF00))
  }

  @Test
  func `half-blocks sample only the visible cells of a huge grid`() {
    let g = TTYGraphics(mode: .halfBlocks)
    var screen = ScreenBuffer(columns: 2, rows: 2)
    let p = placement(
      solid(2, 2, [0, 255, 0, 255]),
      width: 2,
      height: 2,
      columns: 40000,
      rows: 40000,
      row: -1,
      column: -1
    )
    _ = g.compose([p], hostCell: .zero, into: &screen)
    #expect(screen[1, 1].text == "\u{2580}")
    #expect(screen[1, 1].style.foreground == .rgb(0x00FF00))
  }

  @Test
  func `escape underscore is Alt underscore unless a graphics reply`() {
    var d = InputDecoder()
    #expect(
      d.feed(Array("\u{1B}_x".utf8)) == [
        .key(.character(0x5F), .alt), .text("x"),
      ]
    )
    #expect(d.feed(Array("\u{1B}_".utf8)).isEmpty)
    #expect(d.flushPending() == [.key(.character(0x5F), .alt)])
  }

  @Test
  func `half-blocks sample top and bottom halves`() {
    let g = TTYGraphics(mode: .halfBlocks)
    // Top half red, bottom half blue, one cell.
    let rgba = solid(2, 1, [255, 0, 0, 255]) + solid(2, 1, [0, 0, 255, 255])
    var screen = ScreenBuffer(columns: 1, rows: 1)
    _ = g.compose(
      [placement(rgba, width: 2, height: 2, columns: 1, rows: 1)],
      hostCell: .zero,
      into: &screen
    )
    #expect(screen[0, 0].text == "\u{2580}")
    #expect(screen[0, 0].style.foreground == .rgb(0xFF0000))
    #expect(screen[0, 0].style.background == .rgb(0x0000FF))
    let palette = TTYGraphics(mode: .halfBlocks, truecolor: false)
    var quantized = ScreenBuffer(columns: 1, rows: 1)
    _ = palette.compose(
      [placement(rgba, width: 2, height: 2, columns: 1, rows: 1)],
      hostCell: .zero,
      into: &quantized
    )
    #expect(quantized[0, 0].style.foreground == .palette(196))
    #expect(quantized[0, 0].style.background == .palette(21))
  }

  @Test
  func `transparent pixels leave cells alone`() {
    let g = TTYGraphics(mode: .halfBlocks)
    var screen = ScreenBuffer(columns: 1, rows: 1)
    _ = g.compose(
      [
        placement(
          solid(1, 2, [0, 0, 0, 0]),
          width: 1,
          height: 2,
          columns: 1,
          rows: 1
        )
      ],
      hostCell: .zero,
      into: &screen
    )
    #expect(screen[0, 0] == .blank)
  }

  @Test
  func `256-colour quantisation picks cube and grey entries`() {
    #expect(TTYGraphics.palette256(0xFF0000) == 196)
    #expect(TTYGraphics.palette256(0x000000) == 16)
    #expect(TTYGraphics.palette256(0x808080) == 244)
  }
}
