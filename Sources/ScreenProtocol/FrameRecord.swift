import Foundation
import SessionCore
import SwiftMuxProtocol

/// The RST/1 envelope of an `SMXB/1` screen (spec.roaming.md §7.2): the
/// identity a legacy snapshot carries in its JSON.
public struct RSTFrameHeader: Hashable, Sendable {
  public static let byteCount = SessionID.byteCount + 4 * 8

  public var sessionID: SessionID
  public var attachmentEpoch: UInt64
  public var screenRevision: UInt64
  public var resizeRevision: UInt64
  public var lastFullyAppliedInputSequence: UInt64

  public init(
    sessionID: SessionID,
    attachmentEpoch: UInt64,
    screenRevision: UInt64,
    resizeRevision: UInt64,
    lastFullyAppliedInputSequence: UInt64
  ) {
    self.sessionID = sessionID
    self.attachmentEpoch = attachmentEpoch
    self.screenRevision = screenRevision
    self.resizeRevision = resizeRevision
    self.lastFullyAppliedInputSequence = lastFullyAppliedInputSequence
  }

  public var bytes: Data {
    var out = Data(sessionID.bytes)
    for v in [
      attachmentEpoch, screenRevision, resizeRevision,
      lastFullyAppliedInputSequence,
    ] { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
    return out
  }

  public init?(bytes data: Data) {
    let b = [UInt8](data)
    guard b.count == Self.byteCount,
      let session = SessionID(bytes: Array(b[0 ..< SessionID.byteCount]))
    else { return nil }
    func u64(_ i: Int) -> UInt64 {
      var v: UInt64 = 0
      for k in 0 ..< 8 {
        v |= UInt64(b[SessionID.byteCount + 8 * i + k]) << (8 * UInt64(k))
      }
      return v
    }
    sessionID = session
    attachmentEpoch = u64(0)
    screenRevision = u64(1)
    resizeRevision = u64(2)
    lastFullyAppliedInputSequence = u64(3)
  }

  /// The frame identity shared code compares: the screen revision orders
  /// frames and delta bases; the resize revision is the geometry.
  public var frameIdentity: FrameIdentity {
    var identity = FrameIdentity.unbound
    identity.revision = screenRevision
    identity.geometryGeneration = resizeRevision
    return identity
  }
}

/// One decoded screen stream: a complete frame or a delta, each with its
/// envelope.
public enum ScreenRecord: Sendable {
  case frame(PaneFrame, RSTFrameHeader)
  case delta(FrameDelta, RSTFrameHeader)
}

extension SnapshotFrame {
  /// Shared-model limits for RST/1 screens (§12).
  public static let frameLimits: MuxLimits = {
    var limits = MuxLimits.standard
    limits.maxColumns = RSTLimits.maxColumns
    limits.maxRows = RSTLimits.maxRows
    limits.maxFrameBytes = RSTLimits.maxSnapshotDecodedBytes
    // The legacy snapshot's bounds: a style per cell at the grid limit,
    // and graphemes up to the RST/1 byte limit (one scalar per byte at
    // most); longer clusters export as the placeholder.
    limits.maxStyles = RSTLimits.maxStyles
    limits.maxGraphemeScalars = RSTLimits.maxGraphemeBytes
    return limits
  }()

  /// Frames `payload` (an `SMXB/1` record) as encoding 2, or 3 when zlib
  /// makes it smaller.
  public static func encode(frame payload: [UInt8]) throws -> [UInt8] {
    guard payload.count <= RSTLimits.maxSnapshotDecodedBytes else {
      throw FramingError.snapshotTooLarge
    }
    let compressed = Zlib.compress(payload)
    let (encoding, body): (Encoding, [UInt8]) =
      compressed.count < payload.count
      ? (.smxbZlib, compressed) : (.smxb, payload)
    guard body.count <= RSTLimits.maxSnapshotEncodedBytes else {
      throw FramingError.snapshotTooLarge
    }
    var out = [encoding.rawValue]
    out.reserveCapacity(headerLength + body.count)
    appendUInt32(UInt32(payload.count), to: &out)
    appendUInt32(UInt32(body.count), to: &out)
    out.append(contentsOf: body)
    return out
  }

  /// Decodes any screen record. Frames and deltas are checked against the
  /// RST/1 limits and profile: no search, drop target or mouse modes, a
  /// bounded title. A delta is complete only once applied to its base.
  public static func decodeRecord(
    _ bytes: [UInt8],
    limits: NegotiatedLimits = NegotiatedLimits(),
    allowsImages: Bool = false
  ) throws(FramingError) -> ScreenRecord {
    guard let header = try header(bytes, limits: limits) else {
      throw .truncated
    }
    guard header.encoding != .imageBlob else {
      throw .invalidFrame("image record")
    }
    let total = headerLength + header.encodedLength
    guard bytes.count >= total else { throw .truncated }
    guard bytes.count == total else { throw .trailingData }
    let payload = try body(bytes, header)
    guard payload.count == header.decodedLength else { throw .lengthMismatch }
    var frameLimits = Self.frameLimits
    let effective = limits.effective
    frameLimits.maxColumns = effective.maxColumns
    frameLimits.maxRows = effective.maxRows
    let record: SMXB.Record
    do {
      record = try SMXB.decode(
        Data(payload),
        limits: frameLimits,
        maxBytes: RSTLimits.maxSnapshotDecodedBytes
      )
    } catch { throw .invalidFrame(error.message) }
    guard case let .rst(envelope) = record.envelope,
      let rst = RSTFrameHeader(bytes: envelope)
    else { throw .invalidFrame("envelope") }
    switch record.payload {
    case var .frame(frame):
      guard allowsImages || frame.images == nil else {
        throw .invalidFrame("images without kittyGraphics")
      }
      try checkProfile(
        title: frame.title,
        search: frame.search,
        drop: frame.dropTarget,
        modes: frame.modes
      )
      frame.identity = rst.frameIdentity
      return .frame(frame, rst)
    case var .delta(delta):
      guard allowsImages || delta.images == nil else {
        throw .invalidFrame("images without kittyGraphics")
      }
      try checkProfile(
        title: delta.title,
        search: delta.search,
        drop: delta.dropTarget,
        modes: delta.modes
      )
      delta.identity = rst.frameIdentity
      return .delta(delta, rst)
    }
  }

  static func checkProfile(
    title: String,
    search: FrameSearch?,
    drop: FrameDropTarget?,
    modes: SupportedViewModes
  ) throws(FramingError) {
    // `mouseTracking` alone tells a `mouseWheel` client to send wheel
    // notches; motion and paste-event modes stay host-side.
    let mouse: SupportedViewModes = [
      .mouseButtonMotion, .mouseAnyMotion, .kittyPasteEvents,
    ]
    guard title.utf8.count <= RSTLimits.maxTitleBytes, search == nil,
      drop == nil, modes.isDisjoint(with: mouse)
    else { throw .invalidFrame("outside the RST/1 profile") }
  }

  static func body(
    _ bytes: [UInt8],
    _ header: Header
  ) throws(FramingError) -> [UInt8] {
    let body = Array(bytes[headerLength...])
    guard header.encoding.isCompressed else { return body }
    do { return try Zlib.decompress(body, limit: header.decodedLength) } catch {
      throw .decompression(error)
    }
  }
}
