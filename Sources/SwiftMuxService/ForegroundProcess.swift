import Darwin
import SwifttyJS

/// Reads a pane's foreground process group from the kernel. The pane's
/// program (`root`) records its terminal's foreground group (`e_tpgid`),
/// so no PTY descriptor is needed and nothing is signalled or waited on.
enum ForegroundProcess {
  struct Report: Equatable {
    var foreground: JavaScriptEvent.Process?
    var ancestors: [JavaScriptEvent.Process]

    /// Identity for change detection: an `exec` keeps the pid but not the
    /// name; a cwd move alone is not a change.
    var key: [String] {
      ([foreground].compactMap { $0 } + ancestors)
        .map { "\($0.pid) \($0.name)" }
    }
  }

  static let maxAncestors = 16

  static func report(root: pid_t) -> Report {
    guard root > 0, let rootInfo = info(root) else {
      return Report(foreground: nil, ancestors: [])
    }
    let group = pid_t(rootInfo.e_tpgid)
    guard group > 0, let leader = info(group) else {
      return Report(foreground: nil, ancestors: [])
    }
    let foreground = process(group, leader, cwd: true)
    var ancestors: [JavaScriptEvent.Process] = []
    var current = leader
    var pid = group
    // Parents up to the pane's program; a group outside its tree (or the
    // program itself at a prompt) has no ancestors to report.
    while pid != root, ancestors.count < maxAncestors {
      let parent = pid_t(current.pbi_ppid)
      guard parent > 1, let parentInfo = info(parent) else {
        ancestors.removeAll()
        break
      }
      ancestors.append(process(parent, parentInfo, cwd: false))
      pid = parent
      current = parentInfo
    }
    if pid != root { ancestors.removeAll() }
    return Report(foreground: foreground, ancestors: ancestors)
  }

  private static func info(_ pid: pid_t) -> proc_bsdinfo? {
    var value = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &value, size) == size else {
      return nil
    }
    return value
  }

  private static func process(
    _ pid: pid_t,
    _ info: proc_bsdinfo,
    cwd: Bool
  ) -> JavaScriptEvent.Process {
    var info = info
    let long = withUnsafeBytes(of: &info.pbi_name) { string($0) }
    let short = withUnsafeBytes(of: &info.pbi_comm) { string($0) }
    return JavaScriptEvent.Process(
      pid: pid,
      name: long.isEmpty ? short : long,
      cwd: cwd ? directory(pid) : nil
    )
  }

  private static func directory(_ pid: pid_t) -> String? {
    var value = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &value, size) == size
    else { return nil }
    let path = withUnsafeBytes(of: &value.pvi_cdir.vip_path) { string($0) }
    return path.isEmpty ? nil : path
  }

  private static func string(_ bytes: UnsafeRawBufferPointer) -> String {
    let end = bytes.firstIndex(of: 0) ?? bytes.count
    return String(decoding: bytes[..<end], as: UTF8.self)
  }
}
