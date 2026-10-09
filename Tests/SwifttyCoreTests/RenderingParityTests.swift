import Metal
@testable import SwifttyCore
import Testing
import TestSupport

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

    @Test(.enabled(if: RendererTests.device != nil)) func `strikethrough and overline draw together`() throws {
        let r = try make()
        let strike = frame(r, "\u{1B}[9m ")
        let overline = frame(r, "\u{1B}[53m ")
        let combined = frame(r, "\u{1B}[9;53m ")
        #expect(strike.pixels != overline.pixels)
        #expect(combined.pixels == zip(strike.pixels, overline.pixels).map { max($0, $1) })
    }

    @Test(.enabled(if: RendererTests.device != nil)) func `concealed text also conceals its decorations`() throws {
        let r = try make()
        let blank = frame(r, " ")
        let concealed = frame(r, "\u{1B}[8;4:3;9;53mX")
        #expect(concealed.pixels == blank.pixels)
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

    @Test(.enabled(if: RendererTests.device != nil)) func `blinking decorations hide while backgrounds and cursors remain`() throws {
        let r = try make()
        r.options.cursorStyle = .bar
        let session = TerminalSession(columns: 4, rows: 1)
        session.feed(Array("\u{1B}[41;5;4:3;9;53mX\u{1B}[1G".utf8))
        let w = Int(r.cellSize.width) * 4 + 16, h = Int(r.cellSize.height) + 16
        let on = helper.render(r, session.snapshot(), width: w, height: h)
        r.options.textBlinkVisible = false
        let off = helper.render(r, session.snapshot(), width: w, height: h)
        let reference = TerminalSession(columns: 4, rows: 1)
        reference.feed(Array("\u{1B}[41m \u{1B}[1G".utf8))
        let blank = helper.render(r, reference.snapshot(), width: w, height: h)
        #expect(on.pixels != blank.pixels)
        #expect(off.pixels == blank.pixels)
    }

    @Test(.enabled(if: RendererTests.device != nil)) func `faint dims color emoji`() throws {
        let r = try make()
        let normal = frame(r, "\u{1B}]11;#000000\u{7}😀")
        let faint = frame(r, "\u{1B}]11;#000000\u{7}\u{1B}[2m😀")
        func brightness(_ frame: RendererTests.Frame) -> Int {
            stride(from: 0, to: frame.pixels.count, by: 4).reduce(0) {
                $0 + Int(frame.pixels[$1]) + Int(frame.pixels[$1 + 1]) + Int(frame.pixels[$1 + 2])
            }
        }
        let normalInk = brightness(normal), faintInk = brightness(faint)
        #expect(normalInk > 0)
        #expect(faintInk > 0 && faintInk < normalInk * 3 / 4)
    }

    @Test(.enabled(if: RendererTests.device != nil)) func `primary color glyphs keep their colors when the foreground changes`() throws {
        var descriptor = FontDescriptor(size: 20, scale: 2)
        descriptor.family = "Apple Color Emoji"
        let renderer = try MetalRenderer(
            device: #require(RendererTests.device), fontManager: CoreTextFontManager(), font: descriptor,
        )
        let red = frame(renderer, "\u{1B}[31m©")
        let green = frame(renderer, "\u{1B}[32m©")
        #expect(red.inkCount(column: 0, row: 0, renderer: renderer, background: Palette.standard.background) > 0)
        #expect(red.pixels == green.pixels)
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

    @Test(.enabled(if: RendererTests.device != nil), arguments: [
        (
            "constant float2 &resolution = u.resolution;",
            "constant float *values = reinterpret_cast<constant float *>(&resolution); return float4(values[2]);",
        ),
        (
            "constant float2 &resolution = u.resolution;",
            "constant float *values = (constant float *)(&resolution); return float4(values[2]);",
        ),
        (
            "constant float2 &resolution = u.resolution;",
            "constant float *values = (float constant *)(&resolution); return float4(values[2]);",
        ),
        ("constant float2 &resolution = u.resolution;", "return float4((&resolution)[1].x);"),
    ].map(TestFixture.init))
    func `uniform field aliases retain shader animation`(_ sample: TestFixture<(String, String)>) throws {
        let sample = sample.value
        let device = try #require(RendererTests.device)
        let post = try PostProcess(device: device, source: """
        float4 postprocess(float2 position, texture2d<float> source, constant PostUniforms &u) {
            \(sample.0)
            \(sample.1)
        }
        """)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .renderTarget]
        let input = try #require(device.makeTexture(descriptor: descriptor))
        let output = try #require(device.makeTexture(descriptor: descriptor))
        let queue = try #require(device.makeCommandQueue())
        for time: Float in [0.25, 0.75] {
            let command = try #require(queue.makeCommandBuffer())
            post.encode(from: input, to: output, commandBuffer: command, time: time)
            command.commit()
            command.waitUntilCompleted()
            #expect(command.status == .completed)
            var pixels = [UInt8](repeating: 0, count: 4)
            pixels.withUnsafeMutableBytes { buffer in
                output.getBytes(buffer.baseAddress!, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
            }
            #expect(pixels.allSatisfy { abs(Int($0) - Int((time * 255).rounded())) <= 1 })
        }
        #expect(post.usesTime)
    }

    @Test(.enabled(if: RendererTests.device != nil), arguments: [
        ("return float4(u.time);", true),
        ("return float4(u . time);", true),
        ("return float4(u.\n time);", true),
        ("return float4(u./* clock */time);", true),
        ("return float4(u.ti\\\nme);", true),
        ("return float4(u.ti\\\r\nme);", true),
        ("return float4(u.ti\\\rme);", true),
        ("return float4(u.ti\\ \nme);", true),
        ("return float4(u.ti\\\t\nme);", true),
        ("return float4(u.ti\\\u{B}\nme);", true),
        ("return float4(u.ti\\\u{C}\nme);", true),
        ("return float4(u.\\\n time);", true),
        ("constant PostUniforms *clock = &u; return float4(clock->time);", true),
        ("constant float *values = reinterpret_cast<constant float *>(&u); return float4(values[2]);", true),
        ("constant float *values = (constant float *)&u; return float4(values[2]);", true),
        ("constant float *values = (constant float *)&u.resolution; return float4(values[2]);", true),
        ("PostUniforms copy = u; thread float *values = reinterpret_cast<thread float *>(&copy); return float4(values[2]);", true),
        ("return float4(u.resolution, 0, 1);", false),
        ("return float4((float)u.resolution.x);", false),
        ("return float4(static_cast<float>(u.resolution.x));", false),
        ("return float4(uint(u.resolution.x) & 1);", false),
        ("uint mask = 1; return float4(uint(u.resolution.x) & mask);", false),
        ("uint flags = uint(u.resolution.x), mask = 1; return float4(flags & mask);", false),
        ("return float4(u.pad);", false),
        ("return float4(0); // reinterpret_cast<constant float *>(&u)", false),
        ("#define CLOCK time\nreturn float4(u.CLOCK);", true),
        ("#define JOIN(a, b) a ## b\nreturn float4(u.JOIN(ti, me));", true),
        ("#define STATIC_VALUE 0\nreturn float4(STATIC_VALUE);", true),
        ("// #define CLOCK time\nreturn float4(0);", false),
        ("/*\n#define CLOCK time\n*/ return float4(0);", false),
        ("return float4(0); // u.time", false),
        ("/* u.time */ return float4(0);", false),
        ("// ignored \\\n u.time\nreturn float4(0);", false),
        ("// ignored \\ \n u.time\nreturn float4(0);", false),
        ("// ignored \\\n\nreturn float4(u.time);", true),
        ("/\\\n* u.time *\\\n/ return float4(0);", false),
    ].map(TestFixture.init))
    func `shader animation detects direct and indirect time reads`(_ sample: TestFixture<(String, Bool)>) throws {
        let sample = sample.value
        let renderer = try make()
        try renderer.setPostProcessShader("""
        float4 postprocess(float2 position, texture2d<float> source, constant PostUniforms &u) {
            \(sample.0)
        }
        """)
        #expect(renderer.isAnimating == sample.1)
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

    @Test(.enabled(if: RendererTests.device != nil), arguments: [false, true])
    func `selecting either wide character half highlights the whole glyph`(_ rectangle: Bool) throws {
        let r = try make()
        r.options.selectionBackground = 0x00FF00
        r.options.selectionForeground = 0xFF0000
        let session = TerminalSession(columns: 8, rows: 1)
        session.feed(Array("\u{1B}[?25la漢b👩‍💻c".utf8))
        let w = Int(r.cellSize.width) * 8 + 16, h = Int(r.cellSize.height) + 16
        func selected(_ start: Int, _ end: Int) -> [UInt8] {
            session.mutate {
                $0.setSelection(Selection(
                    anchor: TerminalPoint(row: 0, column: start),
                    head: TerminalPoint(row: 0, column: end),
                    rectangle: rectangle,
                ))
            }
            return helper.render(r, session.snapshot(), width: w, height: h).pixels
        }
        for head in [1, 4] {
            let whole = selected(head, head + 1)
            #expect(selected(head, head) == whole)
            #expect(selected(head + 1, head + 1) == whole)
        }
    }

    @Test(.enabled(if: RendererTests.device != nil)) func `selected overlapping search match takes precedence`() throws {
        let r = try make()
        let session = TerminalSession(columns: 6, rows: 1)
        session.feed(Array("\u{1B}[?25lababa".utf8))
        session.mutate {
            $0.search("aba")
            $0.selectSearchMatch(forward: true)
            $0.selectSearchMatch(forward: true)
        }
        r.options.searchBackground = 0xFF0000
        r.options.selectedSearchBackground = 0x00FF00
        let w = Int(r.cellSize.width) * 6 + 16, h = Int(r.cellSize.height) + 16
        let f = helper.render(r, session.snapshot(), width: w, height: h)
        for column in 0 ..< 5 {
            let p = f.pixel(8 + column * Int(r.cellSize.width), 8)
            if column < 2 {
                #expect(p.r == 255 && p.g == 0)
            } else {
                #expect(p.g == 255 && p.r == 0)
            }
        }
    }
}
