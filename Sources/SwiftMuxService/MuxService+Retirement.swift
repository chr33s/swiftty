import Dispatch
import SwiftMuxProtocol

extension MuxService {
  func retirePaneRecord(_ id: PaneID) {
    guard let record = panes.removeValue(forKey: id) else { return }
    retirePane(record.runtime)
  }

  func retirePane(_ runtime: PaneRuntime) {
    guard retiringPanes[runtime.id] == nil else { return }
    retiringPanes[runtime.id] = runtime
    attemptRetirement(runtime)
  }

  private func attemptRetirement(_ runtime: PaneRuntime) {
    runtime.retire { [weak self] error in
      self?
        .onQueue { service in
          guard service.retiringPanes[runtime.id] === runtime else { return }
          if let error {
            if error.code == .resourceLimit {
              // Explicit non-admission: one retry timer per retained pane.
              // Unknown outcomes never enter this path.
              service.queue.asyncAfter(deadline: .now() + .milliseconds(50)) {
                [weak service] in
                service?.onQueue { owner in owner.attemptRetirement(runtime) }
              }
            } else {
              service.retirementFailures[runtime.id] = error
            }
            return
          }
          service.retiringPanes.removeValue(forKey: runtime.id)
          service.retirementFailures.removeValue(forKey: runtime.id)
          service.checkIdle()
        }
    }
  }
}
