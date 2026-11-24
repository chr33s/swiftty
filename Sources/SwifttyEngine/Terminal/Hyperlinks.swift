/// OSC 8 hyperlinks, by the id cells carry (`CellAttributes.link`).
///
/// As in Ghostty, a link's identity is its `id=` parameter and URI: every
/// OSC 8 without an id opens a link of its own, so two runs of the same
/// URI are separate links. Targets are stored once however many links
/// share them. An id is reused once no cell carries it: when the rows it
/// was written on have left history, or when a scan of every cell finds it
/// unused.
struct HyperlinkTable {
  /// Per link, at index `id - 1`: its target, or `free`.
  var target: [UInt32] = []
  /// The last absolute row the link's cells can occupy (`.max`: unknown).
  var lastRow: [Int] = []
  /// The link was the pen's on the alternate screen or across a screen
  /// switch: primary rows say nothing about its cells.
  var pinned: [Bool] = []
  /// Links opened with `id=`: the parameter, and the link by (id, URI).
  var explicitID: [UInt32: [UInt8]] = [:]
  var explicitIndex = HashIndex()
  /// Ids no cell carries.
  var freeIDs: [UInt32] = []
  /// Closed links in closing order, with the row bound recorded then.
  var closed: [(id: UInt32, row: Int)] = []
  var closedHead = 0

  /// Distinct URIs; storage is reused.
  var targets: [[UInt8]] = []
  var targetUses: [UInt32] = []
  var targetHash: [UInt64] = []
  var targetIndex = HashIndex(minimumCapacity: 512)
  var freeTargets: [UInt32] = []

  /// Links in use that trigger the next scan for unused ids, and scans to
  /// skip after one that freed nothing.
  var scanThreshold = HyperlinkTable.minimumScanThreshold
  var scanCooldown = 0

  static let free = UInt32.max
  static let minimumScanThreshold = 4096

  /// Ids handed out and not yet freed.
  var live: Int { target.count - freeIDs.count }

  static func hash(_ bytes: UnsafeBufferPointer<UInt8>, seed: UInt64) -> UInt64
  {
    var hash = seed
    for b in bytes { hash = (hash ^ UInt64(b)) &* 0x100_0000_01B3 }  // FNV-1a
    return hash
  }

  func isLive(_ id: UInt32) -> Bool {
    id != 0 && Int(id) <= target.count && target[Int(id) - 1] != Self.free
  }

  /// The link opened with `explicit` for `uri`, if one is live.
  func link(
    explicit: UnsafeBufferPointer<UInt8>,
    uri: UnsafeBufferPointer<UInt8>,
    key: UInt64
  ) -> UInt32? {
    guard let id = explicitIndex[key], isLive(id), let name = explicitID[id],
      TerminalState.bytesEqual(name, explicit),
      TerminalState.bytesEqual(targets[Int(target[Int(id) - 1])], uri)
    else { return nil }
    return id
  }

  /// Points `id`, a new id or one from `release`, at `uri`.
  mutating func assign(
    _ id: UInt32,
    uri: UnsafeBufferPointer<UInt8>,
    explicit: UnsafeBufferPointer<UInt8>?,
    key: UInt64,
    pinned isPinned: Bool
  ) {
    let hash = Self.hash(uri, seed: 0xCBF2_9CE4_8422_2325)
    let slot: UInt32
    if let known = targetIndex[hash],
      TerminalState.bytesEqual(targets[Int(known)], uri)
    {
      slot = known
    } else if let reused = freeTargets.popLast() {
      slot = reused
      targets[Int(slot)].removeAll(keepingCapacity: true)
      targets[Int(slot)].append(contentsOf: uri)
      targetHash[Int(slot)] = hash
      targetIndex[hash] = slot
    } else {
      slot = UInt32(targets.count)
      targets.append(Array(uri))
      targetUses.append(0)
      targetHash.append(hash)
      targetIndex[hash] = slot
    }
    targetUses[Int(slot)] += 1
    if Int(id) > target.count {
      target.append(slot)
      lastRow.append(.max)
      pinned.append(isPinned)
    } else {
      target[Int(id) - 1] = slot
      lastRow[Int(id) - 1] = .max
      pinned[Int(id) - 1] = isPinned
    }
    if let explicit {
      explicitID[id] = Array(explicit)
      explicitIndex[key] = id
    }
  }

  /// Forgets a link no cell carries; its id may be assigned again.
  mutating func release(_ id: UInt32) {
    let index = Int(id) - 1
    let slot = Int(target[index])
    targetUses[slot] -= 1
    if targetUses[slot] == 0 {
      if targetIndex[targetHash[slot]] == UInt32(slot) {
        targetIndex[targetHash[slot]] = nil
      }
      freeTargets.append(UInt32(slot))
    }
    if let explicit = explicitID.removeValue(forKey: id) {
      let key = explicit.withUnsafeBufferPointer { name in
        targets[slot]
          .withUnsafeBufferPointer { uri in Self.explicitKey(name, uri) }
      }
      if explicitIndex[key] == id { explicitIndex[key] = nil }
    }
    target[index] = Self.free
    lastRow[index] = .max
    pinned[index] = false
  }

  static func explicitKey(
    _ explicit: UnsafeBufferPointer<UInt8>,
    _ uri: UnsafeBufferPointer<UInt8>
  ) -> UInt64 {
    // A byte no id holds separates the two.
    let name = hash(explicit, seed: 0xCBF2_9CE4_8422_2325)
    return hash(uri, seed: (name ^ 0x3B) &* 0x100_0000_01B3)
  }
}

/// A `UInt64` to `UInt32` map for keys that are already hashes (FNV-1a):
/// open addressing with linear probing, where `Dictionary` would hash
/// each key again. At most half the slots are used, tombstones included.
struct HashIndex {
  private var keys: [UInt64]
  private var slotValues: [UInt32]
  /// 0: empty, 1: full, 2: removed.
  private var states: [UInt8]
  private(set) var count = 0
  /// Full and removed slots.
  private var used = 0

  init(minimumCapacity: Int = 0) {
    var capacity = 16
    while capacity < minimumCapacity * 2 { capacity <<= 1 }
    keys = Array(repeating: 0, count: capacity)
    slotValues = Array(repeating: 0, count: capacity)
    states = Array(repeating: 0, count: capacity)
  }

  @inline(__always)
  private func start(_ key: UInt64) -> Int {
    // Fibonacci hashing spreads keys whose low bits agree.
    Int(truncatingIfNeeded: (key &* 0x9E37_79B9_7F4A_7C15) >> 32)
      & (keys.count - 1)
  }

  private func slot(of key: UInt64) -> Int? {
    let mask = keys.count - 1
    var i = start(key)
    while true {
      switch states[i] {
      case 0: return nil
      case 1 where keys[i] == key: return i
      default: i = (i + 1) & mask
      }
    }
  }

  subscript(key: UInt64) -> UInt32? {
    get { slot(of: key).map { slotValues[$0] } }
    set {
      guard let value = newValue else {
        if let i = slot(of: key) {
          count -= 1
          let mask = keys.count - 1
          guard states[(i + 1) & mask] == 0 else {
            states[i] = 2
            return
          }
          // No probe continues past an empty slot, so this one and the
          // tombstones before it can be empty too.
          var j = i
          repeat {
            states[j] = 0
            used -= 1
            j = (j - 1) & mask
          } while states[j] == 2
        }
        return
      }
      if let i = slot(of: key) {
        slotValues[i] = value
        return
      }
      if (used + 1) * 2 > keys.count { rehash(minimumCapacity: count + 1) }
      let mask = keys.count - 1
      var i = start(key)
      while states[i] == 1 { i = (i + 1) & mask }
      if states[i] == 0 { used += 1 }
      states[i] = 1
      keys[i] = key
      slotValues[i] = value
      count += 1
    }
  }

  /// Entries in no particular order.
  var entries: [(key: UInt64, value: UInt32)] {
    var out: [(key: UInt64, value: UInt32)] = []
    out.reserveCapacity(count)
    for i in states.indices where states[i] == 1 {
      out.append((keys[i], slotValues[i]))
    }
    return out
  }

  private mutating func rehash(minimumCapacity: Int) {
    var table = HashIndex(minimumCapacity: max(minimumCapacity * 2, 8))
    for i in states.indices where states[i] == 1 {
      table[keys[i]] = slotValues[i]
    }
    self = table
  }
}
