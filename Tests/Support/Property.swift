import Foundation

/// SplitMix64: a small, seeded, deterministic generator. The same seed
/// always produces the same sequence, so a seed names a failing input.
public struct PropertyRandom: RandomNumberGenerator, Sendable {
  public private(set) var state: UInt64

  public init(seed: UInt64) { state = seed }

  public mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  /// Uniform in `0 ..< bound`; `bound` must be positive.
  public mutating func int(_ bound: Int) -> Int {
    precondition(bound > 0, "empty range")
    return Int.random(in: 0 ..< bound, using: &self)
  }

  public mutating func int(in range: ClosedRange<Int>) -> Int {
    Int.random(in: range, using: &self)
  }

  public mutating func bool() -> Bool { next() & 1 == 1 }

  /// True with probability `1 / n`.
  public mutating func oneIn(_ n: Int) -> Bool { int(n) == 0 }

  public mutating func double(in range: Range<Double>) -> Double {
    Double.random(in: range, using: &self)
  }

  /// A uniformly chosen element; `collection` must not be empty.
  public mutating func element<C: Collection>(of collection: C) -> C.Element {
    precondition(!collection.isEmpty, "no elements")
    let offset = int(collection.count)
    return collection[collection.index(collection.startIndex, offsetBy: offset)]
  }

  /// `count` values from `body`.
  public mutating func array<T>(
    count: Int,
    _ body: (inout PropertyRandom) -> T
  ) -> [T] {
    var out: [T] = []
    out.reserveCapacity(count)
    for _ in 0 ..< count { out.append(body(&self)) }
    return out
  }
}

/// A minimal property-testing harness: generate inputs from fixed seeds,
/// check a property, and greedily shrink the first counterexample.
///
/// `PROPERTY_SEED=<n>` replays exactly one seed; `PROPERTY_COUNT=<n>`
/// changes how many seeds each property checks by default.
public enum Property {
  public struct Failure: CustomStringConvertible, Sendable {
    /// The seed whose generated input first failed.
    public let seed: UInt64
    /// The smallest failing input found, described.
    public let input: String
    /// The violation the smallest input produced.
    public let message: String
    /// Accepted shrink steps and candidates tried.
    public let shrinks: Int
    public let attempts: Int

    public var description: String {
      "property failed for seed \(seed) (replay with PROPERTY_SEED=\(seed)): "
        + escapedTestText(message) + "\n  minimal input (\(shrinks) shrinks, "
        + "\(attempts) candidates): " + escapedTestText(input)
    }
  }

  /// Seeds `1 ... count`, or `PROPERTY_COUNT` of them, or only
  /// `PROPERTY_SEED`.
  public static func seeds(_ count: Int = 100) -> [UInt64] {
    let environment = ProcessInfo.processInfo.environment
    if let text = environment["PROPERTY_SEED"], let seed = UInt64(text) {
      return [seed]
    }
    var count = count
    if let text = environment["PROPERTY_COUNT"], let n = Int(text), n > 0 {
      count = n
    }
    return (1 ... max(1, count)).map(UInt64.init)
  }

  /// Checks `property` on the input generated for each seed. `property`
  /// returns nil when it holds, or a description of the violation; a thrown
  /// error is a violation too. The first failure is shrunk greedily: the
  /// first candidate from `shrink` that still fails replaces the input,
  /// until none does or `maxAttempts` candidates have been tried.
  public static func check<Input>(
    seeds: [UInt64] = Property.seeds(),
    maxAttempts: Int = 500,
    generate: (inout PropertyRandom) -> Input,
    shrink: (Input) -> [Input] = { _ in [] },
    describe: (Input) -> String = { String(describing: $0) },
    property: (Input) throws -> String?
  ) -> Failure? {
    func violation(_ input: Input) -> String? {
      do { return try property(input) } catch { return "threw \(error)" }
    }
    for seed in seeds {
      var random = PropertyRandom(seed: seed)
      let original = generate(&random)
      guard var message = violation(original) else { continue }
      var smallest = original
      var shrinks = 0
      var attempts = 0
      var progress = true
      while progress, attempts < maxAttempts {
        progress = false
        for candidate in shrink(smallest) {
          guard attempts < maxAttempts else { break }
          attempts += 1
          if let failed = violation(candidate) {
            smallest = candidate
            message = failed
            shrinks += 1
            progress = true
            break
          }
        }
      }
      return Failure(
        seed: seed,
        input: describe(smallest),
        message: message,
        shrinks: shrinks,
        attempts: attempts
      )
    }
    return nil
  }

  /// Smaller lists, most aggressive first: the empty list, then each run
  /// of half, a quarter, … and finally one element removed, then (with
  /// `element`) each element replaced by a simpler one.
  public static func shrinkList<T>(
    _ list: [T],
    element: (T) -> [T] = { _ in [] }
  ) -> [[T]] {
    var out: [[T]] = []
    let n = list.count
    guard n > 0 else { return out }
    out.append([])
    var size = n / 2
    while size > 0 {
      var start = 0
      while start < n {
        let end = min(n, start + size)
        out.append(Array(list[..<start] + list[end...]))
        start += size
      }
      size /= 2
    }
    for (i, value) in list.enumerated() {
      for simpler in element(value) {
        var copy = list
        copy[i] = simpler
        out.append(copy)
      }
    }
    return out
  }

  /// Shorter byte arrays, then single bytes made smaller.
  public static func shrinkBytes(_ bytes: [UInt8]) -> [[UInt8]] {
    shrinkList(bytes) { byte in
      var simpler: [UInt8] = []
      for candidate in [0, byte / 2, byte &- 1] where candidate < byte {
        if !simpler.contains(candidate) { simpler.append(candidate) }
      }
      return simpler
    }
  }
}
