/// History of the primary screen: a ring of physical row ids in the owning
/// `Grid`'s row pool, oldest first.
///
/// Rows are never copied into history. When the screen scrolls, the top
/// row's id moves here and, once the ring is full, the oldest id is handed
/// back to the grid as its new bottom row. Steady-state scrolling therefore
/// neither allocates nor copies cells.
struct Scrollback: ~Copyable {
    let capacity: Int
    private let ids: UnsafeMutablePointer<Int32>
    private var head = 0
    private(set) var count = 0

    init(capacity: Int) {
        self.capacity = max(0, capacity)
        ids = .allocate(capacity: max(1, self.capacity))
    }

    deinit { ids.deallocate() }

    var isFull: Bool {
        count == capacity
    }

    /// Physical id of history line `index` (0 = oldest).
    @inline(__always)
    func id(_ index: Int) -> Int32 {
        ids[(head + index) % capacity]
    }

    /// Appends `id`; returns the evicted oldest id when full.
    @inline(__always)
    mutating func push(_ id: Int32) -> Int32? {
        if count < capacity {
            ids[(head + count) % capacity] = id
            count += 1
            return nil
        }
        let evicted = ids[head]
        ids[head] = id
        head = (head + 1) % capacity
        return evicted
    }

    /// Empties the ring, passing every id to `release`.
    mutating func removeAll(_ release: (Int32) -> Void) {
        for i in 0 ..< count {
            release(id(i))
        }
        head = 0
        count = 0
    }
}
