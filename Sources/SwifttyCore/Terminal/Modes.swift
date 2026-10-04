/// ANSI and DEC private modes tracked by the terminal.
public struct Modes: OptionSet, Sendable, Hashable {
    public var rawValue: UInt64
    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    // ANSI (SM/RM)
    public static let insert = Modes(rawValue: 1 << 0) // IRM 4
    public static let linefeedNewline = Modes(rawValue: 1 << 1) // LNM 20

    // DEC private (DECSET/DECRST)
    public static let cursorKeys = Modes(rawValue: 1 << 2) // 1
    public static let reverseVideo = Modes(rawValue: 1 << 3) // 5
    public static let origin = Modes(rawValue: 1 << 4) // 6
    public static let autowrap = Modes(rawValue: 1 << 5) // 7
    public static let mouseX10 = Modes(rawValue: 1 << 6) // 9
    public static let cursorBlink = Modes(rawValue: 1 << 7) // 12
    public static let cursorVisible = Modes(rawValue: 1 << 8) // 25
    public static let mouseNormal = Modes(rawValue: 1 << 9) // 1000
    public static let mouseButton = Modes(rawValue: 1 << 10) // 1002
    public static let mouseAny = Modes(rawValue: 1 << 11) // 1003
    public static let focusEvents = Modes(rawValue: 1 << 12) // 1004
    public static let mouseUTF8 = Modes(rawValue: 1 << 13) // 1005
    public static let mouseSGR = Modes(rawValue: 1 << 14) // 1006
    public static let alternateScroll = Modes(rawValue: 1 << 15) // 1007
    public static let bracketedPaste = Modes(rawValue: 1 << 16) // 2004
    public static let synchronizedOutput = Modes(rawValue: 1 << 17) // 2026
    public static let keypadApplication = Modes(rawValue: 1 << 18) // DECKPAM
    public static let alternateScreen = Modes(rawValue: 1 << 19) // 47/1047/1049 (state)
    public static let reverseWrap = Modes(rawValue: 1 << 20) // 45
    public static let reverseWrapExtended = Modes(rawValue: 1 << 21) // 1045
    public static let leftRightMargin = Modes(rawValue: 1 << 22) // DECLRMM 69
    public static let graphemeCluster = Modes(rawValue: 1 << 23) // 2027
    public static let enableColumnMode = Modes(rawValue: 1 << 24) // 40 (allows DECCOLM)
    public static let column132 = Modes(rawValue: 1 << 25) // DECCOLM 3

    /// Grapheme clustering (2027) is on by default, like Ghostty's
    /// `grapheme-width-method = unicode`; Ghostty's bare `Terminal` has it off.
    public static let initial: Modes = [.autowrap, .cursorVisible, .alternateScroll, .graphemeCluster]
    public static let mouseTracking: Modes = [.mouseX10, .mouseNormal, .mouseButton, .mouseAny]

    /// DEC private mode number → flag, for DECSET/DECRST/DECRQM.
    static func dec(_ number: Int) -> Modes? {
        switch number {
        case 1: .cursorKeys
        case 3: .column132
        case 5: .reverseVideo
        case 6: .origin
        case 7: .autowrap
        case 9: .mouseX10
        case 12: .cursorBlink
        case 25: .cursorVisible
        case 40: .enableColumnMode
        case 45: .reverseWrap
        case 69: .leftRightMargin
        case 1045: .reverseWrapExtended
        case 2027: .graphemeCluster
        case 1000: .mouseNormal
        case 1002: .mouseButton
        case 1003: .mouseAny
        case 1004: .focusEvents
        case 1005: .mouseUTF8
        case 1006: .mouseSGR
        case 1007: .alternateScroll
        case 2004: .bracketedPaste
        case 2026: .synchronizedOutput
        case 47, 1047, 1049: .alternateScreen
        default: nil
        }
    }

    static func ansi(_ number: Int) -> Modes? {
        switch number {
        case 4: .insert
        case 20: .linefeedNewline
        default: nil
        }
    }
}

public enum CursorStyle: UInt8, Sendable {
    case block, underline, bar
}
