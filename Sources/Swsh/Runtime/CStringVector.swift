import Darwin

/// Owns byte-preserving, NUL-terminated copies for one spawn or replacement call.
struct CStringVector: ~Copyable {
  private let pointers: [UnsafeMutablePointer<CChar>?]

  init(_ values: [[UInt8]]) throws {
    guard values.allSatisfy({ !$0.contains(0) }) else {
      throw SystemFailure(
        "NUL in process argument or environment",
        code: EINVAL
      )
    }
    var pointers: [UnsafeMutablePointer<CChar>?] = []
    for value in values {
      let pointer = UnsafeMutablePointer<CChar>
        .allocate(capacity: value.count + 1)
      for (index, byte) in value.enumerated() {
        (pointer + index).initialize(to: CChar(bitPattern: byte))
      }
      (pointer + value.count).initialize(to: 0)
      pointers.append(pointer)
    }
    pointers.append(nil)
    self.pointers = pointers
  }

  deinit { for case let pointer? in pointers { pointer.deallocate() } }

  borrowing func withPointers<Result>(
    _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
  ) rethrows -> Result {
    try pointers.withUnsafeBufferPointer { try body($0.baseAddress!) }
  }
}
