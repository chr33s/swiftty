import Darwin
import Foundation
import SwiftMuxProtocol
import TerminalProcess

/// A spawned pane process: the PTY master, a retained slave (Darwin drops
/// unread output once the last slave closes) and the shell's pid.
package struct LaunchedProcess: Sendable {
  package var master: Int32
  package var slave: Int32
  package var pid: pid_t
  package var warnings: [String]
}

/// Starts pane processes through the fresh `swmux-launcher` executable.
/// No Swift code runs in a forked child of the service.
package struct PaneLauncher: Sendable {
  package var launcherPath: String
  package var innerTerm: String
  /// Extra terminfo search directory for `innerTerm`, if installed there.
  package var terminfoDirectory: String?
  package var launchTimeout: Duration = .seconds(10)

  package init(
    launcherPath: String,
    innerTerm: String,
    terminfoDirectory: String? = nil,
    launchTimeout: Duration = .seconds(10)
  ) {
    self.launcherPath = launcherPath
    self.innerTerm = innerTerm
    self.terminfoDirectory = terminfoDirectory
    self.launchTimeout = launchTimeout
  }

  /// Resolves the program using its environment snapshot and pane directory.
  package static func resolve(
    _ spec: LaunchSpec,
    environment: [String: String],
    directory: String
  ) throws(MuxError) -> (path: String, argv: [String]) {
    guard let command = spec.command, let program = command.first else {
      let shell = loginShell(environment)
      let base = shell.split(separator: "/").last.map(String.init) ?? shell
      // A leading dash in argv[0] asks the shell to act as a login shell.
      return (shell, ["-" + base])
    }
    for part in command where part.utf8.contains(0) {
      throw MuxError(.invalidRequest, "argument contains NUL: \(part)")
    }
    guard !program.isEmpty else {
      throw MuxError(.invalidRequest, "empty program")
    }
    if program.contains("/") { return (program, command) }
    let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    let base = URL(fileURLWithPath: directory, isDirectory: true)
    for dir in path.split(separator: ":", omittingEmptySubsequences: false) {
      // An empty PATH entry names the pane's working directory. Resolve
      // relative entries before the launcher changes directory, so the
      // access check and exec refer to the same absolute executable.
      let candidate = URL(
        fileURLWithPath: dir.isEmpty ? "." : String(dir),
        isDirectory: true,
        relativeTo: base
      )
      .appendingPathComponent(program).path
      if access(candidate, X_OK) == 0 { return (candidate, command) }
    }
    throw MuxError(.launchFailed, "\(program): command not found")
  }

  package static func loginShell(_ environment: [String: String]) -> String {
    if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell,
      shell.pointee != 0
    {
      return String(cString: shell)
    }
    return environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
  }

  /// The pane's environment: the creation snapshot plus inner identity.
  package func environment(
    for spec: LaunchSpec,
    pane: PaneID,
    workspace: WorkspaceID
  ) -> [String: String] {
    var env = spec.environment
    if env["HOME"] == nil, let pw = getpwuid(getuid()) {
      env["HOME"] = String(cString: pw.pointee.pw_dir)
    }
    if env["USER"] == nil, let pw = getpwuid(getuid()) {
      env["USER"] = String(cString: pw.pointee.pw_name)
      env["LOGNAME"] = env["USER"]
    }
    if env["PATH"] == nil { env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin" }
    if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
    env["SHELL"] = env["SHELL"] ?? Self.loginShell(env)
    // Programs see the inner engine, never the outer host or tmux.
    for key in [
      "TMUX", "TMUX_PANE", "TERMINFO", "TERM_SESSION_ID", "ITERM_SESSION_ID",
    ] { env.removeValue(forKey: key) }
    env["TERM"] = innerTerm
    env["COLORTERM"] = "truecolor"
    env["TERM_PROGRAM"] = "swmux"
    env["TERM_PROGRAM_VERSION"] = SMX.build
    env["SWMUX"] = "1"
    env["SWMUX_PANE"] = pane.description
    env["SWMUX_WORKSPACE"] = workspace.description
    if let dir = terminfoDirectory {
      // A trailing empty entry keeps the system database.
      let existing = env["TERMINFO_DIRS"].map { ":" + $0 } ?? ":"
      env["TERMINFO_DIRS"] = dir + existing
    }
    return env
  }

  /// Allocates a PTY with deliberate cooked termios and spawns the
  /// launcher, which execs the program as session leader.
  package func launch(
    _ spec: LaunchSpec,
    pane: PaneID,
    workspace: WorkspaceID,
    columns: Int,
    rows: Int,
    copyingCString: (String) -> UnsafeMutablePointer<CChar>? = { strdup($0) },
    freeingCString: (UnsafeMutablePointer<CChar>) -> Void = { free($0) }
  ) throws(MuxError) -> LaunchedProcess {
    guard launchTimeout > .zero, launchTimeout <= .seconds(30) else {
      throw MuxError(
        .invalidRequest,
        "launcher timeout must be in (0, 30] seconds"
      )
    }
    let env = environment(for: spec, pane: pane, workspace: workspace)
    let directory =
      spec.workingDirectory ?? env["HOME"]
      ?? FileManager.default.homeDirectoryForCurrentUser.path
    guard !directory.utf8.contains(0) else {
      throw MuxError(.invalidRequest, "directory contains NUL")
    }
    for (k, v) in env
    where k.isEmpty || k.utf8.contains(0) || k.contains("=")
      || v.utf8.contains(0)
    { throw MuxError(.invalidRequest, "invalid environment entry \(k)") }
    let (program, argv) = try Self.resolve(
      spec,
      environment: env,
      directory: directory
    )

    var size = winsize(
      ws_row: UInt16(clamping: max(1, rows)),
      ws_col: UInt16(clamping: max(1, columns)),
      ws_xpixel: 0,
      ws_ypixel: 0
    )
    var attrs = Self.interactiveTermios()
    var master: Int32 = -1
    var slave: Int32 = -1
    do {
      try PTYAllocation.open(
        master: &master,
        slave: &slave,
        attributes: &attrs,
        size: &size
      )
    } catch { throw MuxError(.launchFailed, error.description) }
    var pipeFDs: [Int32] = [-1, -1]
    var ownsDescriptors = true
    defer {
      if ownsDescriptors {
        close(master)
        if slave >= 0 { close(slave) }
        for fd in pipeFDs where fd >= 0 { close(fd) }
      }
    }
    try Self.checkFD(
      fcntl(master, F_SETFD, FD_CLOEXEC),
      "fcntl(master cloexec)"
    )
    try Self.checkFD(fcntl(slave, F_SETFD, FD_CLOEXEC), "fcntl(slave cloexec)")
    let flags = fcntl(master, F_GETFL)
    try Self.checkFD(flags, "fcntl(master flags)")
    try Self.checkFD(
      fcntl(master, F_SETFL, flags | O_NONBLOCK),
      "fcntl(master nonblocking)"
    )
    try Self.checkFD(pipe(&pipeFDs), "pipe")
    try Self.checkFD(
      fcntl(pipeFDs[0], F_SETFD, FD_CLOEXEC),
      "fcntl(report read cloexec)"
    )
    try Self.checkFD(
      fcntl(pipeFDs[1], F_SETFD, FD_CLOEXEC),
      "fcntl(report write cloexec)"
    )
    // The child receives the slave as fd 3 and the pipe as fd 4. Sources
    // already at 3 or 4 would collide: `dup2(3, 3)` keeps close-on-exec,
    // and crossed duplicates overwrite each other. Move both above.
    slave = Self.aboveChildDescriptors(slave)
    try Self.checkFD(slave, "fcntl(slave duplicate)")
    pipeFDs[1] = Self.aboveChildDescriptors(pipeFDs[1])
    try Self.checkFD(pipeFDs[1], "fcntl(report duplicate)")

    let pid = try spawnLauncher(
      arguments: [launcherPath, directory, program] + argv,
      environment: env.map { "\($0.key)=\($0.value)" },
      slave: slave,
      reportFD: pipeFDs[1],
      copyingCString: copyingCString,
      freeingCString: freeingCString
    )
    close(pipeFDs[1])
    pipeFDs[1] = -1
    // The handshake now owns the child and remaining descriptors, including
    // cleanup on failure. Do not close them again from this setup scope.
    ownsDescriptors = false
    return try Self.finishLaunch(
      pid: pid,
      master: master,
      slave: slave,
      reportFD: pipeFDs[0],
      timeout: launchTimeout,
      program: program
    )
  }

  /// Descriptors stay caller-owned; only success returns an owned child PID.
  private func spawnLauncher(
    arguments: [String],
    environment: [String],
    slave: Int32,
    reportFD: Int32,
    copyingCString: (String) -> UnsafeMutablePointer<CChar>?,
    freeingCString: (UnsafeMutablePointer<CChar>) -> Void
  ) throws(MuxError) -> pid_t {
    var actions: posix_spawn_file_actions_t?
    try Self.checkSetup(
      posix_spawn_file_actions_init(&actions),
      "posix_spawn_file_actions_init"
    )
    defer { posix_spawn_file_actions_destroy(&actions) }
    try Self.checkSetup(
      posix_spawn_file_actions_adddup2(&actions, slave, 3),
      "posix_spawn_file_actions_adddup2(slave)"
    )
    try Self.checkSetup(
      posix_spawn_file_actions_adddup2(&actions, reportFD, 4),
      "posix_spawn_file_actions_adddup2(report)"
    )
    var attributes: posix_spawnattr_t?
    try Self.checkSetup(
      posix_spawnattr_init(&attributes),
      "posix_spawnattr_init"
    )
    defer { posix_spawnattr_destroy(&attributes) }
    // No POSIX_SPAWN_SETSID: the launcher creates the one session itself.
    let spawnFlags =
      POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
      | POSIX_SPAWN_SETSIGMASK
    try Self.checkSetup(
      posix_spawnattr_setflags(&attributes, Int16(spawnFlags)),
      "posix_spawnattr_setflags"
    )
    var all = sigset_t()
    sigfillset(&all)
    try Self.checkSetup(
      posix_spawnattr_setsigdefault(&attributes, &all),
      "posix_spawnattr_setsigdefault"
    )
    var none = sigset_t()
    sigemptyset(&none)
    try Self.checkSetup(
      posix_spawnattr_setsigmask(&attributes, &none),
      "posix_spawnattr_setsigmask"
    )

    var pid: pid_t = 0
    let status: Int32
    do {
      status = try CStringVector.withStrings(
        arguments,
        copying: copyingCString,
        freeing: freeingCString
      ) { cArgv throws(TerminalProcess.POSIXError) in
        try CStringVector.withStrings(
          environment,
          copying: copyingCString,
          freeing: freeingCString
        ) { cEnv in
          posix_spawn(&pid, launcherPath, &actions, &attributes, cArgv, cEnv)
        }
      }
    } catch { throw MuxError(.launchFailed, error.description) }
    guard status == 0 else {
      throw MuxError(
        .launchFailed,
        "spawn \(launcherPath): \(String(cString: strerror(status)))"
      )
    }
    return pid
  }

  private static func checkFD(
    _ result: Int32,
    _ operation: String
  ) throws(MuxError) {
    guard result >= 0 else {
      throw MuxError(
        .launchFailed,
        "\(operation): \(String(cString: strerror(errno)))"
      )
    }
  }

  private static func checkSetup(
    _ status: Int32,
    _ operation: String
  ) throws(MuxError) {
    guard status == 0 else {
      throw MuxError(
        .launchFailed,
        "\(operation): \(String(cString: strerror(status)))"
      )
    }
  }

  /// Verifies the launch handshake, closing the process and descriptors on
  /// failure; a successful result transfers PTY ownership to the caller.
  private static func finishLaunch(
    pid: pid_t,
    master: Int32,
    slave: Int32,
    reportFD: Int32,
    timeout: Duration,
    program: String
  ) throws(MuxError) -> LaunchedProcess {
    // The launcher either reports and execs (closing the pipe on exec)
    // or reports a failure and exits. EOF alone is not success.
    let report: Data
    do {
      report = try Self.readLaunchReport(from: reportFD, timeout: timeout)
    } catch {
      let cleanup = Self.stopFailedLauncher(pid)
      close(master)
      close(slave)
      close(reportFD)
      throw MuxError(error.code, "\(error.message); \(cleanup)")
    }
    close(reportFD)
    let lines = String(decoding: report, as: UTF8.self).split(separator: "\n")
    let failure = lines.first { $0.hasPrefix("E ") }
    let ready =
      report.last == 0x0A && lines.contains("S exec 0")
      && lines.allSatisfy { $0 == "S exec 0" || $0.hasPrefix("W ") }
    if failure != nil || !ready {
      let cleanup = Self.stopFailedLauncher(pid)
      close(master)
      close(slave)
      let reason: String
      if let failure {
        let parts = failure.split(separator: " ")
        let code = parts.count > 2 ? Int32(parts[2]) ?? 0 : 0
        reason =
          "\(parts.count > 1 ? parts[1] : "launch"): \(code == 0 ? "failed" : String(cString: strerror(code)))"
      } else {
        reason = "launcher: missing complete success report"
      }
      // Hex keeps malformed/control bytes out of diagnostic output. Retain
      // the total length while limiting the sample independently of the cap.
      let hex = report.prefix(32).map { String(format: "%02x", $0) }.joined()
      throw MuxError(
        .launchFailed,
        "\(reason) (\(program)); report bytes=\(report.count) hex=\(hex); \(cleanup)"
      )
    }
    let warnings = lines.filter { $0.hasPrefix("W ") }.map(String.init)
    return LaunchedProcess(
      master: master,
      slave: slave,
      pid: pid,
      warnings: warnings
    )
  }

  /// Requires exclusive child ownership. Peek without collecting so the PID
  /// stays reserved through group signaling; distinguish observed termination
  /// from the status collected after our cleanup signal.
  package static func stopFailedLauncher(_ pid: pid_t) -> String {
    var child = siginfo_t()
    var peek: Int32
    repeat {
      peek = waitid(P_PID, id_t(pid), &child, WEXITED | WNOHANG | WNOWAIT)
    } while peek < 0 && errno == EINTR
    guard peek == 0 else {
      let error = errno
      // ECHILD includes a child already collected by someone else. Never
      // signal its potentially reused PID or inherited process group.
      return "pre-cleanup waitid errno=\(error); cleanup skipped"
    }
    let observed: String
    if child.si_pid == pid {
      let kind = child.si_code == CLD_EXITED ? "exit" : "signal"
      observed = "\(kind)=\(child.si_status)"
    } else {
      observed = "not-waitable"
    }
    // Once login_tty created the pane's own process group, include any
    // descendants. Never signal the service's inherited group.
    if getpgid(pid) == pid { kill(-pid, SIGKILL) }
    kill(pid, SIGKILL)
    var status: Int32 = 0
    var collected: pid_t
    repeat {
      collected = waitpid(pid, &status, 0)
    } while collected < 0 && errno == EINTR
    guard collected == pid else {
      return "pre-cleanup child=\(observed); waitpid errno=\(errno)"
    }
    let terminal = status & 0x7F
    let outcome =
      terminal == 0 ? "exit=\((status >> 8) & 0xFF)" : "signal=\(terminal)"
    return "pre-cleanup child=\(observed); collected \(outcome)"
  }

  private static func readLaunchReport(
    from fd: Int32,
    timeout: Duration
  ) throws(MuxError) -> Data {
    let deadline = ContinuousClock.now + timeout
    var report = Data()
    var buffer = [UInt8](repeating: 0, count: 256)
    while true {
      let remaining = ContinuousClock.now.duration(to: deadline)
      guard remaining > .zero else {
        throw MuxError(.launchFailed, "launcher handshake timed out")
      }
      let parts = remaining.components
      let milliseconds = max(
        1,
        parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000
      )
      var descriptor = pollfd(
        fd: fd,
        events: Int16(POLLIN | POLLHUP),
        revents: 0
      )
      let ready = poll(&descriptor, 1, Int32(clamping: milliseconds))
      if ready == 0 { continue }
      if ready < 0 {
        if errno == EINTR { continue }
        throw MuxError(
          .launchFailed,
          "launcher poll: \(String(cString: strerror(errno)))"
        )
      }
      let n = read(fd, &buffer, buffer.count)
      if n > 0 {
        guard n <= 4096 - report.count else {
          throw MuxError(.launchFailed, "launcher report limit exceeded")
        }
        report.append(contentsOf: buffer[0 ..< n])
        continue
      }
      if n == 0 { return report }
      if errno == EINTR || errno == EAGAIN { continue }
      throw MuxError(
        .launchFailed,
        "launcher read: \(String(cString: strerror(errno)))"
      )
    }
  }

  /// A close-on-exec duplicate of `fd` numbered 5 or higher (closing
  /// `fd`); `fd` itself when it already is. -1 on failure.
  package static func aboveChildDescriptors(_ fd: Int32) -> Int32 {
    guard fd < 5 else { return fd }
    let moved = fcntl(fd, F_DUPFD_CLOEXEC, 5)
    let error = errno
    close(fd)
    if moved < 0 { errno = error }
    return moved
  }

  /// Cooked interactive settings, matching the BSD `ttydefaults`.
  package static func interactiveTermios() -> termios {
    var t = termios()
    t.c_iflag = tcflag_t(BRKINT | ICRNL | IMAXBEL | IXON | IXANY | IUTF8)
    t.c_oflag = tcflag_t(OPOST | ONLCR)
    t.c_cflag = tcflag_t(CREAD | CS8 | HUPCL)
    t.c_lflag = tcflag_t(
      ICANON | ISIG | IEXTEN | ECHO | ECHOE | ECHOKE | ECHOCTL
    )
    func control(_ c: Character) -> cc_t { cc_t(c.asciiValue! & 0x1F) }
    withUnsafeMutableBytes(of: &t.c_cc) { cc in
      cc[Int(VEOF)] = control("D")
      cc[Int(VEOL)] = 0xFF
      cc[Int(VEOL2)] = 0xFF
      cc[Int(VERASE)] = 0x7F
      cc[Int(VWERASE)] = control("W")
      cc[Int(VKILL)] = control("U")
      cc[Int(VREPRINT)] = control("R")
      cc[Int(VINTR)] = control("C")
      cc[Int(VQUIT)] = 0x1C
      cc[Int(VSUSP)] = control("Z")
      cc[Int(VDSUSP)] = control("Y")
      cc[Int(VSTART)] = control("Q")
      cc[Int(VSTOP)] = control("S")
      cc[Int(VLNEXT)] = control("V")
      cc[Int(VDISCARD)] = control("O")
      cc[Int(VMIN)] = 1
      cc[Int(VTIME)] = 0
      cc[Int(VSTATUS)] = control("T")
    }
    cfsetispeed(&t, speed_t(B38400))
    cfsetospeed(&t, speed_t(B38400))
    return t
  }
}
