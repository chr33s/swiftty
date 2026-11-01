// Conservative bounds include mode-dependent paste and rich keyboard encoding.
// Shared by native view admission and the transport backends.
extension TerminalInput {
  package func encodedByteReservation(maxInputBytes: Int) -> Int? {
    switch self {
    case let .text(text):
      let count = text.utf8.count
      guard count > 0, count <= maxInputBytes else { return nil }
      // Modes can change before queued input is encoded. Reserve the largest
      // pure-text report: ESC[0;1; followed by decimal scalars and final u.
      // The fixed input cap bounds this arithmetic to at most 8 * cap + 6.
      var reportCount = 6
      for scalar in text.unicodeScalars {
        var value = scalar.value
        reportCount += 2  // At least one digit and one separator/final byte.
        while value >= 10 {
          reportCount += 1
          value /= 10
        }
      }
      return max(count, reportCount)
    case let .paste(text):
      let count = text.utf8.count
      return count <= maxInputBytes ? count * 2 + 12 : nil
    case let .bytes(bytes):
      return !bytes.isEmpty && bytes.count <= maxInputBytes ? bytes.count : nil
    case let .key(event):
      let count = event.text?.utf8.count ?? 0
      guard count <= maxInputBytes else { return nil }
      // Kitty associated text: seven decimal digits and a separator per
      // scalar, with 64 bytes for the remaining key fields.
      return 64 + count * 8
    case .mouse: return 64
    case .focus: return 3
    }
  }
}
