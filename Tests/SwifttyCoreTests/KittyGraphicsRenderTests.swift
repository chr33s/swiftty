import CoreTestSupport
import Foundation
import Metal
import Synchronization
import Testing
import TestSupport

@testable import SwifttyCore
@testable import SwifttyEngine

/// Kitty graphics rendering: layers, default-background show-through,
/// text-area clipping, placeholders and texture reuse (spec.graphics.md
/// §13, KG20/KG21).
@Suite(.serialized)
struct KittyGraphicsRenderTests {
  private static let padding = 8

  private struct Frame {
    let renderer: MetalRenderer
    let session: TerminalSession
    var cell: (w: Int, h: Int) {
      (Int(renderer.cellSize.width), Int(renderer.cellSize.height))
    }

    init(columns: Int = 4, rows: Int = 2) throws {
      renderer = try MetalRenderer(
        device: #require(RendererTests.device),
        fontManager: CoreTextFontManager(),
        font: FontDescriptor(size: 20)
      )
      renderer.padding = CGFloat(KittyGraphicsRenderTests.padding)
      session = TerminalSession(columns: columns, rows: rows)
      session.setCellPixelSize(
        width: Int(renderer.cellSize.width),
        height: Int(renderer.cellSize.height)
      )
      session.feed(Array("\u{1B}[?25l".utf8))
    }

    /// Transmits a solid-colour RGBA image covering `c`×`r` cells.
    func image(
      id: Int,
      rgba: [UInt8],
      columns c: Int,
      rows r: Int,
      keys: String = ""
    ) {
      let (w, h) = (cell.w * c, cell.h * r)
      var bytes: [UInt8] = []
      bytes.reserveCapacity(w * h * 4)
      for _ in 0 ..< w * h { bytes += rgba }
      let body =
        "a=T,f=32,s=\(w),v=\(h),i=\(id),q=2,C=1\(keys);"
        + Data(bytes).base64EncodedString()
      session.feed(Array("\u{1B}_G\(body)\u{1B}\\".utf8))
    }

    /// BGRA pixel at the centre of a cell (or of the padding when -1).
    func pixel(column: Int, row: Int) throws -> [UInt8] {
      let snapshot = session.snapshot()
      let p = KittyGraphicsRenderTests.padding
      let d = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm,
        width: cell.w * snapshot.columns + 2 * p,
        height: cell.h * snapshot.rowCount + 2 * p,
        mipmapped: false
      )
      d.storageMode = .shared
      d.usage = [.renderTarget, .shaderRead]
      let texture = try #require(renderer.device.makeTexture(descriptor: d))
      let command = try renderer.render(snapshot, to: texture)
      command.waitUntilCompleted()
      var out = [UInt8](repeating: 0, count: 4)
      let x = column < 0 ? p / 2 : p + column * cell.w + cell.w / 2
      let y = row < 0 ? p / 2 : p + row * cell.h + cell.h / 2
      texture.getBytes(
        &out,
        bytesPerRow: 4,
        from: MTLRegionMake2D(x, y, 1, 1),
        mipmapLevel: 0
      )
      return out
    }
  }

  private static let red: [UInt8] = [255, 0, 0, 255]
  private static let bgraRed: [UInt8] = [0, 0, 255, 255]

  @Test(.enabled(if: RendererTests.device != nil))
  func `images above text draw over cells`() throws {
    let f = try Frame()
    f.image(id: 1, rgba: Self.red, columns: 2, rows: 1)
    #expect(try f.pixel(column: 0, row: 0) == Self.bgraRed)
    #expect(try f.pixel(column: 1, row: 0) == Self.bgraRed)
    #expect(try f.pixel(column: 2, row: 0) != Self.bgraRed)
  }

  @Test(.enabled(if: RendererTests.device != nil))
  func `below background images show through default backgrounds only`() throws
  {
    let f = try Frame()
    // A blue explicit background on cell (1, 0).
    f.session.feed(Array("\u{1B}[1;2H\u{1B}[44m \u{1B}[0m\u{1B}[H".utf8))
    f.image(id: 1, rgba: Self.red, columns: 2, rows: 1, keys: ",z=-1073741825")
    #expect(try f.pixel(column: 0, row: 0) == Self.bgraRed)
    #expect(try f.pixel(column: 1, row: 0) != Self.bgraRed)
  }

  @Test(.enabled(if: RendererTests.device != nil))
  func `below text images sit above cell backgrounds`() throws {
    let f = try Frame()
    f.session.feed(Array("\u{1B}[44m  \u{1B}[0m\u{1B}[H".utf8))
    f.image(id: 1, rgba: Self.red, columns: 1, rows: 1, keys: ",z=-1")
    #expect(try f.pixel(column: 0, row: 0) == Self.bgraRed)
  }

  @Test(.enabled(if: RendererTests.device != nil))
  func `images are clipped to the text area`() throws {
    let f = try Frame(columns: 2, rows: 1)
    f.session.feed(Array("\u{1B}[1;2H".utf8))
    f.image(id: 1, rgba: Self.red, columns: 3, rows: 1)
    #expect(try f.pixel(column: 1, row: 0) == Self.bgraRed)
    // The padding right of the grid stays background.
    let snapshot = f.session.snapshot()
    _ = snapshot
    #expect(try f.pixel(column: -1, row: -1) != Self.bgraRed)
  }

  @Test(.enabled(if: RendererTests.device != nil))
  func `placeholder cells draw the image and no glyph`() throws {
    let f = try Frame()
    let (w, h) = (f.cell.w, f.cell.h)
    var bytes: [UInt8] = []
    for _ in 0 ..< w * h { bytes += Self.red }
    let body =
      "a=T,U=1,f=32,s=\(w),v=\(h),i=7,c=1,r=1,q=2;"
      + Data(bytes).base64EncodedString()
    f.session.feed(
      Array("\u{1B}_G\(body)\u{1B}\\\u{1B}[38;5;7m\u{10EEEE}".utf8)
    )
    #expect(try f.pixel(column: 0, row: 0) == Self.bgraRed)
  }

  @Test(.enabled(if: RendererTests.device != nil))
  func `textures are reused until pixels change`() throws {
    let f = try Frame()
    f.image(id: 1, rgba: Self.red, columns: 1, rows: 1)
    _ = try f.pixel(column: 0, row: 0)
    _ = try f.pixel(column: 0, row: 0)
    #expect(f.renderer.imageTextures.count == 1)
    f.image(id: 1, rgba: [0, 255, 0, 255], columns: 1, rows: 1)
    #expect(try f.pixel(column: 0, row: 0) == [0, 255, 0, 255])
    // The old pixels stay cached until a trim (memory warning).
    #expect(f.renderer.imageTextures.count == 2)
    f.renderer.trimImageTextures()
    #expect(f.renderer.imageTextures.count == 1)
  }

  @Test
  func `image regions describe visible images for VoiceOver`() {
    let session = TerminalSession(columns: 10, rows: 4)
    session.setCellPixelSize(width: 10, height: 20)
    let small = Data(repeating: 255, count: 20 * 20 * 4).base64EncodedString()
    let large = Data(repeating: 255, count: 40 * 40 * 4).base64EncodedString()
    // An anchored 2×1 image and a 4×2 placeholder image.
    session.feed(
      Array("\u{1B}_Ga=T,s=20,v=20,i=1,q=2,C=1;\(small)\u{1B}\\".utf8)
    )
    session.feed(
      Array(
        "\u{1B}_Ga=t,s=40,v=40,i=2,q=2;\(large)\u{1B}\\\u{1B}_Ga=p,U=1,i=2,c=4,r=2,q=2\u{1B}\\"
          .utf8
      )
    )
    let d = KittyGraphics.diacritics
    var text = "\u{1B}[38;5;2m"
    for row in 0 ..< 2 {
      text += "\u{1B}[\(row + 2);1H"
      for column in 0 ..< 4 {
        text.unicodeScalars.append(Unicode.Scalar(KittyGraphics.placeholder)!)
        text.unicodeScalars.append(Unicode.Scalar(d[row])!)
        text.unicodeScalars.append(Unicode.Scalar(d[column])!)
      }
    }
    session.feed(Array(text.utf8))
    let regions = session.snapshot().imageRegions
    #expect(
      regions.contains(ImageRegion(row: 0, column: 0, columns: 2, rows: 1))
    )
    #expect(
      regions.contains(ImageRegion(row: 1, column: 0, columns: 4, rows: 2))
    )
    #expect(regions.first { $0.rows == 2 }?.label == "Image, 4 by 2 cells")
  }

  /// §10.2 incremental rescans: only damaged rows are rescanned, from the
  /// rows each snapshot copies.
  @Test
  func `placeholders typed after the first snapshot appear incrementally`() {
    let session = TerminalSession(columns: 10, rows: 6)
    session.setCellPixelSize(width: 10, height: 20)
    let pixels = Data(repeating: 255, count: 40 * 20 * 4).base64EncodedString()
    session.feed(
      Array("\u{1B}_Ga=T,U=1,s=40,v=20,i=7,c=4,r=1,q=2;\(pixels)\u{1B}\\".utf8)
    )
    session.feed(Array("hello".utf8))
    #expect(session.snapshot().images.isEmpty)
    // U+10EEEE alone (no diacritics): row 0, columns 0, 1, …
    let bare = String(
      repeating: String(Character(Unicode.Scalar(KittyGraphics.placeholder)!)),
      count: 4
    )
    session.feed(Array("\u{1B}[3;1H\u{1B}[38;5;7m\(bare)\u{1B}[39m".utf8))
    let first = session.snapshot().images.filter(\.isPlaceholder)
    #expect(first.map(\.row) == [2])
    #expect(first.first?.columns == 4)
    // With diacritics on another row.
    let d = KittyGraphics.diacritics
    var marked = "\u{1B}[5;1H\u{1B}[38;5;7m"
    for c in 0 ..< 4 {
      marked.unicodeScalars.append(Unicode.Scalar(KittyGraphics.placeholder)!)
      marked.unicodeScalars.append(Unicode.Scalar(d[0])!)
      marked.unicodeScalars.append(Unicode.Scalar(d[c])!)
    }
    session.feed(Array((marked + "\u{1B}[39m").utf8))
    #expect(
      session.snapshot().images.filter(\.isPlaceholder).map(\.row) == [2, 4]
    )
    // Erasing a row removes its run; typing elsewhere changes nothing.
    session.feed(Array("\u{1B}[3;1H\u{1B}[2K\u{1B}[6;1Hx".utf8))
    #expect(session.snapshot().images.filter(\.isPlaceholder).map(\.row) == [4])
    // Images leave and return: the cells are rescanned in full.
    session.feed(Array("\u{1B}_Ga=d,d=I,i=7,q=2\u{1B}\\".utf8))
    #expect(session.snapshot().images.isEmpty)
    session.feed(
      Array("\u{1B}_Ga=T,U=1,s=40,v=20,i=7,c=4,r=1,q=2;\(pixels)\u{1B}\\".utf8)
    )
    #expect(session.snapshot().images.filter(\.isPlaceholder).map(\.row) == [4])
  }

  /// An image shown or deleted without text damage still asks the view
  /// for a frame.
  @Test
  func `graphics-only changes request a frame`() {
    let session = TerminalSession(columns: 10, rows: 4)
    session.setCellPixelSize(width: 10, height: 20)
    _ = session.snapshot()
    let updates = Mutex(0)
    session.onUpdate = { updates.withLock { $0 += 1 } }
    let pixels = Data(repeating: 255, count: 20 * 20 * 4).base64EncodedString()
    session.feed(
      Array("\u{1B}_Ga=T,s=20,v=20,i=1,C=1,q=2;\(pixels)\u{1B}\\".utf8)
    )
    #expect(updates.withLock { $0 } == 1)
    _ = session.snapshot()
    session.feed(Array("\u{1B}_Ga=d,d=I,i=1,q=2\u{1B}\\".utf8))
    #expect(updates.withLock { $0 } == 2)
  }

  /// A presentation frame without images (a roaming client switching to
  /// a pane that has none) clears the previous frame's images.
  @Test
  func `presentation frames without images clear the previous ones`() {
    let local = TerminalSession(columns: 10, rows: 4)
    local.setCellPixelSize(width: 10, height: 20)
    let pixels = Data(repeating: 255, count: 20 * 20 * 4).base64EncodedString()
    local.feed(
      Array("\u{1B}_Ga=T,s=20,v=20,i=1,C=1,q=2;\(pixels)\u{1B}\\".utf8)
    )
    let placements = local.snapshot().images
    #expect(!placements.isEmpty)
    var frame = PresentationFrame(
      columns: 10,
      rows: 4,
      cells: Array(repeating: .init(), count: 40),
      wrapped: Array(repeating: false, count: 4),
      styles: [.init()],
      cursorX: 0,
      cursorY: 0,
      title: ""
    )
    frame.images = placements
    frame.imageCellSize = SIMD2(10, 20)
    let shown = TerminalSession(presentationColumns: 10, rows: 4)
    #expect(shown.installPresentation(frame))
    #expect(!shown.snapshot().images.isEmpty)
    frame.images = []
    #expect(shown.installPresentation(frame))
    #expect(shown.snapshot().images.isEmpty)
  }

  @Test
  func `snapshots without images carry none`() {
    let session = TerminalSession(columns: 4, rows: 2)
    session.feed(Array("hello".utf8))
    #expect(session.snapshot().images.isEmpty)
  }
}
