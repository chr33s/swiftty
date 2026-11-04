@testable import SwifttyCore
@testable import SwifttyEngine
import Testing
import TestSupport

struct GraphemeCompactionTests {
  @Test
  func `a cluster grows in place without leaving garbage`() {
    var vt = VT(12, 4)
    vt.feed("👨\u{200D}👩\u{200D}👧\u{200D}👦x")
    #expect(vt.state.graphemes.scalars.count == 7)
    #expect(vt.state.scalars(of: vt.cell(0, 0)).count == 7)
    vt.feed("\r\ne\u{301}\u{302}\u{303}")
    #expect(vt.state.graphemes.scalars.count == 11)
    #expect(
      vt.state.scalars(of: vt.cell(0, 1)) == [
        "e", "\u{301}", "\u{302}", "\u{303}",
      ]
    )
  }

  @Test
  func `recorded break state still pairs regional indicators`() {
    var vt = VT(12, 4)
    vt.feed("🇯🇵🇺🇸🇫\u{200D}👩\u{200D}💻")
    #expect(vt.state.scalars(of: vt.cell(0, 0)) == ["🇯", "🇵"])
    #expect(vt.state.scalars(of: vt.cell(2, 0)) == ["🇺", "🇸"])
    #expect(vt.state.scalars(of: vt.cell(4, 0)) == ["🇫", "\u{200D}"])
    #expect(vt.state.scalars(of: vt.cell(6, 0)) == ["👩", "\u{200D}", "💻"])
  }

  @Test
  func `a control sequence ends in-place growth of the last cluster`() {
    var vt = VT(12, 4)
    vt.feed("e\u{301}\(CSI)1m\u{302}")
    let first = vt.cell(0, 0)
    #expect(vt.state.scalars(of: first) == ["e", "\u{301}", "\u{302}"])
    #expect(vt.state.graphemes.scalars.count == 5)
    vt.feed("\u{303}")
    #expect(
      vt.state.scalars(of: vt.cell(0, 0)) == [
        "e", "\u{301}", "\u{302}", "\u{303}",
      ]
    )
    #expect(vt.state.graphemes.scalars.count == 6)
  }

  @Test
  func `repeated compaction preserves both screens and primary history`() {
    var actual = VT(12, 4)
    var reference = VT(12, 4)
    reference.state.graphemes.compactionLimit = .max
    let seed =
      "\(CSI)31m\(ESC)]8;;file:///retained\u{07}e\u{301}\r\n👩‍💻\r\n漢\u{301}\r\n"
      + "a\u{308}\r\n\(ESC)]8;;\u{07}\(CSI)0m"
    actual.feed(seed)
    reference.feed(seed)
    #expect(actual.state.scrollbackCount > 0)
    var builder = SnapshotBuilder()
    let retainedSnapshot = builder.build(from: &actual.state)
    let retainedText = retainedSnapshot.text
    let churn = String(repeating: "\(CSI)4;1Hx\u{301}", count: 40000)
    for alternate in [true, false, true, false] {
      let switchScreen = "\(CSI)?47" + (alternate ? "h" : "l")
      actual.feed(switchScreen)
      reference.feed(switchScreen)
      if alternate {
        let retained = "\(CSI)H\(CSI)32m❤\u{FE0F}e\u{308}\(CSI)0m"
        actual.feed(retained)
        reference.feed(retained)
      }
      actual.feed(churn)
      reference.feed(churn)
      #expect(
        actual.state.graphemes.scalars.count < GraphemeTable.compactionThreshold
      )
      #expect(TestFixture(actual.lines) == TestFixture(reference.lines))
      #expect(actual.state.cursor == reference.state.cursor)
      let snapshot = builder.build(from: &actual.state)
      #expect(TestFixture(snapshot.text) == TestFixture(reference.lines))
      #expect(TestFixture(retainedSnapshot.text) == TestFixture(retainedText))
      for y in 0 ..< 4 {
        for x in 0 ..< 12 {
          let cell = actual.cell(x, y)
          let expected = reference.cell(x, y)
          #expect(
            actual.state.scalars(of: cell)
              == reference.state.scalars(of: expected)
          )
          #expect(cell.attributes == expected.attributes)
          #expect(cell.width == expected.width)
        }
      }
      #expect(actual.state.scrollbackCount == reference.state.scrollbackCount)
      for index in 0 ..< actual.state.scrollbackCount {
        #expect(
          actual.state.scrollbackText(index)
            == reference.state.scrollbackText(index)
        )
      }
    }
    #expect(
      reference.state.graphemes.scalars.count > 4
        * GraphemeTable.compactionThreshold
    )
    actual.state.resize(columns: 7, rows: 5)
    reference.state.resize(columns: 7, rows: 5)
    #expect(TestFixture(actual.lines) == TestFixture(reference.lines))
    #expect(actual.state.cursor == reference.state.cursor)
    #expect(actual.state.scrollbackCount == reference.state.scrollbackCount)
    let resizedSnapshot = builder.build(from: &actual.state)
    #expect(TestFixture(resizedSnapshot.text) == TestFixture(reference.lines))
    #expect(TestFixture(retainedSnapshot.text) == TestFixture(retainedText))
    for index in 0 ..< actual.state.scrollbackCount {
      #expect(
        actual.state.scrollbackText(index)
          == reference.state.scrollbackText(index)
      )
    }
  }
}
