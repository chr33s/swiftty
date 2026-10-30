#if os(macOS)
import Darwin
import Dispatch

/// Owns reaping after the session releases its PTY. Mutable fields belong
/// to the private queue. Sources retain the owner until it cancels both;
/// no session or PTY descriptor is held during the grace period.
///
/// Sendable: `exitSource`, `timer`, `finished` and `forced` are touched only
/// on `queue`; `pid` and `killAfter` are immutable. The instance lives until
/// `finish` cancels both sources on `queue`.
package final class PTYProcessShutdown: @unchecked Sendable {
  private let pid: pid_t
  private let queue = DispatchQueue(
    label: "swiftty.pty-shutdown",
    qos: .utility,
  )
  private let killAfter = DispatchTime.now() + .seconds(2)
  private var exitSource: DispatchSourceProcess?
  private var timer: DispatchSourceTimer?
  private var finished = false
  private var forced = false

  private init(pid: pid_t) { self.pid = pid }

  /// The caller has sent SIGHUP and transfers exclusive child reaping here.
  package static func start(_ pid: pid_t) {
    let shutdown = PTYProcessShutdown(pid: pid)
    shutdown.queue.async { shutdown.observe() }
  }

  private func observe() {
    let exit = DispatchSource.makeProcessSource(
      identifier: pid,
      eventMask: .exit,
      queue: queue,
    )
    exit.setEventHandler { [self] in check() }
    exitSource = exit
    exit.resume()

    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(
      deadline: .now() + .milliseconds(50),
      repeating: .milliseconds(50),
    )
    timer.setEventHandler { [self] in check() }
    self.timer = timer
    timer.resume()
    // Also collects a child that exited before the source was registered.
    check()
  }

  private func check() {
    guard !finished else { return }
    var info = siginfo_t()
    var peek: Int32
    repeat {
      peek = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
    } while peek < 0 && errno == EINTR
    // Loss of ownership must cancel observation before any more signals.
    guard peek == 0 else {
      finish();
      return
    }
    let exited = info.si_pid == pid
    if !forced, DispatchTime.now() >= killAfter {
      forced = true
      // Keep the owned leader uncollected through escalation so its PID
      // cannot be reused as an unrelated process or process-group ID.
      kill(-pid, SIGKILL)
      kill(pid, SIGKILL)
    }
    guard exited else { return }
    if !forced {
      var members = [pid_t](repeating: 0, count: 2)
      let count = members.withUnsafeMutableBytes {
        proc_listpgrppids(pid, $0.baseAddress, Int32($0.count))
      }
      // A truncated or failed query cannot establish that the group is
      // empty except for the leader. Retain ownership until escalation.
      guard count == 1, members[0] == pid else { return }
    }
    var result: pid_t
    repeat {
      result = waitpid(pid, nil, WNOHANG)
    } while result < 0 && errno == EINTR
    if result != 0 { finish() }
  }

  private func finish() {
    finished = true
    exitSource?.cancel()
    exitSource = nil
    timer?.cancel()
    timer = nil
  }
}
#endif
