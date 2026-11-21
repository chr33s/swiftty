// swroam: a roaming RST/1 terminal client, mosh-style, for any terminal.
import AppleTransport
import Darwin
import Foundation
import RoamingConnect
import RoamingKit
import RoamingTerminal
import SSHClient
import SSHIdentity
import ScreenProtocol
import SessionCore
import Synchronization
import TTYKit

let usage = """
  usage: swroam [options] [user@]host

    Bootstraps over SSH (swifttyd on the host), then follows the session
    over QUIC across network changes and sleep.

    -p PORT            SSH port (22)
    -l USER            SSH user (default: user@ prefix, else $USER)
    -i FILE            OpenSSH Ed25519 private key (default ~/.ssh/id_ed25519
                       when present, else a password prompt)
    -r, --resume ID    reattach to an existing session
    --helper PATH      swifttyd path on the host (\(defaultHelperPath))
    --known-hosts FILE trusted host keys (default
                       ~/Library/Application Support/swroam/known_hosts.json)

  In the session: Ctrl-^ .  detach    Ctrl-^ k  terminate
                  Ctrl-^ Ctrl-^  send Ctrl-^

  """

func fail(_ message: String, code: Int32 = 1) -> Never {
  FileHandle.standardError.write(Data("swroam: \(message)\n".utf8))
  exit(code)
}

func note(_ message: String) {
  FileHandle.standardError.write(Data("swroam: \(message)\n".utf8))
}

// MARK: Arguments

struct Options {
  var host: String?
  var port = 22
  var user: String?
  var identity: String?
  var resume: SessionID?
  var helper = defaultHelperPath
  var knownHosts: String?
}

func parse(_ arguments: [String]) -> Options {
  var options = Options()
  var rest = arguments[...]
  func value(_ flag: String) -> String {
    guard let next = rest.popFirst() else {
      fail("\(flag) needs a value", code: 64)
    }
    return next
  }
  while let argument = rest.popFirst() {
    switch argument {
    case "-h", "--help":
      print(usage, terminator: "")
      exit(0)
    case "-p":
      guard let port = Int(value("-p")), (1 ... 65535).contains(port) else {
        fail("-p: not a port", code: 64)
      }
      options.port = port
    case "-l": options.user = value("-l")
    case "-i": options.identity = value("-i")
    case "-r", "--resume":
      guard let id = SessionID(hex: value(argument)) else {
        fail("\(argument): not a session ID", code: 64)
      }
      options.resume = id
    case "--helper": options.helper = value("--helper")
    case "--known-hosts": options.knownHosts = value("--known-hosts")
    case _ where argument.hasPrefix("-"):
      fail("unknown option \(argument)\n\n\(usage)", code: 64)
    default:
      guard options.host == nil else { fail("one host only", code: 64) }
      if let at = argument.lastIndex(of: "@") {
        options.user = options.user ?? String(argument[..<at])
        options.host = String(argument[argument.index(after: at)...])
      } else {
        options.host = argument
      }
    }
  }
  return options
}

// MARK: Prompts (cooked mode only)

func readSecret(_ prompt: String) -> String? {
  var buffer = [CChar](repeating: 0, count: 1024)
  guard readpassphrase(prompt, &buffer, buffer.count, RPP_REQUIRE_TTY) != nil
  else { return nil }
  defer {
    buffer.withUnsafeMutableBytes {
      _ = memset_s($0.baseAddress, $0.count, 0, $0.count)
    }
  }
  let length = buffer.firstIndex(of: 0) ?? buffer.count
  return String(
    decoding: buffer[..<length].map { UInt8(bitPattern: $0) },
    as: UTF8.self
  )
}

func readLine(prompt: String) -> String? {
  FileHandle.standardError.write(Data(prompt.utf8))
  return Swift.readLine()
}

func credential(_ options: Options) -> SSHCredential {
  let home = FileManager.default.homeDirectoryForCurrentUser
  let path =
    options.identity
    ?? {
      let fallback = home.appending(path: ".ssh/id_ed25519").path
      return FileManager.default.fileExists(atPath: fallback) ? fallback : nil
    }()
  guard let path else {
    guard
      let password = readSecret(
        "\(options.user!)@\(options.host!)'s password: "
      )
    else { fail("no password") }
    return .password(password)
  }
  guard let data = FileManager.default.contents(atPath: path) else {
    fail("\(path): cannot read")
  }
  do {
    return try OpenSSHKeyImporter.decode(data).secret.credential
  } catch .passphraseRequired {
    guard let passphrase = readSecret("Enter passphrase for \(path): ") else {
      fail("no passphrase")
    }
    do {
      return try OpenSSHKeyImporter.decode(data, passphrase: passphrase).secret
        .credential
    } catch { fail("\(path): \(error)") }
  } catch { fail("\(path): \(error) (Ed25519 and ECDSA keys are supported)") }
}

/// Asks about an unknown host key only before raw mode; reconnects never
/// prompt.
final class FirstUseTrustDecider: HostTrustDecider {
  let interactive = Atomic(true)

  func decide(_ request: HostTrustRequest) async -> HostTrustDecision {
    guard interactive.load(ordering: .acquiring) else { return .reject }
    let answer = readLine(
      prompt: """
        The authenticity of host '\(request.host)' can't be established.
        \(request.keyType) key fingerprint is \(request.fingerprint).
        Trust it and continue connecting (yes/no)?
        """
    )
    return answer?.lowercased() == "yes" ? .trustAndRemember : .reject
  }
}

// MARK: Main

let options = parse(Array(CommandLine.arguments.dropFirst()))
guard let host = options.host, !host.isEmpty else {
  FileHandle.standardError.write(Data(usage.utf8))
  exit(64)
}
var resolved = options
resolved.user = options.user ?? ProcessInfo.processInfo.environment["USER"]
guard let user = resolved.user, !user.isEmpty else { fail("no user", code: 64) }

let tty = RawTTY()
guard tty.isTerminal else { fail("stdin and stdout must be a terminal") }

let knownHosts =
  resolved.knownHosts.map { URL(filePath: $0) }
  ?? FileManager.default.homeDirectoryForCurrentUser.appending(
    path: "Library/Application Support/swroam/known_hosts.json"
  )
try? FileManager.default.createDirectory(
  at: knownHosts.deletingLastPathComponent(),
  withIntermediateDirectories: true
)

let decider = FirstUseTrustDecider()
let endpoint = SSHEndpoint(
  configuration: SSHClientConfiguration(
    host: host,
    port: resolved.port,
    username: user
  ),
  credential: credential(resolved),
  trustStore: FileHostTrustStore(fileURL: knownHosts),
  trustDecider: decider,
  helperPath: resolved.helper
)
let sink = TTYPresentationSink()
let size = tty.size
let client = RoamingClient(
  bootstrapper: SSHBootstrapper(endpoint: endpoint),
  // An advertised LAN address is unroutable off-network; race the host
  // SSH reached.
  connector: QUICGrantConnector(fallbackHost: host),
  sink: sink,
  configuration: RoamingClientConfiguration(
    initialGrid: GridSize(columns: size.columns, rows: size.rows)
  )
)

let paths = PathMonitor()
let outcome: RoamingTerminalClient.Outcome
do {
  // Top-level code runs on the main actor.
  let terminal = RoamingTerminalClient(client: client, sink: sink, tty: tty)
  terminal.willEnterRawMode = {
    decider.interactive.store(false, ordering: .releasing)
  }
  paths.start { _ in Task { @MainActor in terminal.pathChanged() } }
  let target: RoamingTarget =
    resolved.resume.map(RoamingTarget.resume)
    ?? .create(GridSize(columns: size.columns, rows: size.rows))
  outcome = try await terminal.run(target)
} catch {
  paths.cancel()
  switch error {
  case .sessionLost: fail("no such session on \(host)")
  case .sessionExited: fail("the session has exited")
  case .hostKeyRejected: fail("host key not trusted")
  case .authenticationFailed: fail("authentication failed")
  case .unreachable: fail("cannot reach \(host) over SSH")
  case let .rejected(code): fail("host refused the session (\(code))")
  default: fail("\(error)")
  }
}
paths.cancel()
switch outcome {
case let .detached(id):
  note(
    "detached" + (id.map { "; resume with: swroam -r \($0.hex) \(host)" } ?? "")
  )
case let .exited(status): exit(status.map { $0 & 0xFF } ?? 0)
case let .lost(reason): fail(reason)
case .terminated: note("session terminated")
}
