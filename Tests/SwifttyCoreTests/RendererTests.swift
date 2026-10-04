import Metal
@testable import SwifttyCore
import Testing

@Suite(.serialized) struct RendererTests {
    static let device = MTLCreateSystemDefaultDevice()

    struct Frame {
        let width: Int, height: Int
        let pixels: [UInt8] // BGRA

        func pixel(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
            let i = (y * width + x) * 4
            return (pixels[i + 2], pixels[i + 1], pixels[i])
        }

        /// Pixels in a cell that differ from `background`.
        func inkCount(column: Int, row: Int, renderer: MetalRenderer, background: UInt32) -> Int {
            let cw = Int(renderer.cellSize.width), ch = Int(renderer.cellSize.height), pad = Int(renderer.padding)
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

    func render(_ renderer: MetalRenderer, _ snapshot: RenderSnapshot, width: Int, height: Int) -> Frame {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        let texture = renderer.device.makeTexture(descriptor: d)!
        renderer.render(snapshot, to: texture).waitUntilCompleted()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return Frame(width: width, height: height, pixels: pixels)
    }

    @Test(.enabled(if: device != nil)) func `draws text colors and cursor`() throws {
        let renderer = try MetalRenderer(
            device: #require(Self.device),
            fontManager: CoreTextFontManager(),
            font: FontDescriptor(size: 13, scale: 2),
        )
        let session = TerminalSession(columns: 10, rows: 3)
        session.feed(Array("X \u{1B}[41m \u{1B}[0m中😀e\u{301}".utf8))
        let w = Int(renderer.cellSize.width) * 10 + 16, h = Int(renderer.cellSize.height) * 3 + 16
        let frame = render(renderer, session.snapshot(), width: w, height: h)
        let bg = Palette.standard.background

        #expect(frame.inkCount(column: 0, row: 0, renderer: renderer, background: bg) > 10) // "X"
        #expect(frame.inkCount(column: 1, row: 0, renderer: renderer, background: bg) == 0) // space
        // Red background cell.
        let cw = Int(renderer.cellSize.width), ch = Int(renderer.cellSize.height)
        let red = frame.pixel(8 + 2 * cw + cw / 2, 8 + ch / 2)
        #expect(red.r > 150 && red.g < 120)
        #expect(frame.inkCount(column: 3, row: 0, renderer: renderer, background: bg) > 10) // 中
        #expect(frame.inkCount(column: 5, row: 0, renderer: renderer, background: bg) > 10) // 😀
        #expect(frame.inkCount(column: 7, row: 0, renderer: renderer, background: bg) > 10) // é cluster
        // Block cursor at column 8.
        let cursor = frame.pixel(8 + 8 * cw + cw / 2, 8 + ch / 2)
        #expect(cursor.r > 200 && cursor.g > 200 && cursor.b > 200)
    }

    @Test(.enabled(if: device != nil)) func `incremental frames match full redraw`() throws {
        let manager = CoreTextFontManager()
        let incremental = try MetalRenderer(device: #require(Self.device), fontManager: manager, font: FontDescriptor())
        let session = TerminalSession(columns: 20, rows: 5)
        let w = Int(incremental.cellSize.width) * 20 + 16, h = Int(incremental.cellSize.height) * 5 + 16
        var last: Frame?
        for i in 0 ..< 8 {
            session.feed(Array("\u{1B}[\(i % 5 + 1);\(i + 1)H\u{1B}[3\(i % 7)mrow\(i)".utf8))
            last = render(incremental, session.snapshot(), width: w, height: h)
        }
        // A fresh renderer drawing the final state from scratch must agree.
        let fresh = try MetalRenderer(device: #require(Self.device), fontManager: manager, font: FontDescriptor())
        session.withState { _ in }
        let reference = render(fresh, session.snapshot(), width: w, height: h)
        let final = try #require(last)
        #expect(final.pixels == reference.pixels)
    }
}
