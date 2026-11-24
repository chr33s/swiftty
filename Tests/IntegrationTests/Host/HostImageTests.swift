#if os(macOS)
import Foundation
import ScreenProtocol
import SessionCore
import SwiftMuxProtocol
import Synchronization
@testable import TerminalHost
import Testing

/// Kitty graphics over RST/1 (spec.graphics.md §16, KG24): the client's
/// cell size reaches the pane, frames carry `images`, pixels arrive on
/// `KGIB/1` streams, and an inventoried digest is aliased, not resent.
@Suite(.timeLimit(.minutes(1)))
struct HostImageTests {
  final class ImageClient: @unchecked Sendable {
    struct State {
      var reader = ControlRecordReader()
      var messages: [ControlMessage] = []
      var frames: [PaneFrame] = []
      var blobs: [ImageBlob] = []
      /// Encoded size of each frame record, in arrival order.
      var frameBytes: [Int] = []
    }

    let connection: InMemoryRSTConnection
    let state = Mutex(State())

    init(_ registry: SessionRegistry) {
      let (client, server) = InMemoryRSTConnection.pair()
      connection = client
      registry.accept(server)
      client.start(
        RSTConnectionHandler(
          onControl: { [self] bytes in
            let messages = state.withLock { s in
              let messages = (try? s.reader.append(bytes)) ?? []
              s.messages += messages
              return messages
            }
            for case let .ping(epoch, nonce) in messages {
              try? await send(.pong(epoch: epoch, nonce: nonce))
            }
          },
          onSnapshot: { [self] bytes in
            if ImageBlob.isRecord(bytes) {
              if let blob = try? ImageBlob.decode(bytes) {
                state.withLock { $0.blobs.append(blob) }
              }
              return
            }
            guard
              case let .frame(frame, header)? = try? SnapshotFrame.decodeRecord(
                bytes,
                allowsImages: true
              )
            else { return }
            state.withLock {
              $0.frames.append(frame)
              $0.frameBytes.append(bytes.count)
            }
            try? await send(
              .screenAck(
                epoch: header.attachmentEpoch,
                screenRevision: header.screenRevision
              )
            )
          },
          onClosed: { _ in }
        )
      )
    }

    func send(_ message: ControlMessage) async throws {
      try await connection.sendControl(ControlRecord.encode(message))
    }

    func attach(
      _ grant: BootstrapGrant,
      inventory: [String] = [],
      variant: ImageVariant = .full,
      cell: (width: Int, height: Int)? = (8, 16)
    ) async throws {
      try await send(
        .attach(
          .init(
            sessionID: grant.sessionID,
            serverInstanceID: grant.serverInstanceID,
            writerID: grant.writerID,
            applicationToken: grant.applicationToken,
            // Full screens only: this client applies no deltas.
            features: RSTFeatures.supported.subtracting(.screenDeltas),
            imageInventory: inventory,
            imageVariant: variant,
            cellWidth: cell?.width,
            cellHeight: cell?.height
          )
        )
      )
      _ = try await hostEventually("Attached") {
        state.withLock { s in
          s.messages.first { if case .attached = $0 { true } else { false } }
        }
      }
    }
  }

  /// A 16×16 opaque red RGBA image, displayed at the cursor.
  static var command: String {
    let pixels = Array(
      [[UInt8]](repeating: [255, 0, 0, 255], count: 256).joined()
    )
    let body =
      "a=T,f=32,s=16,v=16,i=3,q=2;" + Data(pixels).base64EncodedString()
    return "printf '\\033_G\(body)\\033\\\\'; echo shown"
  }

  static func input(
    _ sequence: UInt64,
    _ operation: InputOperation
  ) -> ControlMessage {
    .input(.init(attachmentEpoch: 1, sequence: sequence, operation: operation))
  }

  @Test
  func `frames carry images and pixels arrive as KGIB records`() async throws {
    try await withRegistry { registry in
      let grant = try await registry.create(
        grid: GridSize(columns: 40, rows: 8)
      )
      let client = ImageClient(registry)
      defer { client.connection.close() }
      try await client.attach(grant)
      _ = try await hostEventually("prompt") {
        client.state.withLock {
          $0.frames.last { $0.lines.contains { $0.contains("$") } }
        }
      }
      try await client.send(Self.input(1, .committedText(Self.command)))
      try await client.send(Self.input(2, .key(SemanticKey(.enter))))
      let frame = try await hostEventually("image frame") {
        client.state.withLock {
          $0.frames.last { $0.images?.placements.isEmpty == false }
        }
      }
      let images = try #require(frame.images)
      #expect(images.cellWidth == 8)
      #expect(images.cellHeight == 16)
      let key = images.images[0].key
      let blob = try await hostEventually("blob") {
        client.state.withLock { $0.blobs.first { $0.key == key } }
      }
      #expect(blob.width == 16)
      #expect(blob.codec == .png)
      let rgba = try #require(ImageBlobCodec.decode(blob))
      #expect(Array(rgba.prefix(4)) == [255, 0, 0, 255])
      // Asked again, the host resends it.
      let before = client.state.withLock { $0.blobs.count }
      try await client.send(
        .imageRequest(epoch: 1, keys: [key], variant: .reduced)
      )
      let again = try await hostEventually("resent") {
        client.state.withLock { $0.blobs.count > before ? $0.blobs.last : nil }
      }
      #expect(again.variant == .reduced)
      #expect(again.digest == blob.digest)
    }
  }

  @Test
  func `inventoried digests are aliased instead of resent`() async throws {
    let rgba = Array(
      [[UInt8]](repeating: [255, 0, 0, 255], count: 256).joined()
    )
    let digest = ImageBlobCodec.digest(rgba: rgba)
      .map { String(format: "%02x", $0) }.joined()
    try await withRegistry { registry in
      let grant = try await registry.create(
        grid: GridSize(columns: 40, rows: 8)
      )
      let client = ImageClient(registry)
      defer { client.connection.close() }
      try await client.attach(grant, inventory: [digest])
      _ = try await hostEventually("prompt") {
        client.state.withLock {
          $0.frames.last { $0.lines.contains { $0.contains("$") } }
        }
      }
      try await client.send(Self.input(1, .committedText(Self.command)))
      try await client.send(Self.input(2, .key(SemanticKey(.enter))))
      let alias = try await hostEventually("alias") {
        client.state.withLock { s -> (UInt64, String)? in
          for case let .imageAlias(_, key, d) in s.messages { return (key, d) }
          return nil
        }
      }
      #expect(alias.1 == digest)
      #expect(client.state.withLock { $0.blobs.isEmpty })
    }
  }

  /// A client that learns its cell size after attaching (layout settles
  /// later) sends `CellSize`; the pane's PTY then reports pixels, which
  /// `kitten icat` requires.
  @Test
  func `a cell size sent after attaching reaches the pane PTY`() async throws {
    try await withRegistry { registry in
      let grant = try await registry.create(
        grid: GridSize(columns: 40, rows: 8)
      )
      let client = ImageClient(registry)
      defer { client.connection.close() }
      try await client.attach(grant, cell: nil)
      _ = try await hostEventually("prompt") {
        client.state.withLock {
          $0.frames.last { $0.lines.contains { $0.contains("$") } }
        }
      }
      try await client.send(.cellSize(epoch: 1, width: 9, height: 18))
      try await Task.sleep(for: .milliseconds(200))
      let probe =
        "python3 -c 'import fcntl,termios,struct;"
        + "r=struct.unpack(\"HHHH\",fcntl.ioctl(0,termios.TIOCGWINSZ,bytes(8)));"
        + "print(\"px=%dx%d\"%(r[2],r[3]))'"
      try await client.send(Self.input(1, .committedText(probe)))
      try await client.send(Self.input(2, .key(SemanticKey(.enter))))
      _ = try await hostEventually("pixels") {
        client.state.withLock {
          $0.frames.last { $0.lines.contains { $0.contains("px=360x144") } }
        }
      }
    }
  }

  /// The same pixels under two keys (two images, or a new key for
  /// unchanged pixels) go once; the other key is an alias, even when both
  /// encode at the same time (found by the KG28 iPhone run).
  @Test
  func `identical pixels under two keys are sent once`() async throws {
    try await withRegistry { registry in
      let grant = try await registry.create(
        grid: GridSize(columns: 40, rows: 8)
      )
      let client = ImageClient(registry)
      defer { client.connection.close() }
      try await client.attach(grant)
      _ = try await hostEventually("prompt") {
        client.state.withLock {
          $0.frames.last { $0.lines.contains { $0.contains("$") } }
        }
      }
      // Two images with the same pixels, both on screen.
      let second = Self.command.replacingOccurrences(of: "i=3", with: "i=4")
      #expect(second != Self.command)
      try await client.send(
        Self.input(1, .committedText(Self.command + "; " + second))
      )
      try await client.send(Self.input(2, .key(SemanticKey(.enter))))
      _ = try await hostEventually("two images") {
        client.state.withLock {
          $0.frames.last { ($0.images?.images.count ?? 0) >= 2 }
        }
      }
      _ = try await hostEventually("alias") {
        client.state.withLock { s -> String? in
          for case let .imageAlias(_, _, d) in s.messages { return d }
          return nil
        }
      }
      try await Task.sleep(for: .milliseconds(300))
      #expect(client.state.withLock { $0.blobs.count } == 1)
    }
  }

  /// KG28's property without the radio: a client that roams 20 times
  /// (each a new connection resuming the session with its cached digests)
  /// keeps its image and is never sent the pixels again.
  @Test
  func `twenty reattachments with a cached image resend no pixels`()
    async throws
  {
    try await withRegistry { registry in
      let grant = try await registry.create(
        grid: GridSize(columns: 40, rows: 8)
      )
      let first = ImageClient(registry)
      try await first.attach(grant)
      _ = try await hostEventually("prompt") {
        first.state.withLock {
          $0.frames.last { $0.lines.contains { $0.contains("$") } }
        }
      }
      try await first.send(Self.input(1, .committedText(Self.command)))
      try await first.send(Self.input(2, .key(SemanticKey(.enter))))
      let blob = try await hostEventually("blob") {
        first.state.withLock { $0.blobs.first }
      }
      first.connection.close()
      var aliases = 0
      for round in 1 ... 20 {
        let client = ImageClient(registry)
        defer { client.connection.close() }
        try await client.attach(grant, inventory: [blob.digestHex])
        let frame = try await hostEventually("frame \(round)") {
          client.state.withLock {
            $0.frames.last { $0.images?.placements.isEmpty == false }
          }
        }
        #expect(frame.images?.images.first?.key != nil)
        let alias = try await hostEventually("alias \(round)") {
          client.state.withLock { s -> String? in
            for case let .imageAlias(_, _, d) in s.messages { return d }
            return nil
          }
        }
        #expect(alias == blob.digestHex)
        #expect(
          client.state.withLock { $0.blobs.isEmpty },
          "round \(round) resent pixels"
        )
        aliases += 1
      }
      #expect(aliases == 20)
    }
  }

  /// §21.3: typing with one image on screen sends no pixels after the
  /// first blob, and each screen grows only by the fixed `images` section.
  @Test
  func `typing beside an image resends no pixels`() async throws {
    try await withRegistry { registry in
      let grant = try await registry.create(
        grid: GridSize(columns: 80, rows: 24)
      )
      let client = ImageClient(registry)
      defer { client.connection.close() }
      try await client.attach(grant)
      _ = try await hostEventually("prompt") {
        client.state.withLock {
          $0.frames.last { $0.lines.contains { $0.contains("$") } }
        }
      }
      try await client.send(Self.input(1, .committedText(Self.command)))
      try await client.send(Self.input(2, .key(SemanticKey(.enter))))
      _ = try await hostEventually("blob") {
        client.state.withLock { $0.blobs.first }
      }
      try await Task.sleep(for: .milliseconds(200))
      let start = client.state.withLock { $0.frames.count }
      for (i, c) in "echo typing-done".enumerated() {
        try await client.send(
          Self.input(UInt64(3 + i), .committedText(String(c)))
        )
        try await Task.sleep(for: .milliseconds(15))
      }
      _ = try await hostEventually("typed") {
        client.state.withLock {
          $0.frames.last { $0.lines.contains { $0.contains("typing-done") } }
        }
      }
      let (blobs, typed, frames) = client.state.withLock {
        (
          $0.blobs.count, Array($0.frameBytes[start...]),
          Array($0.frames[start...])
        )
      }
      #expect(blobs == 1)
      #expect(frames.allSatisfy { $0.images?.placements.count == 1 })
      // 4 + 4 + 17 per image + 4 + 56 per placement + 4 prefetch count, in
      // the section framing: well under any pixel payload.
      let section = 8 + 4 + 17 + 4 + 56 + 4
      #expect(typed.allSatisfy { $0 < 4096 })
      print(
        "kitty-rst-typing frames=\(typed.count) max_bytes=\(typed.max() ?? 0) images_section_bytes=\(section)"
      )
    }
  }

  @Test
  func `with images off placements arrive without pixels until loaded`()
    async throws
  {
    try await withRegistry { registry in
      let grant = try await registry.create(
        grid: GridSize(columns: 40, rows: 8)
      )
      let client = ImageClient(registry)
      defer { client.connection.close() }
      try await client.attach(grant, variant: .off)
      _ = try await hostEventually("prompt") {
        client.state.withLock {
          $0.frames.last { $0.lines.contains { $0.contains("$") } }
        }
      }
      try await client.send(Self.input(1, .committedText(Self.command)))
      try await client.send(Self.input(2, .key(SemanticKey(.enter))))
      let frame = try await hostEventually("placements") {
        client.state.withLock {
          $0.frames.last { $0.images?.placements.isEmpty == false }
        }
      }
      try await Task.sleep(for: .milliseconds(300))
      #expect(client.state.withLock { $0.blobs.isEmpty })
      let key = try #require(frame.images?.images.first?.key)
      try await client.send(
        .imageLoad(epoch: 1, keys: [key], variant: .reduced)
      )
      let blob = try await hostEventually("loaded") {
        client.state.withLock { $0.blobs.first }
      }
      #expect(blob.key == key)
      #expect(blob.variant == .reduced)
    }
  }

  @Test
  func `blobs round trip and reject malformed records`() throws {
    let rgba = Array(
      [[UInt8]](repeating: [0, 128, 255, 255], count: 64).joined()
    )
    let blob = try #require(
      ImageBlobCodec.encode(
        key: 9,
        rgba: rgba,
        width: 8,
        height: 8,
        variant: .full
      )
    )
    let decoded = try ImageBlob.decode(blob.encoded())
    #expect(decoded == blob)
    #expect(ImageBlobCodec.decode(decoded) == rgba)
    var bytes = blob.encoded()
    bytes[SnapshotFrame.headerLength + 57] = 9  // unknown codec
    #expect(throws: FramingError.self) { try ImageBlob.decode(bytes) }
    #expect(throws: FramingError.self) {
      try ImageBlob.decode(Array(blob.encoded().dropLast()))
    }
    // A screen decoder refuses image records.
    #expect(throws: FramingError.self) {
      try SnapshotFrame.decodeRecord(blob.encoded())
    }
  }

  @Test
  func `reduced images fit their budget`() throws {
    var rgba: [UInt8] = []
    for i in 0 ..< 2048 * 2048 {
      rgba += [
        UInt8(i & 0xFF), UInt8(i >> 8 & 0xFF), UInt8(i >> 16 & 0xFF), 255,
      ]
    }
    let blob = try #require(
      ImageBlobCodec.encode(
        key: 1,
        rgba: rgba,
        width: 2048,
        height: 2048,
        variant: .reduced
      )
    )
    #expect(blob.width <= 1024)
    #expect(blob.data.count <= ImageBlob.reducedBytes)
    #expect(blob.sourceWidth == 2048)
  }
}
#endif
