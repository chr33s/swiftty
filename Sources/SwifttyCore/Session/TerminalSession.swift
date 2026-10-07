import Darwin
import Dispatch

/// One terminal: the terminal model plus the transport feeding it.
///
/// The transport is either a child process on a PTY (`start`, macOS only) or
/// external: the host delivers program output with `receive` and takes the
/// terminal's replies and encoded input from `onWrite` (SSH channels, an
/// in-process interpreter, tmux panes), or replies separately from
/// `onTerminalReply`.
///
/// All terminal state is owned by a single serial queue. PTY reads are
/// delivered on that queue and parsed in place from a preallocated buffer;
/// the UI and renderer interact only through `send`, `resize` and
/// `snapshot`. Do not call these from `queue` itself.
public final class TerminalSession: @unchecked Sendable {
    public let queue = DispatchQueue(label: "swiftty.terminal", qos: .userInteractive)

    /// Called on `queue` when new content is ready; coalesced until the next
    /// `snapshot()`. Typically schedules a redraw.
    public var onUpdate: (@Sendable () -> Void)?
    /// Called on `queue` for titles, bells, clipboard writes and exit.
    public var onEvent: (@Sendable (TerminalEvent) -> Void)?
    /// Called on `queue` with bytes for the application when no PTY is
    /// attached: replies to queries and encoded keyboard/mouse input.
    public var onWrite: (@Sendable ([UInt8]) -> Void)?
    /// Called on `queue`, when no PTY is attached, with replies the
    /// terminal generated itself (query answers such as DA, DSR, OSC 7501),
    /// so the host can route them apart from user input (e.g. to the tmux
    /// pane that asked). When nil, replies go to `onWrite`.
    public var onTerminalReply: (@Sendable ([UInt8]) -> Void)?
    /// Called on `queue` after OSC 7501 program status changed (reports,
    /// prompt start, reset, exit), once per batch, before `onUpdate`. Fires
    /// whether or not any cell changed.
    public var onProgramStatusChange: (@Sendable (ProgramStatusSnapshot) -> Void)?
    /// Called on `queue` after each batch of changes (parsed output, resize,
    /// `mutate`), before `onUpdate`, with read access to the state. Use it to
    /// mirror values the host reads often (modes, scroll position).
    public var onStateChange: (@Sendable (borrowing TerminalState) -> Void)?
    /// Called on `queue` with each chunk of program output before it is
    /// parsed (recording sessions for replay). Costs nothing when nil.
    public var onProgramOutput: (@Sendable ([UInt8]) -> Void)?
    /// Called on `queue` with tmux control-mode lines (between
    /// `.controlModeStarted` and `.controlModeEnded`), in arrival order.
    public var onControlModeData: (@Sendable ([UInt8]) -> Void)?

    // Owned by `queue`.
    private var state: TerminalState
    private var parser = Parser()
    private var builder = SnapshotBuilder()
    #if os(macOS)
        private var process: PTYProcess?
        private var readSource: DispatchSourceRead?
        private var writeSource: DispatchSourceWrite?
        private var exitSource: DispatchSourceProcess?
        private var pendingWrite: [UInt8] = []
        private var writeSourceActive = false
    #endif
    private var encodeBuffer: [UInt8] = []
    private let readBuffer: UnsafeMutableRawBufferPointer
    private var updateScheduled = false
    private var drawnCursor: CursorState?
    private var synchronizedSince: UInt64 = 0
    private var synchronizedTimeoutScheduled = false
    private var cellPixelSize = (width: 0, height: 0)

    public static let readBufferSize = 64 * 1024
    /// Max bytes parsed per read event so snapshots can interleave.
    public static let readBudget = 1 << 20
    /// Longest a synchronized update (mode 2026) holds back redraws.
    static let synchronizedTimeout: UInt64 = 1_000_000_000

    public init(columns: Int = 80, rows: Int = 24, configuration: SessionConfiguration = SessionConfiguration()) {
        state = TerminalState(
            columns: columns, rows: rows,
            scrollbackLimitBytes: configuration.scrollbackLimitBytes,
            scrollbackLimitRows: configuration.scrollbackLimitRows,
            palette: configuration.palette,
        )
        state.programStatusEnabled = configuration.programStatusEnabled
        readBuffer = .allocate(byteCount: Self.readBufferSize, alignment: 16)
        encodeBuffer.reserveCapacity(256)
    }

    deinit {
        // Source handlers capture `self` weakly and hold it while they run,
        // so none can be running once this executes.
        #if os(macOS)
            if let process {
                process.hangUp()
                Self.reap(process.pid)
            }
            teardown()
        #endif
        readBuffer.deallocate()
    }

    // MARK: Lifecycle

    #if os(macOS)
        public func start(_ configuration: SessionConfiguration) throws {
            try queue.sync {
                precondition(process == nil, "session already started")
                let process = try PTYProcess.spawn(
                    configuration, columns: state.columns, rows: state.rows, cellPixelSize: cellPixelSize,
                )
                self.process = process
                let fd = process.master.rawValue

                let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                read.setEventHandler { [weak self] in self?.readAvailable() }
                read.resume()
                readSource = read

                let write = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
                write.setEventHandler { [weak self] in self?.flushPendingWrite() }
                writeSource = write // resumed only while output is pending

                let exit = DispatchSource.makeProcessSource(identifier: process.pid, eventMask: .exit, queue: queue)
                exit.setEventHandler { [weak self] in self?.childExited() }
                exit.resume()
                exitSource = exit
            }
        }

        public func stop() {
            queue.sync {
                guard let process else { return }
                process.hangUp()
                Self.reap(process.pid)
                teardown()
            }
        }

        /// Collects the exit status of a child whose exit source is being
        /// torn down, so it does not linger as a zombie.
        private static func reap(_ pid: pid_t) {
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
            // The handler retains the source until it cancels itself.
            source.setEventHandler { [source] in
                var status: Int32 = 0
                waitpid(pid, &status, WNOHANG)
                source.cancel()
            }
            source.resume()
            // Already exited (the source may never fire for a zombie).
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == pid {
                source.cancel()
            }
        }

        public var isRunning: Bool {
            queue.sync { process != nil }
        }
    #endif

    /// Parses program output from an external transport. Ordered with
    /// `send`, `resize` and other calls; returns immediately.
    public func receive(_ bytes: [UInt8]) {
        queue.async { [self] in
            bytes.withUnsafeBufferPointer { parse($0) }
            publish()
        }
    }

    // MARK: Input / resize / output

    public func resize(columns: Int, rows: Int) {
        queue.async { [self] in
            state.resize(columns: columns, rows: rows)
            #if os(macOS)
                process?.resize(columns: columns, rows: rows, cellPixelSize: cellPixelSize)
            #endif
            publish()
        }
    }

    /// Cell size in pixels, reported to the PTY and via XTWINOPS.
    public func setCellPixelSize(width: Int, height: Int) {
        queue.async { [self] in
            cellPixelSize = (width, height)
            state.cellPixelSize = (width, height)
            #if os(macOS)
                process?.resize(columns: state.columns, rows: state.rows, cellPixelSize: cellPixelSize)
            #endif
        }
    }

    public func send(_ input: TerminalInput) {
        queue.async { [self] in
            encodeBuffer.removeAll(keepingCapacity: true)
            guard InputEncoder.encode(input, modes: state.modes, keyboardFlags: state.keyboardFlags, into: &encodeBuffer) else { return }
            switch input {
            case let .key(event) where event.action == .release:
                break
            case .text, .key, .paste:
                if state.viewportOffset != 0 {
                    state.scrollViewportToBottom()
                    publish()
                }
            default: break
            }
            writeToChild(encodeBuffer)
        }
    }

    public func scrollViewport(by lines: Int) {
        queue.async { [self] in
            state.scrollViewport(by: lines)
            publish()
        }
    }

    /// Current OSC 7501 records; with `onProgramStatusChange`, all a
    /// newly attached consumer needs.
    public var programStatusSnapshot: ProgramStatusSnapshot {
        queue.sync { state.programStatus.snapshot }
    }

    /// Turns OSC 7501 consumption on or off, ordered with `receive`.
    /// Turning it off clears the records.
    public func setProgramStatusEnabled(_ enabled: Bool) {
        queue.async { [self] in
            state.programStatusEnabled = enabled
            publish()
        }
    }

    /// For external transports: the program exited or the connection
    /// closed. Drops transient program status (see
    /// `TerminalState.programExited()`), ordered with `receive`. PTY
    /// sessions do this themselves when the child exits.
    public func programExited() {
        queue.async { [self] in
            state.programExited()
            publish()
        }
    }

    /// Current modes (for frontends deciding how to route mouse/scroll).
    public var modes: Modes {
        queue.sync { state.modes }
    }

    /// Negotiated kitty keyboard flags for hardware-key routing.
    public var keyboardFlags: UInt8 {
        queue.sync { state.keyboardFlags }
    }

    private var currentCursor: CursorState {
        CursorState(
            x: state.cursor.x,
            y: state.cursor.y,
            isVisible: state.modes.contains(.cursorVisible) && state.viewportOffset == 0,
            style: state.cursorStyle,
            isBlinking: state.modes.contains(.cursorBlink),
        )
    }

    /// - Parameter overscan: rows to include below the viewport while
    ///   scrolled back (see `RenderSnapshot.overscanRows`).
    public func snapshot(overscan: Int = 0) -> RenderSnapshot {
        queue.sync {
            updateScheduled = false
            if state.modes.contains(.synchronizedOutput),
               DispatchTime.now().uptimeNanoseconds - synchronizedSince < Self.synchronizedTimeout,
               let held = builder.repeatLast() {
                return held
            }
            drawnCursor = currentCursor
            return builder.build(from: &state, overscan: overscan)
        }
    }

    /// Feeds bytes as if the child had written them (tests, replays, benchmarks).
    public func feed(_ bytes: borrowing Span<UInt8>) {
        bytes.withUnsafeBufferPointer { buffer in
            queue.sync {
                parse(buffer)
                publish()
            }
        }
    }

    public func feed(_ bytes: [UInt8]) {
        feed(bytes.span)
    }

    /// Runs `body` on the queue with mutable state, then publishes changes.
    public func mutate<R>(_ body: (inout TerminalState) throws -> R) rethrows -> R {
        try queue.sync {
            let result = try body(&state)
            publish()
            return result
        }
    }

    /// Asynchronous `mutate`, ordered with `receive`, `send` and `resize`.
    public func mutateAsync(_ body: @escaping @Sendable (inout TerminalState) -> Void) {
        queue.async { [self] in
            body(&state)
            publish()
        }
    }

    /// Read-only access to the terminal state on its queue.
    public func withState<R>(_ body: (borrowing TerminalState) throws -> R) rethrows -> R {
        try queue.sync { try body(state) }
    }

    // MARK: Queue-owned internals

    private func parse(_ buffer: UnsafeBufferPointer<UInt8>) {
        let span = Span(_unsafeElements: buffer)
        let wasSynchronized = state.modes.contains(.synchronizedOutput)
        parser.consume(span, into: &state)
        if !wasSynchronized, state.modes.contains(.synchronizedOutput) {
            synchronizedSince = DispatchTime.now().uptimeNanoseconds
        }
    }

    #if os(macOS)
        private func readAvailable() {
            guard let process else { return }
            var budget = Self.readBudget
            while budget > 0 {
                let n = process.master.read(into: readBuffer)
                if n > 0 {
                    let chunk = UnsafeBufferPointer(start: readBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self), count: n)
                    onProgramOutput?(Array(chunk))
                    parse(chunk)
                    budget -= n
                    continue
                }
                if n < 0, errno == EINTR {
                    continue
                }
                if n < 0, errno == EAGAIN {
                    break
                }
                // EOF or EIO: the slave side is gone.
                readSource?.cancel()
                readSource = nil
                break
            }
            publish()
        }
    #endif

    /// Flushes replies and events, then notifies the frontend once.
    private func publish() {
        onStateChange?(state)
        if !state.output.isEmpty {
            writeReply(state.output)
            state.output.removeAll(keepingCapacity: true)
        }
        if let status = state.takeProgramStatusChange() {
            onProgramStatusChange?(status)
        }
        let events = state.takeEvents()
        // Start event, then data, then end event: a stream that opens and
        // closes within one batch still arrives in order.
        let ended = events.last == .controlModeEnded
        if let onEvent {
            for event in events where !(ended && event == .controlModeEnded) {
                onEvent(event)
            }
        }
        if !state.controlModeData.isEmpty {
            let data = state.controlModeData
            state.controlModeData.removeAll(keepingCapacity: true)
            onControlModeData?(data)
        }
        if ended {
            onEvent?(.controlModeEnded)
        }
        guard !state.damage.isEmpty || drawnCursor != currentCursor, !updateScheduled else { return }
        if state.modes.contains(.synchronizedOutput),
           DispatchTime.now().uptimeNanoseconds - synchronizedSince < Self.synchronizedTimeout {
            // Publish when the timeout lapses even if no more output arrives.
            if !synchronizedTimeoutScheduled {
                synchronizedTimeoutScheduled = true
                queue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: synchronizedSince + Self.synchronizedTimeout)) { [weak self] in
                    self?.synchronizedTimeoutScheduled = false
                    self?.publish()
                }
            }
            return
        }
        updateScheduled = true
        onUpdate?()
    }

    /// Terminal-generated replies: to the PTY, else `onTerminalReply`,
    /// else `onWrite`.
    private func writeReply(_ bytes: [UInt8]) {
        #if os(macOS)
            if process != nil {
                writeToChild(bytes)
                return
            }
        #endif
        if let onTerminalReply {
            onTerminalReply(bytes)
        } else {
            onWrite?(bytes)
        }
    }

    private func writeToChild(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        #if os(macOS)
            guard let process else { onWrite?(bytes); return }
            if !pendingWrite.isEmpty {
                pendingWrite.append(contentsOf: bytes)
                return
            }
            let written = bytes.withUnsafeBytes { process.master.writeAvailable($0) } ?? bytes.count
            if written < bytes.count {
                pendingWrite.append(contentsOf: bytes[written...])
                setWriteSourceActive(true)
            }
        #else
            onWrite?(bytes)
        #endif
    }

    #if os(macOS)
        private func flushPendingWrite() {
            guard let process, !pendingWrite.isEmpty else { return }
            let written = pendingWrite.withUnsafeBytes { process.master.writeAvailable($0) } ?? pendingWrite.count
            pendingWrite.removeFirst(written)
            if pendingWrite.isEmpty {
                setWriteSourceActive(false)
            }
        }

        private func setWriteSourceActive(_ active: Bool) {
            guard let writeSource, active != writeSourceActive else { return }
            writeSourceActive = active
            if active {
                writeSource.resume()
            } else {
                writeSource.suspend()
            }
        }

        private func childExited() {
            guard let process else { return }
            readAvailable() // drain anything written just before exit
            var status: Int32 = 0
            waitpid(process.pid, &status, WNOHANG)
            let code = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
            teardown()
            state.programExited()
            publish()
            onEvent?(.exited(code))
        }

        private func teardown() {
            readSource?.cancel()
            readSource = nil
            setWriteSourceActive(true) // a suspended source must not be released
            writeSource?.cancel()
            writeSource = nil
            writeSourceActive = false
            pendingWrite.removeAll()
            exitSource?.cancel()
            exitSource = nil
            process = nil
        }
    #endif
}
