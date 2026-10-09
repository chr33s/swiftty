import TestSupport
#if os(macOS)
    import Darwin
    import Foundation
    @testable import SwifttyCore
    import Synchronization
    import Testing

    struct PTYProcessTests {
        @Test func `direct PTY callers still observe slave closure`() async throws {
            let process = try PTYProcess.spawn(SessionConfiguration(command: ["/usr/bin/true"]), columns: 10, rows: 2)
            var result: pid_t
            repeat {
                result = waitpid(process.pid, nil, 0)
            } while result < 0 && errno == EINTR
            #expect(result == process.pid)
            var byte: UInt8 = 0
            var count = -1
            var readError: Int32 = 0
            let deadline = ContinuousClock.now + .seconds(1)
            repeat {
                count = withUnsafeMutableBytes(of: &byte) { process.master.read(into: $0) }
                readError = errno
                guard count < 0, readError == EAGAIN || readError == EINTR else { break }
                try await Task.sleep(for: .milliseconds(10))
            } while ContinuousClock.now < deadline
            #expect(count == 0 || (count < 0 && readError == EIO), "read returned \(count), errno \(readError)")
        }

        @Test func `retained PTY slaves do not leak into unrelated exec children`() async throws {
            var process: PTYProcess? = try PTYProcess.spawn(
                SessionConfiguration(command: ["/usr/bin/true"]), columns: 10, rows: 2,
                cellPixelSize: (0, 0), retainingSlaveForDrain: true,
            )
            let child = try #require(process?.pid)
            var result: pid_t
            repeat {
                result = waitpid(child, nil, 0)
            } while result < 0 && errno == EINTR
            try #require(result == child)
            let masterFD = try #require(process).master.rawValue
            let duplicate = dup(masterFD)
            try #require(duplicate >= 0)
            let master = FileDescriptor(duplicate)
            master.setCloseOnExec()

            // An unrelated exec must not retain the session's drain slave.
            var arguments = [strdup("/bin/sleep"), strdup("30"), nil]
            defer {
                for argument in arguments {
                    free(argument)
                }
            }
            var environment: [UnsafeMutablePointer<CChar>?] = [nil]
            var unrelated: pid_t = 0
            let status = arguments.withUnsafeMutableBufferPointer { argv in
                environment.withUnsafeMutableBufferPointer { env in
                    posix_spawn(&unrelated, "/bin/sleep", nil, nil, argv.baseAddress!, env.baseAddress!)
                }
            }
            try #require(status == 0)
            defer {
                kill(unrelated, SIGKILL)
                while waitpid(unrelated, nil, 0) < 0, errno == EINTR {}
            }
            weak let retained = process
            process = nil
            try #require(retained == nil)
            var byte: UInt8 = 0
            var count = -1
            var readError: Int32 = 0
            let deadline = ContinuousClock.now + .seconds(1)
            repeat {
                count = withUnsafeMutableBytes(of: &byte) { master.read(into: $0) }
                readError = errno
                guard count < 0, readError == EAGAIN || readError == EINTR else { break }
                try await Task.sleep(for: .milliseconds(10))
            } while ContinuousClock.now < deadline
            #expect(kill(unrelated, 0) == 0)
            #expect(count == 0 || (count < 0 && readError == EIO), "read returned \(count), errno \(readError)")
        }

        @Test(arguments: [false, true])
        func `delayed readers preserve final child output`(_ query: Bool) async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let pidFile = directory.appendingPathComponent("pid")
            let gate = directory.appendingPathComponent("exit-ready")
            let written = directory.appendingPathComponent("output-written")
            let session = TerminalSession(columns: 40, rows: 2)
            let output = Mutex<[UInt8]>([])
            let exitCode = Mutex<Int32?>(nil)
            session.onProgramOutput = { bytes in output.withLock { $0.append(contentsOf: bytes) } }
            session.onEvent = { event in
                if case let .exited(code) = event {
                    exitCode.withLock { $0 = code }
                }
            }
            let queryPrefix = query ? "\\033[5n" : ""
            // Query clients disable echo so terminal replies are not displayed as input.
            let script = """
            \(query ? "stty -echo" : ":")
            printf '%s' "$$" > "$1.tmp"
            /bin/mv "$1.tmp" "$1"
            while [ ! -f "$2" ]; do sleep 0.01; done
            printf '\(queryPrefix)final-output\\n'
            touch "$3"
            """
            try session.start(SessionConfiguration(command: ["/bin/sh", "-c", script, "sh", pidFile.path, gate.path, written.path]))
            defer { session.stop() }
            let deadline = ContinuousClock.now + .seconds(10)
            var pid: pid_t?
            while pid == nil, ContinuousClock.now < deadline {
                if let text = try? String(contentsOf: pidFile, encoding: .utf8) {
                    pid = pid_t(text)
                }
                if pid == nil {
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            let child = try #require(pid)
            // Delay reading through the final write and the child's exit attempt.
            // With a retained slave, Darwin can wait for output to drain before
            // making the child waitable; without it, exit discards the output.
            try session.queue.sync {
                try Data().write(to: gate)
                let writeDeadline = ContinuousClock.now + .seconds(3)
                while !FileManager.default.fileExists(atPath: written.path), ContinuousClock.now < writeDeadline {
                    usleep(1000)
                }
                try #require(FileManager.default.fileExists(atPath: written.path))
                let exitDeadline = ContinuousClock.now + .seconds(2)
                while ContinuousClock.now < exitDeadline {
                    var info = siginfo_t()
                    try #require(waitid(P_PID, id_t(child), &info, WEXITED | WNOWAIT | WNOHANG) == 0)
                    if info.si_pid == child {
                        break
                    }
                    usleep(1000)
                }
            }
            let exitDeadline = ContinuousClock.now + .seconds(3)
            while exitCode.withLock({ $0 == nil }), ContinuousClock.now < exitDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(exitCode.withLock { $0 } == 0)
            let expected = (query ? "\u{1B}[5n" : "") + "final-output\r\n"
            #expect(TestFixture(output.withLock { String(decoding: $0, as: UTF8.self) }) == TestFixture(expected))
            #expect(TestFixture(session.withState { $0.screenLines[0] }) == TestFixture("final-output"))
        }

        @Test(arguments: [(0, 0), (-3, 0), (0, -4), (7, 5)])
        func `session resize reports the actual grid dimensions to the child`(_ size: (Int, Int)) async throws {
            let session = TerminalSession(columns: 10, rows: 2)
            let output = Mutex<[UInt8]>([])
            let exited = Mutex<Bool>(false)
            session.onProgramOutput = { bytes in output.withLock { $0.append(contentsOf: bytes) } }
            session.onEvent = { event in
                if case .exited = event {
                    exited.withLock { $0 = true }
                }
            }
            try session.start(SessionConfiguration(command: [
                "/bin/sh", "-c", "stty -echo; printf 'ready\\n'; IFS= read -r line; stty size",
            ]))
            defer { session.stop() }
            let deadline = ContinuousClock.now + .seconds(10)
            while !output.withLock({ String(decoding: $0, as: UTF8.self).contains("ready\r\n") }), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(output.withLock { String(decoding: $0, as: UTF8.self).contains("ready\r\n") })
            session.resize(columns: size.0, rows: size.1)
            session.send(.text("\r"))
            let exitDeadline = ContinuousClock.now + .seconds(10)
            while !exited.withLock({ $0 }), ContinuousClock.now < exitDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(exited.withLock { $0 })
            let dimensions = session.withState { ($0.columns, $0.rows) }
            #expect(dimensions == (max(1, size.0), max(1, size.1)))
            #expect(TestFixture(output.withLock { String(decoding: $0, as: UTF8.self) }) ==
                TestFixture("ready\r\n\(dimensions.1) \(dimensions.0)\r\n"))
        }

        @Test func `running state can be read from process callbacks`() async throws {
            let session = TerminalSession(columns: 10, rows: 2)
            let outputStates = Mutex<[Bool]>([])
            let exitStates = Mutex<[Bool]>([])
            session.onProgramOutput = { [weak session] _ in
                outputStates.withLock { $0.append(session?.isRunning ?? false) }
            }
            session.onEvent = { [weak session] event in
                if case .exited = event {
                    exitStates.withLock { $0.append(session?.isRunning ?? true) }
                }
            }
            try session.start(SessionConfiguration(command: ["/bin/sh", "-c", "printf ready"]))
            defer { session.stop() }
            let deadline = ContinuousClock.now + .seconds(3)
            while exitStates.withLock({ $0.isEmpty }), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let outputs = outputStates.withLock { $0 }
            #expect(!outputs.isEmpty && outputs.allSatisfy(\.self))
            #expect(exitStates.withLock { $0 } == [false])
        }

        @Test(arguments: [("exit 7", 7), ("kill -TERM $$", 143)], [false, true])
        func `child exit drains final output and reports its status`(_ termination: (String, Int), _ burst: Bool) async throws {
            let session = TerminalSession(columns: 40, rows: 2)
            let output = Mutex<[UInt8]>([])
            let exitCodes = Mutex<[Int]>([])
            session.onProgramOutput = { bytes in output.withLock { $0.append(contentsOf: bytes) } }
            session.onEvent = { event in
                if case let .exited(code) = event {
                    exitCodes.withLock { $0.append(Int(code)) }
                }
            }
            let paddingBytes = burst ? TerminalSession.readBudget + TerminalSession.readBufferSize : 0
            let prefix = burst ? "/usr/bin/head -c \(paddingBytes) /dev/zero; " : ""
            try session.start(SessionConfiguration(command: ["/bin/sh", "-c", prefix + "printf 'final-output\\n'; \(termination.0)"]))
            defer { session.stop() }
            let deadline = ContinuousClock.now + .seconds(3)
            while exitCodes.withLock({ $0.isEmpty }), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(exitCodes.withLock { $0 } == [termination.1])
            let received = output.withLock { $0 }
            let tail = Array("final-output\r\n".utf8)
            #expect(received.count == paddingBytes + tail.count)
            #expect(received.prefix(paddingBytes).allSatisfy { $0 == 0 })
            #expect(Array(received.suffix(tail.count)) == tail)
            #expect(!session.isRunning)
            #expect(session.withState { $0.screenLines[0] } == "final-output")
        }

        @Test(arguments: ["program", "argument", "directory", "name", "equals", "empty", "value", "term"])
        func `invalid process strings fail before spawning`(_ field: String) throws {
            var configuration = SessionConfiguration(command: ["/bin/sleep", "0"])
            switch field {
            case "program": configuration.command = ["/bin/sleep\0ignored", "0"]
            case "argument": configuration.command = ["/bin/sleep", "0\0ignored"]
            case "directory": configuration.workingDirectory = "/tmp\0ignored"
            case "name": configuration.environment = ["BAD\0NAME": "value"]
            case "equals": configuration.environment = ["BAD=NAME": "value"]
            case "empty": configuration.environment = ["": "value"]
            case "value": configuration.environment = ["NAME": "value\0ignored"]
            default: configuration.term = "xterm\0ignored"
            }
            do {
                let process = try PTYProcess.spawn(configuration, columns: 10, rows: 2)
                kill(process.pid, SIGKILL)
                while waitpid(process.pid, nil, 0) < 0, errno == EINTR {}
                Issue.record("invalid process configuration was spawned")
            } catch {
                #expect(error.code == EINVAL)
            }
            let session = TerminalSession(columns: 10, rows: 2)
            do {
                try session.start(configuration)
                session.stop()
                Issue.record("invalid session configuration was spawned")
            } catch let error as SwifttyCore.POSIXError {
                #expect(error.code == EINVAL)
            }
            #expect(!session.isRunning)
        }

        @Test func `a failed spawn leaves the session ready to start`() throws {
            let session = TerminalSession(columns: 80, rows: 24)
            do {
                try session.start(SessionConfiguration(command: ["/bin/sleep", "30"], workingDirectory: "/dev/null"))
                Issue.record("spawn succeeded with a working directory that is not a directory")
                session.stop()
            } catch let error as SwifttyCore.POSIXError {
                #expect(error.code == ENOTDIR)
            }
            #expect(!session.isRunning)
            try session.start(SessionConfiguration(command: ["/bin/sleep", "30"]))
            defer { session.stop() }
            #expect(session.isRunning)
        }

        @Test func `PTY dimensions saturate without overflow`() throws {
            let process = try PTYProcess.spawn(
                SessionConfiguration(command: ["/bin/sleep", "30"]),
                columns: Int.max, rows: Int.max, cellPixelSize: (Int.max, Int.max),
            )
            defer {
                kill(process.pid, SIGKILL)
                while waitpid(process.pid, nil, 0) < 0, errno == EINTR {}
            }
            func dimensions() -> [UInt16] {
                var size = winsize()
                #expect(ioctl(process.master.rawValue, TIOCGWINSZ, &size) == 0)
                return [size.ws_col, size.ws_row, size.ws_xpixel, size.ws_ypixel]
            }
            #expect(dimensions() == Array(repeating: UInt16.max, count: 4))
            process.resize(columns: 80, rows: 24, cellPixelSize: (8, 16))
            #expect(dimensions() == [80, 24, 640, 384])
            process.resize(columns: Int.min, rows: Int.min, cellPixelSize: (Int.min, Int.min))
            #expect(dimensions() == [0, 0, 0, 0])
            process.resize(columns: Int.max, rows: Int.max, cellPixelSize: (0, 0))
            #expect(dimensions() == [UInt16.max, UInt16.max, 0, 0])
        }
    }
#endif
