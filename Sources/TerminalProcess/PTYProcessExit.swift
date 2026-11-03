#if os(macOS)
import Darwin

/// Observes an owned child's exit without collecting it or locking its
/// controlling terminal. The caller retains exclusive reaping authority.
package enum PTYProcessExit {
  package static func hasStartedExiting(_ pid: pid_t) -> Bool {
    var info = proc_bsdshortinfo()
    let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
    let result = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size)
    let profileError = errno
    if result == size, info.pbsi_pid == UInt32(pid),
      info.pbsi_ppid == UInt32(getpid()),
      info.pbsi_flags & UInt32(PROC_FLAG_INEXIT) != 0
    {
      return true
    }
    guard result == 0, profileError == ESRCH else { return false }
    // Late exit can remove the process from libproc's active table before
    // waitid fills si_pid. Darwin may withhold that status until the
    // controlling terminal drains, so si_pid 0 here is the unreaped child,
    // not a live process. A live child still has a proc row and returned
    // above. ECHILD or another pid is not our child.
    var child = siginfo_t()
    var owned: Int32
    repeat {
      owned = waitid(P_PID, id_t(pid), &child, WEXITED | WNOHANG | WNOWAIT)
    } while owned < 0 && errno == EINTR
    return owned == 0 && (child.si_pid == pid || child.si_pid == 0)
  }
}
#endif
