/// The pane's one ordered writer: input, terminal replies and paste
/// segments in admission order. Owned by the pane queue.
///
/// While a paste envelope is open, replies and other input are deferred
/// so nothing interleaves inside it; they follow the closing marker.
struct PaneWriter {
  /// Reserve both six-byte markers before opening an envelope, including
  /// its closing marker while it has not yet been queued.
  static let pasteMarkerBytes = 12

  enum Kind: Equatable {
    case input
    case reply
    case paste(UInt64)
    case marker
  }

  struct Segment {
    var bytes: [UInt8]
    var offset = 0
    var kind: Kind
    var remaining: Int { bytes.count - offset }
  }

  struct Paste {
    var id: UInt64
    var bracketed: Bool
    var lastByte: UInt8 = 0
    var started = false
    /// Some payload byte reached the descriptor.
    var wrote = false
  }

  private(set) var queue: [Segment] = []
  private var head = 0
  private(set) var deferred: [Segment] = []
  private(set) var paste: Paste?
  /// Unwritten input and markers, including an open envelope's future
  /// closing marker (for credit release).
  private(set) var pendingInputBytes = 0
  private(set) var pendingReplyBytes = 0
  private(set) var deferredReplyBytes = 0
  let replyReserve: Int

  init(replyReserve: Int) { self.replyReserve = replyReserve }

  var isEmpty: Bool { head == queue.count }

  var hasOpenPaste: Bool { paste != nil }

  /// Ordinary input; deferred while a paste envelope is open.
  mutating func appendInput(_ bytes: [UInt8]) {
    guard !bytes.isEmpty else { return }
    let s = Segment(bytes: bytes, kind: .input)
    if paste != nil { deferred.append(s) } else { queue.append(s) }
    pendingInputBytes += bytes.count
  }

  /// Terminal replies; bounded by the reserve. Returns false if dropped.
  @discardableResult
  mutating func appendReply(_ bytes: [UInt8]) -> Bool {
    guard !bytes.isEmpty else { return true }
    guard pendingReplyBytes + deferredReplyBytes + bytes.count <= replyReserve
    else { return false }
    let s = Segment(bytes: bytes, kind: .reply)
    if paste != nil {
      deferred.append(s)
      deferredReplyBytes += bytes.count
    } else {
      queue.append(s)
      pendingReplyBytes += bytes.count
    }
    return true
  }

  mutating func beginPaste(id: UInt64, bracketed: Bool) {
    precondition(paste == nil)
    paste = Paste(id: id, bracketed: bracketed)
    if bracketed {
      pendingInputBytes += Self.pasteMarkerBytes
      queue.append(Segment(bytes: Array("\u{1B}[200~".utf8), kind: .marker))
    }
  }

  /// Sanitized like xterm: controls that edit, signal or escape become
  /// spaces; unbracketed newlines become carriage returns.
  mutating func appendPaste(id: UInt64, text: String) {
    guard var p = paste, p.id == id else { return }
    var out: [UInt8] = []
    out.reserveCapacity(text.utf8.count)
    for byte in text.utf8 {
      let b = Self.sanitized(byte)
      if !p.bracketed, b == 0x0A {
        if p.lastByte != 0x0D { out.append(0x0D) }
      } else {
        out.append(b)
      }
      p.lastByte = b
    }
    paste = p
    guard !out.isEmpty else { return }
    queue.append(Segment(bytes: out, kind: .paste(id)))
    pendingInputBytes += out.count
  }

  /// Closes the envelope normally, then releases deferred segments.
  mutating func endPaste(id: UInt64) {
    guard let p = paste, p.id == id else { return }
    if p.bracketed {
      queue.append(Segment(bytes: Array("\u{1B}[201~".utf8), kind: .marker))
    }
    releaseDeferred()
  }

  /// Stops a paste: a partly written chunk finishes, unstarted chunks are
  /// discarded, and the closing marker is committed if needed.
  /// Returns the number of discarded bytes and whether any payload byte
  /// had been written (a partly written chunk counts).
  ///
  /// `discardDeferredInput` drops keystrokes queued behind the paste
  /// instead of releasing them. Lease loss uses that so the previous
  /// writer's pending input cannot run after the fence.
  mutating func cancelPaste(
    id: UInt64,
    discardDeferredInput: Bool = false
  ) -> (discarded: Int, wrote: Bool) {
    guard let p = paste, p.id == id else { return (0, false) }
    var discarded = 0
    var kept: [Segment] = []
    for (i, s) in queue.enumerated() where i >= head {
      if s.kind == .paste(id), s.offset == 0 {
        discarded += s.bytes.count
        continue
      }
      if discardDeferredInput, case .input = s.kind, s.offset == 0 {
        discarded += s.bytes.count
        continue
      }
      kept.append(s)
    }
    queue = kept
    head = 0
    pendingInputBytes -= discarded
    if p.bracketed {
      queue.append(Segment(bytes: Array("\u{1B}[201~".utf8), kind: .marker))
    }
    if discardDeferredInput { discarded += dropDeferredInput() }
    releaseDeferred()
    return (discarded, p.wrote)
  }

  /// Drops user input and paste payload that have not reached the program.
  /// Bytes already accepted by the kernel stay. A started paste chunk
  /// finishes its current UTF-8 scalar and drops the rest. A started input
  /// record finishes whole: cutting it could split a key's escape sequence
  /// and corrupt the next writer's first bytes. Replies and markers stay.
  /// An open bracketed paste still receives its closing marker. Used when the
  /// writer lease ends, including after `pasteEnd` has retired the lease's
  /// paste record while bytes are still queued.
  mutating func discardUnwrittenInput() -> Int {
    var discarded = 0
    var kept: [Segment] = []
    for (i, s) in queue.enumerated() where i >= head {
      switch s.kind {
      case .input where s.offset > 0: break
      case .paste where s.offset > 0:
        // Finish the scalar the kernel has started; drop the rest.
        var end = s.offset
        while end < s.bytes.count, s.bytes[end] & 0xC0 == 0x80 { end += 1 }
        if end == s.bytes.count { break }
        discarded += s.bytes.count - end
        guard end > s.offset else { continue }
        var started = s
        started.bytes.removeSubrange(end...)
        kept.append(started)
        continue
      case .input, .paste:
        // Nothing of it reached the kernel.
        discarded += s.bytes.count
        continue
      case .marker, .reply: break
      }
      kept.append(s)
    }
    if discarded != 0 {
      queue = kept
      head = 0
      pendingInputBytes -= discarded
    }
    discarded += dropDeferredInput()
    // A later pasteEnd must not flush the tail or release deferred
    // keystrokes. The closer was reserved with the opener; flush writes it.
    if let open = paste {
      if open.bracketed {
        queue.append(Segment(bytes: Array("\u{1B}[201~".utf8), kind: .marker))
      }
      paste = nil
      if !deferred.isEmpty {
        queue.append(contentsOf: deferred)
        pendingReplyBytes += deferredReplyBytes
        deferredReplyBytes = 0
        deferred = []
      }
    }
    return discarded
  }

  /// Drops keystrokes deferred behind a paste, keeping replies and their
  /// credit. Returns the bytes dropped.
  private mutating func dropDeferredInput() -> Int {
    var dropped = 0
    var replies: [Segment] = []
    for s in deferred {
      if case .input = s.kind {
        dropped += s.bytes.count
        continue
      }
      replies.append(s)
    }
    guard replies.count != deferred.count else { return 0 }
    pendingInputBytes -= dropped
    deferred = replies
    deferredReplyBytes = replies.reduce(0) { total, segment in
      if case .reply = segment.kind {
        total + segment.bytes.count
      } else {
        total
      }
    }
    return dropped
  }

  private mutating func releaseDeferred() {
    paste = nil
    queue.append(contentsOf: deferred)
    pendingReplyBytes += deferredReplyBytes
    deferredReplyBytes = 0
    deferred = []
  }

  /// Writes as much as the descriptor accepts. Returns input bytes
  /// completed (to release credit), or nil on a hard write error.
  mutating func flush(_ write: (UnsafeRawBufferPointer) -> Int?) -> Int? {
    var released = 0
    while head < queue.count {
      let s = queue[head]
      guard
        let n = s.bytes.withUnsafeBytes({ buffer in
          write(UnsafeRawBufferPointer(rebasing: buffer[s.offset...]))
        })
      else { return nil }
      queue[head].offset += n
      switch s.kind {
      case .input, .marker: released += n
      case let .paste(id):
        released += n
        if n > 0, paste?.id == id { paste?.wrote = true }
      case .reply: pendingReplyBytes -= n
      }
      if queue[head].remaining > 0 { break }
      // Admission credit can be reused before segment compaction. Release
      // completed payloads now so their backing storage cannot accumulate.
      queue[head] = Segment(bytes: [], kind: s.kind)
      head += 1
    }
    if head == queue.count {
      queue.removeAll(keepingCapacity: queue.count < 64)
      head = 0
    } else if head > 64 {
      queue.removeFirst(head)
      head = 0
    }
    pendingInputBytes -= released
    return released
  }

  /// Drops everything (the pane is gone). Returns input bytes dropped.
  mutating func discardAll() -> Int {
    let dropped = pendingInputBytes
    queue = []
    head = 0
    deferred = []
    paste = nil
    pendingInputBytes = 0
    pendingReplyBytes = 0
    deferredReplyBytes = 0
    return dropped
  }

  static func sanitized(_ byte: UInt8) -> UInt8 {
    switch byte {
    case 0x00, 0x03, 0x04, 0x05, 0x08, 0x0F, 0x11, 0x12, 0x13, 0x15, 0x16, 0x17,
      0x1A, 0x1B, 0x1C, 0x7F:
      0x20
    default: byte
    }
  }
}
