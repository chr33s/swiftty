@testable import SwifttyEngine
import Testing

/// The OSC fast paths: the link table's hash index and the input-line
/// hint that spares `clearInputLine` its scan.
struct OSCFastPathTests {
  private static func inputLineRows(_ vt: borrowing VT) -> [Int] {
    var flagged: [Int] = []
    let history = vt.state.grid.historyCount
    for i in 0 ..< history where vt.state.grid.isHistoryInputLine(i) {
      flagged.append(i)
    }
    for y in 0 ..< vt.state.rows where vt.state.grid.isInputLine(y) {
      flagged.append(history + y)
    }
    return flagged
  }

  @Test(arguments: [1, 7, 4096] as [UInt64])
  func `hash index matches a dictionary`(seed: UInt64) {
    var state = seed
    func next(_ bound: Int) -> Int {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Int((state >> 33) % UInt64(bound))
    }
    // Keys that share their low or high bits, and 0 and UInt64.max.
    let keys: [UInt64] = (0 ..< 300)
      .map { i in
        switch i % 4 {
        case 0: UInt64(i) << 40
        case 1: UInt64(i)
        case 2: UInt64(i) &* 0x9E37_79B9_7F4A_7C15
        default: i == 3 ? 0 : (i == 7 ? .max : UInt64(i) << 52 | 0xFFFF)
        }
      }
    var index = HashIndex()
    var reference: [UInt64: UInt32] = [:]
    for step in 0 ..< 20_000 {
      let key = keys[next(keys.count)]
      // Mostly churn, as links open and close, with growth phases.
      if next(3) == 0 {
        index[key] = nil
        reference[key] = nil
      } else {
        index[key] = UInt32(step)
        reference[key] = UInt32(step)
      }
      if step % 997 == 0 || step == 19_999 {
        #expect(index.count == reference.count)
        for k in keys { #expect(index[k] == reference[k]) }
        let entries = index.entries.sorted { $0.key < $1.key }
        let expected = reference.sorted { $0.key < $1.key }
        #expect(entries.map(\.key) == expected.map(\.key))
        #expect(entries.map(\.value) == expected.map(\.value))
      }
    }
    for k in keys { index[k] = nil }
    #expect(index.count == 0)
    #expect(index.entries.isEmpty)
  }

  @Test
  func `each prompt flags one input line and output clears it`() {
    var vt = VT(20, 4, scrollback: 4096)
    for i in 0 ..< 30 {
      vt.feed("\(ESC)]133;A\(ESC)\\$ \(ESC)]133;B\(ESC)\\cmd \(i)\r\n")
      let rows = Self.inputLineRows(vt)
      #expect(rows.count == 1)
      vt.feed("\(ESC)]133;C\(ESC)\\out\r\n")
      #expect(Self.inputLineRows(vt).isEmpty)
    }
  }

  @Test
  func `an input line moved by a scroll region is still cleared`() {
    var vt = VT(20, 6, scrollback: 4096)
    for _ in 0 ..< 10 { vt.feed("old\r\n") }
    // Flag row 3, then move it within a region: its absolute row number
    // stays, so the hint names a row without the flag.
    vt.feed("\(CSI)4;1H\(ESC)]133;A\(ESC)\\$ \(ESC)]133;B\(ESC)\\")
    #expect(Self.inputLineRows(vt).count == 1)
    vt.feed("\(CSI)2;6r\(CSI)2S\(CSI)r")
    #expect(Self.inputLineRows(vt).count == 1)
    vt.feed("\(ESC)]133;C\(ESC)\\")
    #expect(Self.inputLineRows(vt).isEmpty)
    // A new prompt after a missed hint flags only its own row.
    vt.feed("\(CSI)6;1H\(ESC)]133;A\(ESC)\\$ \(ESC)]133;B\(ESC)\\")
    vt.feed("\(CSI)2;6r\(CSI)S\(CSI)r")
    vt.feed("\(ESC)]133;A\(ESC)\\$ \(ESC)]133;B\(ESC)\\")
    let expected = vt.state.grid.historyCount + vt.cursor.y
    #expect(Self.inputLineRows(vt) == [expected])
  }

  @Test
  func `an input line that scrolled into history is cleared`() {
    var vt = VT(20, 3, scrollback: 4096)
    vt.feed("\(ESC)]133;A\(ESC)\\$ \(ESC)]133;B\(ESC)\\cmd\r\n")
    for _ in 0 ..< 5 { vt.feed("out\r\n") }
    let rows = Self.inputLineRows(vt)
    #expect(rows.count == 1)
    let history = vt.state.grid.historyCount
    #expect(rows.allSatisfy { $0 < history })
    vt.feed("\(ESC)]133;C\(ESC)\\")
    #expect(Self.inputLineRows(vt).isEmpty)
  }

  /// Sequences for the split test, passed by index: test arguments are
  /// printed, and the log must hold no terminal controls.
  private static let splitSequences = [
    "\(ESC)]0002;zero title\u{07}", "\(ESC)]00004;1;?\u{07}",
    "\(ESC)]4;2;?\(ESC)\\", "\(ESC)]0000\u{07}", "\(ESC)]10;?\u{07}",
    "\(ESC)]7;file://host/\(String(repeating: "d", count: 300))\u{07}",
    "\(ESC)]00004;1;\(String(repeating: "x", count: 9000))\u{07}\(ESC)]4;1;?\u{07}",
    "\(ESC)]7501;\(String(repeating: "y", count: 5000))\u{07}\(ESC)]2;after\u{07}",
    "\(ESC)]133;A\(ESC)\\$ \(ESC)]133;B\(ESC)\\",
    "\(ESC)]8;id=a;https://example.com\(ESC)\\x\(ESC)]8;;\(ESC)\\",
  ]

  /// The command prefix is copied in runs; splitting it anywhere, with
  /// leading zeros or a long body, must not change what is dispatched.
  @Test(arguments: splitSequences.indices)
  func `an OSC split anywhere matches it whole`(index: Int) {
    let bytes = Array(Self.splitSequences[index].utf8)
    var whole = VT(20, 4)
    whole.feed(bytes: bytes)
    let expected = (
      whole.takeOutput(), whole.state.titleBytes, whole.state.directoryBytes,
      whole.lines
    )
    for split in 1 ..< min(bytes.count, 24) {
      var parts = VT(20, 4)
      parts.feed(bytes: Array(bytes[..<split]))
      parts.feed(bytes: Array(bytes[split...]))
      let output = parts.takeOutput()
      #expect(output == expected.0, "split \(split)")
      let title = parts.state.titleBytes
      #expect(title == expected.1, "split \(split)")
      let directory = parts.state.directoryBytes
      #expect(directory == expected.2, "split \(split)")
      let lines = parts.lines
      #expect(lines == expected.3, "split \(split)")
    }
  }

  @Test(arguments: [1, 3, 6, 64])
  func `a colour OSC with leading zeros keeps its length limit`(split: Int) {
    var fresh = VT()
    fresh.feed("\(ESC)]4;1;?\u{07}")
    let original = fresh.takeOutput()
    // Over the colour limit, so discarded whole: colour 1 stays.
    let long = Array(
      "\(ESC)]00004;1;rgb:ff/00/00;\(String(repeating: "x", count: 9000))\u{07}"
        .utf8
    )
    var vt = VT()
    vt.feed(bytes: Array(long[..<split]))
    vt.feed(bytes: Array(long[split...]))
    vt.feed("\(ESC)]4;1;?\u{07}")
    #expect(vt.takeOutput() == original)
  }

  @Test
  func `titles and directories report only changes`() {
    var vt = VT()
    vt.feed("\(ESC)]0;abc\u{07}")
    do {
      let changed = vt.state.titleChanged;
      #expect(changed)
    }
    vt.state.titleChanged = false
    vt.feed("\(ESC)]0;abc\u{07}")
    do {
      let changed = vt.state.titleChanged;
      #expect(!changed)
    }
    vt.feed("\(ESC)]0;abd\u{07}")
    do {
      let changed = vt.state.titleChanged;
      #expect(changed)
    }
    vt.state.titleChanged = false
    vt.feed("\(ESC)]0;ab\u{07}")
    do {
      let changed = vt.state.titleChanged;
      #expect(changed)
    }
    vt.state.titleChanged = false
    vt.feed("\(ESC)]0;\u{07}")
    do {
      let changed = vt.state.titleChanged;
      #expect(changed)
    }
    vt.state.titleChanged = false
    vt.feed("\(ESC)]0;\u{07}")
    do {
      let changed = vt.state.titleChanged;
      #expect(!changed)
    }
  }
}
