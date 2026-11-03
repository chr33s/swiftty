import Dispatch
import Foundation

extension GuardianServer {
  func startProgressWatchdog(_ workspace: Workspace) {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    workspace.progressTimer = timer
    workspace.progressDeadline = .now() + progressTimeout
    timer.schedule(deadline: workspace.progressDeadline)
    timer.setEventHandler { [weak self, weak workspace] in
      guard let self, let workspace, !workspace.unavailable else { return }
      // A late queued acknowledgement cannot revive an expired owner.
      if DispatchTime.now() >= workspace.progressDeadline {
        self.loseWorker(workspace)
      }
    }
    timer.resume()
    issueProgressProbe(workspace)
  }

  private func issueProgressProbe(_ workspace: Workspace) {
    guard !workspace.unavailable, workspace.connection != nil else { return }
    let probe = UUID()
    workspace.progressProbe = probe
    send(.probe(probe), to: workspace)
  }

  func acknowledgeProgress(_ workspace: Workspace) {
    workspace.progressProbe = nil
    workspace.progressDeadline = .now() + progressTimeout
    workspace.progressTimer?.schedule(deadline: workspace.progressDeadline)
    // Only one challenge is outstanding. The next challenge does not extend
    // the deadline: failure is detected within five seconds of last progress.
    queue.asyncAfter(deadline: .now() + min(1, progressTimeout / 2)) {
      [weak self, weak workspace] in
      guard let self, let workspace else { return }
      self.issueProgressProbe(workspace)
    }
  }
}
