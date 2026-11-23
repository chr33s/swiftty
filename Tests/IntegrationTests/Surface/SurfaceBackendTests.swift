import Dispatch
import Foundation
import ScreenProtocol
import SessionCore
import Synchronization
import SwifttyCore
import Testing

@testable import RoamingKit
@testable import TerminalSurface

struct PresentationMapperTests {
  let session = SessionID.random()

  func sample() -> ScreenSnapshot {
    var s = ScreenSnapshot.blank(sessionID: session, columns: 6, rows: 2)
    s.attachmentEpoch = 3
    s.screenRevision = 9
    s.activeBuffer = .alternate
    s.reverseVideo = true
    s.title = "vim"
    s.cursor = ScreenCursor(
      row: 1,
      column: 6,
      visible: false,
      shape: .bar,
      blinking: true
    )
    s.styles = [
      .plain,
      CellStyle(
        foreground: RGBColor(0xFF0000),
        background: RGBColor(0x00FF00),
        underlineColor: RGBColor(0x0000FF),
        attributes: [.bold, .italic, .curlyUnderline, .strikethrough]
      ), CellStyle(attributes: [.inverse, .dottedUnderline, .overline]),
      CellStyle(attributes: [.doubleUnderline, .faint, .invisible, .blink]),
      CellStyle(attributes: [.dashedUnderline]),
    ]
    s.cells[0] = [
      ScreenCell("e\u{301}", width: 1, style: 1),
      ScreenCell("界", width: 2, style: 2), .continuation,
      ScreenCell("👍🏽", width: 2, style: 3), ScreenCell("", width: 0, style: 3),
      ScreenCell("x", width: 1, style: 4),
    ]
    s.wrapped = [true, false]
    s.cells[1][0] = ScreenCell("y")
    return s
  }

  @Test
  func `mapping preserves cells widths styles cursor and screen flags`() throws
  {
    let frame = try PresentationMapper.frame(from: sample())
    #expect(frame.columns == 6 && frame.rows == 2)
    #expect(frame.cells.count == 12)
    #expect(frame.cells[0].text == "e\u{301}")
    #expect(frame.cells.prefix(6).map(\.width) == [1, 2, 0, 2, 0, 1])
    #expect(frame.cells.prefix(6).map(\.style) == [1, 2, 0, 3, 3, 4])
    #expect(frame.cells[3].text == "👍🏽")
    #expect(frame.wrapped == [true, false])
    #expect(frame.cursorX == 6 && frame.cursorY == 1)
    #expect(!frame.cursorVisible)
    #expect(frame.cursorStyle == .bar)
    #expect(frame.cursorBlinking)
    #expect(frame.reverseVideo)
    #expect(frame.alternateScreen)
    #expect(frame.title == "vim")

    let styles = frame.styles
    #expect(styles[0] == PresentationFrame.Style())
    #expect(styles[1].foreground == 0xFF0000)
    #expect(styles[1].background == 0x00FF00)
    #expect(styles[1].underlineColor == 0x0000FF)
    #expect(
      styles[1].flags == [
        .bold, .italic, .underline, .underlineStyleA, .strikethrough,
      ]
    )
    #expect(
      styles[2].flags == [.inverse, .underline, .underlineStyleB, .overline]
    )
    #expect(styles[3].flags == [.doubleUnderline, .faint, .invisible, .blink])
    #expect(
      styles[4].flags == [.underline, .underlineStyleA, .underlineStyleB]
    )
    #expect(styles.allSatisfy { $0.flags.isDisjoint(with: .structural) })
  }

  @Test
  func `malformed snapshots are rejected before mapping`() {
    var bad = sample()
    bad.cells[0][2] = ScreenCell("z")  // wide lead without continuation
    #expect(throws: SnapshotValidationError.self) {
      try PresentationMapper.frame(from: bad)
    }
    var cursor = sample()
    cursor.cursor.row = 5
    #expect(throws: SnapshotValidationError.cursorOutOfRange) {
      try PresentationMapper.frame(from: cursor)
    }
  }

  @Test
  func `frame wire round trip keeps the screen's text and geometry`() throws {
    let payload = try rstFrameRecord(sample())
    guard case let .screen(decoded)? = RoamingClient.decodeRecord(payload)
    else {
      Issue.record("not a screen")
      return
    }
    #expect(decoded.snapshot.textLines == sample().textLines)
    #expect(decoded.snapshot.wrapped == sample().wrapped)
    #expect(decoded.frame.columns == sample().columns)
    #expect(RoamingClient.decodeRecord(Array(payload.dropLast())) == nil)
  }

  @Test
  func `local copy reads the displayed frame`() {
    let frame = PresentationMapper.map(sample())
    let all = SurfaceSelection(start: (0, 0), end: (1, 5))
    // Row 0 soft-wraps into row 1: no newline between them.
    #expect(frame.text(in: all) == "e\u{301}界👍🏽xy")
    #expect(frame.text(in: SurfaceSelection(start: (0, 1), end: (0, 2))) == "界")
  }

  @Test
  func `semantic input maps to RST operations and local encoder input`() {
    let key = SemanticKey(.character("c"), modifiers: [.control])
    #expect(SurfaceInput.key(key).operation == .key(key))
    #expect(SurfaceInput.text("é").operation == .committedText("é"))
    #expect(SurfaceInput.paste("p").operation == .paste("p"))
    guard case let .key(event) = SurfaceInput.key(key).terminalInput else {
      Issue.record("expected key")
      return
    }
    #expect(event.key == .character("c"))
    #expect(event.modifiers == .control)
  }
}

struct SSHStreamBackendTests {
  @Test
  func `slow parsing stops network reads at the output window`() async throws {
    let session = TerminalSession(columns: 80, rows: 24)
    let parsed = Mutex(0)
    session.onProgramOutput = { bytes in parsed.withLock { $0 += bytes.count } }
    let channel = FakeByteChannel()
    let window = 64 * 1024
    let chunk = 16 * 1024
    let backend = SSHStreamBackend(
      channel: channel,
      session: session,
      outputWindow: window
    )
    backend.start()

    // Stall the parser: block the session queue.
    let gate = DispatchSemaphore(value: 0)
    session.mutateAsync { _ in gate.wait() }
    let total = 64 * chunk
    for _ in 0 ..< 64 {
      channel.feed(Array(repeating: UInt8(ascii: "x"), count: chunk))
    }
    try await Task.sleep(for: .milliseconds(50))
    #expect(channel.delivered <= window + chunk)
    #expect(backend.unparsedBytes <= window + chunk)
    #expect(backend.unparsedBytes == channel.delivered)

    gate.signal()
    #expect(await eventually { channel.delivered == total })
    #expect(await eventually { backend.unparsedBytes == 0 })
    #expect(parsed.withLock { $0 } == total)
    #expect(backend.peakUnparsedBytes <= window + chunk)
    await backend.close()
  }

  @Test
  func `input replies resize and exit flow through the channel`() async throws {
    let session = TerminalSession(columns: 80, rows: 24)
    let channel = FakeByteChannel()
    let backend = SSHStreamBackend(channel: channel, session: session)
    let changes = Mutex<[SurfaceLifecycle]>([])
    backend.onLifecycleChange = { c in changes.withLock { $0.append(c) } }
    backend.start()
    #expect(backend.lifecycle == .active)
    #expect(backend.capabilities.remoteClipboardWrites == false)
    #expect(backend.capabilities.localProcess == false)

    #expect(await backend.submit(.text("ls")) == .accepted(sequence: nil))
    #expect(
      await backend.submit(.key(SemanticKey(.enter)))
        == .accepted(sequence: nil)
    )
    #expect(await eventually { channel.written == Array("ls\r".utf8) })

    // A cursor position query is answered once, over the channel.
    channel.feed(Array("ab\u{1B}[6n".utf8))
    #expect(
      await eventually { channel.written == Array("ls\r\u{1B}[1;3R".utf8) }
    )

    await backend.proposeGrid(columns: 100, rows: 30)
    #expect(
      await eventually { channel.resizes == [GridSize(columns: 100, rows: 30)] }
    )
    #expect(session.withState { $0.columns } == 100)

    channel.exit(.exited(0))
    #expect(backend.lifecycle == .exited(0))
    #expect(await backend.submit(.text("x")) == .refused(.closed))
    #expect(changes.withLock { $0 } == [.active, .exited(0)])
  }

  @Test
  func `a view resizing the session directly resizes the remote PTY once`()
    async
  {
    let session = TerminalSession(columns: 80, rows: 24)
    let channel = FakeByteChannel()
    let backend = SSHStreamBackend(channel: channel, session: session)
    backend.start()
    // Views call `session.resize` themselves on layout.
    session.resize(columns: 120, rows: 40)
    #expect(
      await eventually { channel.resizes == [GridSize(columns: 120, rows: 40)] }
    )
    // Output batches that leave the grid alone send nothing more.
    channel.feed(Array("hello".utf8))
    session.resize(columns: 120, rows: 40)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(channel.resizes == [GridSize(columns: 120, rows: 40)])
    await backend.close()
  }

  @Test
  func `parsed program output records when the screen was installed`()
    async throws
  {
    let session = TerminalSession(columns: 20, rows: 5)
    let channel = FakeByteChannel()
    let backend = SSHStreamBackend(channel: channel, session: session)
    let installed = Mutex<[Date]>([])
    backend.onScreenInstalled = { date in installed.withLock { $0.append(date) }
    }
    backend.start()
    channel.feed(Array("hi".utf8))
    #expect(await eventually { !installed.withLock { $0.isEmpty } })
    #expect(session.withState { $0.screenLines.joined().contains("hi") })
    let count = installed.withLock { $0.count }
    session.resize(columns: 30, rows: 6)
    try await Task.sleep(for: .milliseconds(40))
    #expect(installed.withLock { $0.count } == count)
    await backend.close()
  }
}

#if os(macOS) && !targetEnvironment(macCatalyst)
struct LocalPTYBackendTests {
  @Test
  func `local PTY backend runs a shell with full capabilities`() async throws {
    let backend = LocalPTYBackend(
      session: TerminalSession(columns: 40, rows: 5)
    )
    #expect(backend.capabilities == .full)
    var configuration = SessionConfiguration()
    configuration.command = ["/bin/sh"]
    try backend.start(configuration)
    #expect(backend.lifecycle == .active)
    #expect(await backend.submit(.text("exit 7\n")) == .accepted(sequence: nil))
    #expect(await eventually { backend.lifecycle == .exited(7) })
  }
}
#endif

struct FakeByteChannelTests {
  @Test(arguments: [false, true])
  func exitWaitsForCreditHeldOutputAndIsDeliveredOnce(_ beforeStart: Bool) {
    let channel = FakeByteChannel()
    let events = Mutex<[String]>([])
    let handler = TerminalChannelHandler(
      onOutput: { bytes in events.withLock { $0.append("output \(bytes)") } },
      onExit: { exit in events.withLock { $0.append("exit \(exit)") } }
    )
    if !beforeStart { channel.start(handler) }
    channel.feed([1, 2, 3])
    channel.feed([4, 5])
    channel.exit(.exited(7))
    channel.exit(.exited(42))
    if beforeStart { channel.start(handler) }
    #expect(events.withLock { $0.isEmpty })
    channel.grantCredit(3)
    #expect(events.withLock { $0 } == ["output [1, 2, 3]"])
    channel.grantCredit(2)
    #expect(
      events.withLock { $0 } == [
        "output [1, 2, 3]", "output [4, 5]", "exit exited(7)",
      ]
    )
    channel.feed([6])
    channel.grantCredit(1)
    channel.exit(.exited(99))
    #expect(events.withLock { $0.count } == 3)
  }

  @Test
  func reentrantExitCannotOvertakeTheCurrentOutputCallback() {
    let channel = FakeByteChannel()
    let events = Mutex<[String]>([])
    channel.start(
      TerminalChannelHandler(
        onOutput: { [weak channel] bytes in
          events.withLock { $0.append("begin \(bytes)") }
          if bytes == [1] {
            channel?.feed([2])
            channel?.exit(.exited(7))
            channel?.exit(.exited(42))
          }
          events.withLock { $0.append("end \(bytes)") }
        },
        onExit: { exit in events.withLock { $0.append("exit \(exit)") } }
      )
    )
    channel.grantCredit(2)
    channel.feed([1])
    #expect(
      events.withLock { $0 } == [
        "begin [1]", "end [1]", "begin [2]", "end [2]", "exit exited(7)",
      ]
    )
  }
}
