/// Bounded, opt-in pane I/O evidence for owned test fixtures. Observers run
/// synchronously on the pane queue and must not wait or reenter the pane.
package struct PaneIOObservation: Sendable {
  package enum Phase: String, Sendable {
    case read, replyGenerated, replyQueued, replyDropped
    case written, writeBlocked, writeFailed
  }

  package let phase: Phase
  package let byteCount: Int
  /// At most 256 bytes, copied only when an observer is installed.
  package let prefix: [UInt8]
  package let error: Int32?
  package init(phase: Phase, byteCount: Int, prefix: [UInt8], error: Int32?) {
    self.phase = phase
    self.byteCount = byteCount
    self.prefix = prefix
    self.error = error
  }
}
