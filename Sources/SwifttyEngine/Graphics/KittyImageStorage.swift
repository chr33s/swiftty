import Synchronization

/// Per-screen kitty graphics storage: images, placements, eviction and
/// deletes.
///
/// Ported from Ghostty's `src/terminal/kitty/graphics_storage.zig` at
/// 167acf0c. Ghostty anchors placements with page pins; Swiftty has none,
/// so an anchored placement stores an absolute row (stable while output
/// scrolls the primary screen into history) and the terminal moves
/// anchors explicitly for region scrolls, reflow and history erases
/// (spec.graphics.md §9.1). Deviation D9: on the alternate screen,
/// full-screen scrolls move and clip placements like region scrolls, as
/// in kitty, where Ghostty leaves pins on the top row in place.
final class KittyImageStorage {
  typealias Image = KittyGraphics.Image

  struct PlacementKey: Hashable {
    var imageID: UInt32
    var external: Bool
    var id: UInt32

    /// External ids win, then the lowest id.
    func preferred(over other: PlacementKey) -> Bool {
      if external != other.external { return external }
      return id < other.id
    }
  }

  enum Location: Equatable {
    /// Top-left cell: absolute row (see `TerminalState.screenAbsoluteRow`)
    /// and column.
    case anchor(row: Int, column: Int)
    case virtual
    case relative(parent: PlacementKey, horizontal: Int32, vertical: Int32)
  }

  struct Placement: Equatable {
    var location: Location
    var xOffset: UInt32 = 0
    var yOffset: UInt32 = 0
    var sourceX: UInt32 = 0
    var sourceY: UInt32 = 0
    var sourceWidth: UInt32 = 0
    var sourceHeight: UInt32 = 0
    var columns: UInt32 = 0
    var rows: UInt32 = 0
    var z: Int32 = 0
  }

  /// Terminal geometry placement maths depends on.
  struct Geometry {
    var cellWidth: UInt32
    var cellHeight: UInt32
    var columns: Int
    var rows: Int
    /// Absolute row of screen row 0.
    var screenTop: Int
    /// First retained absolute row; anchors above it are garbage.
    var firstRow: Int
  }

  var limit: Int
  var images: [UInt32: Image] = [:]
  var placements: [PlacementKey: Placement] = [:]
  var totalBytes = 0
  var loading: KittyGraphics.LoadingImage?
  /// Bumped when placements may have moved.
  var dirty: UInt64 = 0
  /// Process-global stamp of the last content change.
  var generation: UInt64 = 0
  private var nextImplicitID: UInt32 = 2_147_483_647
  private var nextInternalPlacementID: UInt32 = 0
  var nextInternalPlacementIDForCheckpoint: UInt32 {
    get { nextInternalPlacementID }
    set { nextInternalPlacementID = newValue }
  }
  private var animationIdleGeneration: UInt64?

  private static let generations = Atomic<UInt64>(0)
  static func nextGeneration() -> UInt64 {
    generations.add(1, ordering: .relaxed).newValue
  }

  init(limit: Int) { self.limit = limit }

  var isEnabled: Bool { limit != 0 }

  func markMutated() {
    markDirty()
    generation = Self.nextGeneration()
  }

  func markDirty() { dirty &+= 1 }

  /// Lowers or raises the byte limit; 0 wipes storage and disables the
  /// protocol.
  func setLimit(_ newLimit: Int) {
    if newLimit == 0 {
      images = [:]
      placements = [:]
      totalBytes = 0
      loading = nil
      markMutated()
    }
    if newLimit < totalBytes { _ = evict(totalBytes - newLimit, except: nil) }
    limit = max(0, newLimit)
  }

  // MARK: Images

  enum IDMode { case explicit, implicit }

  func nextImageID(_ mode: IDMode) -> UInt32 {
    var id: UInt32 = mode == .explicit ? 1 : nextImplicitID
    for _ in 0 ..< images.count + 2 {
      if id != 0, images[id] == nil { break }
      id &+= 1
    }
    if id == 0 { id = 1 }
    if mode == .implicit { nextImplicitID = id &+ 1 }
    return id
  }

  func image(id: UInt32) -> Image? { images[id] }

  /// The newest image transmitted with `number`.
  func image(number: UInt32) -> Image? {
    var newest: Image?
    for image in images.values where image.number == number {
      if newest == nil || image.transmission > newest!.transmission {
        newest = image
      }
    }
    return newest
  }

  func imageID(id: UInt32, number: UInt32) -> UInt32? {
    if id != 0 { return images[id] == nil ? nil : id }
    return image(number: number)?.id
  }

  /// Stores `image`, replacing an image with the same id and its
  /// placements. Throws `.outOfMemory` when eviction cannot make room.
  func add(_ image: Image) throws(KittyGraphics.LoadError) {
    let size = image.storageSize
    guard size <= limit else { throw .outOfMemory }
    let old = images[image.id]?.storageSize ?? 0
    let total = totalBytes - old + size
    if total > limit {
      guard evict(total - limit, except: image.id) else { throw .outOfMemory }
    }
    if let existing = images[image.id] {
      removePlacements(imageID: image.id)
      _ = removeOrphans(deleteUnused: false)
      totalBytes -= existing.storageSize
    }
    var stored = image
    stored.placementCount = 0
    markMutated()
    stored.generation = generation
    stored.transmission = generation
    images[image.id] = stored
    totalBytes += size
  }

  func markContentChanged(_ id: UInt32) {
    markMutated()
    images[id]?.generation = generation
  }

  // MARK: Placements

  /// Adds or replaces a placement; `placementID` 0 gets an internal id.
  func addPlacement(
    imageID: UInt32,
    placementID: UInt32,
    _ placement: Placement,
    _ g: Geometry
  ) throws(KittyGraphics.LoadError) {
    precondition(images[imageID] != nil)
    reapGarbage(g)
    let key: PlacementKey
    if placementID == 0 {
      key = PlacementKey(
        imageID: imageID,
        external: false,
        id: nextInternalPlacementID
      )
      nextInternalPlacementID &+= 1
    } else {
      key = PlacementKey(imageID: imageID, external: true, id: placementID)
    }
    if placements[key] == nil {
      guard images[imageID]!.placementCount < 1 << 30 else {
        throw .outOfMemory
      }
      images[imageID]!.placementCount += 1
    }
    placements[key] = placement
    markMutated()
  }

  private func removePlacement(_ key: PlacementKey) {
    guard placements.removeValue(forKey: key) != nil else { return }
    images[key.imageID]?.placementCount -= 1
  }

  private func removePlacements(imageID: UInt32) {
    for key in placements.keys where key.imageID == imageID {
      removePlacement(key)
    }
  }

  /// Removes relative placements whose parent is gone, transitively.
  @discardableResult
  func removeOrphans(deleteUnused: Bool) -> Bool {
    var any = false
    var removed = true
    while removed {
      removed = false
      for (key, p) in placements {
        guard case let .relative(parent, _, _) = p.location,
          placements[parent] == nil
        else { continue }
        removePlacement(key)
        removed = true
        any = true
        if deleteUnused { deleteIfUnused(key.imageID) }
      }
    }
    return any
  }

  func isGarbage(_ p: Placement, _ g: Geometry) -> Bool {
    if case let .anchor(row, _) = p.location { return row < g.firstRow }
    return false
  }

  /// Drops placements whose anchor row left retained history.
  func reapGarbage(_ g: Geometry) {
    var removed = false
    for (key, p) in placements where isGarbage(p, g) {
      removePlacement(key)
      removed = true
    }
    guard removed else { return }
    removeOrphans(deleteUnused: false)
    markMutated()
  }

  enum ParentError: Error {
    case parentImageNotFound, parentPlacementNotFound, selfParent, cycle,
      tooDeep
    case ancestorNotFound

    var message: String {
      switch self {
      case .parentImageNotFound: "ENOPARENT: parent image not found"
      case .parentPlacementNotFound: "ENOPARENT: parent placement not found"
      case .selfParent: "EINVAL: placement cannot be its own parent"
      case .cycle: "ECYCLE: parent chain creates a cycle"
      case .tooDeep: "ETOODEEP: parent chain too deep"
      case .ancestorNotFound: "ENOENT: parent chain ancestor not found"
      }
    }
  }

  static let parentChainLimit = 8

  func resolveParent(
    child: PlacementKey?,
    imageID: UInt32,
    placementID: UInt32,
    _ g: Geometry
  ) throws(ParentError) -> PlacementKey {
    reapGarbage(g)
    guard images[imageID] != nil else { throw .parentImageNotFound }
    let parent: PlacementKey
    if placementID > 0 {
      parent = PlacementKey(imageID: imageID, external: true, id: placementID)
      guard placements[parent] != nil else { throw .parentPlacementNotFound }
    } else {
      var best: PlacementKey?
      for key in placements.keys where key.imageID == imageID {
        if best == nil || key.preferred(over: best!) { best = key }
      }
      guard let best else { throw .parentPlacementNotFound }
      parent = best
    }
    if let child, child == parent { throw .selfParent }
    var depth = 1
    var key = parent
    while true {
      if let child, key == child { throw .cycle }
      guard let p = placements[key] else { throw .ancestorNotFound }
      guard case let .relative(next, _, _) = p.location else { break }
      if depth >= Self.parentChainLimit { throw .tooDeep }
      depth += 1
      key = next
    }
    return parent
  }

  struct Chain {
    var rootKey: PlacementKey
    var root: Placement
    var horizontal: Int32
    var vertical: Int32
  }

  func resolveChain(
    parent: PlacementKey,
    horizontal: Int32,
    vertical: Int32
  ) -> Chain? {
    var h = horizontal
    var v = vertical
    var key = parent
    var depth = 1
    while true {
      guard let p = placements[key] else { return nil }
      switch p.location {
      case let .relative(next, ph, pv):
        if depth >= Self.parentChainLimit { return nil }
        depth += 1
        h =
          h.addingReportingOverflow(ph).overflow
          ? (ph < 0 ? .min : .max) : h + ph
        v =
          v.addingReportingOverflow(pv).overflow
          ? (pv < 0 ? .min : .max) : v + pv
        key = next
      case .anchor, .virtual:
        return Chain(rootKey: key, root: p, horizontal: h, vertical: v)
      }
    }
  }

  /// The virtual placement a placeholder run with these ids draws.
  func placeholderTarget(
    imageID: UInt32,
    placementID: UInt32
  ) -> (PlacementKey, Placement)? {
    if placementID > 0 {
      let key = PlacementKey(imageID: imageID, external: true, id: placementID)
      guard let p = placements[key], p.location == .virtual else { return nil }
      return (key, p)
    }
    var best: PlacementKey?
    for (key, p) in placements
    where key.imageID == imageID && p.location == .virtual {
      if best == nil || key.preferred(over: best!) { best = key }
    }
    guard let best else { return nil }
    return (best, placements[best]!)
  }

  // MARK: Eviction

  func deleteIfUnused(_ id: UInt32) {
    guard let image = images[id], image.placementCount == 0 else { return }
    totalBytes -= image.storageSize
    images[id] = nil
  }

  /// Evicts at least `bytes`, lowest priority first: transient unused,
  /// unused, transient used, used; then oldest transmission, lowest id.
  @discardableResult
  func evict(_ bytes: Int, except excluded: UInt32?) -> Bool {
    let before = images.count
    defer {
      if images.count != before {
        removeOrphans(deleteUnused: false)
        markMutated()
      }
    }
    var evicted = 0
    while evicted < bytes {
      var best: (priority: Int, transmission: UInt64, id: UInt32)?
      for image in images.values where image.id != excluded {
        let c = (
          priority: (image.transient ? 0 : 1)
            + (image.placementCount > 0 ? 2 : 0),
          transmission: image.transmission, id: image.id
        )
        if best == nil || c < best! { best = c }
      }
      guard let best else { return false }
      removePlacements(imageID: best.id)
      let size = images[best.id]!.storageSize
      evicted += size
      totalBytes -= size
      images[best.id] = nil
    }
    return true
  }

  func reserveAnimationBytes(_ bytes: Int, imageID: UInt32) -> Bool {
    guard bytes <= limit else { return false }
    let total = totalBytes + bytes
    if total > limit {
      let required = total - limit
      guard required <= limit, evict(required, except: imageID) else {
        return false
      }
    }
    totalBytes += bytes
    return true
  }

  // MARK: Geometry

  static func saturatingMul(_ a: UInt32, _ b: UInt32) -> UInt32 {
    let (v, o) = a.multipliedReportingOverflow(by: b)
    return o ? .max : v
  }

  static func scale(
    _ value: UInt32,
    _ numerator: UInt32,
    _ denominator: UInt32
  ) -> UInt32 {
    guard denominator != 0 else { return 0 }
    let r =
      (UInt64(value) * UInt64(numerator) + UInt64(denominator) / 2)
      / UInt64(denominator)
    return UInt32(clamping: r)
  }

  struct Rect { var x: UInt32, y: UInt32, width: UInt32, height: UInt32 }

  static func sourceRect(_ p: Placement, _ image: Image) -> Rect {
    let x = min(p.sourceX, image.width)
    let y = min(p.sourceY, image.height)
    return Rect(
      x: x,
      y: y,
      width: min(
        p.sourceWidth > 0 ? p.sourceWidth : image.width,
        image.width - x
      ),
      height: min(
        p.sourceHeight > 0 ? p.sourceHeight : image.height,
        image.height - y
      )
    )
  }

  static func cellOffset(
    _ p: Placement,
    _ g: Geometry
  ) -> (x: UInt32, y: UInt32) {
    (
      g.cellWidth > 0 ? min(p.xOffset, g.cellWidth - 1) : 0,
      g.cellHeight > 0 ? min(p.yOffset, g.cellHeight - 1) : 0
    )
  }

  static func pixelSize(
    _ p: Placement,
    _ image: Image,
    _ g: Geometry
  ) -> (width: UInt32, height: UInt32) {
    let source = sourceRect(p, image)
    if p.columns == 0, p.rows == 0 { return (source.width, source.height) }
    let offset = cellOffset(p, g)
    if p.columns > 0, p.rows > 0 {
      let w = saturatingMul(g.cellWidth, p.columns)
      let h = saturatingMul(g.cellHeight, p.rows)
      return (
        w >= offset.x ? w - offset.x : 0, h >= offset.y ? h - offset.y : 0
      )
    }
    if p.columns > 0 {
      let full = saturatingMul(g.cellWidth, p.columns)
      let w = full >= offset.x ? full - offset.x : 0
      return (w, scale(w, source.height, source.width))
    }
    let full = saturatingMul(g.cellHeight, p.rows)
    let h = full >= offset.y ? full - offset.y : 0
    return (scale(h, source.width, source.height), h)
  }

  static func gridSize(
    _ p: Placement,
    _ image: Image,
    _ g: Geometry
  ) -> (columns: UInt32, rows: UInt32) {
    if p.columns > 0, p.rows > 0 { return (p.columns, p.rows) }
    guard g.cellWidth > 0, g.cellHeight > 0 else { return (0, 0) }
    let size = pixelSize(p, image, g)
    let offset = cellOffset(p, g)
    func ceilDiv(_ a: UInt32, _ b: UInt32) -> UInt32 {
      UInt32((UInt64(a) + UInt64(b) - 1) / UInt64(b))
    }
    let w = UInt32(clamping: UInt64(size.width) + UInt64(offset.x))
    let h = UInt32(clamping: UInt64(size.height) + UInt64(offset.y))
    return (ceilDiv(w, g.cellWidth), ceilDiv(h, g.cellHeight))
  }

  /// Covered cells of an anchored placement in absolute rows; nil for
  /// virtual, relative, garbage or zero-size placements. The bottom is
  /// clamped to the screen's last row.
  static func cells(
    _ p: Placement,
    _ image: Image,
    _ g: Geometry
  ) -> (top: Int, left: Int, bottom: Int, right: Int)? {
    guard case let .anchor(row, column) = p.location, row >= g.firstRow else {
      return nil
    }
    let size = gridSize(p, image, g)
    guard size.columns > 0, size.rows > 0 else { return nil }
    let bottom = min(row + Int(size.rows) - 1, g.screenTop + g.rows - 1)
    let right = min(column + Int(size.columns) - 1, g.columns - 1)
    return (row, column, max(bottom, row), right)
  }

  // MARK: Clipping for region scrolls

  static func clipTop(
    _ p: inout Placement,
    _ image: Image,
    _ g: Geometry,
    count: UInt32,
    span: UInt32
  ) -> Bool {
    let src = sourceRect(p, image)
    let crop =
      p.rows > 0
      ? UInt32(UInt64(src.height) * UInt64(count) / UInt64(span))
      : saturatingMul(g.cellHeight, count)
    guard crop < src.height else { return false }
    p.sourceX = src.x
    p.sourceY = src.y + crop
    p.sourceWidth = src.width
    p.sourceHeight = src.height - crop
    if p.rows > 0 { p.rows -= count }
    return true
  }

  static func clipBottom(
    _ p: inout Placement,
    _ image: Image,
    _ g: Geometry,
    count: UInt32,
    span: UInt32
  ) -> Bool {
    let src = sourceRect(p, image)
    guard src.height > 0 else { return false }
    if p.rows > 0 {
      let crop = UInt32(UInt64(src.height) * UInt64(count) / UInt64(span))
      guard crop < src.height else { return false }
      p.sourceHeight = src.height - crop
      p.rows -= count
    } else {
      let visible = saturatingMul(g.cellHeight, span - count)
      let offset = cellOffset(p, g).y
      guard visible > offset else { return false }
      p.sourceHeight = min(src.height, visible - offset)
    }
    p.sourceX = src.x
    p.sourceY = src.y
    p.sourceWidth = src.width
    return true
  }

  /// Screen rows placements in the active area end on after a region
  /// scroll; applied by `endScroll` once the grid has moved.
  struct ScrollRestore {
    var key: PlacementKey
    var column: Int
    var y: Int
  }

  /// Ghostty's `scrollMarginsBegin`: placements entirely inside the
  /// region move by `delta` rows and clip at its margins; others stay.
  /// `inPlace` limits the work to placements anchored on region rows.
  func beginScroll(
    delta: Int,
    top: Int,
    bottom: Int,
    left: Int,
    right: Int,
    inPlace: Bool,
    _ g: Geometry
  ) -> [ScrollRestore] {
    var restores: [ScrollRestore] = []
    var mutated = false
    for (key, var p) in placements {
      guard case let .anchor(row, column) = p.location, row >= g.firstRow else {
        continue
      }
      let y = row - g.screenTop
      guard y >= 0, y < g.rows else { continue }
      if inPlace, y < top || y > bottom { continue }
      var finalY = y
      if let image = images[key.imageID] {
        let size = Self.gridSize(p, image, g)
        let rows = Int(size.rows)
        let contained =
          size.rows > 0 && size.columns > 0 && y >= top
          && y + rows - 1 <= bottom && column >= left
          && min(column + Int(size.columns) - 1, g.columns - 1) <= right
        if contained {
          let newY = y + delta
          let topClip = max(0, top - newY)
          let bottomClip = max(0, newY + rows - 1 - bottom)
          var visible = topClip < rows && bottomClip < rows
          if visible, topClip > 0 {
            visible = Self.clipTop(
              &p,
              image,
              g,
              count: UInt32(topClip),
              span: size.rows
            )
            if visible {
              finalY = top
              placements[key] = p
              mutated = true
            }
          } else if visible {
            if bottomClip > 0 {
              visible = Self.clipBottom(
                &p,
                image,
                g,
                count: UInt32(bottomClip),
                span: size.rows
              )
              if visible {
                placements[key] = p
                mutated = true
              }
            }
            if visible { finalY = newY }
          }
          if !visible {
            removePlacement(key)
            mutated = true
            continue
          }
        }
      }
      restores.append(ScrollRestore(key: key, column: column, y: finalY))
    }
    if mutated {
      removeOrphans(deleteUnused: false)
      markMutated()
    }
    markDirty()
    return restores
  }

  func endScroll(_ restores: [ScrollRestore], screenTop: Int) {
    for r in restores {
      placements[r.key]?.location = .anchor(
        row: screenTop + r.y,
        column: r.column
      )
    }
  }

  // MARK: History and clearing

  /// Removes placements anchored in history rows below `limit`
  /// (absolute); nil erases all history.
  func eraseHistory(before limit: Int) {
    var removed = false
    for (key, p) in placements {
      guard case let .anchor(row, _) = p.location, row < limit else { continue }
      removePlacement(key)
      removed = true
    }
    guard removed else { return }
    removeOrphans(deleteUnused: false)
    markMutated()
  }

  /// Moves active-area anchors after an operation renumbered rows.
  func rebase(from oldTop: Int, to newTop: Int, rows: Int) {
    guard oldTop != newTop else { return }
    for (key, p) in placements {
      guard case let .anchor(row, column) = p.location, row >= oldTop,
        row < oldTop + rows
      else { continue }
      placements[key]?.location = .anchor(
        row: row - oldTop + newTop,
        column: column
      )
    }
    markDirty()
  }

  /// ED 2 / ED 22: delete visible anchored placements, their orphans,
  /// then every unplaced image.
  func clearScreen(_ g: Geometry) {
    let before = (placements.count, images.count)
    deleteVisible(g, deleteUnused: true)
    removeOrphans(deleteUnused: false)
    for id in Array(images.keys) { deleteIfUnused(id) }
    if before != (placements.count, images.count) { markMutated() }
  }

  private func deleteVisible(_ g: Geometry, deleteUnused: Bool) {
    for (key, p) in placements {
      guard case let .anchor(row, _) = p.location, row >= g.firstRow else {
        continue
      }
      if row < g.screenTop {
        guard let image = images[key.imageID], let r = Self.cells(p, image, g),
          r.bottom >= g.screenTop
        else { continue }
      }
      removePlacement(key)
      if deleteUnused { deleteIfUnused(key.imageID) }
    }
  }

  /// `a=d`.
  func delete(
    _ action: KittyGraphics.Delete,
    cursor: (x: Int, y: Int),
    _ g: Geometry
  ) {
    let before = (placements.count, images.count)
    defer { if before != (placements.count, images.count) { markMutated() } }
    func deleteByID(_ id: UInt32, _ placementID: UInt32, _ unused: Bool) {
      var matched = placementID == 0
      if placementID == 0 {
        removePlacements(imageID: id)
      } else {
        let key = PlacementKey(imageID: id, external: true, id: placementID)
        if placements[key] != nil {
          removePlacement(key)
          matched = true
        }
      }
      if unused, matched { deleteIfUnused(id) }
    }
    func intersecting(row: Int, column: Int, z: Int32?, _ unused: Bool) {
      for (key, p) in placements {
        guard let image = images[key.imageID], let r = Self.cells(p, image, g),
          r.top <= row, row <= r.bottom, r.left <= column, column <= r.right
        else { continue }
        if let z, p.z != z { continue }
        removePlacement(key)
        if unused { deleteIfUnused(key.imageID) }
      }
    }
    switch action {
    case let .all(unused): deleteVisible(g, deleteUnused: unused)
    case let .id(unused, id, pid): deleteByID(id, pid, unused)
    case let .newest(unused, number, pid):
      if let image = image(number: number) { deleteByID(image.id, pid, unused) }
    case let .cursor(unused):
      intersecting(
        row: g.screenTop + cursor.y,
        column: cursor.x,
        z: nil,
        unused
      )
    case let .cell(unused, x, y):
      guard x > 0, y > 0, Int(y) <= g.rows, Int(x) <= g.columns else { break }
      intersecting(
        row: g.screenTop + Int(y) - 1,
        column: Int(x) - 1,
        z: nil,
        unused
      )
    case let .cellZ(unused, x, y, z):
      guard x > 0, y > 0, Int(y) <= g.rows, Int(x) <= g.columns else { break }
      intersecting(
        row: g.screenTop + Int(y) - 1,
        column: Int(x) - 1,
        z: z,
        unused
      )
    case let .column(unused, x):
      guard x > 0 else { break }
      let column = Int(x) - 1
      for (key, p) in placements {
        guard let image = images[key.imageID], let r = Self.cells(p, image, g),
          r.left <= column, r.right >= column
        else { continue }
        removePlacement(key)
        if unused { deleteIfUnused(key.imageID) }
      }
    case let .row(unused, y):
      guard y > 0, Int(y) <= g.rows else { break }
      let row = g.screenTop + Int(y) - 1
      for (key, p) in placements {
        guard let image = images[key.imageID], let r = Self.cells(p, image, g),
          r.top <= row, r.bottom >= row
        else { continue }
        removePlacement(key)
        if unused { deleteIfUnused(key.imageID) }
      }
    case let .z(unused, z):
      for (key, p) in placements where p.location != .virtual && p.z == z {
        removePlacement(key)
        if unused { deleteIfUnused(key.imageID) }
      }
    case let .range(unused, first, last):
      guard last != 0, first <= last else { break }
      for key in placements.keys where (first ... last).contains(key.imageID) {
        removePlacement(key)
      }
      if unused {
        for id in Array(images.keys) where (first ... last).contains(id) {
          deleteIfUnused(id)
        }
      }
    case let .frames(unused, id, number, frame):
      deleteFrame(
        unused: unused,
        imageID: id,
        imageNumber: number,
        frame: frame
      )
    }
    removeOrphans(deleteUnused: action.deletesImages)
  }

  private func deleteFrame(
    unused: Bool,
    imageID: UInt32,
    imageNumber: UInt32,
    frame: UInt32
  ) {
    guard imageID != 0 || imageNumber != 0,
      let id = self.imageID(id: imageID, number: imageNumber),
      var image = images[id]
    else { return }
    guard var animation = image.animation, !animation.frames.isEmpty else {
      guard unused else { return }
      removePlacements(imageID: id)
      totalBytes -= image.storageSize
      images[id] = nil
      return
    }
    let count = animation.frameCount
    var number = min(frame, count)
    if number == 0 { number = 1 }
    if number == 1 {
      totalBytes -= image.pixels?.bytes.count ?? 0
      let promoted = animation.frames.removeFirst()
      image.pixels = promoted.pixels
      animation.rootGap = promoted.gap
    } else {
      let removed = animation.frames.remove(at: Int(number) - 2)
      totalBytes -= removed.pixels.bytes.count
    }
    // 0-based over all frames, root included, like `currentIndex`.
    let removedIndex = number - 1
    let remaining = UInt32(animation.frames.count)
    var contentChanged = false
    if animation.currentIndex > remaining {
      animation.currentIndex = remaining
      animation.frameShownAt = nil
      contentChanged = true
    } else if removedIndex == animation.currentIndex {
      animation.frameShownAt = nil
      contentChanged = true
    } else if removedIndex < animation.currentIndex {
      animation.currentIndex -= 1
    }
    image.animation = animation
    images[id] = image
    if contentChanged { markContentChanged(id) } else { markMutated() }
  }

  // MARK: Animation playback

  /// Advances running animations at `now` (ms); returns the delay until
  /// the next frame change, or nil when nothing is animating.
  func animationTick(now: UInt64) -> UInt64? {
    if animationIdleGeneration == generation { return nil }
    var minDelay: UInt64?
    for id in Array(images.keys) {
      guard var image = images[id], var anim = image.animation,
        anim.state != .stopped, !anim.frames.isEmpty, image.placementCount > 0,
        image.pixels != nil, anim.duration > 0,
        anim.maxLoops == 0 || anim.currentLoop < anim.maxLoops
      else { continue }
      let shownAt = min(anim.frameShownAt ?? now, now)
      anim.frameShownAt = shownAt
      var nextAt = shownAt &+ UInt64(anim.gap(at: anim.currentIndex))
      var changed = false
      if now >= nextAt {
        let count = anim.frameCount
        var index = anim.currentIndex
        var advanced = true
        while true {
          let next = (index + 1) % count
          if next == 0 {
            if anim.state == .loading {
              advanced = false
              break
            }
            anim.currentLoop += 1
            if anim.maxLoops > 0, anim.currentLoop >= anim.maxLoops {
              advanced = false
              break
            }
          }
          index = next
          if anim.gap(at: index) != 0 { break }
        }
        if advanced {
          anim.currentIndex = index
          anim.frameShownAt = now
          changed = true
          nextAt = now &+ UInt64(anim.gap(at: index))
        }
      }
      image.animation = anim
      images[id] = image
      if changed { markContentChanged(id) }
      if nextAt > now {
        let delay = nextAt - now
        minDelay = min(minDelay ?? delay, delay)
      }
    }
    animationIdleGeneration = minDelay == nil ? generation : nil
    return minDelay
  }
}
