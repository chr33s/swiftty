import CAllocCounter
import Darwin
import Metal
@testable import SwifttyCore
import Testing
import TestSupport

/// Hot paths must not touch the heap once warmed up (spec §13).
@Suite(.serialized) struct AllocationTests {
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil), arguments: [
        "e\u{301}", "👩‍💻", "e" + String(repeating: "\u{301}", count: 32),
    ])
    func `cached grapheme redraws do not allocate per cell`(_ cluster: String) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try MetalRenderer(device: device, fontManager: CoreTextFontManager(), font: FontDescriptor())
        let columns = 120, rows = 40
        let session = TerminalSession(columns: columns, rows: rows)
        session.feed(Array(("\u{1B}[?2027h\u{1B}[?25l" + String(repeating: cluster, count: columns * rows)).utf8))
        let hasGrapheme = session.withState { $0.grid[0, 0].isGrapheme }
        #expect(hasGrapheme)
        var snapshot = session.snapshot()
        snapshot.damage = .full
        let blankSession = TerminalSession(columns: columns, rows: rows)
        blankSession.feed(Array("\u{1B}[?25l".utf8))
        var blankSnapshot = blankSession.snapshot()
        blankSnapshot.damage = .full
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(renderer.cellSize.width) * columns + 16,
            height: Int(renderer.cellSize.height) * rows + 16,
            mipmapped: false,
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        for _ in 0 ..< 5 {
            renderer.render(blankSnapshot, to: texture).waitUntilCompleted()
            renderer.render(snapshot, to: texture).waitUntilCompleted()
        }
        alloc_counter_start()
        let blankCommand = renderer.render(blankSnapshot, to: texture)
        blankCommand.waitUntilCompleted()
        let baseline = alloc_counter_stop()
        alloc_counter_start()
        let command = renderer.render(snapshot, to: texture)
        command.waitUntilCompleted()
        let count = alloc_counter_stop()
        #expect(blankCommand.status == .completed && command.status == .completed)
        print("grapheme-redraw scalars=\(cluster.unicodeScalars.count) allocations=\(count) baseline=\(baseline)")
        #expect(count < baseline + 150, "cached redraw allocated \(count) times; ordinary redraw allocated \(baseline)")
    }

    @Test func `allocation measurements restore an existing malloc logger`() throws {
        typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
        let handle = try #require(dlopen(nil, RTLD_NOW))
        defer { dlclose(handle) }
        let symbol = try #require(dlsym(handle, "malloc_logger"))
        let hook = symbol.assumingMemoryBound(to: Logger?.self)
        let previous = hook.pointee
        defer { hook.pointee = previous }
        let observer: Logger = { _, _, _, _, _, _ in }
        hook.pointee = observer
        alloc_counter_start()
        alloc_counter_start() // Restarting must preserve the original logger.
        _ = alloc_counter_stop()
        let restored = try #require(hook.pointee)
        #expect(unsafeBitCast(restored, to: UInt.self) == unsafeBitCast(observer, to: UInt.self))
    }

    @Test func `reading session callbacks does not allocate after warmup`() {
        let session = TerminalSession(columns: 20, rows: 3)
        let bytes: [UInt8] = [1]
        let callbacks = SessionCallbacks()
        callbacks.onUpdate = {}
        session.onUpdate = {}
        session.onEvent = { _ in }
        session.onWrite = { _ in }
        session.onTerminalReply = { _ in }
        session.onProgramStatusChange = { _ in }
        session.onStateChange = { _ in }
        session.onProgramOutput = { _ in }
        session.onControlModeData = { _ in }
        func readCallbacks() {
            _ = callbacks.updateHandler
            _ = session.onUpdate
            _ = session.onEvent
            session.onWrite?(bytes)
            _ = session.onTerminalReply
            _ = session.onProgramStatusChange
            _ = session.onStateChange
            _ = session.onProgramOutput
            _ = session.onControlModeData
        }
        let count = session.queue.sync {
            for _ in 0 ..< 100 {
                readCallbacks()
            }
            alloc_counter_start()
            for _ in 0 ..< 1000 {
                readCallbacks()
            }
            return alloc_counter_stop()
        }
        #expect(count == 0, Comment(rawValue: escapedTestText("Callback reads allocated \(count) times")))
    }

    static func ascii(_ count: Int) -> [UInt8] {
        let line = Array("The quick brown fox jumps over the lazy dog 0123456789 ~!@#$%^&*()\r\n".utf8)
        return Array((0 ..< count / line.count + 1).lazy.flatMap { _ in line }.prefix(count))
    }

    static let utf8 = Array(String(repeating: "héllo wörld — 中文字符 😀 ünïcödé\r\n", count: 2000).utf8)
    static let csi = Array(String(
        repeating: "\u{1B}[1;31mred\u{1B}[0m \u{1B}[38;2;10;20;30mrgb\u{1B}[m\u{1B}[5;10H\u{1B}[K\u{1B}[2Ax\u{1B}[?25l\u{1B}[?25h\r\n",
        count: 2000,
    ).utf8)

    /// Warm-up fills the scrollback (one block) and its line ring so the
    /// measured pass is steady state.
    func allocations(_ input: [UInt8], warmups: Int = 3) -> UInt64 {
        // One scrollback block so warm-up reaches steady state.
        var state = TerminalState(columns: 120, rows: 40, scrollbackLimitBytes: 1)
        var parser = Parser()
        let span = input.span
        for _ in 0 ..< warmups {
            parser.consume(span, into: &state)
        }
        alloc_counter_start()
        parser.consume(span, into: &state)
        _ = state.takeDamage()
        return alloc_counter_stop()
    }

    @Test func `counter works`() {
        alloc_counter_start()
        let array = [Int](repeating: 1, count: 1000)
        let count = alloc_counter_stop()
        #expect(array.count == 1000 && count >= 1)
    }

    @Test(arguments: ["a", "é", "e\u{301}", "中", "👩‍💻"])
    func `ANSI dumps do not allocate per cell`(_ character: String) {
        var state = TerminalState(columns: 32768, rows: 1)
        var parser = Parser()
        let content = String(repeating: character, count: 8192)
        let bytes = Array(content.utf8)
        parser.consume(bytes.span, into: &state)
        #expect(state.dumpPrimaryANSI() == bytes)
        alloc_counter_start()
        let dump = state.dumpPrimaryANSI()
        let count = alloc_counter_stop()
        #expect(dump == bytes)
        #expect(count < 100)
    }

    @Test(arguments: ["a", "é", "e\u{301}", "中", "👩‍💻"])
    func `copying selections and screen text does not allocate per cell`(_ character: String) {
        var state = TerminalState(columns: 32768, rows: 1)
        var parser = Parser()
        let content = String(repeating: character, count: 8192)
        let bytes = Array(content.utf8)
        parser.consume(bytes.span, into: &state)
        state.selectAll()
        #expect(state.selectionText == content)
        #expect(TestFixture(state.text(row: 0)) == TestFixture(content))
        alloc_counter_start()
        let copied = state.selectionText
        let copyAllocations = alloc_counter_stop()
        alloc_counter_start()
        let screen = state.text(row: 0)
        let screenAllocations = alloc_counter_stop()
        #expect(copied == content)
        #expect(screen == content)
        #expect(copyAllocations < 100)
        #expect(screenAllocations < 100)
    }

    @Test(arguments: ["a", "é", "e\u{301}", "😀", "👩‍💻"])
    func `accessibility cursor mapping does not allocate per scalar`(_ character: String) {
        let session = TerminalSession(columns: 4096, rows: 1)
        let content = String(repeating: character, count: 1024)
        session.feed(Array((content + "\u{1B}[1G").utf8))
        let start = session.snapshot()
        session.feed(Array("\u{1B}[4096G".utf8))
        let end = session.snapshot()
        _ = AccessibilityText(start)
        _ = AccessibilityText(end)
        alloc_counter_start()
        let first = AccessibilityText(start)
        let baseline = alloc_counter_stop()
        alloc_counter_start()
        let last = AccessibilityText(end)
        let count = alloc_counter_stop()
        #expect(first.cursorOffset == 0)
        #expect(last.cursorOffset == content.utf16.count)
        #expect(count < baseline + 10)
    }

    @Test func `ascii stream does not allocate`() {
        #expect(allocations(Self.ascii(1 << 20)) == 0)
    }

    @Test func `utf 8 stream does not allocate`() {
        #expect(allocations(Self.utf8) == 0)
    }

    @Test func `csi stream does not allocate`() {
        #expect(allocations(Self.csi) == 0)
    }

    @Test func `cursor and style updates do not rescan active search history`() {
        var state = TerminalState(columns: 120, rows: 40)
        var parser = Parser()
        let content = Self.ascii(64 * 1024)
        parser.consume(content.span, into: &state)
        state.search("quick")
        #expect(state.searchMatches.count > 500)
        let updates = Array(String(repeating: "\u{1B}[1;1H\u{1B}[31m\u{1B}[0m\u{1B}[?25l\u{1B}[?25h", count: 100).utf8)
        parser.consume(updates.span, into: &state)
        alloc_counter_start()
        parser.consume(updates.span, into: &state)
        let allocations = alloc_counter_stop()
        #expect(allocations == 0)
    }

    @Test(arguments: ["quick", "the", "The"])
    func `searching ASCII history does not allocate per cell`(_ query: String) {
        var state = TerminalState(columns: 120, rows: 40)
        var parser = Parser()
        let content = Self.ascii(64 * 1024)
        parser.consume(content.span, into: &state)
        state.search(query)
        alloc_counter_start()
        state.search(query)
        let count = alloc_counter_stop()
        #expect(state.searchMatches.count > 500)
        #expect(count < 100)
    }

    @Test(arguments: ["a", "é", "e\u{301}", "中"])
    func `URL hover allocations do not grow per cell`(_ character: String) {
        func measured(_ length: Int) -> UInt64 {
            var state = TerminalState(columns: 120, rows: 40)
            var parser = Parser()
            let url = "https://example.test/path"
            let bytes = Array((String(repeating: character, count: length) + " " + url).utf8)
            parser.consume(bytes.span, into: &state)
            let point = TerminalPoint(row: state.screenAbsoluteRow(state.cursor.y), column: state.cursor.x - 1)
            #expect(state.link(at: point)?.url == url)
            alloc_counter_start()
            let link = state.link(at: point)
            let count = alloc_counter_stop()
            #expect(link?.url == url)
            return count
        }
        let short = measured(4096)
        let long = measured(32768)
        #expect(long < short + 50)
        #expect(long < 100)
    }

    @Test(arguments: ["a", "é", "e\u{301}", "中"])
    func `word selection does not allocate per cell`(_ character: String) {
        var state = TerminalState(columns: 120, rows: 40)
        var parser = Parser()
        let content = String(repeating: character, count: 8192)
        let bytes = Array(content.utf8)
        parser.consume(bytes.span, into: &state)
        let point = TerminalPoint(row: 0, column: 0)
        let warmed = state.wordRange(at: point)
        alloc_counter_start()
        let range = state.wordRange(at: point)
        let count = alloc_counter_stop()
        #expect(count == 0)
        #expect(range.start == warmed.start && range.end == warmed.end)
        #expect(TestFixture(state.text(from: range.start, to: range.end)) == TestFixture(content))
    }

    @Test func `wrapped line search allocations do not grow with history length`() {
        func measured(_ length: Int) -> UInt64 {
            var state = TerminalState(columns: 120, rows: 40)
            var parser = Parser()
            let content = [UInt8](repeating: 0x61, count: length)
            parser.consume(content.span, into: &state)
            state.search("NEEDLE")
            alloc_counter_start()
            state.search("NEEDLE")
            let count = alloc_counter_stop()
            #expect(state.searchMatches.isEmpty)
            return count
        }
        let short = measured(4096)
        let long = measured(64 * 1024)
        #expect(long == short)
    }

    @Test func `scalar glyph mapping does not allocate after font warmup`() {
        let font = ResolvedFont(descriptor: FontDescriptor())
        let faces = font.faces + [font.emoji]
        let scalars: [Unicode.Scalar] = ["A", "é", "中", "😀"]
        let faceSpan = faces.span
        let scalarSpan = scalars.span
        for face in faceSpan {
            for scalar in scalarSpan {
                _ = CoreTextFontManager.glyph(scalar, in: face)
            }
        }
        var checksum: UInt64 = 0
        alloc_counter_start()
        for _ in 0 ..< 1000 {
            for face in faceSpan {
                for scalar in scalarSpan {
                    checksum += UInt64(CoreTextFontManager.glyph(scalar, in: face) ?? 0)
                }
            }
        }
        let count = alloc_counter_stop()
        #expect(checksum > 0)
        #expect(count == 0)
    }

    @Test func `cell updates do not allocate`() {
        let grid = Grid(columns: 200, rows: 60)
        let cell = Cell(glyph: 0x41, attributes: CellAttributes(foreground: .palette(3)), width: 1)
        alloc_counter_start()
        for y in 0 ..< 60 {
            for x in 0 ..< 200 {
                grid[x, y] = cell
            }
            grid.scrollUp(top: 0, bottom: 59, count: 1, fill: .blank)
            grid.insertCells(row: y, at: 3, count: 4, fill: .blank)
        }
        #expect(alloc_counter_stop() == 0)
    }
}
