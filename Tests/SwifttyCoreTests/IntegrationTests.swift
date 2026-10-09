import Foundation
@testable import SwifttyCore
import Synchronization
import Testing
import TestSupport

/// Drives real programs through a PTY and checks what they draw.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct IntegrationTests {
    @Test(arguments: ["home", "inherit", "/tmp"])
    func `configured working directory modes reach the child`(_ directory: String) throws {
        let config = Configuration.parse("command=direct:/bin/pwd\nworking-directory=\(directory)").sessionConfiguration()
        let expected = URL(fileURLWithPath: config.workingDirectory ?? FileManager.default.currentDirectoryPath).resolvingSymlinksInPath()
            .path
        let harness = try Harness(#require(config.command), columns: 200, rows: 2, workingDirectory: config.workingDirectory)
        defer { harness.session.stop() }
        #expect(harness.waitForExit() == 0)
        #expect(harness.screen.contains(expected))
    }

    @Test(arguments: ["", "shell:", "direct:"])
    func `configured commands expand only in shell mode`(_ prefix: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["a.review", "b file.review"] {
            try Data().write(to: directory.appendingPathComponent(name))
        }
        let direct = prefix == "direct:"
        let variable = direct ? "$SWIFTTY_REVIEW_VALUE" : "\"$SWIFTTY_REVIEW_VALUE\""
        let format = direct ? "<%s>" : "'<%s>'"
        let config = Configuration.parse("command=\(prefix)/usr/bin/printf \(format) \(variable) *.review").sessionConfiguration()
        let args = try #require(config.command)
        let harness = try Harness(
            args,
            columns: 80,
            rows: 2,
            env: ["SWIFTTY_REVIEW_VALUE": "expanded value"],
            workingDirectory: directory.path,
        )
        defer { harness.session.stop() }
        #expect(harness.waitForExit() == 0)
        let expected = direct ? "<$SWIFTTY_REVIEW_VALUE><*.review>" : "<expanded value><a.review><b file.review>"
        #expect(harness.screen.contains(expected))
    }

    final class Harness: Sendable {
        let session: TerminalSession
        let exitCode = Mutex<Int32?>(nil)

        init(_ command: [String], columns: Int = 80, rows: Int = 24, env: [String: String] = [:], workingDirectory: String? = nil) throws {
            session = TerminalSession(columns: columns, rows: rows)
            session.onEvent = { [weak self] event in
                if case let .exited(code) = event {
                    self?.exitCode.withLock { $0 = code }
                }
            }
            var config = SessionConfiguration(command: command, environment: env, workingDirectory: workingDirectory)
            config.removedEnvironment = ["TMUX", "TMUX_PANE"]
            try session.start(config)
        }

        var screen: String {
            session.snapshot().text.joined(separator: "\n")
        }

        /// Polls the screen until `predicate` holds (or 10 s pass).
        @discardableResult
        func wait(_ what: String, timeout: Double = 10, _ predicate: (String) -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if predicate(screen) {
                    return true
                }
                usleep(20000)
            }
            Issue.record(Comment(rawValue: escapedTestText("timed out waiting for \(what); screen:\n\(screen)")))
            return false
        }

        func wait(for text: String) -> Bool {
            wait(text) { $0.contains(text) }
        }

        func waitForExit(timeout: Double = 10) -> Int32? {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let code = exitCode.withLock({ $0 }) {
                    return code
                }
                usleep(20000)
            }
            return nil
        }

        func type(_ s: String) {
            session.send(.text(s))
        }
    }

    static func which(_ tool: String) -> String? {
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "") + ":/usr/bin:/bin"
        return path.split(separator: ":").map { "\($0)/\(tool)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @Test func `pasted controls cannot edit or signal a canonical PTY reader`() throws {
        let script = "stty -echo; printf 'paste-ready\\n'; IFS= read -r value; printf 'received:<%s>\\n' \"$value\""
        let h = try Harness(["/bin/sh", "-c", script])
        defer { h.session.stop() }
        try #require(h.wait(for: "paste-ready"))
        h.session.send(.text("prefix"))
        h.session.send(.paste("\u{15}middle\u{03}tail\u{7F}end"))
        h.session.send(.key(KeyEvent(.enter)))
        #expect(h.wait(for: "received:<prefix middle tail end>"))
        #expect(h.waitForExit() == 0)
    }

    @Test func `PTY backpressure preserves queued input and reply order`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = directory.appendingPathComponent("read-ready")
        let secondGate = directory.appendingPathComponent("read-rest")
        let output = directory.appendingPathComponent("received")
        let text = String(repeating: "a漢🙂", count: 16384)
        let paste = String(repeating: "b界é", count: 16384)
        let lateText = String(repeating: "late🙂", count: 128)
        let expected = Data((text + paste + "\r\u{1B}[0n" + lateText + "\u{1B}[0n").utf8)
        let script = """
        stty raw -echo
        printf 'write-ready\\r\\n'
        while [ ! -f "$1" ]; do sleep 0.01; done
        dd bs=1 count=16384 of="$2" 2>/dev/null || exit 1
        printf '\\r\\nchunk-ready\\r\\n'
        while [ ! -f "$4" ]; do sleep 0.01; done
        dd bs=1 count="$(($3 - 16384))" >>"$2" 2>/dev/null || exit 1
        printf '\\r\\nwrite-complete\\r\\n'
        """
        let h = try Harness(["/bin/sh", "-c", script, "sh", gate.path, output.path, String(expected.count), secondGate.path])
        defer { h.session.stop() }
        try #require(h.wait(for: "write-ready"))
        // No reader is running yet, so this exceeds the PTY input buffer.
        h.session.send(.text(text))
        h.session.send(.paste(paste))
        h.session.send(.key(KeyEvent(.enter)))
        h.session.feed(Array("\u{1B}[5n".utf8)) // Queue a reply after the user input.
        #expect(!FileManager.default.fileExists(atPath: output.path))
        try Data().write(to: gate)
        try #require(h.wait(for: "chunk-ready"))
        // Append while the original queue has a consumed prefix and an unsent tail.
        h.session.send(.text(lateText))
        h.session.feed(Array("\u{1B}[5n".utf8))
        try Data().write(to: secondGate)
        try #require(h.wait(for: "write-complete"))
        #expect(h.waitForExit() == 0)
        #expect(try Data(contentsOf: output) == expected)
    }

    @Test(arguments: ["bin", ":/usr/bin"])
    func `PTY starts commands from relative PATH entries`(_ path: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bin = path == "bin" ? directory.appendingPathComponent("bin") : directory
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("swiftty-review-command")
        try Data("#!/bin/sh\nprintf 'startup-ok\\n'\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let h = try Harness([executable.lastPathComponent], env: ["PATH": path], workingDirectory: directory.path)
        #expect(h.wait(for: "startup-ok"))
        #expect(h.waitForExit() == 0)
    }

    @Test(arguments: [false, true])
    func `PTY starts commands with Unicode path boundaries`(_ explicitPath: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = explicitPath ? "\u{600}" : "\u{300}bin"
        let bin = directory.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("swiftty-review-command")
        try Data("#!/bin/sh\nprintf 'unicode-startup-ok\\n'\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let command = explicitPath ? folder + "/" + executable.lastPathComponent : executable.lastPathComponent
        let path = explicitPath ? "/no-tools" : "missing:" + folder
        let h = try Harness([command], env: ["PATH": path], workingDirectory: directory.path)
        #expect(h.wait(for: "unicode-startup-ok"))
        #expect(h.waitForExit() == 0)
    }

    @Test func `rapid PTY restarts keep new output and exit status intact`() throws {
        for generation in 0 ..< 20 {
            let h = try Harness(["/bin/sleep", "30"])
            // Fill the line discipline so cancellation also covers a write
            // source that may have unsent input and a read source with echo.
            h.session.send(.paste(String(repeating: "x", count: 64 * 1024)))
            h.session.stop()
            let marker = "restart-\(generation)-ok"
            try h.session.start(SessionConfiguration(command: ["/bin/sh", "-c", "printf '\(marker)\\n'; exit 42"]))
            #expect(h.wait(for: marker))
            #expect(h.waitForExit() == 42)
            #expect(!h.session.isRunning)
        }
    }

    @Test(arguments: [false, true])
    func `PTY restart discards incomplete output from the previous program`(_ stop: Bool) throws {
        let ending = stop ? "exec /bin/sleep 30" : "exit 0"
        let h = try Harness(["/bin/sh", "-c", "printf 'old\\033]2;pending'; \(ending)"])
        if stop {
            #expect(h.wait(for: "old"))
            h.session.stop()
        } else {
            #expect(h.waitForExit() == 0)
        }
        h.exitCode.withLock { $0 = nil }
        try h.session.start(SessionConfiguration(command: ["/bin/sh", "-c", "printf ok"]))
        #expect(h.wait(for: "oldok"))
        #expect(h.waitForExit() == 0)
    }

    @Test func `shell runs commands and exits`() throws {
        let h = try Harness(["/bin/sh"], env: ["PS1": "$ ", "ENV": ""])
        #expect(h.wait(for: "$"))
        h.type("echo hello-$((40+2))\r")
        #expect(h.wait(for: "hello-42"))
        h.type("stty size\r")
        #expect(h.wait(for: "24 80"))
        h.session.resize(columns: 100, rows: 30)
        h.type("stty size\r")
        #expect(h.wait(for: "30 100"))
        h.type("printf '\\033[31mred\\033[0m\\n'\r")
        #expect(h.wait(for: "red"))
        h.type("exit 3\r")
        #expect(h.waitForExit() == 3)
    }

    @Test func `shell has controlling terminal and job control`() throws {
        let h = try Harness(["/bin/sh"], env: ["PS1": "$ "])
        #expect(h.wait(for: "$"))
        h.type("tty && echo tty-$((20+22))\r")
        #expect(h.wait(for: "/dev/tty"))
        #expect(h.wait(for: "tty-42"))
        h.type("sleep 30\r")
        usleep(200_000)
        h.session.send(.key(KeyEvent(.character("c"), modifiers: .control)))
        // Expansion makes the marker differ from the echoed command, so
        // passing proves the shell regained control and executed it.
        h.type("echo after-$((40+2))\r")
        #expect(h.wait(for: "after-42"))
        h.session.stop()
    }

    @Test func `scrollback collects output`() throws {
        let h = try Harness(["/bin/sh", "-c", "seq 1 200; sleep 5"], columns: 40, rows: 10)
        #expect(h.wait(for: "200"))
        let count = h.session.withState { $0.scrollbackCount }
        #expect(count >= 190)
        h.session.scrollViewport(by: 1000)
        #expect(TestFixture(h.wait("top of history") { $0.hasPrefix("1\n2\n") }) == TestFixture(true))
        h.session.stop()
    }

    @Test func `vim edits in alternate screen`() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("swiftty-vim-\(getpid()).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        let h = try Harness(["/usr/bin/vim", "-u", "NONE", "-i", "NONE", "-N", "-n", file.path])
        #expect(h.wait(for: "~"))
        #expect(h.session.modes.contains(.alternateScreen))
        h.type("ihello from swiftty")
        h.session.send(.key(KeyEvent(.escape)))
        #expect(h.wait(for: "hello from swiftty"))
        h.type(":wq\r")
        #expect(h.waitForExit() == 0)
        #expect(try TestFixture(String(contentsOf: file, encoding: .utf8)) == TestFixture("hello from swiftty\n"))
        #expect(!h.session.modes.contains(.alternateScreen))
    }

    @Test func `less pages through file`() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("swiftty-less-\(getpid()).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        try (1 ... 300).map { "row \($0)" }.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        let h = try Harness(["/usr/bin/less", file.path], env: ["LESS": "", "LESSHISTFILE": "-"])
        #expect(TestFixture(h.wait(for: "row 1\n")) == TestFixture(true))
        h.type(" ")
        #expect(h.wait(for: "row 30"))
        h.type("G")
        #expect(h.wait(for: "row 300"))
        h.session.send(.key(KeyEvent(.up)))
        h.type("q")
        #expect(h.waitForExit() == 0)
    }

    @Test(.enabled(if: which("tmux") != nil)) func `tmux draws status and panes`() throws {
        let socket = "swiftty-test-\(getpid())"
        let tmux = try #require(Self.which("tmux"))
        defer {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tmux)
            p.arguments = ["-L", socket, "kill-server"]
            try? p.run()
            p.waitUntilExit()
        }
        let h = try Harness([tmux, "-L", socket, "-f", "/dev/null", "new-session", "/bin/sh"], env: ["PS1": "$ "])
        #expect(h.wait("status line") { $0.contains("[0]") || $0.contains("0:sh") })
        h.type("echo inside-tmux-$((40+2))\r")
        #expect(h.wait(for: "inside-tmux-42"))
        h.session.send(.key(KeyEvent(.character("b"), modifiers: .control)))
        h.type("%") // split vertically
        #expect(h.wait("pane border") { $0.contains("│") })
        h.type("exit\r")
        #expect(h.wait("pane closed") { !$0.contains("│") })
        h.type("exit\r")
        #expect(h.waitForExit() != nil)
    }

    @Test func `top renders and quits`() throws {
        let h = try Harness(["/usr/bin/top", "-s", "1", "-n", "10"])
        #expect(h.wait(for: "Processes:"))
        #expect(h.wait(for: "PID"))
        h.type("q")
        #expect(h.waitForExit() == 0)
    }
}
