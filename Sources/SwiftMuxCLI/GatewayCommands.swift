import Darwin
import Foundation
import SwiftMuxClient
import SwiftMuxGuardian
import SwiftMuxProtocol
import SwiftMuxTerminal

@MainActor
func gatewayCommand(service: String) async -> Never {
  let options: [String: String]
  switch command {
  case "new":
    options = parseArguments(values: ["-s", "-c"], flags: ["-d"]).options
  case "attach", "a", "end", "kill":
    options = parseArguments(values: ["-t"]).options
  case "", "list", "ls", "status":
    validateArguments();
    options = [:]
  case "restore":
    options =
      parseArguments(values: ["-t"], flags: ["-d", "--run-saved-commands"])
      .options
  case "saved": await savedCommand(service: service)
  default:
    fail(
      "\(command) is not supported by the gateway control protocol",
      code: 64
    )
  }
  if ["attach", "a", ""].contains(command)
    || (["new", "restore"].contains(command) && options["-d"] == nil)
  {
    checkHost()
  }
  let target = options["-t"].map { nameArgument($0, flag: "-t") }
  if ["end", "kill"].contains(command), target == nil {
    fail("end requires -t NAME or ID", code: 64)
  }
  let selector: WorkspaceSelector =
    target.map { WorkspaceID($0).map(WorkspaceSelector.id) ?? .name($0) }
    ?? .latest
  do {
    let control = try await MuxGatewayConnection.connect(
      peerRequirement: GuardianPeerSigningPolicy.requirementForCurrentProcess(),
      channel: { .connect(machService: service, queue: $0) }
    )
    do {
      switch command {
      case "list", "ls", "status":
        let records = try await control.listWorkspaces()
        if command == "status" {
          print("gateway \(service): \(records.count) retained workspace(s)")
        }
        if records.isEmpty { print("no workspaces") }
        for record in records {
          let state: String
          switch record.state {
          case .available: state = "available"
          case .starting: state = "starting"
          case .discovering: state = "discovering"
          case .empty: state = "empty worker"
          case let .unavailable(error): state = "unavailable (\(error.code))"
          }
          print(
            "\(record.workspace) \(record.summary?.name ?? "unknown"): \(state)"
          )
        }
      case "end", "kill": try await control.endWorkspace(selector)
      case "restore":
        let id = try await gatewayRestore(
          control,
          target: target,
          runSavedCommands: options["--run-saved-commands"] != nil
        )
        if options["-d"] != nil {
          print("reopened \(id)")
        } else {
          await gatewayAttach(control, selector: .id(id), service: service)
        }
      case "new":
        let name = options["-s"].map { nameArgument($0, flag: "-s") }
        let id = try await gatewayCreate(
          control,
          name: name,
          directory: options["-c"],
          command: trailing?.isEmpty == true ? nil : trailing
        )
        if options["-d"] != nil {
          print("created \(id)")
        } else {
          await gatewayAttach(control, selector: .id(id), service: service)
        }
      case "":
        // Retained, starting and unavailable workers count as existing. Only a
        // successful empty inventory permits automatic initial creation.
        if try await control.listWorkspaces().isEmpty {
          let id = try await gatewayCreate(
            control,
            name: nil,
            directory: nil,
            command: nil
          )
          await gatewayAttach(control, selector: .id(id), service: service)
        } else {
          await gatewayAttach(control, selector: .latest, service: service)
        }
      default:
        await gatewayAttach(control, selector: selector, service: service)
      }
      await control.close()
      exit(0)
    } catch {
      await control.close();
      throw error
    }
  } catch { fail("gateway \(service): \(error)", code: 69) }
}

private func gatewayCreate(
  _ control: MuxGatewayConnection,
  name: String?,
  directory: String?,
  command: [String]?
) async throws -> WorkspaceID {
  let id = WorkspaceID()
  do {
    try await control.createWorkspace(
      id,
      request: workspaceRequest(
        name: name,
        directory: directory,
        command: command
      )
    )
    let deadline = ContinuousClock.now + .seconds(5)
    while true {
      if let record = try await control.listWorkspaces()
        .first(where: { $0.workspace == id })
      {
        if case .available = record.state { return id }
        if case let .unavailable(error) = record.state { throw error }
      }
      guard ContinuousClock.now < deadline else {
        throw MuxError(
          .quiescing,
          "workspace \(id) created; discovery is still pending"
        )
      }
      try await Task.sleep(for: .milliseconds(25))
    }
  } catch {
    // Keep the preallocated identity visible after any uncertain launch result.
    FileHandle.standardError.write(
      Data("swmux: creation outcome for workspace \(id): \(error)\n".utf8)
    )
    throw error
  }

}

@MainActor
private func gatewayAttach(
  _ control: MuxGatewayConnection,
  selector: WorkspaceSelector,
  service: String
) async -> Never {
  let controlOwner = GatewayTerminalControl(control, service: service)
  let session = MuxGatewaySession(
    gateway: control,
    frontend: .terminal,
    capabilities: ClientCapabilities.supported.union(.images)
  )
  do {
    let settings = try Settings.load()
    let selected = try await session.select(selector)
    let terminal = TerminalClient(
      gateway: control,
      session: session,
      selection: selected,
      reconnect: { try await controlOwner.reconnect() },
      settings: settings
    )
    let result = await terminal.run()
    await session.close()
    await controlOwner.close()
    switch result {
    case let .detached(reason):
      print("[\(reason)]");
      exit(0)
    case let .lost(reason): fail("connection to gateway was lost: \(reason)")
    case let .failed(reason): fail(reason)
    }
  } catch {
    await session.close()
    await controlOwner.close()
    fail("\(error)")
  }
}
