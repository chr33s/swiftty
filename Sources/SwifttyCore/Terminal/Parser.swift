/// A parsed control sequence (CSI) handed to the terminal.
///
/// Parameters live inline; a sequence never allocates.
public struct CSISequence: Sendable {
    public static let maxParams = 24

    public internal(set) var params = InlineArray<24, UInt16>(repeating: 0)
    public internal(set) var count = 0
    /// Bit `i` set: parameter `i` was introduced by `:` (a sub-parameter).
    public internal(set) var colonMask: UInt32 = 0
    /// Private marker (`?`, `>`, `<`, `=`) or 0.
    public internal(set) var marker: UInt8 = 0
    /// First intermediate byte (0x20–0x2F) or 0.
    public internal(set) var intermediate: UInt8 = 0
    public internal(set) var final: UInt8 = 0

    /// Raw parameter value; missing parameters read as 0.
    @inline(__always)
    public func value(_ i: Int) -> Int {
        i < count ? Int(params[i]) : 0
    }

    /// Parameter with VT defaulting: missing or 0 reads as `fallback`.
    @inline(__always)
    public func param(_ i: Int, default fallback: Int) -> Int {
        let v = value(i)
        return v == 0 ? fallback : v
    }

    @inline(__always)
    public func isSubparameter(_ i: Int) -> Bool {
        i < count && colonMask & (1 << UInt32(i)) != 0
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
        case dcsEntry, dcsParam, dcsIntermediate, dcsIgnore, dcsPassthrough
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
    private var oscCapacity: Int
    /// An OSC 7501 body passed its limit: the sequence is dropped whole.
    private var oscOverflow = false
    public static let maxOSCBytes = 8 << 20

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
    struct Continuation: Sendable {
        var state: State
        var csi: CSISequence
        var currentParam: UInt32
        var hasParam: Bool
        var escIntermediate: UInt8
        var controlModeLineStart: Bool
        var codepoint: UInt32
        var utf8Remaining: Int
        var utf8Minimum: UInt32
        var osc: [UInt8]
        var oscOverflow: Bool
    }

    var continuation: Continuation {
        Continuation(state: state, csi: csi, currentParam: currentParam,
                     hasParam: hasParam, escIntermediate: escIntermediate,
                     controlModeLineStart: controlModeLineStart,
                     codepoint: codepoint, utf8Remaining: utf8Remaining,
                     utf8Minimum: utf8Minimum,
                     osc: Array(UnsafeBufferPointer(start: osc, count: oscCount)),
                     oscOverflow: oscOverflow)
    }

    mutating func restore(_ continuation: Continuation) {
        state = continuation.state
        csi = continuation.csi
        currentParam = continuation.currentParam
        hasParam = continuation.hasParam
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
        continuation.osc.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress {
                osc.update(from: base, count: buffer.count)
            }
        }
        oscOverflow = continuation.oscOverflow
    }

    /// Decodes printable ASCII and complete UTF-8 sequences into `scalars`
    /// until a control byte, an incomplete/invalid sequence, or capacity.
    @inline(__always)
    private func decodeRun(_ p: UnsafePointer<UInt8>, from start: Int, to end: Int) -> (count: Int, end: Int) {
        var i = start, count = 0
        while i < end, count < Self.scalarCapacity {
            let b = p[i]
            if b &- 0x20 < 0x5F {
                scalars[count] = UInt32(b)
                i += 1
            } else if b >= 0xC2, let (cp, length) = Self.decodeUTF8(p + i, available: end - i) {
                scalars[count] = cp
                i += length
            } else {
                break
            }
            count += 1
        }
        return (count, i)
    }

    public mutating func consume(_ bytes: borrowing Span<UInt8>, into terminal: inout TerminalState) {
        bytes.withUnsafeBufferPointer { consume($0, into: &terminal) }
    }

    public mutating func consume(_ buffer: UnsafeBufferPointer<UInt8>, into terminal: inout TerminalState) {
        guard let base = buffer.baseAddress else { return }
        let n = buffer.count
        var i = 0
        while i < n {
            if state == .controlMode {
                // Hand over everything up to the next ESC/CAN/SUB in one piece.
                var end = i
                while end < n, base[end] != 0x1B, base[end] != 0x18, base[end] != 0x1A {
                    end += 1
                }
                if end > i {
                    terminal.dcsPut(UnsafeBufferPointer(start: base + i, count: end - i))
                    controlModeLineStart = base[end - 1] == 0x0A
                    i = end
                    if i == n {
                        break
                    }
                }
            }
            if state == .dcsPassthrough {
                // Hand over everything up to the next ESC/CAN/SUB in one piece.
                var end = i
                while end < n, base[end] != 0x1B, base[end] != 0x18, base[end] != 0x1A {
                    end += 1
                }
                if end > i {
                    terminal.dcsPut(UnsafeBufferPointer(start: base + i, count: end - i))
                    i = end
                    if i == n {
                        break
                    }
                }
            }
            if state == .ground, utf8Remaining == 0 {
                let end = Self.scanPrintableASCII(base, from: i, to: n)
                if end > i {
                    terminal.printASCII(UnsafeBufferPointer(start: base + i, count: end - i))
                    i = end
                    if i == n {
                        break
                    }
                }
                // Complete multi-byte sequences decode inline; partial or
                // invalid ones fall through to the state machine.
                if base[i] >= 0xC2 {
                    let (count, end) = decodeRun(base, from: i, to: n)
                    if count > 0 {
                        terminal.printScalars(UnsafeBufferPointer(start: scalars, count: count))
                        i = end
                        continue
                    }
                }
            }
            step(base[i], &terminal)
            i += 1
        }
    }

    /// Index of the first byte in `from..<to` outside 0x20...0x7E.
    @inline(__always)
    static func scanPrintableASCII(_ p: UnsafePointer<UInt8>, from start: Int, to end: Int) -> Int {
        var i = start
        let raw = UnsafeRawPointer(p)
        while i + 16 <= end {
            let v = raw.loadUnaligned(fromByteOffset: i, as: SIMD16<UInt8>.self)
            // (b - 0x20) < 0x5F  <=>  0x20 <= b <= 0x7E
            let ok = (v &- 0x20) .< SIMD16<UInt8>(repeating: 0x5F)
            if all(ok) {
                i += 16; continue
            }
            break
        }
        while i < end, p[i] &- 0x20 < 0x5F {
            i += 1
        }
        return i
    }

    /// Decodes one well-formed 2–4 byte UTF-8 sequence at `p`.
    @inline(__always)
    static func decodeUTF8(_ p: UnsafePointer<UInt8>, available: Int) -> (UInt32, Int)? {
        let b0 = UInt32(p[0])
        if b0 < 0xE0 {
            guard available >= 2, p[1] & 0xC0 == 0x80 else { return nil }
            return ((b0 & 0x1F) << 6 | UInt32(p[1] & 0x3F), 2)
        }
        if b0 < 0xF0 {
            guard available >= 3, p[1] & 0xC0 == 0x80, p[2] & 0xC0 == 0x80 else { return nil }
            let cp = (b0 & 0x0F) << 12 | UInt32(p[1] & 0x3F) << 6 | UInt32(p[2] & 0x3F)
            guard cp >= 0x800, !(0xD800 ... 0xDFFF).contains(cp) else { return nil }
            return (cp, 3)
        }
        guard b0 <= 0xF4, available >= 4, p[1] & 0xC0 == 0x80, p[2] & 0xC0 == 0x80, p[3] & 0xC0 == 0x80 else {
            return nil
        }
        let cp = (b0 & 0x07) << 18 | UInt32(p[1] & 0x3F) << 12 | UInt32(p[2] & 0x3F) << 6 | UInt32(p[3] & 0x3F)
        guard cp >= 0x10000, cp <= 0x10FFFF else { return nil }
        return (cp, 4)
    }

    // MARK: State machine

    @inline(__always)
    private mutating func step(_ byte: UInt8, _ t: inout TerminalState) {
        if state == .controlMode || state == .controlModeEscape {
            controlModeStep(byte, &t)
            return
        }
        // Anywhere transitions.
        switch byte {
        case 0x18, 0x1A: // CAN, SUB
            if state == .oscString {
                oscCount = 0
                oscOverflow = false
            }
            if state == .dcsPassthrough {
                t.dcsUnhook()
            }
            resetUTF8()
            state = .ground
            return
        case 0x1B:
            if state == .oscString {
                dispatchOSC(&t, bell: false)
            }
            if state == .dcsPassthrough {
                t.dcsUnhook()
            }
            if utf8Remaining > 0 {
                resetUTF8(); t.print(0xFFFD)
            }
            enterEscape()
            return
        default: break
        }

        switch state {
        case .ground:
            ground(byte, &t)

        case .escape:
            switch byte {
            case 0x00 ... 0x1F: t.execute(byte)
            case 0x20 ... 0x2F: escIntermediate = byte; state = .escapeIntermediate
            case 0x5B: enterCSI() // [
            case 0x5D: oscCount = 0; oscOverflow = false; state = .oscString // ]
            case 0x50: enterCSI(); state = .dcsEntry // P
            case 0x58, 0x5E, 0x5F: state = .stringIgnore // X ^ _
            case 0x7F: break
            default: t.escDispatch(intermediate: 0, final: byte); state = .ground
            }

        case .escapeIntermediate:
            switch byte {
            case 0x00 ... 0x1F: t.execute(byte)
            case 0x20 ... 0x2F: break
            case 0x7F: break
            default: t.escDispatch(intermediate: escIntermediate, final: byte); state = .ground
            }

        case .csiEntry, .csiParam:
            switch byte {
            case 0x30 ... 0x39:
                currentParam = min(currentParam &* 10 &+ UInt32(byte - 0x30), 65535)
                hasParam = true
                state = .csiParam
            case 0x3B: pushParam(colon: false); state = .csiParam
            case 0x3A: pushParam(colon: true); state = .csiParam
            case 0x3C ... 0x3F:
                if state == .csiEntry, csi.marker == 0 {
                    csi.marker = byte; state = .csiParam
                } else {
                    state = .csiIgnore
                }
            case 0x20 ... 0x2F: finishParams(); csi.intermediate = byte; state = .csiIntermediate
            case 0x40 ... 0x7E: finishParams(); dispatchCSI(byte, &t)
            case 0x00 ... 0x1F: t.execute(byte)
            default: break
            }

        case .csiIntermediate:
            switch byte {
            case 0x20 ... 0x2F: break
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
            case 0x07: dispatchOSC(&t, bell: true); state = .ground
            case 0x00 ... 0x1F: break
            default: appendOSC(byte)
            }

        case .stringIgnore, .dcsIgnore:
            break // terminated by ESC (\) or CAN/SUB above

        case .dcsEntry, .dcsParam, .dcsIntermediate, .dcsPassthrough:
            dcsStep(byte, &t)

        case .controlMode, .controlModeEscape:
            break // handled before the anywhere transitions
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
                    let valid = cp >= utf8Minimum && cp <= 0x10FFFF && !(0xD800 ... 0xDFFF).contains(cp)
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
    private mutating func begin(_ bits: UInt32, _ remaining: Int, _ minimum: UInt32) {
        codepoint = bits
        utf8Remaining = remaining
        utf8Minimum = minimum
    }

    @inline(__always)
    private mutating func resetUTF8() {
        utf8Remaining = 0
    }

    private mutating func enterEscape() {
        escIntermediate = 0
        state = .escape
    }

    private mutating func enterCSI() {
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
            if colon, csi.count < CSISequence.maxParams {
                csi.colonMask |= 1 << UInt32(csi.count)
            }
        }
        currentParam = 0
        hasParam = false
    }

    private mutating func finishParams() {
        if hasParam || csi.count > 0 || csi.colonMask != 0 {
            pushParam(colon: false)
        }
    }

    private mutating func dispatchCSI(_ final: UInt8, _ t: inout TerminalState) {
        csi.final = final
        t.csiDispatch(csi)
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
            case 0x3B: pushParam(colon: false); state = .dcsParam
            case 0x3A: state = .dcsIgnore
            case 0x3C ... 0x3F:
                if state == .dcsEntry, csi.marker == 0 {
                    csi.marker = byte; state = .dcsParam
                } else {
                    state = .dcsIgnore
                }
            case 0x20 ... 0x2F: finishParams(); csi.intermediate = byte; state = .dcsIntermediate
            case 0x40 ... 0x7E: finishParams(); hookDCS(byte, &t)
            default: break // C0 and DEL are ignored inside DCS
            }

        case .dcsIntermediate:
            switch byte {
            case 0x20 ... 0x2F: break
            case 0x30 ... 0x3F: state = .dcsIgnore
            case 0x40 ... 0x7E: hookDCS(byte, &t)
            default: break
            }

        case .dcsPassthrough:
            withUnsafePointer(to: byte) { t.dcsPut(UnsafeBufferPointer(start: $0, count: 1)) }

        default: break
        }
    }

    private mutating func hookDCS(_ final: UInt8, _ t: inout TerminalState) {
        csi.final = final
        t.dcsHook(csi)
        if csi.marker == 0, csi.intermediate == 0, final == 0x70, csi.value(0) == 1000 {
            state = .controlMode
            controlModeLineStart = true
        } else {
            state = .dcsPassthrough
        }
    }

    /// tmux control mode, one byte at a time (see `State.controlMode`).
    private mutating func controlModeStep(_ byte: UInt8, _ t: inout TerminalState) {
        if state == .controlModeEscape {
            state = .controlMode
            if byte == 0x5C { // ST after `%exit`
                t.dcsUnhook()
                state = .ground
                return
            }
            // The ESC was data (e.g. SGR at the start of a captured line).
            withUnsafePointer(to: UInt8(0x1B)) { t.dcsPut(UnsafeBufferPointer(start: $0, count: 1)) }
            controlModeLineStart = false
        }
        switch byte {
        case 0x18, 0x1A: // CAN, SUB
            t.dcsUnhook()
            state = .ground
        case 0x1B where controlModeLineStart:
            state = .controlModeEscape
        default:
            withUnsafePointer(to: byte) { t.dcsPut(UnsafeBufferPointer(start: $0, count: 1)) }
            controlModeLineStart = byte == 0x0A
        }
    }

    private mutating func appendOSC(_ byte: UInt8) {
        // OSC 7501 has its own bound, below the generic one; a longer
        // report is discarded rather than truncated.
        if oscCount >= ProgramStatusCommand.maxBodyBytes, !oscOverflow, isProgramStatusOSC {
            oscOverflow = true
        }
        if oscOverflow {
            return
        }
        if oscCount == oscCapacity {
            guard oscCapacity < Self.maxOSCBytes else { return }
            let grown = UnsafeMutablePointer<UInt8>.allocate(capacity: oscCapacity * 2)
            grown.update(from: osc, count: oscCount)
            osc.deallocate()
            osc = grown
            oscCapacity *= 2
        }
        osc[oscCount] = byte
        oscCount += 1
    }

    private var isProgramStatusOSC: Bool {
        oscCount >= 5 && osc[0] == 0x37 && osc[1] == 0x35 && osc[2] == 0x30 && osc[3] == 0x31 && osc[4] == 0x3B // 7501;
    }

    private mutating func dispatchOSC(_ t: inout TerminalState, bell: Bool) {
        if !oscOverflow {
            t.oscDispatch(UnsafeBufferPointer(start: osc, count: oscCount), terminatedByBell: bell)
        }
        oscCount = 0
        oscOverflow = false
    }
}
