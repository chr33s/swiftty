/// Kitty graphics in planned-replacement checkpoints (spec.graphics.md §18;
/// spec.durability.md §6): section 15, written only when either screen
/// holds images, so checkpoints of terminals without images are unchanged.
/// A chunked load in progress is not encoded: the cut abandons it, as a
/// delete would. Pixel serials are not kept; a restored worker assigns new
/// ones and clients fetch the pixels again.
extension TerminalCheckpoint { static let kittyGraphicsSection: UInt8 = 15 }

extension KittyImageStorage {
  func checkpoint(into w: inout CheckpointWriter) {
    w.int(limit)
    w.int(images.count)
    for image in images.values.sorted(by: { $0.id < $1.id }) {
      w.u32(image.id)
      w.u32(image.number)
      w.u32(image.width)
      w.u32(image.height)
      w.u8(image.format.rawValue)
      w.bool(image.transient)
      w.bool(image.implicitID)
      w.u64(image.transmission)
      w.data(image.pixels?.bytes ?? [])
      w.bool(image.animation != nil)
      if let a = image.animation {
        w.int(a.frames.count)
        for frame in a.frames {
          w.data(frame.pixels.bytes)
          w.u32(frame.gap)
        }
        w.u32(a.rootGap)
        w.u32(a.currentIndex)
        w.u8(a.state == .stopped ? 0 : a.state == .loading ? 1 : 2)
        w.u32(a.maxLoops)
        w.u32(a.currentLoop)
      }
    }
    func key(_ k: PlacementKey) {
      w.u32(k.imageID)
      w.bool(k.external)
      w.u32(k.id)
    }
    let ordered = placements.sorted {
      ($0.key.imageID, $0.key.external ? 1 : 0, $0.key.id) < (
        $1.key.imageID, $1.key.external ? 1 : 0, $1.key.id
      )
    }
    w.int(ordered.count)
    for (k, p) in ordered {
      key(k)
      switch p.location {
      case let .anchor(row, column):
        w.u8(0)
        w.int(row)
        w.int(column)
      case .virtual: w.u8(1)
      case let .relative(parent, h, v):
        w.u8(2)
        key(parent)
        w.u32(UInt32(bitPattern: h))
        w.u32(UInt32(bitPattern: v))
      }
      for value in [
        p.xOffset, p.yOffset, p.sourceX, p.sourceY, p.sourceWidth,
        p.sourceHeight, p.columns, p.rows,
      ] { w.u32(value) }
      w.u32(UInt32(bitPattern: p.z))
    }
    w.u32(nextInternalPlacementIDForCheckpoint)
  }

  func restore(from r: inout CheckpointReader) throws(CheckpointError) {
    limit = max(0, try r.int())
    let imageCount = try r.int()
    guard (0 ... 1 << 20).contains(imageCount) else {
      throw CheckpointError("image count")
    }
    images = [:]
    totalBytes = 0
    for _ in 0 ..< imageCount {
      var image = KittyGraphics.Image()
      image.id = try r.u32()
      image.number = try r.u32()
      image.width = try r.u32()
      image.height = try r.u32()
      guard image.id != 0, images[image.id] == nil,
        (1 ... KittyGraphics.maxDimension).contains(image.width),
        (1 ... KittyGraphics.maxDimension).contains(image.height),
        let format = KittyGraphics.Format(rawValue: try r.u8()), format != .png
      else { throw CheckpointError("image header") }
      image.format = format
      image.transient = try r.bool()
      image.implicitID = try r.bool()
      image.transmission = try r.u64()
      let size = Int(image.width) * Int(image.height) * format.bytesPerPixel
      let bytes = try r.data(max: size)
      guard bytes.count == size else { throw CheckpointError("image pixels") }
      image.pixels = KittyImagePixels(
        width: Int(image.width),
        height: Int(image.height),
        bytesPerPixel: format.bytesPerPixel,
        bytes: bytes
      )
      if try r.bool() {
        var a = KittyGraphics.Animation()
        let frames = try r.int()
        guard (0 ... 1 << 16).contains(frames), frames == 0 || format == .rgba
        else { throw CheckpointError("animation frames") }
        let frameSize = Int(image.width) * Int(image.height) * 4
        for _ in 0 ..< frames {
          let data = try r.data(max: frameSize)
          guard data.count == frameSize else {
            throw CheckpointError("frame pixels")
          }
          a.frames.append(
            .init(
              pixels: KittyImagePixels(
                width: Int(image.width),
                height: Int(image.height),
                bytesPerPixel: 4,
                bytes: data
              ),
              gap: try r.u32()
            )
          )
        }
        a.rootGap = try r.u32()
        a.currentIndex = try r.u32()
        guard a.currentIndex < a.frameCount else {
          throw CheckpointError("current frame")
        }
        switch try r.u8() {
        case 0: a.state = .stopped
        case 1: a.state = .loading
        case 2: a.state = .running
        default: throw CheckpointError("animation state")
        }
        a.maxLoops = try r.u32()
        a.currentLoop = try r.u32()
        image.animation = a
      }
      totalBytes += image.storageSize
      images[image.id] = image
    }
    func key() throws(CheckpointError) -> PlacementKey {
      PlacementKey(
        imageID: try r.u32(),
        external: try r.bool(),
        id: try r.u32()
      )
    }
    let placementCount = try r.int()
    guard (0 ... 1 << 20).contains(placementCount) else {
      throw CheckpointError("placement count")
    }
    placements = [:]
    for _ in 0 ..< placementCount {
      let k = try key()
      guard images[k.imageID] != nil, placements[k] == nil else {
        throw CheckpointError("placement image")
      }
      let location: Location
      switch try r.u8() {
      case 0: location = .anchor(row: try r.int(), column: max(0, try r.int()))
      case 1: location = .virtual
      case 2:
        location = .relative(
          parent: try key(),
          horizontal: Int32(bitPattern: try r.u32()),
          vertical: Int32(bitPattern: try r.u32())
        )
      default: throw CheckpointError("placement location")
      }
      var v: [UInt32] = []
      for _ in 0 ..< 8 { v.append(try r.u32()) }
      placements[k] = Placement(
        location: location,
        xOffset: v[0],
        yOffset: v[1],
        sourceX: v[2],
        sourceY: v[3],
        sourceWidth: v[4],
        sourceHeight: v[5],
        columns: v[6],
        rows: v[7],
        z: Int32(bitPattern: try r.u32())
      )
      images[k.imageID]!.placementCount += 1
    }
    for (_, p) in placements {
      if case let .relative(parent, _, _) = p.location,
        placements[parent] == nil
      {
        throw CheckpointError("relative placement parent")
      }
    }
    nextInternalPlacementIDForCheckpoint = try r.u32()
    loading = nil
    markMutated()
    for id in Array(images.keys) { images[id]?.generation = generation }
  }
}

extension TerminalState {
  func checkpointKittyGraphics(into w: inout CheckpointWriter) {
    guard hasKittyImages else { return }
    var nested = CheckpointWriter()
    kittyPrimary.checkpoint(into: &nested)
    kittyAlternate.checkpoint(into: &nested)
    w.u8(TerminalCheckpoint.kittyGraphicsSection)
    w.data(nested.bytes)
  }

  func restoreKittyGraphics(
    from r: inout CheckpointReader
  ) throws(CheckpointError) {
    guard r.peekU8() == TerminalCheckpoint.kittyGraphicsSection else { return }
    var s = try r.section(TerminalCheckpoint.kittyGraphicsSection)
    try kittyPrimary.restore(from: &s)
    try kittyAlternate.restore(from: &s)
    try s.finish()
  }
}
