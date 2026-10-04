import Foundation
@testable import SwifttyCore
import Synchronization
import Testing

/// Drives real programs through a PTY and checks what they draw.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct IntegrationTests {
    final class Harness: Sendable {
        let session: TerminalSession
        let exitCode = Mutex<Int32?>(nil)

        init(_ command: [String], columns: Int = 80, rows: Int = 24, env: [String: String] = [:]) throws {
            session = TerminalSession(columns: columns, rows: rows)
            session.onEvent = { [weak self] event in
                if case let .exited(code) = event {
                    self?.exitCode.withLock { $0 = code }
                }
            }
            var config = SessionConfiguration(command: command, environment: env)
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
            Issue.record("timed out waiting for \(what); screen:\n\(screen)")
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
        h.type("tty && echo tty-ok\r")
        #expect(h.wait(for: "tty-ok"))
        h.type("sleep 30\r")
        usleep(200_000)
        h.session.send(.key(KeyEvent(.character("c"), modifiers: .control)))
        h.type("echo after-int\r")
        #expect(h.wait(for: "after-int"))
        h.session.stop()
    }

    @Test func `scrollback collects output`() throws {
        let h = try Harness(["/bin/sh", "-c", "seq 1 200; sleep 5"], columns: 40, rows: 10)
        #expect(h.wait(for: "200"))
        let count = h.session.withState { $0.scrollbackCount }
        #expect(count >= 190)
        h.session.scrollViewport(by: 1000)
        #expect(h.wait("top of history") { $0.hasPrefix("1\n2\n") })
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
        #expect(try String(contentsOf: file, encoding: .utf8) == "hello from swiftty\n")
        #expect(!h.session.modes.contains(.alternateScreen))
    }

    @Test func `less pages through file`() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("swiftty-less-\(getpid()).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        try (1 ... 300).map { "row \($0)" }.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        let h = try Harness(["/usr/bin/less", file.path], env: ["LESS": "", "LESSHISTFILE": "-"])
        #expect(h.wait(for: "row 1\n"))
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
        h.type("echo inside-tmux\r")
        #expect(h.wait(for: "inside-tmux"))
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
