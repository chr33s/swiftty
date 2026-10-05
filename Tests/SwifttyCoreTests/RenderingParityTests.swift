import Metal
@testable import SwifttyCore
import Testing

@Suite(.serialized) struct RenderingParityTests {
    let helper = RendererTests()

    func make() throws -> MetalRenderer {
        try MetalRenderer(
            device: #require(RendererTests.device),
            fontManager: CoreTextFontManager(),
            font: FontDescriptor(size: 13, scale: 2),
        )
    }

    func frame(_ renderer: MetalRenderer, _ input: String, columns: Int = 8, rows: Int = 2) -> RendererTests.Frame {
        let session = TerminalSession(columns: columns, rows: rows)
        session.feed(Array(("\u{1B}[?25l" + input).utf8))
        let w = Int(renderer.cellSize.width) * columns + 16, h = Int(renderer.cellSize.height) * rows + 16
        return helper.render(renderer, session.snapshot(), width: w, height: h)
    }

    /// Pixels in the bottom half of cell (column, 0) that are not background.
    func underlineInk(_ f: RendererTests.Frame, _ r: MetalRenderer, column: Int) -> [(x: Int, y: Int)] {
        let cw = Int(r.cellSize.width), ch = Int(r.cellSize.height)
        var out: [(Int, Int)] = []
        let bg = Palette.standard.background
        for y in 8 + ch * 3 / 4 ..< 8 + ch + 2 {
            for x in 8 + column * cw ..< 8 + (column + 1) * cw {
                let p = f.pixel(x, y)
                if UInt32(p.r) << 16 | UInt32(p.g) << 8 | UInt32(p.b) != bg {
                    out.append((x, y))
                }
            }
        }
        return out
    }

    @Test(.enabled(if: RendererTests.device != nil)) func `underline styles draw differently`() throws {
        let r = try make()
        // Spaces, so only the underline is ink.
        let f = frame(r, "\u{1B}[4m \u{1B}[4:3m \u{1B}[4:4m \u{1B}[4:5m \u{1B}[21m ")
        let single = underlineInk(f, r, column: 0), curly = underlineInk(f, r, column: 1)
        let dotted = underlineInk(f, r, column: 2), dashed = underlineInk(f, r, column: 3)
        let double = underlineInk(f, r, column: 4)
        #expect(!single.isEmpty)
        #expect(Set(curly.map(\.y)).count > Set(single.map(\.y)).count) // the wave spans more rows
        #expect(dotted.count < single.count && !dotted.isEmpty)
        #expect(dashed.count < single.count && dashed.count > dotted.count)
        #expect(double.count > single.count)
    }

    @Test(.enabled(if: RendererTests.device != nil)) func `underline color`() throws {
        let r = try make()
        let f = frame(r, "\u{1B}[4;58;2;0;255;0m \u{1B}[59m ")
        let colored = underlineInk(f, r, column: 0).map { f.pixel($0.x, $0.y) }
        #expect(colored.contains { $0.g > 200 && $0.r < 60 })
        let plain = underlineInk(f, r, column: 1).map { f.pixel($0.x, $0.y) }
        #expect(plain.allSatisfy { !($0.g > 200 && $0.r < 60) })
    }

    @Test(.enabled(if: RendererTests.device != nil)) func `blinking text hides in its off phase`() throws {
        let r = try make()
        let bg = Palette.standard.background
        let on = frame(r, "\u{1B}[5mX")
        #expect(on.inkCount(column: 0, row: 0, renderer: r, background: bg) > 10)
        #expect(r.hasBlinkingText)
        r.options.textBlinkVisible = false
        let off = frame(r, "\u{1B}[5mX\u{1B}[0mY")
        #expect(off.inkCount(column: 0, row: 0, renderer: r, background: bg) == 0)
        #expect(off.inkCount(column: 1, row: 0, renderer: r, background: bg) > 10)
    }

    @Test func `minimum contrast picks black or white`() {
        #expect(MetalRenderer.ensureContrast(0x282C34, on: 0x282C34, ratio: 3) == 0xFFFFFF)
        #expect(MetalRenderer.ensureContrast(0xEEEEEE, on: 0xFFFFFF, ratio: 3) == 0x000000)
        #expect(MetalRenderer.ensureContrast(0xFFFFFF, on: 0x000000, ratio: 3) == 0xFFFFFF)
        #expect(MetalRenderer.ensureContrast(0x777777, on: 0x000000, ratio: 1) == 0x777777)
    }

    @Test(.enabled(if: RendererTests.device != nil)) func `post-processing shader runs over the frame`() throws {
        let r = try make()
        try r.setPostProcessShader("""
        float4 postprocess(float2 position, texture2d<float> source, constant PostUniforms &u) {
            constexpr sampler s(coord::pixel);
            float4 c = source.sample(s, position);
            return float4(1.0 - c.rgb, 1.0);
        }
        """)
        let f = frame(r, "")
        let p = f.pixel(2, 2)
        let bg = Palette.standard.background
        #expect(UInt32(p.r) == 255 - (bg >> 16 & 0xFF) && UInt32(p.b) == 255 - (bg & 0xFF))
        #expect(!r.isAnimating)
        #expect(throws: (any Error).self) { try r.setPostProcessShader("not metal") }
    }

    @Test(.enabled(if: RendererTests.device != nil)) func `palette selection colors apply`() throws {
        let r = try make()
        let session = TerminalSession(columns: 4, rows: 1)
        session.feed(Array("\u{1B}]21;selection_background=#00ff00\u{07}ab".utf8))
        session.mutate { $0.setSelection(Selection(anchor: TerminalPoint(row: 0, column: 0), head: TerminalPoint(row: 0, column: 3))) }
        let w = Int(r.cellSize.width) * 4 + 16, h = Int(r.cellSize.height) + 16
        let f = helper.render(r, session.snapshot(), width: w, height: h)
        let p = f.pixel(8 + Int(r.cellSize.width) * 3 + 2, 10)
        #expect(p.g == 255 && p.r == 0)
    }
}
