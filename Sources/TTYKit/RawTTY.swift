import Darwin
import Foundation

/// The outer tty: saved termios, raw mode and the display modes swmux
/// enables, restored on every handled exit path.
public final class RawTTY {
  public let input: Int32
  public let output: Int32
  private var saved: termios?
  private var savedFlags: Int32?
  private var modesEnabled = false

  public init(input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO) {
    self.input = input
    self.output = output
  }

  public var isTerminal: Bool { isatty(input) == 1 && isatty(output) == 1 }

  public var size: (columns: Int, rows: Int) {
    var ws = winsize()
    guard ioctl(output, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0, ws.ws_row > 0
    else { return (80, 24) }
    return (Int(ws.ws_col), Int(ws.ws_row))
  }

  /// Saves termios before entering raw mode, then enables the alternate
  /// screen and bracketed paste.
  public func enter() throws {
    if saved == nil {
      var t = termios()
      guard tcgetattr(input, &t) == 0 else { throw POSIXFailure("tcgetattr") }
      let flags = fcntl(input, F_GETFL)
      guard flags >= 0 else { throw POSIXFailure("fcntl F_GETFL") }
      saved = t
      savedFlags = flags
    }
    var raw = saved!
    cfmakeraw(&raw)
    guard tcsetattr(input, TCSAFLUSH, &raw) == 0 else {
      throw POSIXFailure("tcsetattr")
    }
    guard fcntl(input, F_SETFL, savedFlags! | O_NONBLOCK) == 0 else {
      let error = POSIXFailure("fcntl F_SETFL")
      restore()
      throw error
    }
    write("\u{1B}[?1049h\u{1B}[?2004h\u{1B}[?25l")
    modesEnabled = true
  }

  /// Restores modes and termios. Idempotent; safe on error paths.
  public func restore() {
    if modesEnabled {
      write(
        "\u{1B}[?2026l\u{1B}[0m\u{1B}[?2004l\u{1B}[0 q\u{1B}[?25h\u{1B}[?1049l"
      )
      modesEnabled = false
    }
    if let flags = savedFlags { _ = fcntl(input, F_SETFL, flags) }
    if var t = saved { tcsetattr(input, TCSAFLUSH, &t) }
    savedFlags = nil
    saved = nil
  }

  /// Writes everything, blocking through EAGAIN. A started update is
  /// completed so the host never stops inside an escape sequence.
  @discardableResult
  public func write(_ string: String) -> Bool { write(Array(string.utf8)) }

  @discardableResult
  public func write(_ bytes: [UInt8]) -> Bool {
    var offset = 0
    while offset < bytes.count {
      let n = bytes.withUnsafeBytes {
        Darwin.write(output, $0.baseAddress! + offset, bytes.count - offset)
      }
      if n > 0 {
        offset += n
        continue
      }
      if n < 0, errno == EINTR { continue }
      if n < 0, errno == EAGAIN {
        var p = pollfd(fd: output, events: Int16(POLLOUT), revents: 0)
        _ = poll(&p, 1, 1000)
        continue
      }
      return false
    }
    return true
  }

  /// Reads what is available without blocking.
  public func read() -> [UInt8]? {
    var buffer = [UInt8](repeating: 0, count: 4096)
    let n = Darwin.read(input, &buffer, buffer.count)
    if n > 0 { return Array(buffer[0 ..< n]) }
    if n == 0 { return nil }
    return errno == EAGAIN || errno == EINTR ? [] : nil
  }
}

public struct POSIXFailure: Error, CustomStringConvertible {
  public let operation: String
  public let code = errno
  public init(_ operation: String) { self.operation = operation }
  public var description: String {
    "\(operation): \(String(cString: strerror(code)))"
  }
}
