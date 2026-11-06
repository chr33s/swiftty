import CSwshSupport
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Owns the controlling-terminal handle independently of all command descriptors.
/// Only the session driver uses this object; terminal restoration is explicit.
final class TerminalControl {
  private let handle: OwnedFD
  private let input: OwnedFD
  private let original: termios
  private let commandBaseline: termios
  private let editorModes: termios
  let shellGroup: pid_t
  private(set) var healthy = true
  private let beforeInstall: (() throws -> Void)?

  init(beforeInstall: (() throws -> Void)? = nil) throws {
    self.beforeInstall = beforeInstall
    guard let path = swsh_controlling_terminal() else {
      throw SystemFailure("resolve controlling terminal")
    }
    let bytes = Array(UnsafeRawBufferPointer(start: path, count: strlen(path)))
    free(path)
    let owner = try OwnedFD.open(bytes, flags: O_RDWR | O_NOCTTY)
    // A terminal signal can flush input after a readiness notification. Keep
    // reads nonblocking without changing the status flags of command stdin or
    // the blocking presentation handle (dup would share those flags).
    let input = try OwnedFD.open(bytes, flags: O_RDONLY | O_NOCTTY | O_NONBLOCK)
    var baseline = termios()
    let group = try owner.withDescriptor { fd -> pid_t in
      guard swsh_default_signal(SIGTTIN) == 0 else {
        throw SystemFailure("restore SIGTTIN")
      }
      var unblock = sigset_t()
      sigemptyset(&unblock)
      sigaddset(&unblock, SIGTTIN)
      guard sigprocmask(SIG_UNBLOCK, &unblock, nil) == 0 else {
        throw SystemFailure("unblock SIGTTIN")
      }
      while true {
        let foreground = tcgetpgrp(fd)
        guard foreground >= 0 else {
          throw SystemFailure("read foreground process group")
        }
        let current = getpgrp()
        if foreground == current { break }
        // A background nested shell must stop and let its parent foreground it.
        guard kill(-current, SIGTTIN) == 0 else {
          throw SystemFailure("wait for foreground")
        }
      }
      for number in [SIGTTOU, SIGTTIN, SIGTSTP, SIGQUIT, SIGPIPE] {
        guard swsh_ignore_signal(number) == 0 else {
          throw SystemFailure("ignore shell signal")
        }
      }
      let own = getpid()
      if getpgrp() != own && setpgid(0, own) != 0 {
        throw SystemFailure("create shell process group")
      }
      guard tcsetpgrp(fd, own) == 0 else {
        throw SystemFailure("foreground shell")
      }
      guard tcgetattr(fd, &baseline) == 0 else {
        throw SystemFailure("read terminal modes")
      }
      return own
    }
    var editor = baseline
    editor.c_lflag &= ~tcflag_t(ICANON | ECHO | IEXTEN)
    editor.c_iflag &= ~tcflag_t(IXON)
    withUnsafeMutableBytes(of: &editor.c_cc) { bytes in
      bytes[Int(VMIN)] = 1
      bytes[Int(VTIME)] = 0
    }
    original = baseline
    commandBaseline = baseline
    editorModes = editor
    shellGroup = group
    handle = consume owner
    self.input = consume input
  }

  var descriptor: Int32 { handle.withDescriptor { $0 } }
  var inputDescriptor: Int32 { input.withDescriptor { $0 } }

  var size: (columns: Int, rows: Int) {
    var value = winsize()
    guard ioctl(descriptor, UInt(TIOCGWINSZ), &value) == 0 else {
      return (80, 24)
    }
    return (
      max(1, Int(value.ws_col == 0 ? 80 : value.ws_col)),
      max(1, Int(value.ws_row == 0 ? 24 : value.ws_row))
    )
  }

  func edit() throws { try install(editorModes) }
  func commandMode() throws { try install(commandBaseline) }

  func give(to group: pid_t, modes: termios? = nil) throws {
    // A failure here must never be followed by SIGCONT.
    try install(commandBaseline)
    guard tcsetpgrp(descriptor, group) == 0 else {
      throw fail("transfer terminal foreground group")
    }
    if let modes { try install(modes) }
  }

  func reclaim(stopped: Bool) throws -> termios? {
    var saved = termios()
    if stopped && tcgetattr(descriptor, &saved) != 0 {
      throw fail("capture stopped job modes")
    }
    guard tcsetpgrp(descriptor, shellGroup) == 0 else {
      throw fail("reclaim terminal foreground group")
    }
    try install(editorModes)
    return stopped ? saved : nil
  }

  func restoreForExit() throws {
    guard tcsetpgrp(descriptor, shellGroup) == 0 else {
      throw fail("restore shell foreground group")
    }
    try install(original)
  }

  func write(_ bytes: [UInt8]) throws { try writeBytes(bytes, to: descriptor) }

  private func install(_ value: termios) throws {
    do { try beforeInstall?() } catch {
      healthy = false
      throw error
    }
    var modes = value
    while tcsetattr(descriptor, TCSANOW, &modes) != 0 {
      if errno == EINTR { continue }
      throw fail("restore terminal modes")
    }
  }

  private func fail(_ operation: String) -> SystemFailure {
    healthy = false
    return SystemFailure(operation)
  }
}
