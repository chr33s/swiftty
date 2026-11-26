import Darwin
import Foundation
import SwiftMuxClient
import SwiftMuxGuardian
import SwiftMuxProtocol

// Saved layouts from the terminal (spec.durability.md §12.2). Gateway only:
// the saved store belongs to the durable topology.

/// Reopens a Saved record as a new workspace with fresh shells. Saved
/// commands run only with `--run-saved-commands`.
@MainActor
func gatewayRestore(
  _ control: MuxGatewayConnection,
  target: String?,
  runSavedCommands: Bool
) async throws -> WorkspaceID {
  let list = try await control.savedWorkspaces()
  let candidates = list.workspaces.filter {
    $0.state == .saved || $0.state == .unavailable
  }
  let entry: SavedWorkspaceListing
  if let target {
    let matches = candidates.filter {
      $0.name == target || $0.id.description == target
        || (target.count >= 8
          && $0.id.description.lowercased().hasPrefix(target.lowercased()))
    }
    guard matches.count == 1, let match = matches.first else {
      throw MuxError(
        .notFound,
        matches.isEmpty
          ? "no saved layout \(target)" : "saved layout \(target) is ambiguous"
      )
    }
    entry = match
  } else {
    guard let newest = candidates.first else {
      throw MuxError(.notFound, "no saved layouts")
    }
    entry = newest
  }
  let base = workspaceRequest(name: nil, directory: nil, command: nil)
  var launch = base.launch
  launch.workingDirectory = nil
  let (id, outcome) = try await control.reopenSaved(
    SavedReopenRequest(
      record: entry.id,
      launch: launch,
      columns: base.columns,
      rows: base.rows,
      remainOnExit: base.remainOnExit,
      runCommandSlots: runSavedCommands ? entry.commands.map(\.slot) : []
    )
  )
  if !outcome.failedSlots.isEmpty {
    FileHandle.standardError.write(
      Data("swmux: \(outcome.failedSlots.count) pane(s) did not start\n".utf8)
    )
  }
  if !outcome.directoryFallbackSlots.isEmpty {
    FileHandle.standardError.write(
      Data("swmux: saved directory unavailable; started in home\n".utf8)
    )
  }
  if !runSavedCommands, !entry.commands.isEmpty {
    let lines = entry.commands.map { command in
      "swmux: \(command.listingLabel) not run; "
        + "pass --run-saved-commands to run saved commands\n"
    }
    FileHandle.standardError.write(Data(lines.joined().utf8))
  }
  return id
}

@MainActor
func savedCommand(service: String) async -> Never {
  let parsed = parseArguments(
    values: ["-t", "--layout", "--output", "--reopen", "--retention"],
    flags: ["--all"],
    allowsSubcommand: true
  )
  let options = parsed.options
  let sub = parsed.subcommand ?? "list"
  guard ["list", "ls", "policy", "delete"].contains(sub) else {
    fail("usage: swmux saved [list|policy|delete]", code: 64)
  }
  do {
    let control = try await MuxGatewayConnection.connect(
      peerRequirement: GuardianPeerSigningPolicy.requirementForCurrentProcess(),
      channel: { .connect(machService: service, queue: $0) }
    )
    defer { Task { await control.close() } }
    switch sub {
    case "policy":
      let list = try await control.savedWorkspaces()
      var policy = list.policy
      if options.isEmpty {
        printPolicy(policy)
        exit(0)
      }
      func toggle(_ flag: String) -> Bool? {
        guard let value = options[flag] else { return nil }
        guard ["on", "off"].contains(value) else {
          fail("\(flag) takes on or off", code: 64)
        }
        return value == "on"
      }
      if let value = toggle("--layout") { policy.saveLayout = value }
      if let value = toggle("--output") { policy.saveOutput = value }
      if let value = options["--reopen"] {
        guard let reopen = SavedReopenAtLaunch(rawValue: value) else {
          fail("--reopen takes ask, automatic or never", code: 64)
        }
        policy.reopenAtLaunch = reopen
      }
      if let value = options["--retention"] {
        guard let days = Int(value), (1 ... 365).contains(days) else {
          fail("--retention takes 1–365 days", code: 64)
        }
        policy.retentionDays = days
      }
      guard policy.isValid else {
        fail("saving output requires saving layouts", code: 64)
      }
      printPolicy(
        try await control.setSavedPolicy(
          policy,
          expectedRevision: list.policy.revision
        )
      )
    case "delete":
      if options["--all"] != nil {
        try await control.deleteSaved(nil)
        print("deleted all saved layouts")
      } else {
        guard let target = options["-t"], let id = WorkspaceID(target) else {
          fail("delete requires -t ID or --all", code: 64)
        }
        try await control.deleteSaved(id)
        print("deleted \(id)")
      }
    default:
      let list = try await control.savedWorkspaces()
      switch list.store {
      case .available: break
      case let .unavailable(reason):
        print("saved layouts unavailable: \(reason)")
      case .keyLost:
        print("the saved layout key was missing; earlier layouts were deleted")
      }
      if list.workspaces.isEmpty { print("no saved layouts") }
      let format = Date.FormatStyle(date: .abbreviated, time: .shortened)
      for entry in list.workspaces {
        let saved = entry.savedAt.map { " saved \($0.formatted(format))" } ?? ""
        print(
          "\(entry.id) \(entry.name): \(entry.state.rawValue), "
            + "\(entry.tabCount) tab(s), \(entry.paneCount) pane(s)\(saved)"
        )
      }
    }
    exit(0)
  } catch { fail("gateway \(service): \(error)", code: 69) }
}

private func printPolicy(_ policy: SavedLayoutPolicy) {
  print(
    "layout \(policy.saveLayout ? "on" : "off"), "
      + "output \(policy.saveOutput ? "on" : "off"), "
      + "reopen \(policy.reopenAtLaunch.rawValue), "
      + "retention \(policy.retentionDays) day(s)"
  )
}
