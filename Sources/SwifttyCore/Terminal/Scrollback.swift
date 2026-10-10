/// Oldest-first ring of pooled row ids. A full ring recycles its oldest row
/// without copying cells or allocating.
struct Scrollback: ~Copyable {
  let capacity: Int
  private let ids: UnsafeMutablePointer<Int32>
  private var head = 0
  private(set) var count = 0
  /// Lines evicted (oldest first) since creation or the last `removeAll`;
  /// `evicted + index` names a line stably while it stays in history.
  private(set) var evicted = 0

  init(capacity: Int) {
    self.capacity = max(0, capacity)
    ids = .allocate(capacity: max(1, self.capacity))
  }

  deinit { ids.deallocate() }

  var isFull: Bool { count == capacity }

  func checkInvariants() -> Bool {
    count >= 0 && count <= capacity && evicted >= 0
      && (capacity == 0 ? head == 0 : head >= 0 && head < capacity)
  }

  /// Physical id of history line `index` (0 = oldest).
  @inline(__always)
  func id(_ index: Int) -> Int32 {
    precondition(index >= 0 && index < count, "history index out of bounds")
    return ids[(head + index) % capacity]
  }

  /// Appends `id`; returns the evicted oldest id when full.
  @inline(__always)
  mutating func push(_ id: Int32) -> Int32? {
    precondition(capacity > 0, "cannot push into disabled history")
    if count < capacity {
      ids[(head + count) % capacity] = id
      count += 1
      return nil
    }
    let oldest = ids[head]
    ids[head] = id
    head = (head + 1) % capacity
    evicted += 1
    return oldest
  }

  /// Empties the ring, passing every id to `release`.
  mutating func removeAll(_ release: (Int32) -> Void) {
    for i in 0 ..< count { release(id(i)) }
    head = 0
    count = 0
    evicted = 0
  }
}
