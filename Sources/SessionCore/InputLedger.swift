/// Client-side bounded queue of submitted but unacknowledged operations
/// (spec §8). Never drops or coalesces an operation; refuses new ones
/// instead when full.
public struct ClientInputQueue: Sendable {
  public struct Entry: Hashable, Sendable {
    public var sequence: UInt64
    public var operation: InputOperation
  }

  public enum EnqueueError: Error, Equatable {
    case full
    case invalid(InputOperation.ValidationError)
  }

  public private(set) var writerID: WriterID
  public private(set) var entries: [Entry] = []
  public private(set) var nextSequence: UInt64 = 1
  public private(set) var pendingBytes = 0
  public private(set) var byteLimit: Int

  public init(
    writerID: WriterID,
    byteLimit: Int = RSTLimits.maxPendingInputBytes
  ) {
    self.writerID = writerID
    self.byteLimit = byteLimit
  }

  public var isEmpty: Bool { entries.isEmpty }

  /// A refreshed grant may lower the budget below retained input. Keep
  /// accepted operations; refuse new input until acknowledgments free room.
  public mutating func updateByteLimit(_ limit: Int) {
    byteLimit = max(0, min(limit, RSTLimits.maxPendingInputBytes))
  }
  /// Highest sequence acknowledged as applied by the host.
  public var acknowledged: UInt64 { nextSequence - 1 - UInt64(entries.count) }

  /// Assigns the next sequence number to `operation`.
  public mutating func enqueue(
    _ operation: InputOperation
  ) throws(EnqueueError) -> Entry {
    do { try operation.validate() } catch { throw .invalid(error) }
    let cost = operation.retainedBytes
    guard pendingBytes + cost <= byteLimit else { throw .full }
    let entry = Entry(sequence: nextSequence, operation: operation)
    entries.append(entry)
    pendingBytes += cost
    nextSequence += 1
    return entry
  }

  /// Drops operations the host reports as fully applied.
  public mutating func acknowledge(through sequence: UInt64) {
    var dropped = 0
    for entry in entries {
      guard entry.sequence <= sequence else { break }
      pendingBytes -= entry.operation.retainedBytes
      dropped += 1
    }
    entries.removeFirst(dropped)
  }

  /// After `Attached`: drops what the host already applied and returns
  /// the remaining operations, with their original identifiers, to retry.
  public mutating func reconcile(serverApplied: UInt64) -> [Entry] {
    acknowledge(through: serverApplied)
    return entries
  }

  /// A cold restart starts a fresh writer with an empty queue.
  public mutating func resetWriter(_ writer: WriterID) {
    writerID = writer
    entries = []
    nextSequence = 1
    pendingBytes = 0
  }
}

/// Host-side input ledger for one session (spec §8, §A.5). Pure
/// state: the serialized session owner encodes admitted operations once,
/// reports PTY write progress, and sends `InputAck` for completions.
public struct HostInputLedger: Sendable {
  public struct Admitted: Hashable, Sendable {
    public var sequence: UInt64
    public var operation: InputOperation
    /// Bytes generated once with the modes current at admission.
    public var bytes: [UInt8]
    /// Bytes already accepted by the PTY.
    public var offset: Int
    /// Budget held for an operation recorded before its encoding exists
    /// (a host that encodes at write time), released on completion.
    public var reserved: Int = 0
    public var remaining: Int { bytes.count - offset }
  }

  public enum Admission: Equatable, Sendable {
    /// New operation; call `record(_:bytes:)` with its encoding.
    case admit
    /// Already fully applied; resend the acknowledgment only.
    case alreadyApplied
    /// Identical retry of an admitted, still-pending operation; its
    /// remaining suffix continues without rewriting the prefix.
    case inProgress
    case rejected(Rejection)
  }

  public enum Rejection: String, Error, Equatable, Sendable, Codable {
    case wrongWriter
    case gap
    case conflict
    case backpressure
    case invalid
  }

  public private(set) var writerID: WriterID?
  public private(set) var lastApplied: UInt64 = 0
  public private(set) var admitted: [Admitted] = []
  public let byteLimit: Int

  public init(byteLimit: Int = RSTLimits.maxPendingInputBytes) {
    self.byteLimit = byteLimit
  }

  public var lastAdmitted: UInt64 { lastApplied + UInt64(admitted.count) }
  public var pendingBytes: Int {
    admitted.reduce(0) { $0 + $1.remaining + $1.reserved }
  }
  public var hasPending: Bool { !admitted.isEmpty }
  /// The head operation when part of it already reached the PTY.
  public var partialSequence: UInt64? {
    guard let head = admitted.first, head.offset > 0 else { return nil }
    return head.sequence
  }

  /// Installs a writer. A different writer may take over only when no
  /// admitted operation remains; its sequence restarts at one.
  public mutating func authorize(_ writer: WriterID) throws(Rejection) {
    if writerID == writer { return }
    guard admitted.isEmpty else { throw .wrongWriter }
    writerID = writer
    lastApplied = 0
  }

  public func classify(
    writer: WriterID,
    sequence: UInt64,
    operation: InputOperation
  ) -> Admission {
    guard writer == writerID else { return .rejected(.wrongWriter) }
    guard sequence >= 1 else { return .rejected(.invalid) }
    if sequence <= lastApplied { return .alreadyApplied }
    if sequence <= lastAdmitted {
      let entry = admitted[Int(sequence - lastApplied - 1)]
      return entry.operation == operation ? .inProgress : .rejected(.conflict)
    }
    guard sequence == lastAdmitted + 1 else { return .rejected(.gap) }
    do { try operation.validate() } catch { return .rejected(.invalid) }
    // An empty ledger always admits one valid operation: a maximal paste's
    // bound (2 × 32 KiB + markers) exceeds the byte limit, and refusing it
    // would stall the writer forever. Zero-byte effects still retain an
    // operation, so their storage is bounded too: resizes must not pile up
    // behind a blocked PTY write.
    let retainedBytes = admitted.reduce(0) { $0 + $1.operation.retainedBytes }
    guard
      admitted.isEmpty
        || (pendingBytes + operation.expansionBound <= byteLimit
          && retainedBytes + operation.retainedBytes <= byteLimit)
    else { return .rejected(.backpressure) }
    return .admit
  }

  /// Records the encoding of a newly admitted operation (after `.admit`).
  public mutating func record(
    _ sequence: UInt64,
    operation: InputOperation,
    bytes: [UInt8]
  ) {
    precondition(sequence == lastAdmitted + 1, "admission out of order")
    admitted.append(
      Admitted(
        sequence: sequence,
        operation: operation,
        bytes: bytes,
        offset: 0
      )
    )
  }

  /// Records an operation whose bytes are produced later by the writer;
  /// its `expansionBound` counts against the byte limit until it
  /// completes, so admission stays bounded.
  public mutating func reserve(_ sequence: UInt64, operation: InputOperation) {
    precondition(sequence == lastAdmitted + 1, "admission out of order")
    var entry = Admitted(
      sequence: sequence,
      operation: operation,
      bytes: [],
      offset: 0
    )
    entry.reserved = operation.expansionBound
    admitted.append(entry)
  }

  /// Drops every admitted operation that was never handed to the writer,
  /// so a new writer can take over (a cold-started client never replays
  /// uncertain input). Only valid when none of them was sent.
  public mutating func abandonUnsent() { admitted.removeAll() }

  /// The next bytes to write: the unwritten suffix of the head operation.
  public var nextWrite: (sequence: UInt64, bytes: ArraySlice<UInt8>)? {
    guard let head = admitted.first else { return nil }
    return (head.sequence, head.bytes[head.offset...])
  }

  /// Records that the PTY accepted `count` bytes of the head operation.
  /// Returns its sequence when that completes it. Zero-byte operations
  /// (resizes, keys without an encoding) complete through `completeHead()`.
  public mutating func wrote(_ count: Int) -> UInt64? {
    precondition(!admitted.isEmpty && count > 0)
    precondition(count <= admitted[0].remaining, "wrote past operation end")
    admitted[0].offset += count
    return admitted[0].remaining == 0 ? completeHead() : nil
  }

  /// Retires admitted operations that can never be written (their
  /// target is gone) so the writer can move on: they count as complete
  /// and are never retried or delivered elsewhere. Returns their sequences.
  public mutating func discard(through sequence: UInt64) -> [UInt64] {
    var retired: [UInt64] = []
    while let head = admitted.first, head.sequence <= sequence {
      lastApplied = head.sequence
      admitted.removeFirst()
      retired.append(head.sequence)
    }
    return retired
  }

  /// Completes the head once all of its bytes are written, or once its
  /// zero-byte effect (a resize) has been performed.
  public mutating func completeHead() -> UInt64? {
    guard let head = admitted.first, head.remaining == 0 else { return nil }
    lastApplied = head.sequence
    admitted.removeFirst()
    return head.sequence
  }
}
