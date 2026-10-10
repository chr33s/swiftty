import Dispatch
import Metal
@testable import SwifttyCore
import Testing
import TestSupport

/// Session lifecycle regressions.
struct RegressionTests {
  @Test
  func `overlong OSC number is ignored`() {
    var vt = VT(10, 2)
    vt.feed("\(ESC)]99999999999999999999;x\u{07}\(ESC)]2;ok\u{07}hi")
    #expect(vt.state.title == "ok")
    #expect(TestFixture(vt.lines[0]) == TestFixture("hi"))
  }

  @Test
  func `DEC special graphics maps underscore to blank`() {
    var vt = VT(4, 1)
    vt.feed("\(ESC)(0_q")
    #expect(vt.cell(0, 0).glyph == 0xA0)
    #expect(vt.cell(1, 0).glyph == 0x2500)
  }

  @Test
  func `grapheme table stays bounded on the alternate screen`() {
    var vt = VT(4, 2)
    vt.feed("\(CSI)?1049h")
    let frame = "\(CSI)He\u{301}"
    let chunk = String(repeating: frame, count: 10000)
    for _ in 0 ..< 30 { vt.feed(chunk) }
    #expect(
      vt.state.graphemes.scalars.count <= GraphemeTable.compactionThreshold + 2
    )
    #expect(TestFixture(vt.lines[0]) == TestFixture("e\u{301}"))
  }

  @Test
  func `shrinking height keeps rows below the cursor`() {
    var vt = VT(5, 6)
    vt.feed("0\r\n1\r\n2\r\n3\r\n4\r\n5\(CSI)2;1H")
    vt.state.resize(columns: 5, rows: 3)
    var all = (0 ..< vt.state.scrollbackCount)
      .map { vt.state.scrollbackText($0) }
    all += vt.lines
    #expect(all == ["0", "1", "2", "3", "4", "5"])
  }

  @Test
  func `reused snapshot storage keeps wrap flags`() {
    let session = TerminalSession(columns: 5, rows: 4)
    session.feed(Array("abcdefgh".utf8))
    do {
      let first = session.snapshot()
      #expect(first.rows[0].isWrapped)
    }
    session.feed(Array("\(CSI)4;1Hx".utf8))
    let second = session.snapshot()
    #expect(!second.damage.isFull && !second.damage.contains(row: 0))
    #expect(second.rows[0].isWrapped)
  }

  @Test
  func `synchronized output publishes after its timeout`() {
    let session = TerminalSession(columns: 5, rows: 2)
    let updated = DispatchSemaphore(value: 0)
    session.onUpdate = { updated.signal() }
    session.feed(Array("\(CSI)?2026hx".utf8))
    #expect(updated.wait(timeout: .now() + 0.3) == .timedOut)
    #expect(updated.wait(timeout: .now() + 3) == .success)
  }

  @Test
  func `a new synchronized frame in the same batch gets its own timeout`() {
    let session = TerminalSession(columns: 10, rows: 2)
    session.feed(Array("a".utf8))
    _ = session.snapshot()
    let updated = DispatchSemaphore(value: 0)
    session.onUpdate = { updated.signal() }
    session.feed(Array("\(CSI)?2026hb".utf8))
    #expect(updated.wait(timeout: .now() + 3) == .success)
    #expect(TestFixture(session.snapshot().text[0]) == TestFixture("ab"))

    // A new synchronized frame must not inherit the previous frame's deadline.
    session.feed(Array("\(CSI)?2026l\(CSI)?2026hc".utf8))
    #expect(TestFixture(session.snapshot().text[0]) == TestFixture("ab"))
    #expect(updated.wait(timeout: .now() + 0.3) == .timedOut)
    #expect(updated.wait(timeout: .now() + 3) == .success)
    #expect(TestFixture(session.snapshot().text[0]) == TestFixture("abc"))
  }

  @Test
  func `a pending timeout follows the latest synchronized frame`() {
    let session = TerminalSession(columns: 10, rows: 2)
    session.feed(Array("a".utf8))
    _ = session.snapshot()
    let updated = DispatchSemaphore(value: 0)
    session.onUpdate = { updated.signal() }
    session.feed(Array("\(CSI)?2026hb".utf8))
    #expect(updated.wait(timeout: .now() + 0.6) == .timedOut)
    session.feed(Array("\(CSI)?2026l\(CSI)?2026hc".utf8))
    // The first deadline will fire during this wait. It must defer
    // publication until the second frame's deadline.
    #expect(updated.wait(timeout: .now() + 0.6) == .timedOut)
    #expect(TestFixture(session.snapshot().text[0]) == TestFixture("a"))
    #expect(updated.wait(timeout: .now() + 3) == .success)
    #expect(TestFixture(session.snapshot().text[0]) == TestFixture("abc"))
  }
}

@Suite(.serialized)
struct RendererRegressionTests {
  @Test(.enabled(if: RendererTests.device != nil))
  func `skipped snapshot still repaints its rows`() throws {
    let manager = CoreTextFontManager()
    let renderer = try MetalRenderer(
      device: #require(RendererTests.device),
      fontManager: manager,
      font: FontDescriptor()
    )
    let session = TerminalSession(columns: 10, rows: 4)
    let w = Int(renderer.cellSize.width) * 10 + 16
    let h = Int(renderer.cellSize.height) * 4 + 16
    let helper = RendererTests()
    session.feed(Array("one".utf8))
    _ = helper.render(renderer, session.snapshot(), width: w, height: h)
    session.feed(Array("\(CSI)3;1Hlost".utf8))
    _ = session.snapshot()  // no drawable this frame
    session.feed(Array("\(CSI)4;1Hlast".utf8))
    let frame = helper.render(renderer, session.snapshot(), width: w, height: h)
    let fresh = try MetalRenderer(
      device: #require(RendererTests.device),
      fontManager: manager,
      font: FontDescriptor()
    )
    session.mutate { $0.damage.setFull() }
    let reference = helper.render(
      fresh,
      session.snapshot(),
      width: w,
      height: h
    )
    #expect(frame.pixels == reference.pixels)
  }
}
