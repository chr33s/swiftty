#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

struct JobID: Hashable, Sendable { let value: UInt64 }

enum ProcessResult: Equatable, Sendable {
  case exited(Int32)
  case signaled(Int32)
  var status: Int32 {
    switch self {
    case .exited(let status): status
    case .signaled(let signal): 128 + signal
    }
  }
}

enum StageState: Equatable, Sendable {
  case running(pid_t)
  case stopped(pid_t, Int32)
  case awaitingContinuation(pid_t)
  case finished(ProcessResult)

  var pid: pid_t? {
    switch self {
    case .running(let pid), .stopped(let pid, _),
      .awaitingContinuation(let pid):
      pid
    case .finished: nil
    }
  }
  var isStopped: Bool { if case .stopped = self { true } else { false } }
}

struct JobRecord {
  let id: JobID
  var stages: [StageState]
  var assembling = true
  var group: pid_t?
  var setupSuspended = false
  var savedModes: termios?
  var background = false
  /// `set -o pipefail` at launch: report the last failing stage.
  var pipefail = false

  enum Disposition: Equatable {
    case running, stopped
    case completed(ProcessResult)
  }

  var disposition: Disposition {
    guard !assembling else { return .running }
    let live = stages.filter { $0.pid != nil }
    if live.isEmpty, case .finished(let last) = stages.last {
      guard pipefail, last.status == 0 else { return .completed(last) }
      for case .finished(let result) in stages.reversed()
      where result.status != 0 { return .completed(result) }
      return .completed(last)
    }
    if !setupSuspended && !live.isEmpty && live.allSatisfy(\.isStopped) {
      return .stopped
    }
    return .running
  }
}
