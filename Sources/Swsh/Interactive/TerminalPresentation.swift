import Darwin

/// Passive terminal metadata always goes to /dev/tty, never redirected command data.
struct TerminalPresentation {
  let terminal: TerminalControl
  let enabled: Bool

  func prompt() throws {
    guard enabled else { return }
    if let cwd = getcwd(nil, 0) {
      defer { free(cwd) }
      let path = UnsafeRawBufferPointer(start: cwd, count: strlen(cwd))
      let encoded =
        path.map { byte -> String in
          if (65 ... 90).contains(byte) || (97 ... 122).contains(byte)
            || (48 ... 57).contains(byte)
            || [47, 45, 46, 95, 126].contains(byte)
          {
            return String(UnicodeScalar(byte))
          }
          let digits = Array("0123456789ABCDEF".utf8)
          return String(
            decoding: [37, digits[Int(byte >> 4)], digits[Int(byte & 15)]],
            as: UTF8.self
          )
        }
        .joined()
      try terminal.write(Array("\u{1B}]7;file://localhost\(encoded)\u{7}".utf8))
    }
    try terminal.write(Array("\u{1B}]133;A\u{7}".utf8))
  }

  func command() throws {
    if enabled { try terminal.write(Array("\u{1B}]133;C\u{7}".utf8)) }
  }

  func finished(_ status: Int32) throws {
    if enabled { try terminal.write(Array("\u{1B}]133;D;\(status)\u{7}".utf8)) }
  }
}
