import Dispatch
import Foundation
import SwiftMuxProtocol

extension GuardianServer {
  func beginSpawn(
    _ command: GuardianCommand,
    workspace: Workspace,
    charge: Int
  ) throws {
    guard case let .spawn(id, launch, columns, rows) = command else {
      preconditionFailure("not a spawn")
    }
    try validateSize(columns, rows)
    guard (launch.command?.count ?? 0) <= 256, launch.environment.count <= 256,
      try JSONEncoder().encode(launch).count <= GuardianWire.inputChunkLimit
    else { throw MuxError(.resourceLimit, "launch specification too large") }
    guard workspace.panes[id] == nil,
      workspaces.values.reduce(pendingLaunches, { $0 + $1.panes.count })
        < limits.maxPanes
    else {
      throw MuxError(.resourceLimit, "pane identity or capacity unavailable")
    }
    let workspaceID = workspace.authority.workspace
    let runtime = GuardianPTY(
      id: id,
      workspace: workspaceID,
      queue: queue,
      limits: limits
    )
    let pane = Pane(runtime)
    installConsumer(pane, id: id, workspace: workspace)
    workspace.pendingLaunch = PendingLaunch(
      id: id,
      pane: pane,
      command: command,
      charge: charge
    )
    pendingLaunches += 1
    workspace.resultBytes += charge
    resultBytes += charge
    var launcher = self.launcher
    if let build = workspace.buildPin {
      launcher.launcherPath = build.launcherPath
      launcher.terminfoDirectory = build.terminfoPath
    }
    let selectedLauncher = launcher
    // Retain the guardian through adoption/cleanup. Dropping a connection or
    // calling shutdown cannot abandon a spawned child's descriptors/PID.
    DispatchQueue.global(qos: .userInitiated)
      .async { [self] in
        let result: Result<LaunchedProcess, MuxError>
        do throws(MuxError) {
          result = .success(
            try selectedLauncher.launch(
              launch,
              pane: id,
              workspace: workspaceID,
              columns: columns,
              rows: rows
            )
          )
        } catch { result = .failure(error) }
        queue.async { self.completeSpawn(result, workspace: workspaceID) }
      }
  }

  private func completeSpawn(
    _ result: Result<LaunchedProcess, MuxError>,
    workspace id: WorkspaceID
  ) {
    // Inventory cannot be removed while a launch is outstanding.
    let workspace = workspaces[id]!
    let pending = workspace.pendingLaunch!
    workspace.pendingLaunch = nil
    pendingLaunches -= 1
    let reply: GuardianResult
    switch result {
    case let .success(child):
      let runtime = pending.pane.runtime
      workspace.panes[pending.id] = pending.pane
      runtime.adopt(child)
      if workspace.unavailable { runtime.detachConsumer() }
      if stopping || workspace.ending { runtime.terminate() }
      reply = .spawned(pid: child.pid, process: pending.pane.process)
    case let .failure(error): reply = .rejected(error)
    }
    recordResult(
      reply,
      command: pending.command,
      workspace: workspace,
      charge: pending.charge,
      alreadyReserved: true
    )
    checkStopped()
  }
}
