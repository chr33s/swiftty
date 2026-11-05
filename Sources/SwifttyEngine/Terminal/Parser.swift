/// A parsed control sequence (CSI) handed to the terminal.
///
/// Parameters live inline; a sequence never allocates.
struct CSISequence: Sendable {
  static let maxParams = 24

  var params = InlineArray<24, UInt16>(repeating: 0)
  var count = 0
  /// Bit `i` set: parameter `i` was introduced by `:` (a sub-parameter).
  var colonMask: UInt32 = 0
  /// Private marker (`?`, `>`, `<`, `=`) or 0.
  var marker: UInt8 = 0
  /// First intermediate byte (0x20–0x2F) or 0.
  var intermediate: UInt8 = 0
  var final: UInt8 = 0

  /// Raw parameter value; missing parameters read as 0.
  @inline(__always)
  func value(_ i: Int) -> Int { i >= 0 && i < count ? Int(params[i]) : 0 }

  /// Parameter with VT defaulting: missing or 0 reads as `fallback`.
  @inline(__always)
  func param(_ i: Int, default fallback: Int) -> Int {
    let v = value(i)
    return v == 0 ? fallback : v
  }

  @inline(__always)
  func isSubparameter(_ i: Int) -> Bool {
    i >= 0 && i < count && colonMask & (1 << UInt32(i)) != 0
  }
}

/// VT500-style escape sequence parser over raw bytes.
///
/// Printable ASCII runs are found with SIMD and written to the grid in bulk;
/// everything else goes through a byte-at-a-time state machine. The parser
/// owns no heap memory except a preallocated OSC buffer.
public struct Parser: ~Copyable {
  enum State: UInt8, Sendable {
    case ground, escape, escapeIntermediate
    case csiEntry, csiParam, csiIntermediate, csiIgnore
    case oscString, stringIgnore
    case dcsEntry, dcsParam, dcsIntermediate, dcsIgnore, dcsPassthrough,
      dcsEscape
    /// tmux control mode (`DCS 1000 p`): a line protocol whose blocks
    /// carry raw text, escape sequences included (`capture-pane -e`).
    /// Only `ESC \` at the start of a line (after `%exit`) ends it;
    /// any other ESC is data. CAN and SUB still abort.
    case controlMode, controlModeEscape
  }

  private var state = State.ground
  private var csi = CSISequence()
  private var currentParam: UInt32 = 0
  private var hasParam = false
  private var parameterOverflow = false
  private var escIntermediate: UInt8 = 0
  /// In `controlMode`: the next byte starts a line.
  private var controlModeLineStart = true

  // UTF-8 decoding state.
  private var codepoint: UInt32 = 0
  private var utf8Remaining = 0
  private var utf8Minimum: UInt32 = 0

  // OSC payload, grown on demand and reused.
  private var osc: UnsafeMutablePointer<UInt8>
  private var oscCount = 0
  /// First nonzero byte of the numeric command, maintained as bytes arrive.
  private var oscCommandStart = 0
  private var oscCapacity: Int
  /// An OSC body failed validation or passed its limit: drop it whole.
  private var oscOverflow = false
  public static let maxOSCBytes = 8 << 20
  /// OSC 4/21 can expand small queries into many replies. This body limit
  /// keeps one command's replies below 64 KiB while allowing all 256
  /// palette entries, including their full 16-bit RGB specifications.
  public static let maxColorOSCBytes = 8 << 10

  // Scratch for decoded scalars of a mixed (non-ASCII) printable run.
  private let scalars: UnsafeMutablePointer<UInt32>
  private static let scalarCapacity = 1024

  public init() {
    oscCapacity = 4096
    osc = .allocate(capacity: oscCapacity)
    scalars = .allocate(capacity: Self.scalarCapacity)
  }

  deinit {
    osc.deallocate()
    scalars.deallocate()
  }

  /// Owned parsing state for continuing a stream on another session.
  /// Scratch buffers stay local; only the pending sequence is copied.
  package struct Continuation: Sendable {
    var state: State
    var csi: CSISequence
    var currentParam: UInt32
    var hasParam: Bool
    var parameterOverflow: Bool
    var escIntermediate: UInt8
    var controlModeLineStart: Bool
    var codepoint: UInt32
    var utf8Remaining: Int
    var utf8Minimum: UInt32
    var osc: [UInt8]
    var oscOverflow: Bool
  }

  package var continuation: Continuation {
    Continuation(
      state: state,
      csi: csi,
      currentParam: currentParam,
      hasParam: hasParam,
      parameterOverflow: parameterOverflow,
      escIntermediate: escIntermediate,
      controlModeLineStart: controlModeLineStart,
      codepoint: codepoint,
      utf8Remaining: utf8Remaining,
      utf8Minimum: utf8Minimum,
      osc: Array(UnsafeBufferPointer(start: osc, count: oscCount)),
      oscOverflow: oscOverflow,
    )
  }

  package mutating func restore(_ continuation: Continuation) {
    state = continuation.state
    csi = continuation.csi
    currentParam = continuation.currentParam
    hasParam = continuation.hasParam
    parameterOverflow = continuation.parameterOverflow
    escIntermediate = continuation.escIntermediate
    controlModeLineStart = continuation.controlModeLineStart
    codepoint = continuation.codepoint
    utf8Remaining = continuation.utf8Remaining
    utf8Minimum = continuation.utf8Minimum
    if continuation.osc.count > oscCapacity {
      osc.deallocate()
      while oscCapacity < continuation.osc.count { oscCapacity *= 2 }
      osc = .allocate(capacity: oscCapacity)
    }
    oscCount = continuation.osc.count
    oscCommandStart = continuation.osc.prefix { $0 == 0x30 }.count
    continuation.osc.withUnsafeBufferPointer { buffer in
      if let base = buffer.baseAddress {
        osc.update(from: base, count: buffer.count)
      }
    }
    oscOverflow = continuation.oscOverflow
  }

  /// Decodes printable ASCII and complete UTF-8 sequences into `scalars`
  /// until a control byte, an incomplete/invalid sequence, or capacity.
  /// Also stops before sixteen printable ASCII bytes, which `printASCII`
  /// writes faster than a scalar run.
  @inline(__always)
  private func decodeRun(
    _ p: UnsafePointer<UInt8>,
    from start: Int,
    to end: Int
  ) -> (count: Int, end: Int) {
    let windows = Self.decodeWindows(p, from: start, to: end, into: scalars)
    var count = windows.count
    var i = windows.end
    if windows.asciiAhead { return (count, i) }
    // The last bytes of the input, and whatever a window rejected.
    while i < end, count < Self.scalarCapacity {
      let b = p[i]
      if b &- 0x20 < 0x5F {
        scalars[count] = UInt32(b)
        i += 1
      } else if b >= 0xC2 {
        guard let (cp, length) = Self.decodeUTF8(p + i, available: end - i)
        else { break }
        scalars[count] = cp
        i += length
      } else {
        break
      }
      count += 1
    }
    return (count, i)
  }

  /// One bit per byte of a comparison, at bit `4 * index`.
  @inline(__always)
  private static func nibbles(_ mask: SIMDMask<SIMD16<Int8>>) -> UInt64 {
    let bytes = SIMD16<UInt8>(repeating: 0).replacing(with: 0xFF, where: mask)
    // Narrow each byte pair to the nibbles around its middle.
    let pairs = unsafeBitCast(bytes, to: SIMD8<UInt16>.self)
    let narrowed = SIMD8<UInt8>(truncatingIfNeeded: pairs &>> 4)
    return unsafeBitCast(narrowed, to: UInt64.self) & 0x1111_1111_1111_1111
  }

  /// Decodes sixteen-byte windows that each begin a sequence, while twenty
  /// bytes are readable and sixteen scalars fit. Windows of two- or
  /// three-byte sequences take the block decoders. Any other window is
  /// validated whole, then its bytes are folded into scalars in a fixed
  /// sequence: mixed widths cost no branch. Stops at the first byte that
  /// is neither printable ASCII nor the start of a valid sequence, or at
  /// a window a block decoder rejects; the caller's scalar loop decides
  /// what those bytes mean.
  ///
  /// `asciiAhead`: the next sixteen bytes are printable ASCII.
  @inline(never)
  private static func decodeWindows(
    _ p: UnsafePointer<UInt8>,
    from start: Int,
    to end: Int,
    into scalars: UnsafeMutablePointer<UInt32>
  ) -> (count: Int, end: Int, asciiAhead: Bool) {
    var i = start
    var count = 0
    let continuation = SIMD16<Int8>(repeating: -64)  // 0x80...0xBF as signed
    while end &- i >= 20, count <= scalarCapacity &- 16 {
      let raw = UnsafeRawPointer(p + i)
      let v0 = raw.loadUnaligned(as: SIMD16<UInt8>.self)
      let c0 = SIMD16<Int8>(truncatingIfNeeded: v0) .< continuation
      let starts = nibbles(.!c0)
      guard starts & 1 != 0 else { break }
      // Starts at every second or third byte: valid text has only two- or
      // three-byte sequences there. Anything else is for the scalar loop.
      if starts == 0x0101_0101_0101_0101 {
        guard decodeTwoByteBlock(v0, into: scalars + count) else { break }
        count &+= 8
        i &+= 16
        continue
      }
      if starts & 0x000F_FFFF_FFFF_FFFF == 0x0001_0010_0100_1001 {
        guard decodeThreeByteBlock(v0, into: scalars + count) else { break }
        count &+= 4
        i &+= 12
        continue
      }
      // Each sequence start must be followed by exactly as many
      // continuation bytes as its lead announces.
      let v1 = raw.loadUnaligned(fromByteOffset: 1, as: SIMD16<UInt8>.self)
      let v2 = raw.loadUnaligned(fromByteOffset: 2, as: SIMD16<UInt8>.self)
      let v3 = raw.loadUnaligned(fromByteOffset: 3, as: SIMD16<UInt8>.self)
      let v4 = raw.loadUnaligned(fromByteOffset: 4, as: SIMD16<UInt8>.self)
      let c1 = SIMD16<Int8>(truncatingIfNeeded: v1) .< continuation
      let c2 = SIMD16<Int8>(truncatingIfNeeded: v2) .< continuation
      let c3 = SIMD16<Int8>(truncatingIfNeeded: v3) .< continuation
      let c4 = SIMD16<Int8>(truncatingIfNeeded: v4) .< continuation
      let two = v0 .>= SIMD16(repeating: 0xC0)
      let three = v0 .>= SIMD16(repeating: 0xE0)
      let four = v0 .>= SIMD16(repeating: 0xF0)
      let twoFollow = c1 .& c2
      let threeFollow = twoFollow .& c3
      var wrong =
        (two .^ c1) .| (three .^ twoFollow) .| (four .^ threeFollow)
        .| (threeFollow .& c4)
      // Overlong three- and four-byte forms, surrogates, and scalars
      // past U+10FFFF show in the second byte.
      let belowA0 = v1 .< SIMD16(repeating: 0xA0)
      let below90 = v1 .< SIMD16(repeating: 0x90)
      wrong =
        wrong .| ((v0 .== SIMD16(repeating: 0xE0)) .& belowA0)
        .| ((v0 .== SIMD16(repeating: 0xED)) .& .!belowA0)
        .| ((v0 .== SIMD16(repeating: 0xF0)) .& below90)
        .| ((v0 .== SIMD16(repeating: 0xF4)) .& .!below90)
      let printable = (v0 &- SIMD16(repeating: 0x20)) .< SIMD16(repeating: 0x5F)
      let lead = (v0 &- SIMD16(repeating: 0xC2)) .< SIMD16(repeating: 0x33)
      let stops = nibbles((.!c0 .& wrong) .| .!(printable .| c0 .| lead))
      if stops == 0, starts == 0x1111_1111_1111_1111 {
        return (count, i, true)
      }
      // Payload bits of every byte: leads lose their length marker.
      let zero = SIMD16<UInt8>(repeating: 0)
      let marker =
        SIMD16<UInt8>(repeating: 0x80)
        | zero.replacing(with: 0x60, where: two)
        | zero.replacing(with: 0x10, where: three)
        | zero.replacing(with: 0x08, where: four)
      let payload = unsafeBitCast(v0 & ~marker, to: SIMD2<UInt64>.self)
      // Fold each byte into the scalar it belongs to, storing the scalar
      // so far at its index: the last store of each index is complete.
      // A continuation byte shifts six payload bits in; a first byte
      // shifts the previous scalar out of the low word instead.
      let shift = unsafeBitCast(
        SIMD16<UInt8>(repeating: 32).replacing(with: 6, where: c0),
        to: SIMD2<UInt64>.self
      )
      var scalar = payload[0] & 0xFF
      var index = count
      scalars[index] = UInt32(truncatingIfNeeded: scalar)
      var bytes = payload[0] >> 8
      var shifts = shift[0] >> 8
      var marks = starts >> 4
      for _ in 1 ..< 8 {
        index &+= Int(truncatingIfNeeded: marks & 1)
        scalar = scalar &<< (shifts & 0xFF) | bytes & 0xFF
        scalars[index] = UInt32(truncatingIfNeeded: scalar)
        bytes >>= 8
        shifts >>= 8
        marks >>= 4
      }
      bytes = payload[1]
      shifts = shift[1]
      for _ in 0 ..< 8 {
        index &+= Int(truncatingIfNeeded: marks & 1)
        scalar = scalar &<< (shifts & 0xFF) | bytes & 0xFF
        scalars[index] = UInt32(truncatingIfNeeded: scalar)
        bytes >>= 8
        shifts >>= 8
        marks >>= 4
      }
      guard stops == 0 else {
        // Sequences before the first stop are complete; later indexes
        // hold scraps past the count.
        let first = stops.trailingZeroBitCount
        count &+= (starts & ((1 &<< UInt64(first)) &- 1)).nonzeroBitCount
        i &+= first &>> 2
        break
      }
      // The last sequence may end in the next three bytes.
      let b16 = UInt64(p[i &+ 16])
      let b17 = UInt64(p[i &+ 17])
      let b18 = UInt64(p[i &+ 18])
      let more1 = b16 & 0xC0 == 0x80
      let more2 = more1 && b17 & 0xC0 == 0x80
      let more3 = more2 && b18 & 0xC0 == 0x80
      scalar = more1 ? scalar &<< 6 | b16 & 0x3F : scalar
      scalar = more2 ? scalar &<< 6 | b17 & 0x3F : scalar
      scalar = more3 ? scalar &<< 6 | b18 & 0x3F : scalar
      scalars[index] = UInt32(truncatingIfNeeded: scalar)
      count &+= starts.nonzeroBitCount
      i &+= 16 &+ (more1 ? 1 : 0) &+ (more2 ? 1 : 0) &+ (more3 ? 1 : 0)
    }
    return (count, i, false)
  }

  /// Eight byte pairs whose second bytes are continuation bytes. Writes
  /// eight scalars only when every first byte leads a two-byte sequence.
  @inline(__always)
  private static func decodeTwoByteBlock(
    _ bytes: SIMD16<UInt8>,
    into output: UnsafeMutablePointer<UInt32>
  ) -> Bool {
    // Little-endian pairs: the lead is the low byte.
    let pairs = unsafeBitCast(bytes, to: SIMD8<UInt16>.self)
    let lead = pairs & SIMD8(repeating: 0xFF)
    guard all((lead &- SIMD8(repeating: 0xC2)) .< SIMD8(repeating: 0x1E))
    else { return false }
    // Two-byte UTF-8 fits in eleven bits. Widen only the result.
    let scalars =
      ((lead & SIMD8(repeating: 0x1F)) &<< 6)
      | ((pairs &>> 8) & SIMD8(repeating: 0x3F))
    UnsafeMutableRawPointer(output)
      .storeBytes(
        of: SIMD8<UInt32>(truncatingIfNeeded: scalars),
        as: SIMD8<UInt32>.self
      )
    return true
  }

  /// Four byte triples, in the first twelve bytes, whose second and third
  /// bytes are continuation bytes. Writes four scalars only when every
  /// first byte leads a three-byte sequence that encodes a scalar.
  @inline(__always)
  private static func decodeThreeByteBlock(
    _ bytes: SIMD16<UInt8>,
    into output: UnsafeMutablePointer<UInt32>
  ) -> Bool {
    let lead = SIMD4<UInt8>(bytes[0], bytes[3], bytes[6], bytes[9])
    guard all((lead & SIMD4(repeating: 0xF0)) .== SIMD4(repeating: 0xE0))
    else { return false }
    let first = SIMD4<UInt8>(bytes[1], bytes[4], bytes[7], bytes[10])
    let second = SIMD4<UInt8>(bytes[2], bytes[5], bytes[8], bytes[11])
    // Three-byte UTF-8 fits in sixteen bits. Widen only the validated result.
    let a = SIMD4<UInt16>(truncatingIfNeeded: lead)
    let b = SIMD4<UInt16>(truncatingIfNeeded: first)
    let c = SIMD4<UInt16>(truncatingIfNeeded: second)
    let scalars =
      ((a & SIMD4(repeating: 0x0F)) &* SIMD4(repeating: 4096))
      | ((b & SIMD4(repeating: 0x3F)) &* SIMD4(repeating: 64))
      | (c & SIMD4(repeating: 0x3F))
    let invalidScalar =
      (scalars .< SIMD4(repeating: 0x800))
      .| ((scalars &- SIMD4(repeating: 0xD800)) .< SIMD4(repeating: 0x800))
    guard !any(invalidScalar) else { return false }
    let widened = SIMD4<UInt32>(truncatingIfNeeded: scalars)
    UnsafeMutableRawPointer(output)
      .storeBytes(of: widened, as: SIMD4<UInt32>.self)
    return true
  }

  public mutating func consume(
    _ bytes: borrowing Span<UInt8>,
    into terminal: inout TerminalState
  ) { bytes.withUnsafeBufferPointer { consume($0, into: &terminal) } }

  public mutating func consume(
    _ buffer: UnsafeBufferPointer<UInt8>,
    into terminal: inout TerminalState
  ) { _ = consume(buffer, into: &terminal, replyLimit: nil) }

  /// Parses a prefix, stopping after replies reach the threshold. One
  /// complete command may cross it; parser state and the remaining bytes
  /// belong to the caller until it drains those replies and resumes.
  package mutating func consumePrefix(
    _ buffer: UnsafeBufferPointer<UInt8>,
    into terminal: inout TerminalState,
    replyLimit: Int
  ) -> Int {
    precondition(replyLimit > 0)
    return consume(buffer, into: &terminal, replyLimit: replyLimit)
  }

  private mutating func consume(
    _ buffer: UnsafeBufferPointer<UInt8>,
    into terminal: inout TerminalState,
    replyLimit: Int?
  ) -> Int {
    guard let base = buffer.baseAddress, !buffer.isEmpty else { return 0 }
    defer {
      terminal.resolveDeferredClears()
      terminal.refreshSearchIfNeeded()
      terminal._checkInvariants(screenOnly: true)
    }
    let n = buffer.count
    var i = 0
    while i < n {
      if let replyLimit, terminal.output.count >= replyLimit { break }
      if state == .controlMode || state == .dcsPassthrough {
        // Hand over everything up to the next ESC/CAN/SUB in one piece.
        var end = i
        while end < n, base[end] != 0x1B, base[end] != 0x18, base[end] != 0x1A {
          end += 1
        }
        if end > i {
          terminal.resolveDeferredClears()
          terminal.dcsPut(UnsafeBufferPointer(start: base + i, count: end - i))
          if state == .controlMode {
            controlModeLineStart = base[end - 1] == 0x0A
          }
          i = end
          if i == n { break }
        }
      }
      if state == .oscString {
        let end = Self.scanNonControl(base, from: i, to: n)
        if end > i {
          appendOSC(base + i, count: end - i)
          i = end
          if i == n { break }
        }
      }
      if state == .ground, utf8Remaining == 0 {
        let end = Self.scanPrintableASCII(base, from: i, to: n)
        if end > i {
          terminal.printASCII(
            UnsafeBufferPointer(start: base + i, count: end - i)
          )
          i = end
          if i == n { break }
        }
        // Ordinary line endings need both controls, but only one
        // pass through the parser's ground-state dispatch.
        if base[i] == 0x0D, i + 1 < n, base[i + 1] == 0x0A {
          terminal.execute(0x0D)
          terminal.lineFeedDeferringClears()
          i += 2
          continue
        }
        // Complete multi-byte sequences decode inline; partial or
        // invalid ones fall through to the state machine.
        if base[i] >= 0xC2 {
          let (count, end) = decodeRun(base, from: i, to: n)
          if count > 0 {
            // Sequential writes blank only the stale cells they skip.
            terminal.printScalars(
              UnsafeBufferPointer(start: scalars, count: count)
            )
            i = end
            continue
          }
        }
      }
      // Stale rows arise only in ground state.
      if state == .ground {
        terminal.resolveDeferredClears()
        if base[i] == 0x1B, utf8Remaining == 0,
          let end = csiInline(base, from: i, to: n, &terminal)
        {
          i = end
          continue
        }
      }
      step(base[i], &terminal)
      i += 1
    }
    return i
  }

  /// Index of the first byte in `from..<to` outside 0x20...0x7E.
  @inline(__always)
  static func scanPrintableASCII(
    _ p: UnsafePointer<UInt8>,
    from start: Int,
    to end: Int
  ) -> Int {
    var i = start
    let raw = UnsafeRawPointer(p)
    while i + 16 <= end {
      let v = raw.loadUnaligned(fromByteOffset: i, as: SIMD16<UInt8>.self)
      // (b - 0x20) < 0x5F  <=>  0x20 <= b <= 0x7E
      let ok = (v &- 0x20) .< SIMD16<UInt8>(repeating: 0x5F)
      if all(ok) {
        i += 16;
        continue
      }
      break
    }
    while i < end, p[i] &- 0x20 < 0x5F { i += 1 }
    return i
  }

  /// Index of the first C0 control (< 0x20) in `from..<to`.
  @inline(__always)
  static func scanNonControl(
    _ p: UnsafePointer<UInt8>,
    from start: Int,
    to end: Int
  ) -> Int {
    var i = start
    let raw = UnsafeRawPointer(p)
    let space = SIMD16<UInt8>(repeating: 0x20)
    while i + 64 <= end {
      let a = raw.loadUnaligned(fromByteOffset: i, as: SIMD16<UInt8>.self)
      let b = raw.loadUnaligned(fromByteOffset: i + 16, as: SIMD16<UInt8>.self)
      let c = raw.loadUnaligned(fromByteOffset: i + 32, as: SIMD16<UInt8>.self)
      let d = raw.loadUnaligned(fromByteOffset: i + 48, as: SIMD16<UInt8>.self)
      let low = pointwiseMin(pointwiseMin(a, b), pointwiseMin(c, d))
      if any(low .< space) { break }
      i += 64
    }
    while i + 16 <= end {
      let v = raw.loadUnaligned(fromByteOffset: i, as: SIMD16<UInt8>.self)
      if any(v .< space) { break }
      i += 16
    }
    while i < end, p[i] >= 0x20 { i += 1 }
    return i
  }

  /// Decodes one well-formed 2–4 byte UTF-8 sequence at `p`.
  @inline(__always)
  static func decodeUTF8(
    _ p: UnsafePointer<UInt8>,
    available: Int
  ) -> (UInt32, Int)? {
    let b0 = UInt32(p[0])
    if b0 < 0xE0 {
      guard available >= 2, p[1] & 0xC0 == 0x80 else { return nil }
      return ((b0 & 0x1F) << 6 | UInt32(p[1] & 0x3F), 2)
    }
    if b0 < 0xF0 {
      guard available >= 3, p[1] & 0xC0 == 0x80, p[2] & 0xC0 == 0x80 else {
        return nil
      }
      let cp =
        (b0 & 0x0F) << 12 | UInt32(p[1] & 0x3F) << 6 | UInt32(p[2] & 0x3F)
      guard cp >= 0x800, !(0xD800 ... 0xDFFF).contains(cp) else { return nil }
      return (cp, 3)
    }
    guard b0 <= 0xF4, available >= 4, p[1] & 0xC0 == 0x80, p[2] & 0xC0 == 0x80,
      p[3] & 0xC0 == 0x80
    else { return nil }
    let cp =
      (b0 & 0x07) << 18 | UInt32(p[1] & 0x3F) << 12 | UInt32(p[2] & 0x3F) << 6
      | UInt32(p[3] & 0x3F)
    guard cp >= 0x10000, cp <= 0x10FFFF else { return nil }
    return (cp, 4)
  }

  // MARK: State machine

  @inline(__always)
  private mutating func step(_ byte: UInt8, _ t: inout TerminalState) {
    if state == .dcsEscape {
      if byte == 0x5C {
        t.dcsUnhook()
        state = .ground
        return
      }
      // ESC begins another sequence unless followed by the ST final.
      t.discardControlString()
      state = .escape
    }
    if state == .controlMode || state == .controlModeEscape {
      controlModeStep(byte, &t)
      return
    }
    // Anywhere transitions.
    switch byte {
    case 0x18, 0x1A:  // CAN, SUB
      if state == .oscString {
        oscCount = 0
        oscCommandStart = 0
        oscOverflow = false
      }
      if state == .dcsPassthrough { t.discardControlString() }
      resetUTF8()
      state = .ground
      return
    case 0x1B:
      let finishingDCS = state == .dcsPassthrough
      if state == .oscString { dispatchOSC(&t, bell: false) }
      if utf8Remaining > 0 {
        resetUTF8();
        t.print(0xFFFD)
      }
      enterEscape()
      if finishingDCS { state = .dcsEscape }
      return
    default: break
    }

    switch state {
    case .ground: ground(byte, &t)

    case .escape: escapeStep(byte, &t)

    case .escapeIntermediate:
      guard byte < 0xA0 else { return }
      switch byte {
      case 0x00 ... 0x1F: t.execute(byte)
      case 0x20 ... 0x2F:
        // No supported ESC command has multiple intermediates. Keep
        // consuming the sequence with a byte no dispatch can match.
        escIntermediate = 0xFF
      case 0x7F: break
      default:
        t.escDispatch(intermediate: escIntermediate, final: byte);
        state = .ground
      }

    case .csiEntry, .csiParam:
      switch byte {
      case 0x30 ... 0x39:
        currentParam = min(currentParam &* 10 &+ UInt32(byte - 0x30), 65535)
        hasParam = true
        state = .csiParam
      case 0x3B:
        pushParam(colon: false);
        state = .csiParam
      case 0x3A:
        if state == .csiEntry {
          state = .csiIgnore
        } else {
          pushParam(colon: true)
        }
      case 0x3C ... 0x3F:
        if state == .csiEntry, csi.marker == 0 {
          csi.marker = byte;
          state = .csiParam
        } else {
          state = .csiIgnore
        }
      case 0x20 ... 0x2F:
        finishParams();
        csi.intermediate = byte;
        state = .csiIntermediate
      case 0x40 ... 0x7E:
        finishParams();
        dispatchCSI(byte, &t)
      case 0x00 ... 0x1F: t.execute(byte)
      default: break
      }

    case .csiIntermediate:
      switch byte {
      case 0x20 ... 0x2F: state = .csiIgnore
      case 0x40 ... 0x7E: dispatchCSI(byte, &t)
      case 0x00 ... 0x1F: t.execute(byte)
      case 0x30 ... 0x3F: state = .csiIgnore
      default: break
      }

    case .csiIgnore:
      switch byte {
      case 0x40 ... 0x7E: state = .ground
      case 0x00 ... 0x1F: t.execute(byte)
      default: break
      }

    case .oscString:
      switch byte {
      case 0x07:
        dispatchOSC(&t, bell: true);
        state = .ground
      case 0x00 ... 0x1F:
        // Ignoring controls inside Base64 would turn a corrupted
        // clipboard write into apparently valid data.
        if isClipboardOSC { oscOverflow = true }
      default: appendOSC(byte)
      }

    // terminated by ESC (\) or CAN/SUB above
    case .stringIgnore, .dcsIgnore: break

    case .dcsEntry, .dcsParam, .dcsIntermediate, .dcsPassthrough:
      dcsStep(byte, &t)

    // handled before the anywhere transitions
    case .dcsEscape, .controlMode, .controlModeEscape: break
    }
  }

  @inline(__always)
  private mutating func escapeStep(_ byte: UInt8, _ t: inout TerminalState) {
    guard byte < 0xA0 else { return }
    switch byte {
    case 0x00 ... 0x1F: t.execute(byte)
    case 0x20 ... 0x2F:
      escIntermediate = byte;
      state = .escapeIntermediate
    case 0x5B: enterCSI()  // [
    case 0x5D:
      oscCount = 0;
      oscCommandStart = 0;
      oscOverflow = false;
      state = .oscString  // ]
    case 0x50:
      enterCSI();
      state = .dcsEntry  // P
    case 0x58, 0x5E, 0x5F: state = .stringIgnore  // X ^ _
    case 0x7F: break
    default:
      t.escDispatch(intermediate: 0, final: byte);
      state = .ground
    }
  }

  @inline(__always)
  private mutating func ground(_ byte: UInt8, _ t: inout TerminalState) {
    if utf8Remaining > 0 {
      if byte & 0xC0 == 0x80 {
        codepoint = codepoint << 6 | UInt32(byte & 0x3F)
        utf8Remaining -= 1
        if utf8Remaining == 0 {
          let cp = codepoint
          let valid =
            cp >= utf8Minimum && cp <= 0x10FFFF
            && !(0xD800 ... 0xDFFF).contains(cp)
          t.print(valid ? cp : 0xFFFD)
        }
        return
      }
      // Truncated sequence: emit a replacement and reprocess this byte.
      resetUTF8()
      t.print(0xFFFD)
    }
    switch byte {
    case 0x00 ... 0x1F: t.execute(byte)
    case 0x20 ... 0x7E: t.print(UInt32(byte))
    case 0x7F: break
    case 0xC2 ... 0xDF: begin(UInt32(byte & 0x1F), 1, 0x80)
    case 0xE0 ... 0xEF: begin(UInt32(byte & 0x0F), 2, 0x800)
    case 0xF0 ... 0xF4: begin(UInt32(byte & 0x07), 3, 0x10000)
    default: t.print(0xFFFD)
    }
  }

  @inline(__always)
  private mutating func begin(
    _ bits: UInt32,
    _ remaining: Int,
    _ minimum: UInt32
  ) {
    codepoint = bits
    utf8Remaining = remaining
    utf8Minimum = minimum
  }

  @inline(__always)
  private mutating func resetUTF8() { utf8Remaining = 0 }

  private mutating func enterEscape() {
    escIntermediate = 0
    state = .escape
  }

  private mutating func enterCSI() {
    parameterOverflow = false
    csi.count = 0
    csi.colonMask = 0
    csi.marker = 0
    csi.intermediate = 0
    currentParam = 0
    hasParam = false
    state = .csiEntry
  }

  private mutating func pushParam(colon: Bool) {
    if csi.count < CSISequence.maxParams {
      csi.params[csi.count] = UInt16(currentParam)
      csi.count += 1
    } else {
      parameterOverflow = true
    }
    if colon {
      // Keep the separator even beyond inline parameter storage so a
      // non-SGR sequence cannot hide an invalid colon by overflowing it.
      csi.colonMask |= 1 << UInt32(csi.count)
    }
    currentParam = 0
    hasParam = false
  }

  @inline(__always)
  private mutating func finishParams() {
    if hasParam || csi.count > 0 || csi.colonMask != 0 {
      pushParam(colon: false)
    }
  }

  /// A complete, ordinary CSI at `p[start]` (ESC) parsed in one loop; returns
  /// the index after it, or nil to leave the bytes to `step`.
  @inline(__always)
  private mutating func csiInline(
    _ p: UnsafePointer<UInt8>,
    from start: Int,
    to end: Int,
    _ t: inout TerminalState
  ) -> Int? {
    var j = start + 1
    guard j < end, p[j] == 0x5B else { return nil }
    enterCSI()
    j += 1
    if j < end, (0x3C ... 0x3F).contains(p[j]) {
      csi.marker = p[j]
      j += 1
    }
    var entry = csi.marker == 0
    while j < end {
      let b = p[j]
      j += 1
      switch b {
      case 0x30 ... 0x39:
        currentParam = min(currentParam &* 10 &+ UInt32(b - 0x30), 65535)
        hasParam = true
      case 0x3B: pushParam(colon: false)
      case 0x3A where !entry: pushParam(colon: true)
      case 0x40 ... 0x7E:
        finishParams()
        dispatchCSI(b, &t)
        return j
      case 0x20 ... 0x2F:
        guard j < end, (0x40 ... 0x7E).contains(p[j]) else { return nil }
        finishParams()
        csi.intermediate = b
        dispatchCSI(p[j], &t)
        return j + 1
      default: return nil
      }
      entry = false
    }
    return nil
  }

  private mutating func dispatchCSI(_ final: UInt8, _ t: inout TerminalState) {
    // Colon-separated subparameters are supported only by SGR.
    if !parameterOverflow, final == 0x6D || csi.colonMask == 0 {
      csi.final = final
      t.csiDispatch(csi)
    }
    state = .ground
  }

  /// DCS parameter, intermediate and data states.
  private mutating func dcsStep(_ byte: UInt8, _ t: inout TerminalState) {
    switch state {
    case .dcsEntry, .dcsParam:
      switch byte {
      case 0x30 ... 0x39:
        currentParam = min(currentParam &* 10 &+ UInt32(byte - 0x30), 65535)
        hasParam = true
        state = .dcsParam
      case 0x3B:
        pushParam(colon: false);
        state = .dcsParam
      case 0x3A: state = .dcsIgnore
      case 0x3C ... 0x3F:
        if state == .dcsEntry, csi.marker == 0 {
          csi.marker = byte;
          state = .dcsParam
        } else {
          state = .dcsIgnore
        }
      case 0x20 ... 0x2F:
        finishParams();
        csi.intermediate = byte;
        state = .dcsIntermediate
      case 0x40 ... 0x7E:
        finishParams();
        hookDCS(byte, &t)
      default: break  // C0 and DEL are ignored inside DCS
      }

    case .dcsIntermediate:
      switch byte {
      case 0x20 ... 0x2F: state = .dcsIgnore
      case 0x30 ... 0x3F: state = .dcsIgnore
      case 0x40 ... 0x7E: hookDCS(byte, &t)
      default: break
      }

    case .dcsPassthrough:
      withUnsafePointer(to: byte) {
        t.dcsPut(UnsafeBufferPointer(start: $0, count: 1))
      }

    default: break
    }
  }

  private mutating func hookDCS(_ final: UInt8, _ t: inout TerminalState) {
    guard !parameterOverflow else {
      state = .dcsIgnore
      return
    }
    csi.final = final
    t.dcsHook(csi)
    if csi.marker == 0, csi.intermediate == 0, final == 0x70,
      csi.value(0) == 1000
    {
      state = .controlMode
      controlModeLineStart = true
    } else {
      state = .dcsPassthrough
    }
  }

  /// tmux control mode, one byte at a time (see `State.controlMode`).
  private mutating func controlModeStep(_ byte: UInt8, _ t: inout TerminalState)
  {
    if state == .controlModeEscape {
      state = .controlMode
      if byte == 0x5C {  // ST after `%exit`
        t.dcsUnhook()
        state = .ground
        return
      }
      // The ESC was data (e.g. SGR at the start of a captured line).
      withUnsafePointer(to: UInt8(0x1B)) {
        t.dcsPut(UnsafeBufferPointer(start: $0, count: 1))
      }
      controlModeLineStart = false
    }
    switch byte {
    case 0x18, 0x1A:  // CAN, SUB
      t.dcsUnhook()
      state = .ground
    case 0x1B where controlModeLineStart: state = .controlModeEscape
    default:
      withUnsafePointer(to: byte) {
        t.dcsPut(UnsafeBufferPointer(start: $0, count: 1))
      }
      controlModeLineStart = byte == 0x0A
    }
  }

  private mutating func appendOSC(_ byte: UInt8) {
    if oscCount >= Self.maxColorOSCBytes, !oscOverflow, isColorOSC {
      oscOverflow = true
    }
    // OSC 7501 has its own bound, below the generic one; a longer
    // report is discarded rather than truncated.
    if oscCount >= ProgramStatusCommand.maxBodyBytes, !oscOverflow,
      isProgramStatusOSC
    {
      oscOverflow = true
    }
    if oscOverflow { return }
    if oscCount == oscCapacity {
      guard oscCapacity < Self.maxOSCBytes else {
        oscOverflow = true
        return
      }
      let grown = UnsafeMutablePointer<UInt8>
        .allocate(capacity: oscCapacity * 2)
      grown.update(from: osc, count: oscCount)
      osc.deallocate()
      osc = grown
      oscCapacity *= 2
    }
    if oscCommandStart == oscCount, byte == 0x30 { oscCommandStart += 1 }
    osc[oscCount] = byte
    oscCount += 1
  }

  /// `appendOSC(_:)` for each of `count` non-control bytes.
  private mutating func appendOSC(_ p: UnsafePointer<UInt8>, count: Int) {
    var p = p
    var count = count
    // Byte by byte until the command prefix the limits depend on is fixed.
    while count > 0, oscCount <= oscCommandStart + 3 || oscCount < 5 {
      appendOSC(p.pointee)
      p += 1
      count -= 1
    }
    guard count > 0, !oscOverflow else { return }
    var limit = Self.maxOSCBytes
    if isColorOSC { limit = min(limit, Self.maxColorOSCBytes) }
    if isProgramStatusOSC {
      limit = min(limit, ProgramStatusCommand.maxBodyBytes)
    }
    let accepted = min(count, max(0, limit - oscCount))
    if oscCount + accepted > oscCapacity {
      var capacity = oscCapacity
      while capacity < oscCount + accepted { capacity *= 2 }
      let grown = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
      grown.update(from: osc, count: oscCount)
      osc.deallocate()
      osc = grown
      oscCapacity = capacity
    }
    (osc + oscCount).update(from: p, count: accepted)
    oscCount += accepted
    if accepted < count { oscOverflow = true }
  }

  private var isColorOSC: Bool {
    let start = oscCommandStart
    if start + 1 < oscCount, osc[start] == 0x34, osc[start + 1] == 0x3B {
      return true
    }
    return start + 2 < oscCount && osc[start] == 0x32 && osc[start + 1] == 0x31
      && osc[start + 2] == 0x3B
  }

  private var isClipboardOSC: Bool {
    let start = oscCommandStart
    return start + 2 < oscCount && osc[start] == 0x35 && osc[start + 1] == 0x32
      && osc[start + 2] == 0x3B
  }

  private var isProgramStatusOSC: Bool {
    oscCount >= 5 && osc[0] == 0x37 && osc[1] == 0x35 && osc[2] == 0x30
      && osc[3] == 0x31 && osc[4] == 0x3B  // 7501;
  }

  private mutating func dispatchOSC(_ t: inout TerminalState, bell: Bool) {
    if !oscOverflow {
      t.oscDispatch(
        UnsafeBufferPointer(start: osc, count: oscCount),
        terminatedByBell: bell
      )
    }
    oscCount = 0
    oscCommandStart = 0
    oscOverflow = false
  }
}
