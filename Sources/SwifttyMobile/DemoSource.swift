import Foundation
import SwifttyCore

/// Demo shell connected through `onWrite` and `receive`; apps supply remote
/// transports.
public final class DemoSource: @unchecked Sendable {
  public let session: TerminalSession

  public init(session: TerminalSession) { self.session = session }

  /// Starts a fresh shell and prints the banner and first prompt.
  /// Ordered with the session's queued input and output.
  public func start() {
    session.queue.async { [self] in
      let editor = DemoEditor()
      session.onWrite = { [weak self, editor] bytes in
        guard let self else { return }
        session.receive { state in
          editor.shell.input(bytes, columns: state.columns, rows: state.rows)
        }
      }
      // Echoes from input preceding this start are already queued.
      // Append the banner here so they cannot reach the fresh prompt.
      session.receive(DemoShell.banner + DemoShell.prompt)
    }
  }

  /// Detaches after previously queued input has been processed.
  public func stop() {
    session.queue.async { [session] in session.onWrite = nil }
  }
}

/// Each start owns its editor. Queued echoes retain the editor that accepted
/// their input, and cannot change a fresh editor after a restart. Access is
/// confined to the session queue by `receive`.
private final class DemoEditor: @unchecked Sendable { var shell = DemoShell() }

/// Byte-based demo editor with OSC 133 marks, cursor movement, and sample
/// commands.
public struct DemoShell: Sendable {
  static let promptText = "\u{1B}[1;32mdemo\u{1B}[0m:\u{1B}[1;34m~\u{1B}[0m$ "
  /// Prompt start mark, reverse wrapping for editing across rows, the
  /// prompt, and the command-line mark.
  public static let prompt = Array(
    "\u{1B}]133;A\u{7}\u{1B}[?45h\(promptText)\u{1B}]133;B\u{7}".utf8
  )
  public static let banner = Array(
    """
    \u{1B}[1mswiftty\u{1B}[0m demo: a local echo shell, no real host.\r
    Type \u{1B}[1mhelp\u{1B}[0m for commands.\r\n\r\n
    """
    .utf8
  )

  /// The line being edited.
  public private(set) var line: [Unicode.Scalar] = []
  /// Cursor position in `line`.
  public private(set) var cursor = 0
  private var escape = EscapeState.none
  private var parameters: [UInt8] = []
  /// Bytes of an incomplete UTF-8 sequence.
  private var pending: [UInt8] = []
  private var columns: Int
  private var visibleRows: Int?
  private var windowed = false
  /// Actual bell events from the current edit, excluding OSC terminators.
  private var editBells = 0

  private enum EscapeState { case none, escape, csi, discardCSI, ss3 }

  public init(columns: Int = 80) { self.columns = max(1, columns) }

  public var lineText: String { String(String.UnicodeScalarView(line)) }

  /// Consumes bytes from the terminal (typed keys, replies, pastes) and
  /// returns what the "host" prints back. Pass current dimensions after a
  /// resize. Supplying `rows` enables a viewport for commands taller than
  /// the screen; otherwise the editor assumes every command fits.
  public mutating func input(
    _ bytes: [UInt8],
    columns: Int? = nil,
    rows: Int? = nil
  ) -> [UInt8] {
    var redraw = false
    if let columns {
      redraw = max(1, columns) != self.columns
      self.columns = max(1, columns)
    }
    if let rows {
      redraw = redraw || max(1, rows) != visibleRows
      visibleRows = max(1, rows)
    }
    var out: [UInt8] = []
    var start = 0
    for i in bytes.indices
    where bytes[i] == 0x0D || bytes[i] == 0x0A || bytes[i] == 0x03 {
      out += edit(Array(bytes[start ..< i]), redraw: redraw)
      redraw = false
      if windowed, escape == .none || bytes[i] == 0x03 {
        // Commit the complete command before output begins, rather
        // than submitting the fragment currently visible.
        out +=
          Array("\u{1B}[H\u{1B}[2J".utf8) + Self.redrawnPrompt + render(line)
        cursor = line.count
        windowed = false
      }
      out += inputBytes([bytes[i]])
      start = i + 1
    }
    out += edit(Array(bytes[start...]), redraw: redraw)
    return out
  }

  private static let redrawnPrompt = Array(
    "\u{1B}]133;A;redraw=0\u{7}\u{1B}[?45h\(promptText)\u{1B}]133;B\u{7}".utf8,
  )

  private mutating func edit(_ bytes: [UInt8], redraw: Bool) -> [UInt8] {
    editBells = 0
    let out = inputBytes(bytes)
    guard redraw || out.count > editBells else { return out }
    guard let visibleRows else { return out }
    let layout = DemoCommandLayout(
      line: line,
      cursor: cursor,
      columns: columns,
      render: render
    )
    guard windowed || layout.rows.count > visibleRows else { return out }
    windowed = true
    return Array(repeating: 0x07, count: editBells)
      + layout.frame(height: visibleRows)
  }

  private mutating func inputBytes(_ bytes: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    for byte in bytes {
      // A non-continuation byte ends any incomplete scalar. Keep it
      // available to the ordinary input parser, including a new lead.
      if byte & 0xC0 != 0x80 { pending.removeAll(keepingCapacity: true) }
      if byte == 0x1B {
        escape = .escape
        parameters.removeAll(keepingCapacity: true)
        continue
      }
      if byte == 0x18 || byte == 0x1A {
        escape = .none
        parameters.removeAll(keepingCapacity: true)
        continue
      }
      if byte == 0x03 {
        escape = .none  // Ctrl-C must also interrupt an unfinished key report.
        parameters.removeAll(keepingCapacity: true)
      }
      switch escape {
      case .escape:
        escape = byte == 0x5B ? .csi : byte == 0x4F ? .ss3 : .none
        parameters.removeAll()
        continue
      case .csi:
        // Parameters and intermediates until a final byte. Covers
        // arrows, bracketed-paste markers, focus and kitty keys.
        if (0x40 ... 0x7E).contains(byte) {
          escape = .none
          out += editKey(
            final: byte,
            parameters: String(decoding: parameters, as: UTF8.self)
          )
        } else if (0x20 ... 0x3F).contains(byte), parameters.count < 64 {
          parameters.append(byte)
        } else {
          parameters.removeAll(keepingCapacity: true)
          escape = .discardCSI
        }
        continue
      case .discardCSI:
        // Drop the complete overlong/invalid report, not its prefix.
        if (0x40 ... 0x7E).contains(byte) { escape = .none }
        continue
      case .ss3:
        escape = .none
        out += editKey(final: byte, parameters: "")
        continue
      case .none: break
      }
      switch byte {
      case 0x0D, 0x0A:
        out += move(to: line.count)
        let command = lineText
        line.removeAll()
        cursor = 0
        out += Array("\r\n\u{1B}]133;C\u{7}".utf8)
        let (output, status) = run(command)
        out += output
        if !command.trimmingCharacters(in: .whitespaces).isEmpty || status != 0
        {
          out += Array("\u{1B}]133;D;\(status)\u{7}".utf8)
        }
        out += Self.prompt
      case 0x7F, 0x08: out += backspace()
      case 0x01:  // Ctrl-A
        out += move(to: 0)
      case 0x05:  // Ctrl-E
        out += move(to: line.count)
      case 0x03:  // Ctrl-C
        out += move(to: line.count)
        line.removeAll()
        cursor = 0
        out += Array("^C\r\n".utf8) + Self.prompt
      case 0x15:  // Ctrl-U: delete before the cursor
        let removed = cursor
        guard removed > 0 else { continue }
        out += move(to: 0)
        line.removeFirst(removed)
        out += redrawTail()
      case 0x0C:  // Ctrl-L
        let typed = line
        out += Array("\u{1B}[H\u{1B}[2J".utf8) + Self.prompt + render(line)
        line = typed
        out += Self.left(columnOffset(line.count) - columnOffset(cursor))
      case 0x20 ..< 0x80: out += insert(Unicode.Scalar(byte))
      case 0x80...:
        pending.append(byte)
        var decoder = UTF8()
        var iterator = pending.makeIterator()
        if case let .scalarValue(scalar) = decoder.decode(&iterator) {
          pending.removeAll()
          out += insert(scalar)
        } else if pending.count >= 4
          || pending.first.map({ $0 & 0xC0 == 0x80 }) == true
        {
          pending.removeAll()  // invalid: drop it
        }
      default: break  // other control characters
      }
    }
    return out
  }

  // MARK: Editing

  /// Logical cells from the prompt's start, including spacer cells when a
  /// wide grapheme cannot fit at a row's right edge. A pending wrap counts
  /// as the insertion position beyond the last column.
  private func columnOffset(_ position: Int) -> Int {
    var column = 8  // Visible width of "demo:~$ ".
    let values = line[..<position].map(\.value)
    var first = 0
    while first < values.count {
      let cluster = UnicodeWidth.graphemeWidth(values[first...])
      let width = min(columns, max(1, cluster.width))
      if width == 2, column % columns == columns - 1 { column += 1 }
      column += width
      first += cluster.length
    }
    return column
  }

  /// The editor assigns at least one cell to every grapheme. Give a
  /// cluster starting with a zero-width scalar a visible base so it cannot
  /// attach to the prompt or leave the terminal cursor behind the editor's
  /// cursor, even if a subsequent scalar widens the cluster.
  private func render(_ scalars: some Sequence<Unicode.Scalar>) -> [UInt8] {
    let scalars = Array(scalars)
    if scalars.allSatisfy(\.isASCII) { return scalars.map { UInt8($0.value) } }
    let values = scalars.map(\.value)
    var printed = String.UnicodeScalarView()
    var first = 0
    while first < values.count {
      let cluster = UnicodeWidth.graphemeWidth(values[first...])
      let end = first + cluster.length
      if columns == 1, cluster.width > 1 {
        // A wide glyph cannot fit. Emit one placeholder per whole
        // grapheme: streaming an emoji sequence into a one-column
        // terminal can otherwise consume several placeholder cells.
        printed.append(" ")
      } else {
        if UnicodeWidth.width(values[first]) == 0 { printed.append("◌") }
        printed.append(contentsOf: scalars[first ..< end])
      }
      first = end
    }
    return Array(String(printed).utf8)
  }

  /// The editor stores scalar indexes; use the renderer's segmentation
  /// to move between complete graphemes, including emoji sequences.
  private func boundary(from position: Int, forward: Bool) -> Int {
    let utf16 = line[..<position].reduce(0) { $0 + $1.utf16.count }
    let target =
      TerminalGeometry.compositionPosition(
        in: line,
        atUTF16Offset: utf16 + (forward ? 1 : -1),
        roundUp: forward,
      )
      .utf16Offset
    return scalarIndex(atUTF16Offset: target)
  }

  private func scalarIndex(atUTF16Offset target: Int) -> Int {
    var index = 0
    var offset = 0
    while offset < target {
      offset += line[index].utf16.count
      index += 1
    }
    return index
  }

  private static func left(_ n: Int) -> [UInt8] {
    n > 0 ? Array("\u{1B}[\(n)D".utf8) : []
  }

  /// Clears from the cursor, reprints the rest of the line and returns
  /// to the cursor.
  private func redrawTail() -> [UInt8] {
    let tail = line[cursor...]
    return Array("\u{1B}[J".utf8) + render(tail)
      + Self.left(columnOffset(line.count) - columnOffset(cursor))
  }

  private mutating func repaint(
    fromUTF16Offset start: Int,
    cursorUTF16Offset end: Int,
    movingLeft columns: Int
  ) -> [UInt8] {
    let first = scalarIndex(atUTF16Offset: start)
    cursor = scalarIndex(atUTF16Offset: end)
    return Self.left(columns) + Array("\u{1B}[J".utf8) + render(line[first...])
      + Self.left(columnOffset(line.count) - columnOffset(cursor))
  }

  private mutating func insert(_ scalar: Unicode.Scalar) -> [UInt8] {
    // Appending ordinary ASCII cannot merge either neighbor. Keep the
    // common typing path independent of the existing line's length.
    if cursor == line.count, scalar.isASCII, line.last?.isASCII != false {
      line.append(scalar)
      cursor += 1
      return Array(String(scalar).utf8)
    }
    let oldColumn = columnOffset(cursor)
    let insertionOffset = line[..<cursor].reduce(0) { $0 + $1.utf16.count }
    line.insert(scalar, at: cursor)
    cursor += 1
    let start = TerminalGeometry.compositionPosition(
      in: line,
      atUTF16Offset: insertionOffset
    )
    let end = TerminalGeometry.compositionPosition(
      in: line,
      atUTF16Offset: insertionOffset + scalar.utf16.count,
      roundUp: true,
    )
    if start.utf16Offset < insertionOffset
      || end.utf16Offset > insertionOffset + scalar.utf16.count
    {
      // Insertion can join both neighbors (for example, an emoji ZWJ).
      // Repaint from the merged grapheme's start, clearing cells freed
      // by its new width, and keep the cursor outside the grapheme.
      return repaint(
        fromUTF16Offset: start.utf16Offset,
        cursorUTF16Offset: end.utf16Offset,
        movingLeft: oldColumn
          - columnOffset(scalarIndex(atUTF16Offset: start.utf16Offset)),
      )
    }
    let tail = line[cursor...]
    return render([scalar]) + render(tail)
      + Self.left(columnOffset(line.count) - columnOffset(cursor))
  }

  private mutating func backspace() -> [UInt8] {
    guard cursor > 0 else {
      editBells += 1
      return [0x07]
    }
    return remove(boundary(from: cursor, forward: false) ..< cursor)
  }

  private mutating func remove(_ range: Range<Int>) -> [UInt8] {
    let oldColumn = columnOffset(cursor)
    let offset = line[..<range.lowerBound].reduce(0) { $0 + $1.utf16.count }
    line.removeSubrange(range)
    cursor = range.lowerBound
    let start = TerminalGeometry.compositionPosition(
      in: line,
      atUTF16Offset: offset
    )
    if start.utf16Offset < offset {
      // Removing a separator can merge the surviving neighbors.
      let end = TerminalGeometry.compositionPosition(
        in: line,
        atUTF16Offset: offset,
        roundUp: true
      )
      return repaint(
        fromUTF16Offset: start.utf16Offset,
        cursorUTF16Offset: end.utf16Offset,
        movingLeft: oldColumn
          - columnOffset(scalarIndex(atUTF16Offset: start.utf16Offset)),
      )
    }
    return Self.left(oldColumn - columnOffset(cursor)) + redrawTail()
  }

  private mutating func move(to target: Int) -> [UInt8] {
    let target = min(max(target, 0), line.count)
    defer { cursor = target }
    if target == cursor, target == line.count,
      columnOffset(target) % columns == 0
    {
      // After deleting the first cell of a wrapped row, the insertion
      // position is the next row's column zero rather than a pending
      // wrap on the preceding row. Repaint the last grapheme to restore
      // that state before Enter, Ctrl-C or End uses the line's end.
      if line.isEmpty { return Self.left(1) + Array("\u{1B}[J ".utf8) }
      let previous = boundary(from: target, forward: false)
      return Self.left(columnOffset(target) - columnOffset(previous))
        + Array("\u{1B}[J".utf8) + render(line[previous ..< target])
    }
    return target < cursor
      ? Self.left(columnOffset(cursor) - columnOffset(target))
      : render(line[cursor ..< target])
  }

  /// Arrows, Home, End and Delete.
  private mutating func editKey(final: UInt8, parameters: String) -> [UInt8] {
    switch final {
    case UInt8(ascii: "D"):
      return move(to: boundary(from: cursor, forward: false))
    case UInt8(ascii: "C"):
      return move(to: boundary(from: cursor, forward: true))
    case UInt8(ascii: "H"): return move(to: 0)
    case UInt8(ascii: "F"): return move(to: line.count)
    case UInt8(ascii: "~") where parameters == "3":
      if cursor < line.count {
        return remove(cursor ..< boundary(from: cursor, forward: true))
      }
      editBells += 1
      return [0x07]
    default: return []
    }
  }

  // MARK: Commands

  private func run(_ text: String) -> (output: [UInt8], status: Int) {
    let words = text.trimmingCharacters(in: .whitespaces)
      .split(separator: " ", maxSplits: 1)
    guard let command = words.first else { return ([], 0) }
    let rest = words.count > 1 ? String(words[1]) : ""
    let output: String =
      switch command {
      case "help":
        """
        Commands:\r
          help      this list\r
          echo ...  print the arguments\r
          colors    SGR colour table, underline styles, blink\r
          unicode   wide characters, emoji and box drawing\r
          links     an OSC 8 hyperlink and a plain URL\r
          clear     clear the screen (also Ctrl-L)\r

        """
      case "echo": rest + "\r\n"
      case "clear": "\u{1B}[H\u{1B}[2J"
      case "colors": Self.colorTable()
      case "links":
        """
        OSC 8: \u{1B}]8;;https://ghostty.org\u{1B}\\Ghostty\u{1B}]8;;\u{1B}\\ \
        \u{1B}]8;;https://www.swift.org\u{1B}\\Swift\u{1B}]8;;\u{1B}\\\r
        URL:   https://github.com/ghostty-org/ghostty\r

        """
      case "unicode":
        """
        CJK: 漢字かなカナ 한글  emoji: 🙂 👍🏽 👩‍💻 🇿🇦\r
        ┌──┬──┐ ╭──╮ ▁▂▃▄▅▆▇█ ⣿⡇ \u{E0B0}\r
        └──┴──┘ ╰──╯ ░▒▓ ←↑→↓\r

        """
      default: "\(command): command not found\r\n"
      }
    let known: Set<Substring> = [
      "help", "echo", "clear", "colors", "links", "unicode",
    ]
    return (Array(output.utf8), known.contains(command) ? 0 : 127)
  }

  static func colorTable() -> String {
    var s = ""
    for base in [0, 8] {
      for n in base ..< base + 8 {
        s += "\u{1B}[48;5;\(n)m \(String(format: "%3d", n)) "
      }
      s += "\u{1B}[0m\r\n"
    }
    // The 6×6×6 cube, one green level per row pair.
    for g in 0 ..< 6 {
      for r in 0 ..< 6 {
        for b in 0 ..< 6 { s += "\u{1B}[48;5;\(16 + r * 36 + g * 6 + b)m " }
      }
      s += "\u{1B}[0m\r\n"
    }
    for n in 232 ..< 256 { s += "\u{1B}[48;5;\(n)m " }
    s += "\u{1B}[0m\r\n"
    for i in 0 ..< 36 {
      let v = i * 255 / 35
      s += "\u{1B}[48;2;\(v);\(255 - v);128m "
    }
    s += "\u{1B}[0m\r\n"
    s +=
      "\u{1B}[1mbold\u{1B}[0m \u{1B}[3mitalic\u{1B}[0m \u{1B}[4munderline\u{1B}[0m "
    s +=
      "\u{1B}[9mstrike\u{1B}[0m \u{1B}[7minverse\u{1B}[0m \u{1B}[2mfaint\u{1B}[0m\r\n"
    s +=
      "\u{1B}[4:3mcurly\u{1B}[0m \u{1B}[4:3;58;2;255;85;85mred curly\u{1B}[0m \u{1B}[4:4mdotted\u{1B}[0m "
    s +=
      "\u{1B}[4:5mdashed\u{1B}[0m \u{1B}[4:2;58;5;39mdouble\u{1B}[0m \u{1B}[5mblink\u{1B}[0m\r\n"
    return s
  }
}
