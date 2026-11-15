import Darwin
import Foundation
import RoamingTerminal
import ScreenProtocol
import SessionCore
import SwiftMuxProtocol
import SwifttyEngine
import Synchronization
import TTYKit
import TerminalSurface
import Testing

// The TTY roaming frontend (swroam): frame drawing, input mapping, the
// coalescing sink, and the whole client against the fake host over a
// real pseudo-terminal.

@Suite
struct RoamingTerminalScreenTests {
  private func frame(
    columns: Int,
    rows: Int,
    cells: [PresentationFrame.Cell],
    styles: [PresentationFrame.Style] = [.init()],
    reverseVideo: Bool = false
  ) -> PresentationFrame {
    PresentationFrame(
      columns: columns,
      rows: rows,
      cells: cells,
      wrapped: Array(repeating: false, count: rows),
      styles: styles,
      cursorX: 1,
      cursorY: 0,
      cursorStyle: .bar,
      reverseVideo: reverseVideo
    )
  }

  @Test
  func clipsToTheOuterTerminalAndBlanksACutWideCell() {
    // "a界" in a 3-column host row shown on a 2-column terminal.
    let cells: [PresentationFrame.Cell] = [
      .init(text: "a"), .init(text: "界", width: 2), .init(text: "", width: 0),
      .init(text: "b"), .init(text: "c"), .init(text: "d"),
    ]
    let screen = ScreenBuffer(
      frame(columns: 3, rows: 2, cells: cells),
      columns: 2,
      rows: 3
    )
    #expect(screen.text(row: 0) == "a")
    #expect(screen[1, 0].width == 1)
    #expect(screen.text(row: 1) == "bc")
    #expect(screen.text(row: 2) == "")
    #expect(screen.cursor?.x == 1)
    #expect(screen.cursor?.style == CursorStyle.bar.rawValue)
  }

  @Test
  func mapsColorsAndDropsStructuralFlags() {
    let style = PresentationFrame.Style(
      foreground: 0x11_2233,
      flags: [.bold, .spacerTail]
    )
    let screen = ScreenBuffer(
      frame(
        columns: 1,
        rows: 1,
        cells: [.init(text: "x", style: 1)],
        styles: [.init(), style],
        reverseVideo: true
      ),
      columns: 1,
      rows: 1
    )
    let outer = screen[0, 0].style
    #expect(outer.foreground == .rgb(0x11_2233))
    #expect(outer.background == .default)
    #expect(outer.flags == CellFlags([.bold, .inverse]).rawValue)
  }
}

@Suite
struct RoamingTerminalInputTests {
  @Test
  func controlKeysBecomeSemanticKeys() {
    #expect(
      SurfaceInput(
        DecodedInput.key(.character(UInt32(UInt8(ascii: "c"))), .control)
      ) == .key(SemanticKey(.character("c"), modifiers: .control))
    )
    #expect(
      SurfaceInput(DecodedInput.key(.up, .shift))
        == .key(SemanticKey(.up, modifiers: .shift))
    )
    #expect(SurfaceInput(DecodedInput.text("ls")) == .text("ls"))
  }

  @Test
  func refusesInputTheHostMustNotReceive() {
    #expect(SurfaceInput(DecodedInput.text("")) == nil)
    #expect(
      SurfaceInput(DecodedInput.paste("rm -rf /tmp/x", truncated: true)) == nil
    )
    #expect(SurfaceInput(DecodedInput.key(.function(13), [])) == nil)
    #expect(SurfaceInput(DecodedInput.key(.character(0x03), [])) == nil)
  }
}

@Suite
struct TTYPresentationSinkTests {
  private func frame(_ text: String) -> PresentationFrame {
    PresentationFrame(
      columns: 1,
      rows: 1,
      cells: [.init(text: text)],
      wrapped: [false],
      styles: [.init()],
      cursorX: 0,
      cursorY: 0
    )
  }

  @Test
  func notifiesOnceUntilReadAndKeepsOnlyTheNewest() {
    let sink = TTYPresentationSink()
    let notifications = Mutex(0)
    sink.setFrameHandler { notifications.withLock { $0 += 1 } }
    #expect(sink.install(frame("a")))
    #expect(sink.install(frame("b")))
    #expect(notifications.withLock { $0 } == 1)
    #expect(sink.take()?.cells.first?.text == "b")
    #expect(sink.install(frame("c")))
    #expect(notifications.withLock { $0 } == 2)
  }

  @Test
  func refusesInvalidFramesAndFramesAfterClose() {
    let sink = TTYPresentationSink()
    var invalid = frame("a")
    invalid.cursorX = 5
    #expect(!sink.install(invalid))
    sink.close()
    #expect(!sink.install(frame("a")))
    #expect(sink.take() == nil)
  }
}

/// Bytes collected from any thread.
final class ByteLog: Sendable {
  private let storage = Mutex<[UInt8]>([])

  var bytes: [UInt8] { storage.withLock { $0 } }

  func append(_ more: ArraySlice<UInt8>) { storage.withLock { $0 += more } }
}

@Suite(.serialized)
struct RoamingTerminalClientTests {
  /// A pseudo-terminal: the client owns the replica as its outer TTY;
  /// the test types into the primary, which a reader drains continuously
  /// as a real terminal would (raw-mode restore waits for that).
  final class PTY: Sendable {
    let primary: Int32
    let replica: Int32
    private let output = ByteLog()
    private let reader: any DispatchSourceRead

    init(columns: Int, rows: Int) throws {
      var primary: Int32 = -1
      var replica: Int32 = -1
      var size = winsize(
        ws_row: UInt16(rows),
        ws_col: UInt16(columns),
        ws_xpixel: 0,
        ws_ypixel: 0
      )
      guard openpty(&primary, &replica, nil, nil, &size) == 0 else {
        throw POSIXFailure("openpty")
      }
      _ = fcntl(primary, F_SETFL, fcntl(primary, F_GETFL) | O_NONBLOCK)
      self.primary = primary
      self.replica = replica
      reader = DispatchSource.makeReadSource(
        fileDescriptor: primary,
        queue: DispatchQueue(label: "pty.primary")
      )
      reader.setEventHandler { [output] in
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
          let n = read(primary, &buffer, buffer.count)
          guard n > 0 else { break }
          output.append(buffer[0 ..< n])
        }
      }
      reader.resume()
    }

    deinit {
      reader.cancel()
      close(primary)
      close(replica)
    }

    func type(_ bytes: [UInt8]) {
      _ = bytes.withUnsafeBytes { write(primary, $0.baseAddress, $0.count) }
    }

    /// Everything the client wrote so far.
    var screen: String { String(decoding: output.bytes, as: UTF8.self) }
  }

  struct Harness: Sendable {
    let host: FakeHost
    let client: RoamingClient
    let pty: PTY
    let terminal: RoamingTerminalClient

    @MainActor
    init() throws {
      host = try FakeHost()
      let sink = TTYPresentationSink()
      client = RoamingClient(
        bootstrapper: FakeBootstrapper(host: host),
        connector: FakeConnector(host: host),
        sink: sink,
        configuration: testConfiguration(),
        timing: TestClock().timing
      )
      pty = try PTY(columns: 20, rows: 4)
      terminal = RoamingTerminalClient(
        client: client,
        sink: sink,
        tty: RawTTY(input: pty.replica, output: pty.replica)
      )
    }

    func run() -> Task<RoamingTerminalClient.Outcome, any Error> {
      let terminal = terminal
      return Task { @MainActor in
        try await terminal.run(.create(GridSize(columns: 20, rows: 4)))
      }
    }

    /// The run's outcome; fails instead of hanging the suite.
    func outcome(
      of run: Task<RoamingTerminalClient.Outcome, any Error>
    ) async throws -> RoamingTerminalClient.Outcome {
      typealias Waiter = CheckedContinuation<
        RoamingTerminalClient.Outcome?, Never
      >
      let result = await withCheckedContinuation { (waiter: Waiter) in
        let once = Mutex<Waiter?>(waiter)
        Task {
          let value = try? await run.value
          once.withLock { $0.take() }?.resume(returning: value)
        }
        Task {
          try? await Task.sleep(for: .seconds(10))
          once.withLock { $0.take() }?.resume(returning: nil)
        }
      }
      return try #require(result, "the terminal client did not finish")
    }

    func active() async -> Bool {
      await eventually { await client.state == .active }
    }
  }

  @Test
  func drawsHostScreensAndSendsTypedText() async throws {
    let h = try await Harness()
    let run = h.run()
    try #require(await h.active())
    let epoch = try #require(await h.host.currentEpoch)
    await h.host.sendScreen(epoch: epoch, revision: 10, text: "hello host")
    // Only changed cells are drawn, so unchanged blanks split the words.
    #expect(
      await eventually {
        h.pty.screen.contains("hello") && h.pty.screen.contains("host")
      }
    )
    h.pty.type(Array("ls".utf8))
    #expect(await eventually { await h.host.text.contains("ls") })
    // Ctrl-^ Ctrl-^ sends one Ctrl-^ (the host sees a control key).
    let before = await h.host.received.count
    h.pty.type([0x1E, 0x1E])
    #expect(await eventually { await h.host.received.count == before + 1 })
    h.pty.type([0x1E, UInt8(ascii: ".")])
    let result = try await h.outcome(of: run)
    #expect(result == .detached(h.host.sessionID))
    #expect(await eventually { await h.host.detachCount == 1 })
    #expect(await h.host.terminateCount == 0)
  }

  @Test
  func escapeKTerminatesTheSession() async throws {
    let h = try await Harness()
    let run = h.run()
    try #require(await h.active())
    h.pty.type([0x1E, UInt8(ascii: "k")])
    #expect(try await h.outcome(of: run) == .terminated)
    #expect(await eventually { await h.host.terminateCount == 1 })
  }

  @Test
  func reportsTheRemoteExitStatus() async throws {
    let h = try await Harness()
    let run = h.run()
    try #require(await h.active())
    await h.host.exit(status: 3)
    #expect(try await h.outcome(of: run) == .exited(3))
  }

  @Test
  func bannerShowsWhileReconnecting() async throws {
    let h = try await Harness()
    let run = h.run()
    try #require(await h.active())
    await h.host.severCurrent()
    #expect(await eventually { h.pty.screen.contains("swroam: ") })
    #expect(await h.active())
    h.pty.type([0x1E, UInt8(ascii: ".")])
    _ = try await h.outcome(of: run)
  }
}
