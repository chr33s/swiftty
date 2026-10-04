import Darwin

/// A child process attached to a pseudo-terminal.
///
/// Spawned with `posix_spawn`: `POSIX_SPAWN_SETSID` makes the child a
/// session leader and opening the slave by path then makes it the
/// controlling terminal, so no fork-time code is needed.
public final class PTYProcess: @unchecked Sendable {
    public let master: FileDescriptor
    public let pid: pid_t

    private init(master: consuming FileDescriptor, pid: pid_t) {
        self.master = master
        self.pid = pid
    }

    public static func spawn(
        _ configuration: SessionConfiguration,
        columns: Int,
        rows: Int,
        cellPixelSize: (width: Int, height: Int) = (0, 0),
    ) throws(POSIXError) -> PTYProcess {
        var masterFD: Int32 = -1, slaveFD: Int32 = -1
        var size = Self.winsize(columns: columns, rows: rows, cellPixelSize: cellPixelSize)
        var nameBuffer = [CChar](repeating: 0, count: 128)
        guard openpty(&masterFD, &slaveFD, &nameBuffer, nil, &size) == 0 else { throw POSIXError("openpty") }
        let master = FileDescriptor(masterFD)
        let slave = FileDescriptor(slaveFD)
        master.setCloseOnExec()

        // UTF-8 aware line discipline (correct backspace over multibyte input).
        var attrs = termios()
        if tcgetattr(slave.rawValue, &attrs) == 0 {
            attrs.c_iflag |= tcflag_t(IUTF8)
            tcsetattr(slave.rawValue, TCSANOW, &attrs)
        }

        let ttyName = String(decoding: nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let argv = configuration.resolvedArguments()
        let env = configuration.resolvedEnvironment().map { "\($0.key)=\($0.value)" }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, ttyName, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        if let cwd = configuration.workingDirectory {
            posix_spawn_file_actions_addchdir(&actions, cwd)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        var pid: pid_t = 0
        let status = withCStrings(argv) { cArgv in
            withCStrings(env) { cEnv in
                posix_spawn(&pid, configuration.executablePath(), &actions, &attributes, cArgv, cEnv)
            }
        }
        guard status == 0 else { throw POSIXError("posix_spawn \(argv[0])", code: status) }
        _ = consume slave // the child has its own copy
        try master.setNonBlocking()
        return PTYProcess(master: master, pid: pid)
    }

    public func resize(columns: Int, rows: Int, cellPixelSize: (width: Int, height: Int) = (0, 0)) {
        var size = Self.winsize(columns: columns, rows: rows, cellPixelSize: cellPixelSize)
        _ = ioctl(master.rawValue, TIOCSWINSZ, &size)
    }

    /// Sends SIGHUP to the child's process group, as closing a terminal does.
    public func hangUp() {
        kill(-pid, SIGHUP)
    }

    private static func winsize(columns: Int, rows: Int, cellPixelSize: (width: Int, height: Int)) -> Darwin.winsize {
        Darwin.winsize(
            ws_row: UInt16(clamping: rows),
            ws_col: UInt16(clamping: columns),
            ws_xpixel: UInt16(clamping: columns * cellPixelSize.width),
            ws_ypixel: UInt16(clamping: rows * cellPixelSize.height),
        )
    }
}

private func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
    let pointers = strings.map { strdup($0) } + [nil]
    defer { for p in pointers {
        free(p)
    } }
    return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}
