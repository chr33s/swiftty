import Darwin
import SwiftMuxProtocol

/// What runs in the foreground of a pane's terminal, read from the
/// process table: the leader of the terminal's foreground process group.
enum ForegroundProgram {
  /// Interpreters whose script names the program better than they do
  /// (`node …/bin/codex`, `sh ./build.sh`).
  static let interpreters: Set<String> = [
    "node", "bun", "deno", "python", "python3", "ruby", "perl", "sh", "bash",
    "dash", "zsh",
  ]

  /// The foreground program on the controlling terminal of `session` (the
  /// pane's first process), as a bare name; nil when unreadable.
  static func name(session pid: pid_t) -> String? {
    guard pid > 0 else { return nil }
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
      return nil
    }
    let group = pid_t(bitPattern: info.e_tpgid)
    // The shell itself is named as it runs, never by its arguments.
    guard group > 0, group != pid, let name = programName(group) else {
      return programName(pid)
    }
    if interpreters.contains(name) || name.hasPrefix("python3."),
      let script = scriptName(group)
    {
      return script
    }
    return name
  }

  /// `processName`, except that an executable named by its version
  /// (Claude Code's `~/.local/share/claude/versions/2.1.296`) is named by
  /// how it was invoked, or else by its installation directory.
  static func programName(_ pid: pid_t) -> String? {
    guard let name = processName(pid) else { return nil }
    guard isVersion(name), let process = processArguments(pid) else {
      return name
    }
    return versionedName(
      arguments: process.arguments,
      executable: process.executable
    ) ?? name
  }

  /// A versioned executable's program: argv[0] (the symlink it ran
  /// through), else the nearest path component that is neither a version
  /// nor a `versions` directory.
  static func versionedName(arguments: [String], executable: String?) -> String?
  {
    if let first = arguments.first, let name = ProgramName.sanitize(first),
      !isVersion(name)
    {
      return name
    }
    guard let executable else { return nil }
    for component in executable.split(separator: "/").reversed() {
      guard let name = ProgramName.sanitize(component) else { return nil }
      if isVersion(name) || name == "versions" { continue }
      return name
    }
    return nil
  }

  /// "2.1.296", "v1.2": a version number standing in for a program name.
  static func isVersion(_ name: String) -> Bool {
    let digits = name.first == "v" ? name.dropFirst() : name[...]
    return digits.first?.isASCII == true && digits.first?.isNumber == true
      && digits.allSatisfy { $0 == "." || ("0" ... "9").contains($0) }
  }

  static func processName(_ pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
    guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return ProgramName.sanitize(
      String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
    )
  }

  /// An interpreter's script: its first argument, when that is a file
  /// rather than an option (`python3 -m`, `node -e` keep the interpreter).
  static func scriptName(_ pid: pid_t) -> String? {
    guard let arguments = processArguments(pid)?.arguments, arguments.count > 1,
      !arguments[1].hasPrefix("-")
    else { return nil }
    return ProgramName.sanitize(arguments[1])
  }

  /// The process's executable path and argv (`KERN_PROCARGS2`), at most
  /// the first few arguments.
  static func processArguments(
    _ pid: pid_t
  ) -> (executable: String, arguments: [String])? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else {
      return nil
    }
    let count = buffer.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
    // argc, the executable path, NUL padding, then argv.
    var cursor = 4
    while cursor < size, buffer[cursor] != 0 { cursor += 1 }
    let executable = String(decoding: buffer[4 ..< cursor], as: UTF8.self)
    while cursor < size, buffer[cursor] == 0 { cursor += 1 }
    var arguments: [String] = []
    while cursor < size, arguments.count < min(count, 3) {
      let start = cursor
      while cursor < size, buffer[cursor] != 0 { cursor += 1 }
      arguments.append(
        String(decoding: buffer[start ..< cursor], as: UTF8.self)
      )
      cursor += 1
    }
    return (executable, arguments)
  }
}
