import SwiftMuxGuardian
import Testing
import TestSupport

/// `PaneWriter` under random admission, paste, cancellation, discard and
/// partial-write sequences: credits stay exact after every operation, and
/// the written stream is well formed and keeps admission order.
struct PaneWriterPropertyTests {
  enum Extra: Hashable { case none, accent, newline }

  /// Token numbers are unique and increase with admission order.
  enum Op: Hashable, CustomStringConvertible {
    case input(Int)
    case reply(Int)
    case begin(bracketed: Bool)
    case paste(Int, Extra)
    case end
    case cancel(discardDeferredInput: Bool)
    case discard
    /// Writes until the descriptor has accepted this many bytes.
    case flush(Int)

    var description: String {
      switch self {
      case let .input(n): "I\(n)"
      case let .reply(n): "R\(n)"
      case let .begin(bracketed): bracketed ? "begin[]" : "begin"
      case let .paste(n, extra):
        "p\(n)" + (extra == .accent ? "é" : extra == .newline ? "⏎" : "")
      case .end: "end"
      case let .cancel(discard): discard ? "cancel!" : "cancel"
      case .discard: "discard"
      case let .flush(n): "F\(n)"
      }
    }
  }

  struct Script: CustomStringConvertible {
    var reserve: Int
    var ops: [Op]

    var description: String {
      "reserve \(reserve): " + ops.map(\.description).joined(separator: " ")
    }
  }

  static func generate(_ random: inout PropertyRandom) -> Script {
    var ops: [Op] = []
    var open = false
    var token = 0
    for _ in 0 ..< random.int(in: 10 ... 120) {
      token += 1
      let roll = random.int(100)
      let flushQuota = random.oneIn(8) ? 1_000 : random.int(in: 0 ... 24)
      if open {
        switch roll {
        case ..<30:
          let extra: Extra =
            random.oneIn(4) ? .accent : random.oneIn(5) ? .newline : .none
          ops.append(.paste(token, extra))
        case ..<42: ops.append(.input(token))
        case ..<54: ops.append(.reply(token))
        case ..<64:
          ops.append(.end)
          open = false
        case ..<72:
          ops.append(.cancel(discardDeferredInput: random.bool()))
          open = false
        case ..<76:
          ops.append(.discard)
          open = false
        default: ops.append(.flush(flushQuota))
        }
      } else {
        switch roll {
        case ..<25: ops.append(.input(token))
        case ..<45: ops.append(.reply(token))
        case ..<58:
          ops.append(.begin(bracketed: !random.oneIn(4)))
          open = true
        case ..<61: ops.append(.discard)
        // Operations naming a paste that is no longer open are no-ops.
        case ..<63: ops.append(.paste(token, .none))
        case ..<65: ops.append(.end)
        case ..<67: ops.append(.cancel(discardDeferredInput: random.bool()))
        default: ops.append(.flush(flushQuota))
        }
      }
    }
    return Script(reserve: random.int(in: 4 ... 48), ops: ops)
  }

  static func shrink(_ script: Script) -> [Script] {
    Property.shrinkList(script.ops) { op in
      switch op {
      case let .flush(n) where n > 0: [.flush(0), .flush(n / 2)]
      case let .paste(n, extra) where extra != .none: [.paste(n, .none)]
      default: []
      }
    }
    .map { Script(reserve: script.reserve, ops: $0) }
  }

  /// Credits and byte counts against the queued and deferred segments.
  static func invariants(_ w: PaneWriter, credit: Int) -> String? {
    var queuedInput = 0
    var queuedReply = 0
    for s in w.queue {
      if case .reply = s.kind {
        queuedReply += s.remaining
      } else {
        queuedInput += s.remaining
      }
    }
    var deferredInput = 0
    var deferredReply = 0
    for s in w.deferred {
      guard s.offset == 0 else { return "a deferred segment was written" }
      switch s.kind {
      case .input: deferredInput += s.remaining
      case .reply: deferredReply += s.remaining
      default: return "deferred \(s.kind) segment"
      }
    }
    let closer = w.paste?.bracketed == true ? 6 : 0
    let input = queuedInput + deferredInput + closer
    guard w.pendingInputBytes == input else {
      return "pendingInputBytes \(w.pendingInputBytes), segments hold \(input)"
    }
    guard w.pendingInputBytes == credit else {
      return
        "pendingInputBytes \(w.pendingInputBytes), admitted minus released "
        + "and discarded is \(credit)"
    }
    guard w.pendingReplyBytes == queuedReply else {
      return "pendingReplyBytes \(w.pendingReplyBytes), queued \(queuedReply)"
    }
    guard w.deferredReplyBytes == deferredReply else {
      return
        "deferredReplyBytes \(w.deferredReplyBytes), deferred \(deferredReply)"
    }
    guard w.pendingReplyBytes + w.deferredReplyBytes <= w.replyReserve else {
      return "replies exceed the reserve \(w.replyReserve)"
    }
    return nil
  }

  enum Piece: Equatable {
    case open, close
    case input(Int)
    case reply(Int)
    /// A complete paste token.
    case paste(Int)
    /// Paste payload that is not a complete token (a cut chunk, `é`, CR, LF).
    case payload
  }

  static let opener = Array("\u{1B}[200~".utf8)
  static let closer = Array("\u{1B}[201~".utf8)

  /// Splits the written stream into markers, tokens and payload; nil for
  /// a byte that none of them could have produced.
  static func pieces(_ bytes: [UInt8]) -> [Piece]? {
    var out: [Piece] = []
    var i = 0
    func number(after start: Int) -> (Int, Int)? {
      var j = start
      var value = 0
      while j < bytes.count, (0x30 ... 0x39).contains(bytes[j]) {
        value = value * 10 + Int(bytes[j] - 0x30)
        j += 1
      }
      return j > start ? (value, j) : nil
    }
    while i < bytes.count {
      let rest = bytes[i...]
      if rest.starts(with: opener) {
        out.append(.open)
        i += opener.count
        continue
      }
      if rest.starts(with: closer) {
        out.append(.close)
        i += closer.count
        continue
      }
      switch bytes[i] {
      case UInt8(ascii: "I"), UInt8(ascii: "R"):
        guard let (n, end) = number(after: i + 1), end < bytes.count,
          bytes[end] == UInt8(ascii: ";")
        else { return nil }
        out.append(bytes[i] == UInt8(ascii: "I") ? .input(n) : .reply(n))
        i = end + 1
      case UInt8(ascii: "p"):
        if let (n, end) = number(after: i + 1), end < bytes.count,
          bytes[end] == UInt8(ascii: ",")
        {
          out.append(.paste(n))
          i = end + 1
        } else {
          out.append(.payload)
          i = number(after: i + 1)?.1 ?? i + 1
        }
      case 0xC3 where i + 1 < bytes.count && bytes[i + 1] == 0xA9:
        out.append(.payload)
        i += 2
      case 0x0A, 0x0D:
        out.append(.payload)
        i += 1
      default: return nil
      }
    }
    return out
  }

  enum Admitted: Hashable {
    case input(Int)
    case reply(Int)
  }

  static func run(_ script: Script) -> String? {
    var writer = PaneWriter(replyReserve: script.reserve)
    var output: [UInt8] = []
    var pasteID: UInt64 = 0
    var bracketed = false
    var admitted = 0
    var settled = 0
    var order: [Admitted] = []
    var inputs: [Int] = []
    var requiredInputs = 0
    var pasteTokens: [Int] = []
    var pasteBracketed: [Int: Bool] = [:]
    var pasteOf: [Int: UInt64] = [:]
    var requiredPastes: Set<Int> = []

    func flush(_ quota: Int) -> String? {
      var left = quota
      let start = output.count
      let replies = writer.pendingReplyBytes
      guard
        let released = writer.flush({ buffer in
          let n = min(left, buffer.count)
          output.append(contentsOf: buffer.prefix(n))
          left -= n
          return n
        })
      else { return "flush failed" }
      settled += released
      let replyBytes = replies - writer.pendingReplyBytes
      let written = output.count - start
      guard released == written - replyBytes else {
        return "flush released \(released) of \(written) bytes written with "
          + "\(replyBytes) reply bytes"
      }
      return nil
    }

    func checked(_ step: String) -> String? {
      invariants(writer, credit: admitted - settled)
        .map { "after \(step): \($0)" }
    }

    for (index, op) in script.ops.enumerated() {
      let step = "op \(index) (\(op))"
      switch op {
      case let .input(n):
        let bytes = Array("I\(n);".utf8)
        writer.appendInput(bytes)
        admitted += bytes.count
        inputs.append(n)
        order.append(.input(n))
      case let .reply(n):
        let bytes = Array("R\(n);".utf8)
        let room =
          writer.pendingReplyBytes + writer.deferredReplyBytes + bytes.count
          <= writer.replyReserve
        let accepted = writer.appendReply(bytes)
        guard accepted == room else {
          return "\(step): appendReply returned \(accepted), room \(room)"
        }
        if accepted { order.append(.reply(n)) }
      case let .begin(b):
        guard !writer.hasOpenPaste else { continue }
        pasteID += 1
        bracketed = b
        writer.beginPaste(id: pasteID, bracketed: b)
        if b { admitted += PaneWriter.pasteMarkerBytes }
      case let .paste(n, extra):
        let text =
          "p\(n)," + (extra == .accent ? "é" : extra == .newline ? "\n" : "")
        let open = writer.hasOpenPaste
        // Sanitizing keeps this text's length.
        writer.appendPaste(id: pasteID, text: text)
        if open {
          admitted += text.utf8.count
          pasteTokens.append(n)
          pasteBracketed[n] = bracketed
          pasteOf[n] = pasteID
          requiredPastes.insert(n)
        }
      case .end: writer.endPaste(id: pasteID)
      case let .cancel(discard):
        let open = writer.hasOpenPaste
        let result = writer.cancelPaste(
          id: pasteID,
          discardDeferredInput: discard
        )
        settled += result.discarded
        if !open, result.discarded != 0 {
          return "\(step): cancelling no paste discarded \(result.discarded)"
        }
        if open {
          requiredPastes = requiredPastes.filter { pasteOf[$0] != pasteID }
          if discard { requiredInputs = inputs.count }
        }
      case .discard:
        settled += writer.discardUnwrittenInput()
        requiredInputs = inputs.count
        requiredPastes = []
      case let .flush(quota):
        if let failure = flush(quota) { return "\(step): \(failure)" }
      }
      if let failure = checked(step) { return failure }
    }
    if writer.hasOpenPaste { writer.endPaste(id: pasteID) }
    if let failure = flush(Int.max) { return "final flush: \(failure)" }
    if let failure = checked("final flush") { return failure }
    guard writer.isEmpty, !writer.hasOpenPaste, writer.pendingInputBytes == 0,
      writer.pendingReplyBytes == 0, writer.deferredReplyBytes == 0
    else { return "writer not empty after the final flush" }

    // The written stream.
    guard String(validating: output, as: UTF8.self) != nil else {
      return "invalid UTF-8 written"
    }
    let text = escapedTestText(String(decoding: output, as: UTF8.self))
    guard let pieces = pieces(output) else {
      return "unexpected bytes in \(text)"
    }
    var inside = false
    var writtenInputs: [Int] = []
    var writtenReplies: [Int] = []
    var writtenAdmitted: [Admitted] = []
    var writtenPastes: [Int] = []
    for piece in pieces {
      switch piece {
      case .open:
        guard !inside else { return "nested paste opener in \(text)" }
        inside = true
      case .close:
        guard inside else { return "unmatched paste closer in \(text)" }
        inside = false
      case let .input(n):
        guard !inside else { return "input I\(n) inside a paste in \(text)" }
        writtenInputs.append(n)
        writtenAdmitted.append(.input(n))
      case let .reply(n):
        guard !inside else { return "reply R\(n) inside a paste in \(text)" }
        writtenReplies.append(n)
        writtenAdmitted.append(.reply(n))
      case let .paste(n):
        guard let wasBracketed = pasteBracketed[n] else {
          return "paste token p\(n) was never admitted"
        }
        guard wasBracketed == inside else {
          return
            "paste token p\(n) \(inside ? "inside" : "outside") an envelope"
        }
        writtenPastes.append(n)
      case .payload: break
      }
    }
    guard !inside else { return "paste left open in \(text)" }

    let replies: [Int] = order.compactMap {
      if case let .reply(n) = $0 { n } else { nil }
    }
    guard writtenReplies == replies else {
      return "replies written \(writtenReplies), accepted \(replies)"
    }
    let inputOrder = Dictionary(
      uniqueKeysWithValues: inputs.enumerated().map { ($1, $0) }
    )
    let inputPositions = writtenInputs.compactMap { inputOrder[$0] }
    guard inputPositions.count == writtenInputs.count,
      zip(inputPositions, inputPositions.dropFirst()).allSatisfy({ $0 < $1 })
    else { return "inputs written \(writtenInputs), admitted \(inputs)" }
    let missing = Set(inputs[requiredInputs...]).subtracting(writtenInputs)
    guard missing.isEmpty else {
      return "inputs \(missing.sorted()) admitted after the last discard lost"
    }
    let present = Set(writtenAdmitted)
    let expected = order.filter { present.contains($0) }
    guard writtenAdmitted == expected else {
      return "input and replies interleaved \(writtenAdmitted), not \(expected)"
    }
    let pasteOrder = Dictionary(
      uniqueKeysWithValues: pasteTokens.enumerated().map { ($1, $0) }
    )
    let pastePositions = writtenPastes.compactMap { pasteOrder[$0] }
    guard
      zip(pastePositions, pastePositions.dropFirst()).allSatisfy({ $0 < $1 })
    else { return "paste tokens written \(writtenPastes), \(pasteTokens)" }
    let lostPastes = requiredPastes.subtracting(writtenPastes)
    guard lostPastes.isEmpty else {
      return "paste tokens \(lostPastes.sorted()) of completed pastes lost"
    }
    return nil
  }

  @Test
  func randomOperationSequencesKeepCreditsAndStreamOrder() {
    let failure = Property.check(
      seeds: Property.seeds(300),
      generate: Self.generate,
      shrink: Self.shrink,
      property: Self.run
    )
    #expect(failure == nil, "\(failure?.description ?? "")")
  }
}
