import Darwin

/// A small terminal editor: append/backspace, kill-line/word, history and bracketed paste.
/// Input readiness shares the supervisor's event source, so background children are reaped.
struct LineEditor {
  enum Result {
    case line([UInt8])
    case cancelled, eof
  }
  let terminal: TerminalControl
  let supervisor: JobSupervisor
  let history: HistoryStore
  let state: ShellState
  let metadata: Bool
  var completion: (([UInt8]) throws -> [UInt8]?)? = nil

  func read(prompt: String) throws -> Result {
    try terminal.edit()
    try terminal.write(Array("\u{1B}[?2004h".utf8))
    defer { try? terminal.write(Array("\u{1B}[?2004l".utf8)) }
    var buffer: [UInt8] = []
    var draft: [UInt8] = []
    var historyIndex = history.entries.count
    var escape: [UInt8] = []
    var pasting = false
    var display = EditorDisplay()
    var size = terminal.size
    func redraw() throws {
      try terminal.write(
        display.paint(
          prompt: prompt,
          bytes: visible(buffer),
          columns: size.columns,
          rows: size.rows
        )
      )
    }
    try redraw()
    if metadata { try terminal.write(Array("\u{1B}]133;B\u{7}".utf8)) }
    while true {
      let ready = try supervisor.poll(milliseconds: 1000, watchInput: true)
      supervisor.discardCompleted()
      let currentSize = terminal.size
      if currentSize != size {
        size = currentSize
        try redraw()
      }
      if supervisor.shutdownRequested != nil { return .eof }
      if supervisor.editInterrupted {
        supervisor.clearEditInterrupt()
        try terminal.write(Array("^C\r\n".utf8))
        return .cancelled
      }
      guard ready else { continue }
      var byte: UInt8 = 0
      let count = Darwin.read(terminal.inputDescriptor, &byte, 1)
      if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
      guard count >= 0 else { throw SystemFailure("read editor input") }
      if count == 0 { return .eof }
      if !escape.isEmpty || byte == 27 {
        escape.append(byte)
        let sequence = String(decoding: escape, as: UTF8.self)
        if pasting {
          let end = "\u{1B}[201~"
          if sequence == end {
            pasting = false;
            escape = []
          } else if !end.hasPrefix(sequence) {
            buffer.append(contentsOf: escape)
            try redraw()
            escape = []
          }
          continue
        }
        let known = ["\u{1B}[A", "\u{1B}[B", "\u{1B}[200~", "\u{1B}[201~"]
        if sequence == "\u{1B}[200~" {
          pasting = true;
          escape = [];
          continue
        }
        if sequence == "\u{1B}[201~" {
          pasting = false;
          escape = [];
          continue
        }
        if !pasting && (sequence == "\u{1B}[A" || sequence == "\u{1B}[B") {
          if historyIndex == history.entries.count { draft = buffer }
          if sequence.hasSuffix("A") {
            historyIndex = max(0, historyIndex - 1)
          } else {
            historyIndex = min(history.entries.count, historyIndex + 1)
          }
          buffer =
            historyIndex < history.entries.count
            ? history.entries[historyIndex] : draft
          escape = []
          try redraw()
        } else if !known.contains(where: { $0.hasPrefix(sequence) })
          || escape.count > 16
        {
          escape = []
        }
        continue
      }
      if pasting {
        buffer.append(byte);
        if String(validating: buffer, as: UTF8.self) != nil { try redraw() };
        continue
      }
      switch byte {
      case 10, 13:
        try terminal.write(Array("\r\n".utf8))
        return .line(buffer)
      case 4:
        if buffer.isEmpty {
          try terminal.write(Array("\r\n".utf8));
          return .eof
        }
      case 8, 127: removeLastCharacter(&buffer)
      case 21: buffer.removeAll()
      case 23:
        while buffer.last == 32 || buffer.last == 9 { buffer.removeLast() }
        while let last = buffer.last, last != 32 && last != 9 {
          removeLastCharacter(&buffer)
        }
      case 9:
        let suffix: [UInt8]?
        if let completion {
          suffix = try completion(buffer)
        } else {
          suffix = Completion(state: state).suffix(for: buffer)
        }
        if let suffix {
          buffer.append(contentsOf: suffix)
        } else {
          try terminal.write([7])
        }
      default:
        buffer.append(byte);
        if String(validating: buffer, as: UTF8.self) != nil { try redraw() };
        continue
      }
      try redraw()
    }
  }

  private func removeLastCharacter(_ buffer: inout [UInt8]) {
    guard !buffer.isEmpty else { return }
    if let string = String(validating: buffer, as: UTF8.self) {
      buffer = Array(string.dropLast().utf8)
    } else {
      buffer.removeLast()
    }
  }

  private func visible(_ buffer: [UInt8]) -> [UInt8] {
    var visible: [UInt8] = []
    for byte in buffer {
      if byte == 10 {
        visible.append(contentsOf: [92, 110])
      } else if byte == 9 {
        visible.append(contentsOf: [32, 32, 32, 32])
      } else if byte < 32 {
        visible.append(contentsOf: [94, byte + 64])
      } else if byte == 127 {
        visible.append(contentsOf: [94, 63])
      } else {
        visible.append(byte)
      }
    }
    return visible
  }
}
