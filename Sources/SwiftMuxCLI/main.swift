// swmux: the SwiftMux terminal client for Swiftty.
import Darwin
import Foundation
import SwiftMuxClient
import SwiftMuxGuardian
import SwiftMuxProtocol
import SwiftMuxXPC
import SwiftMuxTerminal

let usage = """
  usage: swmux [--gateway-service NAME] [command] [options]

    (no command)                 attach to the newest workspace, or create one
    new [-s NAME] [-c DIR] [-d] [-- COMMAND...]
                                 create a workspace (and attach unless -d)
    attach [-t NAME]             attach to a workspace
    list | ls                    list workspaces
    detach                       release the active attachment
    end -t NAME                  end a workspace and its processes
    end-all                      end every workspace
    status                       show service status
    restore [-t NAME|ID] [-d] [--run-saved-commands]
                                 reopen a saved layout with fresh shells
    saved [list]                 list saved layouts
    saved policy [--layout on|off] [--output on|off]
                 [--reopen ask|automatic|never] [--retention DAYS]
    saved delete -t ID | --all   delete saved layouts
    agent install|uninstall|status
                                 manage a development LaunchAgent (the app
                                 bundle registers its own with SMAppService)

  options: --allow-host  run outside the supported Swiftty host profile
           --gateway-service NAME  use an explicitly installed durable gateway
             (before command; supports new, attach, list, status, targeted end,
             restore and saved)

  """

func fail(_ message: String, code: Int32 = 1) -> Never {
  FileHandle.standardError.write(Data("swmux: \(message)\n".utf8))
  exit(code)
}

/// A name argument as every client sends names: spacing folded and
/// invisibles dropped.
func nameArgument(_ typed: String, flag: String) -> String {
  guard let name = DisplayText.plainName(typed) else {
    fail("\(flag): the name shows nothing", code: 64)
  }
  return name
}

var arguments = Array(CommandLine.arguments.dropFirst())
/// Everything after `--` is the program and its arguments, never options.
var trailing: [String]?
if let i = arguments.firstIndex(of: "--") {
  trailing = Array(arguments[(i + 1)...])
  arguments = Array(arguments[..<i])
}
var allowHost = false
var gatewayService: String?
while let option = arguments.first,
  ["--allow-host", "--gateway-service"].contains(option)
{
  arguments.removeFirst()
  if option == "--allow-host" {
    allowHost = true;
    continue
  }
  guard gatewayService == nil, let service = arguments.first, !service.isEmpty,
    service.utf8.count <= 255,
    service.utf8.allSatisfy({
      (48 ... 57).contains($0) || (65 ... 90).contains($0)
        || (97 ... 122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
    })
  else { fail("--gateway-service requires one service name", code: 64) }
  gatewayService = service
  arguments.removeFirst()
}
let command =
  arguments.first.map {
    ["-h", "--help", "--version"].contains($0) || !$0.hasPrefix("-") ? $0 : ""
  } ?? ""
var rest = command.isEmpty ? arguments : Array(arguments.dropFirst())

@MainActor
func parseArguments(
  values: Set<String> = [],
  flags: Set<String> = [],
  allowsSubcommand: Bool = false
) -> (options: [String: String], subcommand: String?) {
  var options: [String: String] = [:]
  var subcommand: String?
  var tokens = rest[...]
  while let token = tokens.popFirst() {
    if token == "--allow-host" || values.contains(token)
      || flags.contains(token)
    {
      guard options[token] == nil else {
        fail("duplicate option: \(token)", code: 64)
      }
      if values.contains(token) {
        guard let value = tokens.popFirst() else {
          fail("\(token) requires a value", code: 64)
        }
        // Consume the value before recognizing any later flags.
        options[token] = value
      } else {
        options[token] = ""
        if token == "--allow-host" { allowHost = true }
      }
    } else if allowsSubcommand, subcommand == nil, !token.hasPrefix("-") {
      subcommand = token
    } else {
      fail("unexpected argument: \(token)", code: 64)
    }
  }
  rest = []
  guard trailing == nil || command == "new" else {
    fail("only new accepts a command after --", code: 64)
  }
  return (options, subcommand)
}

@MainActor
func validateArguments() { _ = parseArguments() }

func connect(_ kind: FrontendKind) async -> MuxConnection {
  do {
    return try await MuxConnection.connect(
      frontend: kind,
      terminalProfile: kind == .terminal ? SMX.terminalProfile : nil,
      // The outer terminal is Swiftty: kitty images (spec.graphics.md §14.5).
      capabilities: kind == .terminal
        ? ClientCapabilities.supported.union(.images) : .supported
    )
  } catch let error as MuxError where error.code == .connectionLost {
    fail(
      """
      the SwiftMux service is unavailable (\(error.message)).
      Open Swiftty to enable its background item, or for a development build run:
        swmux agent install
      """,
      code: 69
    )
  } catch { fail("\(error)", code: 69) }
}

/// The terminal frontend supports one pinned host profile.
@MainActor
func checkHost() {
  guard !allowHost else { return }
  let env = ProcessInfo.processInfo.environment
  guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
    fail("attach needs a terminal")
  }
  guard env["TERM_PROGRAM"] == "swiftty" else {
    fail(
      "swmux supports only the Swiftty terminal (\(SMX.terminalProfile)); TERM_PROGRAM is \(env["TERM_PROGRAM"] ?? "unset"). Use --allow-host to try anyway."
    )
  }
  if env["SWMUX"] != nil { fail("already inside a swmux pane") }
}

func attach(
  _ selector: WorkspaceSelector,
  connection: MuxConnection
) async -> Never {
  let settings: Settings
  do { settings = try Settings.load() } catch { fail("settings: \(error)") }
  let reply: MuxReply
  do {
    reply = try await connection.execute(.attach(AttachRequest(selector)))
  } catch { fail("\(error)") }
  guard case let .attached(attachment, workspace) = reply else {
    fail("unexpected reply")
  }
  let limits = await connection.welcome?.limits ?? .standard
  let outcome =
    await MainActor.run {
      TerminalClient(
        connection: connection,
        attachment: attachment,
        workspace: workspace,
        limits: limits,
        settings: settings
      )
    }
    .run()
  switch outcome {
  case let .detached(reason):
    print("[\(reason)]")
    exit(0)
  case let .lost(reason): fail("connection to the service was lost: \(reason)")
  case let .failed(reason): fail(reason)
  }
}

func environmentSnapshot() -> [String: String] {
  var env = ProcessInfo.processInfo.environment
  for key in [
    "TERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "COLORTERM", "SWMUX",
    "SWMUX_PANE",
  ] { env.removeValue(forKey: key) }
  return env
}

func workspaceRequest(
  name: String?,
  directory: String?,
  command: [String]?
) -> NewWorkspaceRequest {
  let settings: Settings
  do { settings = try Settings.load() } catch { fail("settings: \(error)") }
  var ws = winsize()
  let size =
    ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0
    ? (Int(ws.ws_col), max(1, Int(ws.ws_row) - 1)) : (80, 23)
  return NewWorkspaceRequest(
    name: name,
    columns: size.0,
    rows: size.1,
    launch: LaunchSpec(
      command: command,
      workingDirectory: directory ?? FileManager.default.currentDirectoryPath,
      environment: environmentSnapshot()
    ),
    remainOnExit: settings.remainOnExit
  )
}

func newWorkspace(
  _ connection: MuxConnection,
  name: String?,
  directory: String?,
  command: [String]?
) async -> WorkspaceSnapshot {
  let request = workspaceRequest(
    name: name,
    directory: directory,
    command: command
  )
  do {
    guard
      case let .created(snapshot) = try await connection.execute(
        .newWorkspace(request)
      )
    else { fail("unexpected reply") }
    return snapshot
  } catch { fail("\(error)") }
}

func formatList(_ list: [WorkspaceSummary]) -> String {
  guard !list.isEmpty else { return "no workspaces" }
  let formatter = DateFormatter()
  formatter.dateStyle = .short
  formatter.timeStyle = .short
  return
    list.map { ws in
      let tabs = "\(ws.tabCount) tab\(ws.tabCount == 1 ? "" : "s")"
      let panes = "\(ws.paneCount) pane\(ws.paneCount == 1 ? "" : "s")"
      let created = formatter.string(from: ws.createdAt)
      return "\(ws.name): \(tabs), \(panes) (created \(created))"
        + (ws.isAttached ? " (attached)" : "")
    }
    .joined(separator: "\n")
}

// MARK: Development LaunchAgent

func agentCommand(_ sub: String) -> Never {
  let label = SMX.defaultMachService
  let plist = FileManager.default.homeDirectoryForCurrentUser.appending(
    path: "Library/LaunchAgents/\(label).plist"
  )
  let domain = "gui/\(getuid())"
  func launchctl(_ args: [String]) -> Int32 {
    do { return try LaunchAgentCommand.run(args) } catch {
      fail("launchctl: \(error)")
    }
  }
  switch sub {
  case "install":
    let exe = URL(fileURLWithPath: CommandLine.arguments[0])
      .resolvingSymlinksInPath()
    let agent = exe.deletingLastPathComponent()
      .appending(path: "swiftmux-agent").path
    guard FileManager.default.isExecutableFile(atPath: agent) else {
      fail("swiftmux-agent not found next to swmux (\(agent))")
    }
    let contents: String
    do {
      contents = try AgentPlist.contents(label: label, program: agent)
    } catch { fail("launch-agent plist: \(error)") }
    do {
      try FileManager.default.createDirectory(
        at: plist.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try contents.write(to: plist, atomically: true, encoding: .utf8)
    } catch { fail("writing \(plist.path): \(error)") }
    _ = launchctl(["bootout", "\(domain)/\(label)"])
    guard launchctl(["bootstrap", domain, plist.path]) == 0 else {
      fail("launchctl bootstrap failed")
    }
    print("installed \(plist.path) -> \(agent)")
    exit(0)
  case "uninstall":
    do {
      try LaunchAgentRemoval.remove(
        bootout: { launchctl(["bootout", "\(domain)/\(label)"]) },
        probe: { launchctl(["print", "\(domain)/\(label)"]) },
        removePlist: { try LaunchAgentRemoval.unlinkPlist(at: plist) },
      )
    } catch { fail("uninstalling \(label): \(error)") }
    print("removed development LaunchAgent registration \(label)")
    exit(0)
  case "status":
    let loaded: Bool
    do {
      loaded = try LaunchAgentRemoval.isLoaded(
        probeStatus: launchctl(["print", "\(domain)/\(label)"])
      )
    } catch { fail("reading agent status for \(label): \(error)") }
    print(
      "\(label): \(loaded ? "loaded" : "not loaded")\(FileManager.default.fileExists(atPath: plist.path) ? " (\(plist.path))" : "")"
    )
    exit(0)
  default: fail("usage: swmux agent install|uninstall|status", code: 64)
  }
}

// MARK: Dispatch

signal(SIGPIPE, SIG_IGN)
if let gatewayService,
  !["help", "-h", "--help", "--version", "version"].contains(command)
{
  await gatewayCommand(service: gatewayService)
}
switch command {
case "help", "-h", "--help":
  validateArguments()
  print(usage, terminator: "")
case "--version", "version":
  validateArguments()
  print("swmux \(SMX.build) (SMX/\(SMX.protocolVersion))")
case "agent":
  let parsed = parseArguments(allowsSubcommand: true)
  agentCommand(parsed.subcommand ?? "")
case "list", "ls":
  validateArguments()
  let c = await connect(.control)
  guard case let .workspaces(list) = try await c.execute(.listWorkspaces) else {
    exit(1)
  }
  print(formatList(list))
case "status":
  validateArguments()
  let c = await connect(.control)
  guard case let .status(s) = try await c.execute(.status) else { exit(1) }
  print(
    """
    service \(s.server.short) (\(s.build), pid \(s.pid)) since \(s.startedAt)
    \(s.workspaces) workspace(s), \(s.panes) pane(s), \(s.attached ? "attached" : "detached")\(s.quiescing ? ", quiescing" : "")
    inner TERM \(s.innerTerm)
    """
  )
case "detach":
  validateArguments()
  let c = await connect(.control)
  _ = try await c.execute(.detachActive)
case "end", "kill":
  let parsed = parseArguments(values: ["-t"])
  guard let typed = parsed.options["-t"] else {
    fail("end requires -t NAME", code: 64)
  }
  let name = nameArgument(typed, flag: "-t")
  let c = await connect(.control)
  do { _ = try await c.execute(.endWorkspace(.name(name))) } catch {
    fail("\(error)")
  }
case "restore", "saved":
  fail(
    "\(command) requires --gateway-service NAME: saved layouts belong to the durable gateway",
    code: 64
  )
case "end-all":
  validateArguments()
  let c = await connect(.control)
  _ = try await c.execute(.endAllWorkspaces)
  _ = try await c.execute(.quiesce(false))
case "new":
  let parsed = parseArguments(values: ["-s", "-c"], flags: ["-d"])
  let detached = parsed.options["-d"] != nil
  let name = parsed.options["-s"].map { nameArgument($0, flag: "-s") }
  let dir = parsed.options["-c"]
  let cmd = trailing
  if !detached { checkHost() }
  let c = await connect(detached ? .control : .terminal)
  let ws = await newWorkspace(
    c,
    name: name,
    directory: dir,
    command: cmd?.isEmpty == true ? nil : cmd
  )
  if detached {
    print("created \(ws.name)")
    exit(0)
  }
  await attach(.id(ws.id), connection: c)
case "attach", "a":
  let target = parseArguments(values: ["-t"]).options["-t"]
    .map { nameArgument($0, flag: "-t") }
  checkHost()
  let c = await connect(.terminal)
  await attach(target.map { .name($0) } ?? .latest, connection: c)
case "":
  validateArguments()
  checkHost()
  let c = await connect(.terminal)
  guard case let .workspaces(list) = try await c.execute(.listWorkspaces) else {
    exit(1)
  }
  if let latest = list.last { await attach(.id(latest.id), connection: c) }
  let ws = await newWorkspace(c, name: nil, directory: nil, command: nil)
  await attach(.id(ws.id), connection: c)
default:
  FileHandle.standardError.write(Data(usage.utf8))
  exit(64)
}
