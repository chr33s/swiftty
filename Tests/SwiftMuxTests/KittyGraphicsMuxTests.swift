import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
@testable import SwiftMuxService
@testable import SwiftMuxExport
@testable import SwifttyEngine
import Testing

/// Kitty graphics across SwiftMux (spec.graphics.md §14, KG22/KG23):
/// pane pixel geometry, the frame `images` section, its SMXB encoding and
/// validation, deltas, and pixel fetches.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct KittyGraphicsMuxTests {
  /// A 2×2 RGBA red image transmitted and displayed at the cursor.
  private static let image: String = {
    let pixels: [UInt8] = Array(
      [[UInt8]](repeating: [255, 0, 0, 255], count: 4).joined()
    )
    return "a=T,f=32,s=2,v=2,i=7,q=2;" + Data(pixels).base64EncodedString()
  }()

  private func screenWithImage() -> OwnedScreen {
    var state = TerminalState(columns: 10, rows: 4)
    state.cellPixelSize = (8, 16)
    var parser = Parser()
    let bytes = Array("\u{1B}_G\(Self.image)\u{1B}\\".utf8)
    parser.consume(bytes.span, into: &state)
    return state.captureOwnedScreen()
  }

  @Test
  func `exported frames carry placements that survive SMXB`() throws {
    let screen = screenWithImage()
    #expect(screen.images.count == 1)
    var frame = try FrameExporter.frame(
      from: screen,
      identity: BridgeTests.identity()
    )
    frame.images = FrameExporter.images(from: screen)
    let images = try #require(frame.images)
    #expect(images.cellWidth == 8)
    #expect(images.images.first?.width == 2)
    #expect(images.placements.first?.layer == 2)
    let data = SMXB.encode(frame)
    let decoded = try SMXB.decode(data, limits: .standard)
    guard case let .frame(round) = decoded.payload else {
      Issue.record("not a frame")
      return
    }
    #expect(round.images == frame.images)
  }

  @Test
  func `animated images export their other frames for prefetch`() throws {
    var state = TerminalState(columns: 10, rows: 4)
    state.cellPixelSize = (8, 16)
    var parser = Parser()
    let blue = Data(
      Array([[UInt8]](repeating: [0, 0, 255, 255], count: 4).joined())
    )
    let bytes = Array(
      ("\u{1B}_G\(Self.image)\u{1B}\\"
        + "\u{1B}_Ga=f,i=7,s=2,v=2,q=2;\(blue.base64EncodedString())\u{1B}\\")
        .utf8
    )
    parser.consume(bytes.span, into: &state)
    let screen = state.captureOwnedScreen()
    let images = try #require(FrameExporter.images(from: screen))
    #expect(images.prefetch.count == 1)
    #expect(images.prefetch[0].key != images.images[0].key)
    var frame = try FrameExporter.frame(
      from: screen,
      identity: BridgeTests.identity()
    )
    frame.images = images
    guard
      case let .frame(round) =
        try SMXB.decode(SMXB.encode(frame), limits: .standard).payload
    else {
      Issue.record("not a frame")
      return
    }
    #expect(round.images?.prefetch == images.prefetch)
  }

  @Test
  func `panes advance animations and frames reference each frame in turn`()
    async throws
  {
    let h = try Harness()
    let c = try await MuxConnection.connect(
      endpoint: h.endpoint,
      frontend: .native,
      capabilities: ClientCapabilities.supported.union(.images)
    )
    let blue = Data(
      Array([[UInt8]](repeating: [0, 0, 255, 255], count: 4).joined())
    )
    let frameAPC =
      "\\033_Ga=f,i=7,s=2,v=2,z=60,q=2;\(blue.base64EncodedString())\\033\\\\"
    let play = "\\033_Ga=a,i=7,r=1,z=60,s=3,v=1,q=2\\033\\\\"
    let apc = "\\033_G\(Self.image)\\033\\\\"
    var launch = shellLaunch()
    launch.command = [
      "/bin/sh", "-c", "sleep 0.5; printf '\(apc)\(frameAPC)\(play)'; exec cat",
    ]
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: launch))
      )
    else { throw MuxError(.invalidRequest, "create") }
    try await c.attachAndShow(
      .id(ws.id),
      columns: 40,
      rows: 10,
      cellWidth: 8,
      cellHeight: 16
    )
    let pane = ws.tabs[0].activePane
    let first = try await c.frame(of: pane, label: "animated") {
      $0.images?.prefetch.isEmpty == false
    }
    let shown = try #require(first.images?.images.first?.key)
    let other = try #require(first.images?.prefetch.first?.key)
    // The pane's own clock swaps the shown frame for the other one.
    let next = try await c.frame(of: pane, label: "next frame") {
      $0.images?.images.first?.key == other
    }
    #expect(next.images?.prefetch.first?.key == shown)
  }

  /// Local pixel transfer cost (spec.graphics.md §14.4): a 3840×2160 RGBA
  /// image (33 MB) in 4 MiB `imageChunk` replies. Recorded to decide the
  /// optional shared-memory transfer.
  @Test
  func `a 4K image fetches locally in under a second`() async throws {
    let h = try Harness()
    let c = try await MuxConnection.connect(
      endpoint: h.endpoint,
      frontend: .native,
      capabilities: ClientCapabilities.supported.union(.images)
    )
    let (w, h4k) = (3840, 2160)
    let path = NSTemporaryDirectory() + "swiftty-mux-fetch-\(UUID().uuidString)"
    try Data(count: w * h4k * 4).write(to: URL(fileURLWithPath: path))
    defer { unlink(path) }
    let name = Data(path.utf8).base64EncodedString()
    var launch = shellLaunch()
    launch.command = [
      "/bin/sh", "-c",
      "sleep 0.5; printf '\\033_Ga=T,t=f,f=32,s=\(w),v=\(h4k),i=1,q=2;\(name)\\033\\\\'; exec cat",
    ]
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: launch))
      )
    else { throw MuxError(.invalidRequest, "create") }
    try await c.attachAndShow(
      .id(ws.id),
      columns: 40,
      rows: 10,
      cellWidth: 8,
      cellHeight: 16
    )
    let pane = ws.tabs[0].activePane
    let frame = try await c.frame(of: pane, label: "image") {
      $0.images?.placements.isEmpty == false
    }
    let image = try #require(frame.images?.images.first)
    let start = ContinuousClock.now
    var offset = 0
    while offset < image.byteCount {
      guard
        case let .imageChunk(chunk) = try await c.execute(
          .imageChunk(pane: pane, key: image.key, offset: offset)
        )
      else { throw MuxError(.invalidRequest, "chunk") }
      offset += chunk.bytes.count
    }
    let elapsed = ContinuousClock.now - start
    let seconds =
      Double(elapsed.components.seconds) + Double(
        elapsed.components.attoseconds
      ) / 1e18
    print(
      "kitty-mux-fetch bytes=\(offset) seconds=\(seconds) MB/s=\(Double(offset) / 1_048_576 / seconds)"
    )
    #expect(offset == image.byteCount)
    #expect(elapsed < .seconds(1))
  }

  @Test
  func `validation rejects bad references and geometry`() throws {
    var frame = try FrameExporter.frame(
      from: screenWithImage(),
      identity: BridgeTests.identity()
    )
    var images = try #require(FrameExporter.images(from: screenWithImage()))
    images.placements[0].image = 5
    frame.images = images
    #expect(throws: MuxError.self) {
      try FrameValidator.validate(frame, limits: .standard)
    }
    images.placements[0].image = 0
    images.placements[0].sourceWidth = 99
    frame.images = images
    #expect(throws: MuxError.self) {
      try FrameValidator.validate(frame, limits: .standard)
    }
    images.placements[0].sourceWidth = 2
    images.placements[0].row = 40
    frame.images = images
    #expect(throws: MuxError.self) {
      try FrameValidator.validate(frame, limits: .standard)
    }
  }

  @Test
  func `deltas carry the complete images section`() throws {
    let screen = screenWithImage()
    var base = try FrameExporter.frame(
      from: screen,
      identity: BridgeTests.identity()
    )
    base.rowVersions = Array(repeating: 1, count: screen.rows)
    var next = base
    next.identity.revision = 2
    next.images = FrameExporter.images(from: screen)
    let delta = try #require(
      FrameDeltaBuilder.delta(from: next, base: FrameBaseline(base)!)
    )
    #expect(delta.images == next.images)
    let applied = try FrameDeltaApplier.apply(delta, to: base)
    #expect(applied.images == next.images)
  }

  @Test
  func `image chunks validate offsets and keys`() throws {
    let screen = screenWithImage()
    let pixels = screen.images[0].pixels
    let chunk = try #require(FrameExporter.imageChunk(pixels, offset: 0))
    try chunk.validate(requestedOffset: 0, key: pixels.serial)
    #expect(chunk.bytes.count == 16)
    #expect(throws: MuxError.self) {
      try chunk.validate(requestedOffset: 4, key: pixels.serial)
    }
    #expect(throws: MuxError.self) {
      try chunk.validate(requestedOffset: 0, key: 0)
    }
  }

  @Test
  func `panes report pixel sizes and serve image pixels`() async throws {
    let h = try Harness()
    let c = try await MuxConnection.connect(
      endpoint: h.endpoint,
      frontend: .native,
      capabilities: ClientCapabilities.supported.union(.images)
    )
    #expect(await c.welcome?.features.contains(.kittyGraphics) == true)
    var launch = shellLaunch()
    let apc = "\\033_G\(Self.image)\\033\\\\"
    launch.command = [
      "/bin/sh", "-c",
      "sleep 0.5; stty size; printf '\(apc)'; printf 'done\\n'; exec cat",
    ]
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: launch))
      )
    else { throw MuxError(.invalidRequest, "create") }
    try await c.attachAndShow(
      .id(ws.id),
      columns: 40,
      rows: 10,
      cellWidth: 8,
      cellHeight: 16
    )
    let pane = ws.tabs[0].activePane
    let frame = try await c.frame(of: pane, label: "image") {
      $0.images?.placements.isEmpty == false
    }
    let images = try #require(frame.images)
    #expect(images.cellWidth == 8)
    #expect(images.cellHeight == 16)
    let image = images.images[0]
    guard
      case let .imageChunk(chunk) = try await c.execute(
        .imageChunk(pane: pane, key: image.key, offset: 0)
      )
    else { throw MuxError(.invalidRequest, "chunk") }
    #expect(chunk.image == image)
    #expect(Array(chunk.bytes.prefix(4)) == [255, 0, 0, 255])
    await #expect(throws: MuxError.self) {
      try await c.execute(.imageChunk(pane: pane, key: 999_999_999, offset: 0))
    }
  }

  @Test
  func `clients without the images capability get no section`() async throws {
    let h = try Harness()
    let c = try await h.connect()
    var launch = shellLaunch()
    let apc = "\\033_G\(Self.image)\\033\\\\"
    launch.command = [
      "/bin/sh", "-c", "sleep 0.5; printf '\(apc)done\\n'; exec cat",
    ]
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: launch))
      )
    else { throw MuxError(.invalidRequest, "create") }
    try await c.attachAndShow(
      .id(ws.id),
      columns: 40,
      rows: 10,
      cellWidth: 8,
      cellHeight: 16
    )
    let frame = try await c.frame(of: ws.tabs[0].activePane, label: "done") {
      $0.lines.joined().contains("done")
    }
    #expect(frame.images == nil)
  }
}
