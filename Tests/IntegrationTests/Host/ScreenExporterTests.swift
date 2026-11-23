#if os(macOS)
import ScreenProtocol
import SessionCore
import SwiftMuxExport
import SwiftMuxProtocol
import SwifttyCore
@testable import TerminalHost
import TestSupport
import Testing

private let esc = "\u{1B}"
private let session = SessionID(bytes: Array(repeating: 9, count: 16))!

private func export(
  _ input: String,
  columns: Int = 20,
  rows: Int = 6
) throws -> ScreenSnapshot {
  var configuration = SessionConfiguration()
  configuration.scrollbackLimitRows = 0
  configuration.scrollbackLimitBytes = 0
  let terminal = TerminalSession(
    columns: columns,
    rows: rows,
    configuration: configuration
  )
  terminal.feed(Array(input.utf8))
  // The roaming path: the worker's frame (its own budgets), the host's
  // RST/1 profile, the frame wire format and the client's mapping.
  let worker = try terminal.withState {
    try FrameExporter.frame(
      from: $0.captureOwnedWindow(top: nil),
      identity: .unbound,
      limits: .standard
    )
  }
  let (frame, header) = try #require(
    ScreenExporter.frame(
      from: worker,
      stamp: .init(sessionID: session, attachmentEpoch: 3, screenRevision: 7)
    )
  )
  let payload = try SnapshotFrame.encode(
    frame: [UInt8](SMXB.encode(frame, envelope: .rst(header.bytes)))
  )
  let snapshot = try decodeScreen(payload)
  try snapshot.validate()
  return snapshot
}

struct ScreenExporterTests {
  @Test
  func `a full worker style table survives to the client`() throws {
    // Every style a worker frame can carry: the plain style and the rest
    // distinct truecolors, on the largest RST/1 grid.
    let distinct = MuxLimits.standard.maxStyles - 1
    var input = ""
    for index in 0 ..< RSTLimits.maxColumns * RSTLimits.maxRows {
      let color = index % distinct
      input += "\(esc)[38;2;0;\(color >> 8);\(color & 255)mX"
    }
    let snapshot = try export(
      input,
      columns: RSTLimits.maxColumns,
      rows: RSTLimits.maxRows
    )
    #expect(snapshot.styles.count == distinct + 1)
    for y in 0 ..< snapshot.rows {
      for x in 0 ..< snapshot.columns {
        let index = (y * snapshot.columns + x) % distinct
        let cell = snapshot.cells[y][x]
        #expect(cell.text == "X")
        #expect(
          snapshot.styles[cell.style].foreground == RGBColor(UInt32(index))
        )
      }
    }
  }

  @Test
  func `graphemes keep complete text and server widths`() throws {
    let s = try export("e\u{301}界👩‍👩‍👧x")
    let row = s.cells[0]
    #expect(row[0] == ScreenCell("e\u{301}", width: 1, style: 0))
    #expect(row[1] == ScreenCell("界", width: 2, style: 0))
    #expect(row[2].width == 0 && row[2].text.isEmpty)
    #expect(row[3].text == "👩‍👩‍👧" && row[3].width == 2)
    #expect(row[4].width == 0)
    #expect(row[5].text == "x")
    #expect(s.columns == 20 && s.rows == 6)
    #expect(s.sessionID == session && s.attachmentEpoch == 3)
    #expect(s.screenRevision == 7)
  }

  @Test
  func `colors resolve through the palette and defaults stay nil`() throws {
    let s = try export(
      "\(esc)[31mR\(esc)[38;2;1;2;3mT\(esc)[48;5;21mB\(esc)[0mD"
    )
    let row = s.cells[0]
    let palette = Palette.standard
    #expect(s.styles[row[0].style].foreground == RGBColor(palette.colors[1]))
    #expect(s.styles[row[0].style].background == nil)
    #expect(s.styles[row[1].style].foreground == RGBColor(0x010203))
    #expect(s.styles[row[2].style].background == RGBColor(0x0000FF))
    #expect(s.styles[row[2].style].foreground == RGBColor(0x010203))
    #expect(s.styles[row[3].style] == .plain)
    #expect(s.styles[0] == .plain)
    // Deduplicated: every blank cell shares the plain style.
    #expect(s.styles.count == 4)
  }

  @Test
  func `attributes map to the presentation profile`() throws {
    let s = try export(
      "\(esc)[1;3;4:3;9;53;58;2;10;20;30mX\(esc)[0m\(esc)[7mI\(esc)[0m"
        + "\(esc)[2;5;8;21mF\(esc)[0m\(esc)[4:4mo\(esc)[4:5ma\(esc)[0m"
    )
    let row = s.cells[0]
    let x = s.styles[row[0].style]
    #expect(
      x.attributes == [
        .bold, .italic, .curlyUnderline, .strikethrough, .overline,
      ]
    )
    #expect(x.underlineColor == RGBColor(0x0A141E))
    #expect(s.styles[row[1].style].attributes == [.inverse])
    #expect(
      s.styles[row[2].style].attributes == [
        .faint, .blink, .invisible, .doubleUnderline,
      ]
    )
    #expect(s.styles[row[3].style].attributes == [.dottedUnderline])
    #expect(s.styles[row[4].style].attributes == [.dashedUnderline])
  }

  @Test
  func `wraps and wide characters that do not fit`() throws {
    let s = try export("abcdefg\r\nabcd界", columns: 5, rows: 4)
    #expect(s.wrapped == [true, false, true, false])
    #expect(s.textLines == ["abcde", "fg", "abcd", "界"])
    // The padding head left by the wide character is a blank cell.
    #expect(s.cells[2][4] == ScreenCell("", width: 1, style: 0))
    #expect(s.cells[3][0].width == 2 && s.cells[3][1].width == 0)
  }

  @Test
  func `cursor, title, modes and alternate screen`() throws {
    let s = try export(
      "\(esc)]0;my\u{7F}title\u{07}\(esc)[5 q\(esc)[?5h\(esc)[?1049hALT"
        + "\(esc)[3;4H\(esc)[?25l"
    )
    #expect(s.activeBuffer == .alternate)
    #expect(s.textLines.first == "ALT")
    #expect(
      s.cursor
        == ScreenCursor(
          row: 2,
          column: 3,
          visible: false,
          shape: .bar,
          blinking: true
        )
    )
    #expect(s.title == "mytitle")
    #expect(s.reverseVideo)

    let primary = try export("main\(esc)[?1049hALT\(esc)[?1049l")
    #expect(primary.activeBuffer == .primary)
    #expect(primary.textLines.first == "main")
    #expect(primary.cursor.visible && primary.cursor.shape == .block)
  }

  @Test
  func `long graphemes and titles are bounded`() throws {
    // The longest cluster a worker frame carries arrives whole; a longer
    // one is shown as the replacement character, not a missing screen.
    let budget = MuxLimits.standard.maxGraphemeScalars
    let fits = String(repeating: "\u{301}", count: budget - 1)
    let overlong = String(repeating: "\u{301}", count: budget + 8)
    let s = try export(
      "a\(overlong)b\(fits)c\(esc)]2;\(String(repeating: "é", count: 600))\u{07}"
    )
    #expect(s.cells[0][0].text == RSTLimits.graphemePlaceholder)
    #expect(s.cells[0][1].text == "b" + fits)
    #expect(s.cells[0][2].text == "c")
    #expect(s.title.utf8.count <= RSTLimits.maxTitleBytes)
    #expect(s.title == String(repeating: "é", count: 512))
  }

  @Test
  func `title is cut on a character boundary`() {
    let title = String(repeating: "a", count: 1023) + "é"
    let bounded = ScreenExporter.boundedTitle(title)
    #expect(bounded == String(repeating: "a", count: 1023))
  }
}
#endif
