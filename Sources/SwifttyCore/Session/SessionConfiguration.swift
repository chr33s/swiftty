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
    /// Nonpositive values disable history.
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

    /// Matches Ghostty's launch heuristic; Finder and `open` are desktop launches.
    static var isCommandLineLaunch: Bool {
        getppid() != 1 && (!(ProcessInfo.processInfo.environment["TERM_PROGRAM"] ?? "").isEmpty || CommandLine.arguments.count > 1)
    }

    static func loginShell(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fromCommandLine: Bool = Self.isCommandLineLaunch,
    ) -> String {
        if fromCommandLine, let shell = environment["SHELL"], !shell.isEmpty {
            return shell
        }
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell, shell.pointee != 0 {
            return String(cString: shell)
        }
        return environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
    }

    func executablePath() throws(POSIXError) -> String {
        try validateProcessStrings()
        guard let command, let program = command.first else { return Self.loginShell() }
        guard !program.isEmpty else { throw POSIXError("empty executable name", code: ENOENT) }
        if program.unicodeScalars.contains("/") {
            return program
        }
        let path = resolvedEnvironment()["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let parentDirectory = FileManager.default.currentDirectoryPath
        let directory = workingDirectory.map { $0.unicodeScalars.first == "/" ? $0 : parentDirectory + "/" + $0 } ?? parentDirectory
        var denied = false
        for part in path.unicodeScalars.split(separator: ":", omittingEmptySubsequences: false) {
            let dir = String(part)
            let base = dir.isEmpty ? directory : (dir.unicodeScalars.first == "/" ? dir : directory + "/" + dir)
            let candidate = base + "/" + program
            // Like posix_spawnp, reject an oversized candidate rather than
            // silently choosing a different executable later in PATH.
            guard candidate.utf8.count < Int(PATH_MAX) else {
                throw POSIXError("resolve executable \(program)", code: ENAMETOOLONG)
            }
            var info = stat()
            guard stat(candidate, &info) == 0 else {
                denied = denied || errno == EACCES
                continue
            }
            guard info.st_mode & S_IFMT == S_IFREG else {
                denied = true
                continue
            }
            if access(candidate, X_OK) == 0 {
                return candidate
            }
            denied = denied || errno == EACCES
        }
        throw POSIXError("resolve executable \(program)", code: denied ? EACCES : ENOENT)
    }

    /// C process APIs cannot represent embedded NULs, and environment
    /// entries must retain an unambiguous name=value boundary.
    private func validateProcessStrings() throws(POSIXError) {
        if command?.contains(where: { $0.utf8.contains(0) }) == true {
            throw POSIXError("command contains a NUL byte", code: EINVAL)
        }
        if workingDirectory?.utf8.contains(0) == true {
            throw POSIXError("working directory contains a NUL byte", code: EINVAL)
        }
        for (name, value) in resolvedEnvironment() {
            guard !name.isEmpty, !name.utf8.contains(0), !name.utf8.contains(0x3D) else {
                throw POSIXError("invalid environment variable name", code: EINVAL)
            }
            guard !value.utf8.contains(0) else {
                throw POSIXError("environment value contains a NUL byte", code: EINVAL)
            }
        }
    }

    func resolvedArguments() -> [String] {
        if let command, !command.isEmpty {
            return command
        }
        // A leading dash in argv[0] asks the shell to act as a login shell.
        let shell = Self.loginShell()
        return ["-" + (shell.unicodeScalars.split(separator: "/").last.map(String.init) ?? shell)]
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
