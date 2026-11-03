import Darwin

/// Scoped, null-terminated argument/environment copies shared by spawn paths.
package enum CStringVector {
  package static func withStrings<R>(
    _ strings: [String],
    copying: (String) -> UnsafeMutablePointer<CChar>? = { strdup($0) },
    freeing: (UnsafeMutablePointer<CChar>) -> Void = { free($0) },
    _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) throws(POSIXError) ->
      R
  ) throws(POSIXError) -> R {
    var pointers: [UnsafeMutablePointer<CChar>?] = []
    defer { for pointer in pointers { if let pointer { freeing(pointer) } } }
    for string in strings {
      guard !string.utf8.contains(0) else {
        throw POSIXError("C string contains NUL", code: EINVAL)
      }
      guard let pointer = copying(string) else {
        throw POSIXError("strdup", code: ENOMEM)
      }
      pointers.append(pointer)
    }
    pointers.append(nil)
    return try pointers.withUnsafeBufferPointer { buffer throws(POSIXError) in
      try body(buffer.baseAddress!)
    }
  }
}
