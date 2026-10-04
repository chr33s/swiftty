import Darwin
import Dispatch

/// One terminal: a child process on a PTY plus the terminal model it drives.
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

    // Owned by `queue`.
    private var state: TerminalState
    private var parser = Parser()
    private var builder = SnapshotBuilder()
    private var process: PTYProcess?
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var exitSource: DispatchSourceProcess?
    private var pendingWrite: [UInt8] = []
    private var writeSourceActive = false
    private var encodeBuffer: [UInt8] = []
    private let readBuffer: UnsafeMutableRawBufferPointer
    private var updateScheduled = false
    private var synchronizedSince: UInt64 = 0
    private var cellPixelSize = (width: 0, height: 0)

    public static let readBufferSize = 64 * 1024
    /// Max bytes parsed per read event so snapshots can interleave.
    public static let readBudget = 1 << 20

    public init(columns: Int = 80, rows: Int = 24, configuration: SessionConfiguration = SessionConfiguration()) {
        state = TerminalState(
            columns: columns, rows: rows,
            scrollbackLimitBytes: configuration.scrollbackLimitBytes,
            palette: configuration.palette,
        )
        readBuffer = .allocate(byteCount: Self.readBufferSize, alignment: 16)
        encodeBuffer.reserveCapacity(256)
    }

    deinit {
        process?.hangUp()
        teardown()
        readBuffer.deallocate()
    }

    // MARK: Lifecycle

    public func start(_ configuration: SessionConfiguration) throws {
        try queue.sync {
            precondition(process == nil, "session already started")
            let process = try PTYProcess.spawn(
                configuration, columns: state.columns, rows: state.rows, cellPixelSize: cellPixelSize,
            )
            self.process = process
            let fd = process.master.rawValue

            let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            read.setEventHandler { [unowned self] in readAvailable() }
            read.resume()
            readSource = read

            let write = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            write.setEventHandler { [unowned self] in flushPendingWrite() }
            writeSource = write // resumed only while output is pending

            let exit = DispatchSource.makeProcessSource(identifier: process.pid, eventMask: .exit, queue: queue)
            exit.setEventHandler { [unowned self] in childExited() }
            exit.resume()
            exitSource = exit
        }
    }

    public func stop() {
        queue.sync {
            process?.hangUp()
            teardown()
        }
    }

    public var isRunning: Bool {
        queue.sync { process != nil }
    }

    // MARK: Input / resize / output

    public func resize(columns: Int, rows: Int) {
        queue.async { [self] in
            state.resize(columns: columns, rows: rows)
            process?.resize(columns: columns, rows: rows, cellPixelSize: cellPixelSize)
            publish()
        }
    }

    /// Cell size in pixels, reported to the PTY and via XTWINOPS.
    public func setCellPixelSize(width: Int, height: Int) {
        queue.async { [self] in
            cellPixelSize = (width, height)
            state.cellPixelSize = (width, height)
            process?.resize(columns: state.columns, rows: state.rows, cellPixelSize: cellPixelSize)
        }
    }

    public func send(_ input: TerminalInput) {
        queue.async { [self] in
            encodeBuffer.removeAll(keepingCapacity: true)
            guard InputEncoder.encode(input, modes: state.modes, into: &encodeBuffer) else { return }
            switch input {
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

    /// Current modes (for frontends deciding how to route mouse/scroll).
    public var modes: Modes {
        queue.sync { state.modes }
    }

    public func snapshot() -> RenderSnapshot {
        queue.sync {
            updateScheduled = false
            if state.modes.contains(.synchronizedOutput),
               DispatchTime.now().uptimeNanoseconds - synchronizedSince < 1_000_000_000,
               let held = builder.repeatLast() {
                return held
            }
            return builder.build(from: &state)
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

    private func readAvailable() {
        guard let process else { return }
        var budget = Self.readBudget
        while budget > 0 {
            let n = process.master.read(into: readBuffer)
            if n > 0 {
                parse(UnsafeBufferPointer(start: readBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self), count: n))
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

    /// Flushes replies and events, then notifies the frontend once.
    private func publish() {
        if !state.output.isEmpty {
            writeToChild(state.output)
            state.output.removeAll(keepingCapacity: true)
        }
        let events = state.takeEvents()
        if let onEvent {
            for event in events {
                onEvent(event)
            }
        }
        guard !state.damage.isEmpty, !updateScheduled else { return }
        if state.modes.contains(.synchronizedOutput),
           DispatchTime.now().uptimeNanoseconds - synchronizedSince < 1_000_000_000 {
            return
        }
        updateScheduled = true
        onUpdate?()
    }

    private func writeToChild(_ bytes: [UInt8]) {
        guard let process, !bytes.isEmpty else { return }
        if !pendingWrite.isEmpty {
            pendingWrite.append(contentsOf: bytes)
            return
        }
        let written = bytes.withUnsafeBytes { process.master.writeAvailable($0) } ?? bytes.count
        if written < bytes.count {
            pendingWrite.append(contentsOf: bytes[written...])
            setWriteSourceActive(true)
        }
    }

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
}
