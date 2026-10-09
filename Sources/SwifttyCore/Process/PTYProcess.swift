#if os(macOS)
    import Darwin

    /// A child process attached to a pseudo-terminal.
    ///
    /// Spawned with `posix_spawn`: `POSIX_SPAWN_SETSID` makes the child a
    /// session leader and opening the slave by path then makes it the
    /// controlling terminal, so no fork-time code is needed.
    public final class PTYProcess: @unchecked Sendable {
        public let master: FileDescriptor
        public let pid: pid_t
        /// Darwin discards unread master output when the last slave closes.
        /// A session keeps this descriptor until it drains and tears down the PTY.
        private let drainSlave: FileDescriptor?

        private init(master: consuming FileDescriptor, pid: pid_t, drainSlave: consuming FileDescriptor? = nil) {
            self.master = master
            self.pid = pid
            self.drainSlave = drainSlave
        }

        public static func spawn(
            _ configuration: SessionConfiguration,
            columns: Int,
            rows: Int,
            cellPixelSize: (width: Int, height: Int) = (0, 0),
        ) throws(POSIXError) -> PTYProcess {
            try spawn(configuration, columns: columns, rows: rows, cellPixelSize: cellPixelSize, retainingSlaveForDrain: false)
        }

        /// For a session that observes process exit and drains before teardown.
        static func spawn(
            _ configuration: SessionConfiguration,
            columns: Int,
            rows: Int,
            cellPixelSize: (width: Int, height: Int),
            retainingSlaveForDrain: Bool,
        ) throws(POSIXError) -> PTYProcess {
            let executable = try configuration.executablePath()
            var masterFD: Int32 = -1, slaveFD: Int32 = -1
            var size = Self.winsize(columns: columns, rows: rows, cellPixelSize: cellPixelSize)
            var nameBuffer = [CChar](repeating: 0, count: 128)
            guard openpty(&masterFD, &slaveFD, &nameBuffer, nil, &size) == 0 else { throw POSIXError("openpty") }
            let master = FileDescriptor(masterFD)
            let slave = FileDescriptor(slaveFD)
            // The child reopens the slave by path; neither parent descriptor
            // should keep a terminal alive through an unrelated exec.
            master.setCloseOnExec()
            slave.setCloseOnExec()
            try master.setNonBlocking()

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
            try check(posix_spawn_file_actions_init(&actions), "posix_spawn_file_actions_init")
            defer { posix_spawn_file_actions_destroy(&actions) }
            try check(posix_spawn_file_actions_addopen(&actions, 0, ttyName, O_RDWR, 0), "posix_spawn_file_actions_addopen")
            try check(posix_spawn_file_actions_adddup2(&actions, 0, 1), "posix_spawn_file_actions_adddup2")
            try check(posix_spawn_file_actions_adddup2(&actions, 0, 2), "posix_spawn_file_actions_adddup2")
            if let cwd = configuration.workingDirectory {
                try check(posix_spawn_file_actions_addchdir(&actions, cwd), "posix_spawn_file_actions_addchdir")
            }

            var attributes: posix_spawnattr_t?
            try check(posix_spawnattr_init(&attributes), "posix_spawnattr_init")
            defer { posix_spawnattr_destroy(&attributes) }
            let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
            try check(posix_spawnattr_setflags(&attributes, Int16(flags)), "posix_spawnattr_setflags")
            var defaultSignals = sigset_t()
            sigfillset(&defaultSignals)
            try check(posix_spawnattr_setsigdefault(&attributes, &defaultSignals), "posix_spawnattr_setsigdefault")
            var noSignals = sigset_t()
            sigemptyset(&noSignals)
            try check(posix_spawnattr_setsigmask(&attributes, &noSignals), "posix_spawnattr_setsigmask")

            var pid: pid_t = 0
            let status = withCStrings(argv) { cArgv in
                withCStrings(env) { cEnv in
                    posix_spawn(&pid, executable, &actions, &attributes, cArgv, cEnv)
                }
            }
            guard status == 0 else { throw POSIXError("posix_spawn \(argv[0])", code: status) }
            if retainingSlaveForDrain {
                return PTYProcess(master: master, pid: pid, drainSlave: slave)
            }
            _ = consume slave // the child has its own copy
            return PTYProcess(master: master, pid: pid)
        }

        private static func check(_ status: Int32, _ operation: String) throws(POSIXError) {
            guard status == 0 else { throw POSIXError(operation, code: status) }
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
            // Clamp each nonnegative factor before multiplying so even extreme
            // public API arguments fit in Int and saturate the kernel's fields.
            let columns = UInt16(clamping: columns)
            let rows = UInt16(clamping: rows)
            return Darwin.winsize(
                ws_row: UInt16(clamping: rows),
                ws_col: UInt16(clamping: columns),
                ws_xpixel: UInt16(clamping: Int(columns) * Int(UInt16(clamping: cellPixelSize.width))),
                ws_ypixel: UInt16(clamping: Int(rows) * Int(UInt16(clamping: cellPixelSize.height))),
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
#endif
