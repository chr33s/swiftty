import Darwin
import Foundation

public struct SessionConfiguration: Sendable {
    /// Program and arguments; `nil` runs the user's login shell.
    public var command: [String]?
    /// Variables added to (or overriding) the inherited environment.
    public var environment: [String: String] = [:]
    /// Inherited variables to remove (e.g. `TMUX` when nesting).
    public var removedEnvironment: Set<String> = []
    public var workingDirectory: String?
    public var term = "xterm-256color"
    public var scrollbackLimitBytes = 10_000_000
    /// Cap on history lines (Ghostty's `scrollback-limit-lines`).
    public var scrollbackLimitRows = 100_000
    public var palette = Palette.standard
    /// Consume OSC 7501 program status and answer its support query
    /// (`TerminalState.programStatusEnabled`).
    public var programStatusEnabled = false

    public init(command: [String]? = nil, environment: [String: String] = [:], workingDirectory: String? = nil) {
        self.command = command
        self.environment = environment
        self.workingDirectory = workingDirectory
    }

    static func loginShell() -> String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell, shell.pointee != 0 {
            return String(cString: shell)
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    func executablePath() -> String {
        guard let command, let program = command.first else { return Self.loginShell() }
        if program.contains("/") {
            return program
        }
        let path = resolvedEnvironment()["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(program)"
            if access(candidate, X_OK) == 0 {
                return candidate
            }
        }
        return program
    }

    func resolvedArguments() -> [String] {
        if let command, !command.isEmpty {
            return command
        }
        // A leading dash in argv[0] asks the shell to act as a login shell.
        let shell = Self.loginShell()
        return ["-" + (shell.split(separator: "/").last.map(String.init) ?? shell)]
    }

    func resolvedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = term
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "swiftty"
        env["TERM_PROGRAM_VERSION"] = "0.1"
        if env["LANG"] == nil {
            env["LANG"] = "en_US.UTF-8"
        }
        env.removeValue(forKey: "TERMINFO")
        for key in removedEnvironment {
            env.removeValue(forKey: key)
        }
        for (key, value) in environment {
            env[key] = value
        }
        return env
    }
}
