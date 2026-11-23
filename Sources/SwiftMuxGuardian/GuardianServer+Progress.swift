import Dispatch
import SwiftMuxProtocol
import Foundation

extension GuardianServer {
  func startProgressWatchdog(_ workspace: Workspace) {
    workspace.progressTimer?.cancel()
    workspace.progressEpoch &+= 1
    let timer = DispatchSource.makeTimerSource(queue: queue)
    workspace.progressTimer = timer
    workspace.progressDeadline = .now() + progressTimeout
    timer.schedule(deadline: workspace.progressDeadline)
    timer.setEventHandler { [weak self, weak workspace] in
      guard let self, let workspace, !workspace.unavailable else { return }
      // A late queued acknowledgement cannot revive an expired owner.
      if DispatchTime.now() >= workspace.progressDeadline {
        self.loseWorker(
          workspace,
          MuxError(.connectionLost, "progress watchdog expired")
        )
      }
    }
    timer.resume()
    issueProgressProbe(workspace)
  }

  private func issueProgressProbe(_ workspace: Workspace) {
    guard !workspace.unavailable, workspace.connection != nil else { return }
    let probe = UUID()
    workspace.progressProbe = probe
    workspace.probesIssued += 1
    send(.probe(probe), to: workspace)
  }

  func acknowledgeProgress(_ workspace: Workspace) {
    workspace.progressProbe = nil
    workspace.progressDeadline = .now() + progressTimeout
    workspace.progressTimer?.schedule(deadline: workspace.progressDeadline)
    // Only one challenge is outstanding. The next challenge does not extend
    // the deadline: failure is detected within five seconds of last progress.
    let epoch = workspace.progressEpoch
    // Workspace is queue-confined and not Sendable: re-resolve it on the queue.
    let id = workspace.authority.workspace
    let identity = ObjectIdentifier(workspace)
    queue.asyncAfter(deadline: .now() + min(1, progressTimeout / 2)) {
      [weak self] in
      guard let self, let workspace = self.workspaces[id],
        ObjectIdentifier(workspace) == identity,
        workspace.progressEpoch == epoch
      else { return }
      self.issueProgressProbe(workspace)
    }
  }
}
