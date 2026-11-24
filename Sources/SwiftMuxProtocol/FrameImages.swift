import Foundation

/// Kitty graphics in a pane frame (spec.graphics.md §14.3): resolved
/// placements in frame rows plus references to the pixels they draw.
/// Pixels never travel inside frames; clients fetch them by key
/// (`MuxCommand.requestImages`, `MuxEvent.imageData`).
public struct FrameImages: Codable, Sendable, Equatable {
  /// Most images and placements one frame may reference.
  public static let maxImages = 64
  public static let maxPlacements = 1024
  /// Largest image side, in pixels (the protocol's own limit).
  public static let maxDimension: UInt32 = 10_000

  /// Host cell size in pixels that placement pixel geometry assumes;
  /// clients scale by their own cell size over this.
  public var cellWidth: UInt16
  public var cellHeight: UInt16
  public var images: [FrameImage]
  public var placements: [FramePlacement]
  /// The other frames of visible animations (Phase 5 frame sets,
  /// spec.graphics.md §16.4): clients fetch or receive them ahead, so the
  /// host's frame changes never wait on pixels. At most `maxImages`.
  public var prefetch: [FrameImage]

  public init(
    cellWidth: UInt16,
    cellHeight: UInt16,
    images: [FrameImage],
    placements: [FramePlacement],
    prefetch: [FrameImage] = []
  ) {
    self.cellWidth = cellWidth
    self.cellHeight = cellHeight
    self.images = images
    self.placements = placements
    self.prefetch = prefetch
  }

  enum CodingKeys: String, CodingKey {
    case cellWidth, cellHeight, images, placements, prefetch
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    cellWidth = try c.decode(UInt16.self, forKey: .cellWidth)
    cellHeight = try c.decode(UInt16.self, forKey: .cellHeight)
    images = try c.decode([FrameImage].self, forKey: .images)
    placements = try c.decode([FramePlacement].self, forKey: .placements)
    prefetch = try c.decodeIfPresent([FrameImage].self, forKey: .prefetch) ?? []
  }
}

/// Pixels a frame references. `key` changes whenever the pixels do.
public struct FrameImage: Codable, Sendable, Equatable, Hashable {
  public var key: UInt64
  public var width: UInt32
  public var height: UInt32
  /// 1 (gray), 2 (gray + alpha), 3 (RGB) or 4 (RGBA), straight alpha.
  public var bytesPerPixel: UInt8

  public init(key: UInt64, width: UInt32, height: UInt32, bytesPerPixel: UInt8)
  {
    self.key = key
    self.width = width
    self.height = height
    self.bytesPerPixel = bytesPerPixel
  }

  public var byteCount: Int { Int(width) * Int(height) * Int(bytesPerPixel) }
}

public struct FramePlacement: Codable, Sendable, Equatable {
  /// Index into `FrameImages.images`.
  public var image: UInt16
  /// 0 below cell backgrounds, 1 below text, 2 above text.
  public var layer: UInt8
  public var z: Int32
  public var placeholder: Bool
  /// Top-left cell relative to the frame's first row and column; may be
  /// negative or past the frame when the placement is partly visible.
  public var row: Int32
  public var column: Int32
  public var columns: UInt32
  public var rows: UInt32
  /// Host pixels.
  public var offsetX: UInt32
  public var offsetY: UInt32
  public var width: UInt32
  public var height: UInt32
  public var sourceX: UInt32
  public var sourceY: UInt32
  public var sourceWidth: UInt32
  public var sourceHeight: UInt32

  public init(
    image: UInt16,
    layer: UInt8,
    z: Int32,
    placeholder: Bool,
    row: Int32,
    column: Int32,
    columns: UInt32,
    rows: UInt32,
    offsetX: UInt32,
    offsetY: UInt32,
    width: UInt32,
    height: UInt32,
    sourceX: UInt32,
    sourceY: UInt32,
    sourceWidth: UInt32,
    sourceHeight: UInt32
  ) {
    self.image = image
    self.layer = layer
    self.z = z
    self.placeholder = placeholder
    self.row = row
    self.column = column
    self.columns = columns
    self.rows = rows
    self.offsetX = offsetX
    self.offsetY = offsetY
    self.width = width
    self.height = height
    self.sourceX = sourceX
    self.sourceY = sourceY
    self.sourceWidth = sourceWidth
    self.sourceHeight = sourceHeight
  }
}

extension FrameImages {
  /// Rejects references, sizes and geometry outside the protocol limits.
  public func validate(rows: Int, columns: Int) throws(MuxError) {
    guard images.count <= Self.maxImages,
      placements.count <= Self.maxPlacements, prefetch.count <= Self.maxImages
    else { throw MuxError(.invalidRequest, "frame images count") }
    for image in prefetch {
      guard image.width > 0, image.height > 0, image.width <= Self.maxDimension,
        image.height <= Self.maxDimension,
        (1 ... 4).contains(image.bytesPerPixel)
      else { throw MuxError(.invalidRequest, "frame prefetch image") }
    }
    var keys = Set<UInt64>()
    for image in images {
      guard image.width > 0, image.height > 0, image.width <= Self.maxDimension,
        image.height <= Self.maxDimension,
        (1 ... 4).contains(image.bytesPerPixel), keys.insert(image.key).inserted
      else { throw MuxError(.invalidRequest, "frame image") }
    }
    let limit = UInt32(4 * Self.maxDimension)
    for p in placements {
      guard Int(p.image) < images.count, p.layer <= 2 else {
        throw MuxError(.invalidRequest, "frame placement image")
      }
      let image = images[Int(p.image)]
      guard p.width > 0, p.height > 0, p.width <= limit, p.height <= limit,
        p.columns > 0, p.rows > 0, p.columns <= limit, p.rows <= limit,
        p.offsetX <= limit, p.offsetY <= limit, p.sourceWidth > 0,
        p.sourceHeight > 0,
        UInt64(p.sourceX) + UInt64(p.sourceWidth) <= UInt64(image.width),
        UInt64(p.sourceY) + UInt64(p.sourceHeight) <= UInt64(image.height),
        Int(p.row) + Int(p.rows) > 0, Int(p.row) < rows,
        Int(p.column) + Int(p.columns) > 0, Int(p.column) < columns
      else { throw MuxError(.invalidRequest, "frame placement geometry") }
    }
  }
}

/// Part of an image's pixels (`MuxCommand.imageChunk`).
public struct MuxImageChunk: Codable, Sendable, Equatable {
  /// Most pixel bytes one reply carries.
  public static let maxBytes = 4 << 20

  public var image: FrameImage
  public var offset: Int
  public var bytes: Data

  public init(image: FrameImage, offset: Int, bytes: Data) {
    self.image = image
    self.offset = offset
    self.bytes = bytes
  }

  public func validate(requestedOffset: Int, key: UInt64) throws(MuxError) {
    guard image.key == key, offset == requestedOffset, image.width > 0,
      image.height > 0, image.width <= FrameImages.maxDimension,
      image.height <= FrameImages.maxDimension,
      (1 ... 4).contains(image.bytesPerPixel), bytes.count <= Self.maxBytes,
      offset >= 0, offset <= image.byteCount - bytes.count,
      !bytes.isEmpty || offset == image.byteCount
    else { throw MuxError(.invalidRequest, "image chunk") }
  }
}
