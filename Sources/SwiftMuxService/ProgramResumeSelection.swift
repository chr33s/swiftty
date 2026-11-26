import Darwin
import SwiftMuxProtocol
import SwifttyEngine

/// One process as the resume selector needs it: parent, user, and start time
/// in microseconds since the epoch.
struct ProgramResumeProcessInfo: Equatable, Sendable {
  var ppid: Int32
  var uid: uid_t
  var start: UInt64
}

/// `proc_pidinfo` for resume selection. A missing process, including one
/// that has exited, is nil.
enum ProgramResumeProcess {
  static func lookup(_ pid: Int32) -> ProgramResumeProcessInfo? {
    guard pid > 0 else { return nil }
    var value = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &value, size) == size else {
      return nil
    }
    return ProgramResumeProcessInfo(
      ppid: Int32(truncatingIfNeeded: value.pbi_ppid),
      uid: value.pbi_uid,
      start: value.pbi_start_tvsec &* 1_000_000 &+ value.pbi_start_tvusec
    )
  }
}

/// The last owner this pane published, plus the start times captured when
/// each report was first seen. A recycled pid does not keep the old command.
struct ProgramResumeMemory: Equatable, Sendable {
  struct Start: Equatable, Sendable {
    var report: ProgramResumeReport
    var start: UInt64
  }

  struct Retention: Equatable, Sendable {
    var pid: Int32
    var exitedAt: ContinuousClock.Instant?
  }

  var starts: [Int32: Start] = [:]
  var retention: Retention?
}

/// Picks the one resume command for a pane. An ancestor beats a descendant.
/// Siblings produce no command. A just-exited owner is kept for `grace`
/// while the pane root is alive, and kept after that when the root itself
/// has exited.
enum ProgramResumeSelection {
  static let grace = Duration.seconds(2)
  static let maxHops = 16

  static func select(
    reports: [ProgramResumeReport],
    memory: inout ProgramResumeMemory,
    lookup: (Int32) -> ProgramResumeProcessInfo?,
    root: Int32,
    uid: uid_t,
    now: ContinuousClock.Instant
  ) -> SavedProgramResume? {
    if reports.isEmpty {
      memory.starts.removeAll()
      memory.retention = nil
      return nil
    }
    let byPID = Dictionary(
      reports.map { ($0.pid, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    memory.starts = memory.starts.filter { byPID[$0.key] != nil }
    let candidates = candidatesInTree(
      reports,
      memory: &memory,
      lookup: lookup,
      root: root,
      uid: uid
    )
    if let kept = retained(
      memory: &memory,
      reports: byPID,
      lookup: lookup,
      rootAlive: lookup(root) != nil,
      uid: uid,
      now: now
    ) {
      return kept
    }
    guard let winner = soleAncestor(candidates) else {
      memory.retention = nil
      return nil
    }
    let command = saved(winner.report)
    memory.retention = ProgramResumeMemory.Retention(
      pid: winner.report.pid,
      exitedAt: nil
    )
    return command.isRunnable ? command : nil
  }

  private struct Candidate {
    var report: ProgramResumeReport
    var chain: [Int32]
  }

  private static func candidatesInTree(
    _ reports: [ProgramResumeReport],
    memory: inout ProgramResumeMemory,
    lookup: (Int32) -> ProgramResumeProcessInfo?,
    root: Int32,
    uid: uid_t
  ) -> [Candidate] {
    var candidates: [Candidate] = []
    for report in reports {
      let info = lookup(report.pid)
      if let seen = memory.starts[report.pid] {
        if seen.report != report {
          if let info, info.uid == uid {
            memory.starts[report.pid] = ProgramResumeMemory.Start(
              report: report,
              start: info.start
            )
          } else {
            memory.starts[report.pid] = nil
            continue
          }
        } else if info?.start != seen.start {
          continue
        }
      } else if let info, info.uid == uid {
        memory.starts[report.pid] = ProgramResumeMemory.Start(
          report: report,
          start: info.start
        )
      } else {
        continue
      }
      guard let info, info.uid == uid,
        let chain = chain(of: report.pid, root: root, lookup: lookup)
      else { continue }
      candidates.append(Candidate(report: report, chain: chain))
    }
    return candidates
  }

  /// The stored report of an owner that has exited. Nil means choose normally.
  private static func retained(
    memory: inout ProgramResumeMemory,
    reports: [Int32: ProgramResumeReport],
    lookup: (Int32) -> ProgramResumeProcessInfo?,
    rootAlive: Bool,
    uid: uid_t,
    now: ContinuousClock.Instant
  ) -> SavedProgramResume? {
    guard let previous = memory.retention, let report = reports[previous.pid]
    else { return nil }
    let info = lookup(previous.pid)
    if let info, info.uid != uid { return nil }
    if let info, let seen = memory.starts[previous.pid], seen.report == report,
      seen.start != info.start
    {
      return nil
    }
    let dead = info == nil
    guard !rootAlive || dead else { return nil }
    if rootAlive {
      if memory.retention?.exitedAt == nil { memory.retention?.exitedAt = now }
      guard let exited = memory.retention?.exitedAt,
        exited.duration(to: now) < grace
      else { return nil }
    } else {
      memory.retention?.exitedAt = nil
    }
    let command = saved(report)
    return command.isRunnable ? command : nil
  }

  private static func soleAncestor(_ candidates: [Candidate]) -> Candidate? {
    candidates.filter { candidate in
      candidates.allSatisfy { $0.chain.contains(candidate.report.pid) }
    }
    .min { $0.chain.count < $1.chain.count }
  }

  private static func chain(
    of pid: Int32,
    root: Int32,
    lookup: (Int32) -> ProgramResumeProcessInfo?
  ) -> [Int32]? {
    var chain = [pid]
    var current = pid
    var hops = 0
    while current != root {
      if hops >= maxHops { return nil }
      guard let info = lookup(current) else { return nil }
      let parent = info.ppid
      if parent <= 0 || chain.contains(parent) { return nil }
      chain.append(parent)
      current = parent
      hops += 1
    }
    return chain
  }

  private static func saved(_ report: ProgramResumeReport) -> SavedProgramResume
  {
    SavedProgramResume(
      argv: report.argv,
      workingDirectory: report.workingDirectory
    )
  }
}
