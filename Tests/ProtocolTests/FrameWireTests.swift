import Foundation
@testable import ScreenProtocol
import SessionCore
import SwiftMuxProtocol
import Testing

/// RST/1 `paneFrames`, `screenDeltas` and `copySelection` on the wire
/// (spec.roaming.md §7.2, §7.4, §7.5; A20–A22 protocol parts).
struct FrameWireTests {
  static let header = RSTFrameHeader(
    sessionID: .random(),
    attachmentEpoch: 3,
    screenRevision: 41,
    resizeRevision: 2,
    lastFullyAppliedInputSequence: 7
  )

  /// A small valid frame: "ab" over "c", versions 1 and 2.
  static func frame(
    _ text: [String] = ["ab ", "c  "],
    versions: [UInt64] = [1, 2]
  ) -> PaneFrame {
    let columns = 3
    var glyphs: [UInt32] = []
    for row in text {
      for scalar in row.unicodeScalars {
        glyphs.append(scalar == " " ? 0 : scalar.value)
      }
    }
    let count = glyphs.count
    return PaneFrame(
      identity: header.frameIdentity,
      grid: FrameGrid(
        columns: columns,
        rows: text.count,
        alternateScreen: false,
        wrapped: Data(repeating: 0, count: text.count),
        glyphs: glyphs.withUnsafeBytes { Data($0) },
        styles: Data(repeating: 0, count: count * 2),
        kinds: Data(repeating: CellKind.narrow.rawValue, count: count)
      ),
      graphemes: [],
      styles: [.plain],
      underlineColors: [],
      palette: FramePalette(
        colors: Array(repeating: 0x10_2030, count: 256),
        foreground: 0xFF_FFFF,
        background: 0,
        cursor: 0xFF_FFFF
      ),
      cursor: FrameCursor(x: 0, y: 1, visible: true, style: 0, blinking: false),
      modes: [],
      history: HistoryWindow(
        generation: 5,
        firstRow: 0,
        availableRows: text.count,
        viewportTop: 0,
        viewportOffset: 0,
        scrollbackRows: 0
      ),
      search: nil,
      title: "t",
      rowVersions: versions
    )
  }

  @Test
  func `the rst header round-trips`() throws {
    let decoded = try #require(RSTFrameHeader(bytes: Self.header.bytes))
    #expect(decoded == Self.header)
    #expect(RSTFrameHeader(bytes: Self.header.bytes.dropLast()) == nil)
    #expect(decoded.frameIdentity.revision == 41)
    #expect(decoded.frameIdentity.geometryGeneration == 2)
  }

  @Test
  func `frames use encodings 2 and 3 and decode with their envelope`() throws {
    let frame = Self.frame()
    let record = SMXB.encode(frame, envelope: .rst(Self.header.bytes))
    let wire = try SnapshotFrame.encode(frame: [UInt8](record))
    #expect([2, 3].contains(wire[0]))
    guard
      case let .frame(decoded, header) = try SnapshotFrame.decodeRecord(wire)
    else {
      Issue.record("not a frame")
      return
    }
    #expect(header == Self.header)
    #expect(decoded == frame)
    // A legacy decoder refuses the frame encodings rather than misreading.
    #expect(throws: FramingError.self) { try SnapshotFrame.decode(wire) }
  }

  @Test
  func `deltas decode and apply against their base`() throws {
    // One row of three changes: under half, so a delta is worth sending.
    let base = Self.frame(["ab ", "c  ", "e  "], versions: [1, 2, 4])
    var next = Self.frame(["ab ", "cd ", "e  "], versions: [1, 3, 4])
    next.identity.revision = 42
    let baseline = try #require(FrameBaseline(base))
    let delta = try #require(
      FrameDeltaBuilder.delta(from: next, base: baseline)
    )
    let wire = try SnapshotFrame.encode(
      frame: [UInt8](SMXB.encode(delta, envelope: .rst(Self.header.bytes)))
    )
    guard case let .delta(decoded, _) = try SnapshotFrame.decodeRecord(wire)
    else {
      Issue.record("not a delta")
      return
    }
    // The envelope's revisions become the identity a base is matched by.
    #expect(decoded.identity.revision == 41)
    var sent = decoded
    sent.identity.revision = 42
    let applied = try FrameDeltaApplier.apply(
      sent,
      to: base,
      limits: SnapshotFrame.frameLimits
    )
    #expect(applied.lines == ["ab", "cd", "e"])
  }

  @Test
  func `frames outside the rst profile are rejected`() throws {
    var searched = Self.frame()
    searched.search = FrameSearch(
      matchCount: 1,
      selected: nil,
      visible: [],
      selectedVisible: nil
    )
    var mouse = Self.frame()
    mouse.modes = [.mouseTracking]
    var envelope = Self.frame()
    envelope.identity = FrameIdentity.unbound
    for frame in [searched, mouse] {
      let wire = try SnapshotFrame.encode(
        frame: [UInt8](SMXB.encode(frame, envelope: .rst(Self.header.bytes)))
      )
      #expect(throws: FramingError.self) {
        try SnapshotFrame.decodeRecord(wire)
      }
    }
    // A SwiftMux envelope is not an RST/1 screen.
    let mux = try SnapshotFrame.encode(frame: [UInt8](SMXB.encode(envelope)))
    #expect(throws: FramingError.self) { try SnapshotFrame.decodeRecord(mux) }
  }

  @Test
  func `new control messages round-trip`() throws {
    let messages: [ControlMessage] = [
      .requestFullScreen(epoch: 4, screenRevision: 9),
      .copySelection(
        .init(
          attachmentEpoch: 4,
          requestID: 9,
          generation: 5,
          alternateScreen: false,
          startRow: 0,
          startColumn: 1,
          endRow: 300,
          endColumn: 39,
          unit: .word,
          screenRowVersions: [[290, 17], [291, 18]]
        )
      ), .copyChunk(epoch: 4, requestID: 9, index: 0, text: "1\n2\n漢"),
      .copyResult(epoch: 4, requestID: 9, totalBytes: 7, error: nil),
      .copyResult(
        epoch: 4,
        requestID: 9,
        totalBytes: nil,
        error: .selectionChanged
      ),
    ]
    for message in messages {
      let record = try ControlRecord.encode(message)
      #expect(try ControlRecord.decodeBody(record.dropFirst(4)) == message)
      #expect(message.epoch == 4)
    }
    let tooLong = ControlMessage.copyChunk(
      epoch: 1,
      requestID: 1,
      index: 0,
      text: String(repeating: "x", count: ControlMessage.maxCopyChunkBytes + 1)
    )
    let record = try ControlRecord.encode(tooLong)
    #expect(throws: FramingError.self) {
      try ControlRecord.decodeBody(record.dropFirst(4))
    }
  }

  @Test
  func `attach carries client features and older attaches still decode`() throws
  {
    let attach = ControlMessage.attach(
      .init(
        sessionID: .random(),
        serverInstanceID: .random(),
        writerID: .random(),
        applicationToken: .random(),
        features: .supported
      )
    )
    let record = try ControlRecord.encode(attach)
    #expect(try ControlRecord.decodeBody(record.dropFirst(4)) == attach)
    guard case var .attach(old) = attach else { return }
    old.features = []
    let legacy = try ControlRecord.encode(.attach(old))
    #expect(!String(decoding: legacy, as: UTF8.self).contains("features"))
  }

  @Test
  func `dependent features need their prerequisites`() {
    #expect(
      RSTFeatures.supported.agreed(with: [.screenDeltas, .copySelection])
        .isEmpty
    )
    #expect(
      RSTFeatures.supported.agreed(with: [.paneFrames, .copySelection]) == [
        .paneFrames
      ]
    )
    #expect(
      RSTFeatures.supported.agreed(with: .supported) == RSTFeatures.supported
    )
  }
}
