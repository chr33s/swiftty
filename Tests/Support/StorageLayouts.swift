/// Reachable ring layouts: partial prefixes and full rings at every head.
public struct RingLayout: Sendable {
  public let capacity: Int
  public let appended: Int

  public static func small(capacities: ClosedRange<Int> = 0 ... 8) -> [Self] {
    capacities.flatMap { capacity in
      (0 ... (capacity * 3)).map { Self(capacity: capacity, appended: $0) }
    }
  }
}

public struct SeededGenerator: Sendable {
  public let seed: UInt64
  private var state: UInt64

  public init(seed: UInt64) {
    self.seed = seed
    state = seed
  }

  public mutating func next(upperBound: Int) -> Int {
    precondition(upperBound > 0)
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return Int((state >> 33) % UInt64(upperBound))
  }
}
