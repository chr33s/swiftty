/// Kitty graphics protocol execution (`ESC _ G … ESC \`).
///
/// Ported from Ghostty's `src/terminal/kitty/graphics_exec.zig` at
/// 167acf0c: action dispatch, chunked loads, replacement, placement,
/// cursor movement, animation and responses. The terminal-side hooks
/// that keep anchors on their content are at the end of this file
/// (spec.graphics.md §8.4, §9.1).
extension TerminalState {
  typealias KittyResponse = KittyGraphics.Response

  /// Platform default per screen (spec.graphics.md §8.2).
  public static var defaultImageStorageLimit: Int {
    #if os(macOS)
    320_000_000
    #else
    128_000_000
    #endif
  }

  /// The active screen's image storage.
  var kittyImages: KittyImageStorage {
    isAlternateScreen ? kittyAlternate : kittyPrimary
  }

  var kittyGeometry: KittyImageStorage.Geometry {
    KittyImageStorage.Geometry(
      cellWidth: UInt32(clamping: cellPixelSize.width),
      cellHeight: UInt32(clamping: cellPixelSize.height),
      columns: columns,
      rows: rows,
      screenTop: screenAbsoluteRow(0),
      firstRow: firstAbsoluteRow
    )
  }

  /// Whether graphics commands are executed and answered at all.
  var kittyGraphicsActive: Bool {
    kittyGraphicsEnabled && kittyImages.isEnabled
  }

  /// Whether any image or placement exists on either screen.
  public var hasKittyImages: Bool {
    !kittyPrimary.images.isEmpty || !kittyAlternate.images.isEmpty
  }

  // MARK: APC

  /// Whether any byte is 0x80 or above, eight bytes at a time.
  @inline(__always)
  static func hasHighBit(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
    guard let base = bytes.baseAddress else { return false }
    let raw = UnsafeRawPointer(base)
    let n = bytes.count
    var acc: UInt64 = 0
    var i = 0
    while i + 8 <= n {
      acc |= raw.loadUnaligned(fromByteOffset: i, as: UInt64.self)
      i += 8
    }
    while i < n {
      acc |= UInt64(base[i])
      i += 1
    }
    return acc & 0x8080_8080_8080_8080 != 0
  }

  // Out of line: the parser's text paths must not grow (§21.3).
  @inline(never)
  mutating func kittyAPCStart() { kittyCommand = KittyGraphics.CommandBox() }

  // Out of line: the parser's text paths must not grow (§21.3).
  @inline(never)
  mutating func kittyAPCPut(
    _ bytes: UnsafeBufferPointer<UInt8>,
    hasHighBytes: Bool? = nil
  ) {
    guard let box = kittyCommand else { return }
    // Like Ghostty's parse table, bytes 0x80 and above are not payload.
    if hasHighBytes ?? Self.hasHighBit(bytes) {
      let kept = bytes.filter { $0 < 0x80 }
      kept.withUnsafeBufferPointer { box.parser.feed($0) }
    } else {
      box.parser.feed(bytes)
    }
  }

  // Out of line: the parser's text paths must not grow (§21.3).
  @inline(never)
  mutating func kittyAPCAbort() { kittyCommand = nil }

  // Out of line: the parser's text paths must not grow (§21.3).
  @inline(never)
  mutating func kittyAPCEnd() {
    guard let box = kittyCommand else { return }
    kittyCommand = nil
    var parser = box.parser
    graphemes.releaseTail()
    guard let command = parser.complete() else { return }
    if let response = executeKittyGraphics(command),
      let bytes = response.encoded()
    {
      guard !discardsReplies else { return }
      output.append(contentsOf: bytes)
    }
  }

  // MARK: Dispatch

  /// Runs one command; the reply after quiet handling, if any.
  mutating func executeKittyGraphics(
    _ command: KittyGraphics.Command
  ) -> KittyResponse? {
    guard kittyGraphicsActive else { return nil }
    // Parse-time validation: unknown actions and enum values drop the
    // command without a reply.
    let rawAction = command.get("a") ?? 0x74
    guard rawAction <= 0xFF else { return nil }
    let action = UInt8(rawAction)
    switch action {
    case 0x71, 0x74, 0x54, 0x66:  // q t T f
      guard KittyGraphics.Transmission(command) != nil else { return nil }
    case 0x64:  // d
      guard KittyGraphics.Delete(command) != nil else { return nil }
    case 0x70, 0x61, 0x63: break  // p a c
    default: return nil
    }
    var quiet = command.quiet
    let id = command.value("i")
    let number = command.value("I")
    if id > 0, number > 0 {
      let r = KittyResponse(
        id: id,
        imageNumber: number,
        placementID: command.value("p"),
        message: "EINVAL: image ID and number are mutually exclusive"
      )
      return quiet == .failures ? nil : r
    }
    let response: KittyResponse?
    switch action {
    case 0x71: response = kittyQuery(command)
    case 0x70:
      response = kittyDisplay(
        KittyGraphics.Display(command),
        quiet: command.quiet
      )
    case 0x64:
      abandonKittyLoad()
      kittyImages.delete(
        KittyGraphics.Delete(command)!,
        cursor: (cursor.x, cursor.y),
        kittyGeometry
      )
      response = nil
    case 0x74, 0x54, 0x66:
      let storage = kittyImages
      let t = KittyGraphics.Transmission(command)!
      if storage.loading != nil, t.medium != .direct { abandonKittyLoad() }
      if storage.loading != nil {
        switch command.quiet {
        case .no: quiet = storage.loading!.quiet
        case .ok, .failures: storage.loading!.quiet = command.quiet
        }
      }
      response =
        action == 0x66
        ? kittyTransmitFrame(command) : kittyTransmit(command, action: action)
    case 0x61: response = kittyControlAnimation(command)
    case 0x63: response = kittyComposeAnimation(command)
    default: response = nil
    }
    guard let response else { return nil }
    switch quiet {
    case .no: return response.isEmpty ? nil : response
    case .ok: return response.isOK ? nil : response
    case .failures: return nil
    }
  }

  private func kittyQuery(_ command: KittyGraphics.Command) -> KittyResponse {
    let t = KittyGraphics.Transmission(command)!
    guard t.imageID != 0 else {
      return KittyResponse(message: "EINVAL: image ID required")
    }
    var result = KittyResponse(
      id: t.imageID,
      imageNumber: t.imageNumber,
      placementID: t.placementID
    )
    do {
      var loading = try KittyGraphics.LoadingImage(
        command: command,
        transmission: t,
        media: kittyGraphicsMedia,
        storageLimit: kittyImages.limit,
        display: nil
      )
      _ = try loading.complete()
    } catch { result.message = error.message }
    return result
  }

  /// Ends the chunked load in progress, deleting the image it replaced.
  mutating func abandonKittyLoad() {
    let storage = kittyImages
    guard let loading = storage.loading else { return }
    storage.loading = nil
    if let id = Self.replacedImageID(loading) { deleteReplacedKittyImage(id) }
  }

  private static func replacedImageID(
    _ loading: KittyGraphics.LoadingImage
  ) -> UInt32? {
    guard loading.frame == nil, loading.image.number == 0,
      !loading.image.implicitID, loading.image.id > 0
    else { return nil }
    return loading.image.id
  }

  private mutating func deleteReplacedKittyImage(_ id: UInt32) {
    kittyImages.delete(
      .id(delete: true, imageID: id, placementID: 0),
      cursor: (cursor.x, cursor.y),
      kittyGeometry
    )
  }

  // MARK: Transmit

  private mutating func kittyTransmit(
    _ command: KittyGraphics.Command,
    action: UInt8
  ) -> KittyResponse {
    let storage = kittyImages
    let t = KittyGraphics.Transmission(command)!
    var result: KittyResponse
    if let loading = storage.loading {
      if loading.frame != nil { return kittyTransmitFrame(command) }
      result = loading.response
    } else {
      result = KittyResponse(
        id: t.imageID,
        imageNumber: t.imageNumber,
        placementID: t.placementID
      )
    }
    let load:
      (image: KittyGraphics.Image, more: Bool, display: KittyGraphics.Display?)
    do { load = try loadAndAddKittyImage(command, action: action) } catch {
      result.message = error.message
      return result
    }
    if let display = load.display {
      var d = display
      d.imageID = load.image.id
      result = kittyDisplay(d, quiet: command.quiet)
    }
    if load.more { return KittyResponse() }
    if load.image.implicitID { return KittyResponse() }
    result.id = load.image.id
    return result
  }

  private mutating func loadAndAddKittyImage(
    _ command: KittyGraphics.Command,
    action: UInt8
  ) throws(KittyGraphics.LoadError) -> (
    image: KittyGraphics.Image, more: Bool, display: KittyGraphics.Display?
  ) {
    let storage = kittyImages
    let t = KittyGraphics.Transmission(command)!
    var loading: KittyGraphics.LoadingImage
    if var existing = storage.loading {
      // Own the buffer while appending: a shared one would be copied per chunk.
      storage.loading = nil
      do { try existing.addData(command.payload) } catch {
        storage.loading = existing
        if let id = Self.replacedImageID(existing) {
          deleteReplacedKittyImage(id)
        }
        throw error
      }
      if t.moreChunks {
        storage.loading = existing
        return (existing.image, true, nil)
      }
      storage.loading = nil
      loading = existing
    } else {
      do {
        loading = try KittyGraphics.LoadingImage(
          command: command,
          transmission: t,
          media: kittyGraphicsMedia,
          storageLimit: storage.limit,
          display: action == 0x54 ? KittyGraphics.Display(command) : nil
        )
      } catch {
        if t.imageID > 0 { deleteReplacedKittyImage(t.imageID) }
        throw error
      }
    }
    if loading.image.id == 0 {
      if loading.image.number > 0 {
        loading.image.id = storage.nextImageID(.explicit)
      } else {
        loading.image.id = storage.nextImageID(.implicit)
        loading.image.implicitID = true
      }
    }
    let replaced = Self.replacedImageID(loading)
    // A continuation with more chunks returned above, so this starts one.
    if t.moreChunks {
      storage.loading = loading
      return (loading.image, true, nil)
    }
    let image: KittyGraphics.Image
    do {
      image = try loading.complete()
      if let replaced { deleteReplacedKittyImage(replaced) }
      try kittyImages.add(image)
    } catch {
      if let replaced { deleteReplacedKittyImage(replaced) }
      throw error
    }
    return (kittyImages.image(id: image.id) ?? image, false, loading.display)
  }

  // MARK: Display

  private mutating func kittyDisplay(
    _ d: KittyGraphics.Display,
    quiet: KittyGraphics.Command.Quiet
  ) -> KittyResponse {
    guard d.imageID != 0 || d.imageNumber != 0 else {
      return KittyResponse(message: "EINVAL: image ID or number required")
    }
    var result = KittyResponse(
      id: d.imageID,
      imageNumber: d.imageNumber,
      placementID: d.placementID
    )
    if d.virtual, d.parentID > 0 {
      result.message = "EINVAL: virtual placement cannot refer to a parent"
      return result
    }
    let storage = kittyImages
    let g = kittyGeometry
    guard
      let image = d.imageID != 0
        ? storage.image(id: d.imageID) : storage.image(number: d.imageNumber)
    else {
      result.message = "ENOENT: image not found"
      return result
    }
    result.id = image.id
    let location: KittyImageStorage.Location
    if d.virtual {
      location = .virtual
    } else if d.parentID == 0 {
      location = .anchor(row: screenAbsoluteRow(cursor.y), column: cursor.x)
    } else {
      let child =
        d.placementID > 0
        ? KittyImageStorage.PlacementKey(
          imageID: image.id,
          external: true,
          id: d.placementID
        ) : nil
      do {
        let parent = try storage.resolveParent(
          child: child,
          imageID: d.parentID,
          placementID: d.parentPlacementID,
          g
        )
        location = .relative(
          parent: parent,
          horizontal: d.horizontalOffset,
          vertical: d.verticalOffset
        )
      } catch {
        result.message = error.message
        return result
      }
    }
    var p = KittyImageStorage.Placement(
      location: location,
      xOffset: d.xOffset,
      yOffset: d.yOffset,
      sourceX: d.x,
      sourceY: d.y,
      sourceWidth: d.width,
      sourceHeight: d.height,
      columns: d.columns,
      rows: d.rows,
      z: d.z
    )
    let offset = KittyImageStorage.cellOffset(p, g)
    if g.cellWidth > 0 { p.xOffset = offset.x }
    if g.cellHeight > 0 { p.yOffset = offset.y }
    do {
      try storage.addPlacement(
        imageID: image.id,
        placementID: result.placementID,
        p,
        g
      )
    } catch {
      result.message = error.message
      return result
    }
    guard case let .anchor(_, column) = location, d.movesCursor else {
      return result
    }
    let size = KittyImageStorage.gridSize(p, image, g)
    let target = column + Int(size.columns)
    let wraps = target >= columns
    let requested = max(0, Int(size.rows) - 1) + (wraps ? 1 : 0)
    let inRegion =
      cursor.y >= scrollTop && cursor.y <= scrollBottom
      && cursor.x >= scrollLeft && cursor.x <= scrollRight
    let beforeScroll = inRegion ? scrollBottom - cursor.y : 0
    for _ in 0 ..< min(requested, beforeScroll + rows) { index() }
    cursor.pendingWrap = false
    cursor.x = wraps ? 0 : min(target, columns - 1)
    return result
  }

  // MARK: Animation

  private mutating func kittyTransmitFrame(
    _ command: KittyGraphics.Command
  ) -> KittyResponse {
    let storage = kittyImages
    if var loading = storage.loading {
      if loading.frame == nil { return kittyTransmit(command, action: 0x74) }
      storage.loading = nil
      var result = loading.response
      do { try loading.addData(command.payload) } catch {
        storage.loading = loading
        result.message = error.message
        return result
      }
      if KittyGraphics.Transmission(command)?.moreChunks == true {
        storage.loading = loading
        return KittyResponse()
      }
      storage.loading = nil
      return completeKittyFrame(&loading)
    }
    guard let f = KittyGraphics.FrameLoad(command) else {
      return KittyResponse()
    }
    let t = f.transmission
    var result = KittyResponse(
      id: t.imageID,
      imageNumber: t.imageNumber,
      placementID: t.placementID,
      frame: f.editFrame
    )
    guard t.imageID != 0 || t.imageNumber != 0 else {
      result.message = "EINVAL: image ID or number required"
      return result
    }
    guard let id = storage.imageID(id: t.imageID, number: t.imageNumber),
      let image = storage.image(id: id)
    else {
      result.message = "ENOENT: image not found"
      return result
    }
    result.id = id
    var loading: KittyGraphics.LoadingImage
    do {
      loading = try KittyGraphics.LoadingImage(
        command: command,
        transmission: t,
        media: kittyGraphicsMedia,
        storageLimit: storage.limit,
        display: nil
      )
    } catch {
      result.message = error.message
      return result
    }
    loading.frame = .init(command: f, imageGeneration: image.generation)
    loading.response.id = id
    loading.response.frame = f.editFrame
    if t.moreChunks {
      storage.loading = loading
      return KittyResponse()
    }
    return completeKittyFrame(&loading)
  }

  private mutating func completeKittyFrame(
    _ loading: inout KittyGraphics.LoadingImage
  ) -> KittyResponse {
    let storage = kittyImages
    var result = loading.response
    let f = loading.frame!.command
    guard
      let id = storage.imageID(
        id: loading.image.id,
        number: loading.image.number
      ), var image = storage.image(id: id),
      image.generation == loading.frame!.imageGeneration
    else {
      result.message = "ENOENT: image not found"
      return result
    }
    guard let root = image.pixels else {
      result.message = "EINVAL: image data incomplete"
      return result
    }
    let frameImage: KittyGraphics.Image
    do { frameImage = try loading.complete() } catch {
      result.message = error.message
      return result
    }
    guard frameImage.width <= image.width, frameImage.height <= image.height
    else {
      result.message = "EINVAL: frame dimensions exceed image"
      return result
    }
    let src = frameImage.pixels!.rgba()
    // Composition happens in RGBA; convert the image first.
    if root.bytesPerPixel != 4 {
      let rgba = KittyImagePixels(
        width: root.width,
        height: root.height,
        bytesPerPixel: 4,
        bytes: root.rgba()
      )
      storage.totalBytes += rgba.bytes.count - root.bytes.count
      image.pixels = rgba
      image.format = .rgba
    }
    if image.animation == nil { image.animation = KittyGraphics.Animation() }
    let count = image.animation!.frameCount
    let number =
      f.editFrame == 0 || f.editFrame > count + 1 ? count + 1 : f.editFrame
    result.frame = number
    let frameLength = Int(image.width) * Int(image.height) * 4
    if number == count + 1 {
      let gap: UInt32 =
        f.gap > 0
        ? UInt32(f.gap) : f.gap < 0 ? 0 : KittyGraphics.defaultGapMilliseconds
      if f.baseFrame > 0, image.frame(f.baseFrame) == nil {
        storage.images[id] = image
        result.message = "EINVAL: base frame not found"
        return result
      }
      storage.images[id] = image
      guard storage.reserveAnimationBytes(frameLength, imageID: id),
        var stored = storage.image(id: id)
      else {
        result.message = "ENOSPC: animation frame storage full"
        return result
      }
      var canvas: [UInt8]
      if f.baseFrame > 0 {
        canvas = stored.frame(f.baseFrame)!.bytes
      } else {
        canvas = [UInt8](repeating: 0, count: frameLength)
        KittyGraphics.fillBackground(&canvas, f.background)
      }
      KittyGraphics.composeRect(
        &canvas,
        width: stored.width,
        height: stored.height,
        src,
        width: frameImage.width,
        height: frameImage.height,
        x: f.x,
        y: f.y,
        overwrite: f.overwrite
      )
      stored.animation!.frames
        .append(
          .init(
            pixels: KittyImagePixels(
              width: Int(stored.width),
              height: Int(stored.height),
              bytesPerPixel: 4,
              bytes: canvas
            ),
            gap: gap
          )
        )
      storage.images[id] = stored
      storage.markMutated()
    } else {
      guard var dst = image.frame(number)?.bytes else {
        storage.images[id] = image
        result.message = "EINVAL: frame data incomplete"
        return result
      }
      if f.gap != 0 {
        image.animation!.setGap(at: number - 1, f.gap > 0 ? UInt32(f.gap) : 0)
      }
      KittyGraphics.composeRect(
        &dst,
        width: image.width,
        height: image.height,
        src,
        width: frameImage.width,
        height: frameImage.height,
        x: f.x,
        y: f.y,
        overwrite: f.overwrite
      )
      image.setFrame(
        number,
        KittyImagePixels(
          width: Int(image.width),
          height: Int(image.height),
          bytesPerPixel: 4,
          bytes: dst
        )
      )
      let current = number - 1 == image.animation!.currentIndex
      if current { image.animation!.frameShownAt = nil }
      storage.images[id] = image
      if current {
        storage.markContentChanged(id)
      } else {
        storage.markMutated()
      }
    }
    return result
  }

  private mutating func kittyControlAnimation(
    _ c: KittyGraphics.Command
  ) -> KittyResponse {
    let storage = kittyImages
    var result = KittyResponse(
      id: c.value("i"),
      imageNumber: c.value("I"),
      placementID: c.value("p")
    )
    guard c.value("i") != 0 || c.value("I") != 0 else {
      result.message = "EINVAL: image ID or number required"
      return result
    }
    guard let id = storage.imageID(id: c.value("i"), number: c.value("I")),
      var image = storage.image(id: id)
    else {
      result.message = "ENOENT: image not found"
      return result
    }
    var anim = image.animation ?? KittyGraphics.Animation()
    var mutated = false
    var contentChanged = false
    let frame = c.value("r")
    let gap = c.signed("z")
    if frame != 0, frame <= anim.frameCount, gap != 0 {
      anim.setGap(at: frame - 1, gap > 0 ? UInt32(gap) : 0)
      mutated = true
    }
    let current = c.value("c")
    if current != 0, current <= anim.frameCount,
      current - 1 != anim.currentIndex
    {
      anim.currentIndex = current - 1
      anim.frameShownAt = nil
      contentChanged = true
    }
    let state: KittyGraphics.Animation.State? =
      switch c.value("s") {
      case 1: .stopped
      case 2: .loading
      case 3: .running
      default: nil
      }
    if let state {
      if anim.state == .stopped, state != .stopped { anim.frameShownAt = nil }
      anim.state = state
      anim.currentLoop = 0
      mutated = true
    }
    let loops = c.value("v")
    if loops != 0 {
      anim.maxLoops = loops - 1
      mutated = true
    }
    image.animation = anim
    storage.images[id] = image
    if contentChanged {
      storage.markContentChanged(id)
    } else if mutated {
      storage.markMutated()
    }
    return KittyResponse()
  }

  private mutating func kittyComposeAnimation(
    _ c: KittyGraphics.Command
  ) -> KittyResponse {
    let storage = kittyImages
    var result = KittyResponse(
      id: c.value("i"),
      imageNumber: c.value("I"),
      placementID: c.value("p")
    )
    guard c.value("i") != 0 || c.value("I") != 0 else {
      result.message = "EINVAL: image ID or number required"
      return result
    }
    guard let id = storage.imageID(id: c.value("i"), number: c.value("I")),
      var image = storage.image(id: id)
    else {
      result.message = "ENOENT: image not found"
      return result
    }
    result.id = id
    guard image.pixels != nil else {
      result.message = "EINVAL: image data incomplete"
      return result
    }
    let sourceFrame = c.value("r")
    let destFrame = c.value("c")
    guard image.frame(sourceFrame) != nil else {
      result.message = "ENOENT: source frame not found"
      return result
    }
    guard image.frame(destFrame) != nil else {
      result.message = "ENOENT: destination frame not found"
      return result
    }
    let x = UInt64(c.value("x"))
    let y = UInt64(c.value("y"))
    let left = UInt64(c.value("X"))
    let top = UInt64(c.value("Y"))
    let width = UInt64(c.value("w") > 0 ? c.value("w") : image.width)
    let height = UInt64(c.value("h") > 0 ? c.value("h") : image.height)
    guard x + width <= UInt64(image.width), y + height <= UInt64(image.height)
    else {
      result.message = "EINVAL: destination rectangle out of bounds"
      return result
    }
    guard left + width <= UInt64(image.width),
      top + height <= UInt64(image.height)
    else {
      result.message = "EINVAL: source rectangle out of bounds"
      return result
    }
    if sourceFrame == destFrame {
      let xOverlaps = max(left, x) < min(left, x) + width
      let yOverlaps = max(top, y) < min(top, y) + height
      if xOverlaps, yOverlaps {
        result.message = "EINVAL: source and destination rectangles overlap"
        return result
      }
    }
    if image.pixels!.bytesPerPixel != 4 {
      let root = image.pixels!
      let rgba = KittyImagePixels(
        width: root.width,
        height: root.height,
        bytesPerPixel: 4,
        bytes: root.rgba()
      )
      storage.totalBytes += rgba.bytes.count - root.bytes.count
      image.pixels = rgba
      image.format = .rgba
      storage.images[id] = image
      storage.markContentChanged(id)
      image = storage.image(id: id)!
    }
    let src = image.frame(sourceFrame)!.bytes
    var dst = image.frame(destFrame)!.bytes
    KittyGraphics.composeCanvasRect(
      &dst,
      src,
      canvasWidth: image.width,
      width: Int(width),
      height: Int(height),
      srcX: UInt32(left),
      srcY: UInt32(top),
      dstX: UInt32(x),
      dstY: UInt32(y),
      overwrite: c.value("C") != 0
    )
    image.setFrame(
      destFrame,
      KittyImagePixels(
        width: Int(image.width),
        height: Int(image.height),
        bytesPerPixel: 4,
        bytes: dst
      )
    )
    storage.images[id] = image
    let current = image.animation?.currentIndex ?? 0
    if destFrame - 1 == current {
      storage.markContentChanged(id)
    } else {
      storage.markMutated()
    }
    return result
  }

  /// Advances animations on the active screen; the delay in ms until the
  /// next frame change, or nil when nothing animates.
  public mutating func kittyAnimationTick(now milliseconds: UInt64) -> UInt64? {
    kittyImages.animationTick(now: milliseconds)
  }

  // MARK: Terminal hooks

  /// Runs a region scroll of the active screen, moving and clipping
  /// placements entirely inside the region (Ghostty `scrollMarginsBegin`).
  @inline(__always)
  mutating func withKittyScroll(
    delta: Int,
    inPlace: Bool,
    _ body: (inout TerminalState) -> Void
  ) {
    // Hot path: no placements on either screen.
    if kittyPrimary.placements.isEmpty, kittyAlternate.placements.isEmpty {
      return body(&self)
    }
    kittyScroll(delta: delta, inPlace: inPlace, body)
  }

  @inline(never)
  private mutating func kittyScroll(
    delta: Int,
    inPlace: Bool,
    _ body: (inout TerminalState) -> Void
  ) {
    let storage = kittyImages
    guard !storage.placements.isEmpty else { return body(&self) }
    let fullScreen =
      scrollTop == 0 && scrollBottom == rows - 1 && scrollLeft == 0
      && scrollRight == columns - 1
    // Rows scrolling into history keep their absolute numbers; an
    // in-place scroll (SD, RI) moves text under fixed anchors instead.
    if fullScreen, !isAlternateScreen, !inPlace {
      storage.markDirty()
      return body(&self)
    }
    let restores = storage.beginScroll(
      delta: delta,
      top: scrollTop,
      bottom: scrollBottom,
      left: scrollLeft,
      right: scrollRight,
      inPlace: inPlace,
      kittyGeometry
    )
    body(&self)
    storage.endScroll(restores, screenTop: screenAbsoluteRow(0))
  }

  /// ED 2, ED 22, 1049, Cmd-K: see `KittyImageStorage.clearScreen`.
  mutating func kittyClearScreen() {
    guard !kittyImages.images.isEmpty else { return }
    kittyImages.clearScreen(kittyGeometry)
  }

  /// Cmd-K: delete every placement on the active screen and in its
  /// history, then every image left unplaced.
  public mutating func clearKittyImages() {
    abandonKittyLoad()
    let storage = kittyImages
    if !isAlternateScreen { storage.eraseHistory(before: primaryScreenTop) }
    storage.clearScreen(kittyGeometry)
  }

  /// RIS: storage is rebuilt with its limits.
  mutating func resetKittyGraphics() {
    kittyCommand = nil
    presentationImages = []
    for storage in [kittyPrimary, kittyAlternate] {
      let dirty = storage.dirty
      storage.images = [:]
      storage.placements = [:]
      storage.totalBytes = 0
      storage.loading = nil
      storage.markMutated()
      storage.dirty = dirty &+ 1
    }
  }

  /// Absolute row of the primary screen's top row, whichever is active.
  var primaryScreenTop: Int {
    isAlternateScreen
      ? inactiveGrid.historyEvicted + inactiveGrid.historyCount
      : grid.historyEvicted + grid.historyCount
  }

  /// Re-applies the storage limit to both screens.
  func applyImageStorageLimit() {
    kittyPrimary.setLimit(imageStorageLimit)
    kittyAlternate.setLimit(imageStorageLimit)
  }
}
