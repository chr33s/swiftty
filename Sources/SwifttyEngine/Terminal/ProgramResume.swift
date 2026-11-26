/// One accepted OSC 7577 resume command (spec.md, OSC 7577 program resume).
/// The argv is what a chosen saved-layout slot may start. It is not a live
/// process and it does not include the token.
public struct ProgramResumeReport: Sendable, Equatable {
  public var pid: Int32
  public var argv: [String]
  /// Present only when the report sent `cwd`.
  public var workingDirectory: String?
  public var time: Int64

  public init(
    pid: Int32,
    argv: [String],
    workingDirectory: String?,
    time: Int64
  ) {
    self.pid = pid
    self.argv = argv
    self.workingDirectory = workingDirectory
    self.time = time
  }
}

/// Accepted OSC 7577 records for one pane. RIS, DECSTR, and every other
/// terminal sequence leave this store alone: those sequences are not
/// authenticated, so they must not drop a command.
struct ProgramResumeStore: Equatable {
  static let capacity = 64

  struct Record: Equatable {
    var argv: [String]
    var workingDirectory: String?
    var time: Int64

    init(_ report: ProgramResumeReport) {
      argv = report.argv
      workingDirectory = report.workingDirectory
      time = report.time
    }
  }

  private(set) var records: [Int32: Record] = [:]
  /// Latest accepted time for a pid, including a `clear`, so an older
  /// report cannot replace it. Entries older than the 60-second window
  /// are dropped.
  private(set) var lastAccepted: [Int32: Int64] = [:]

  var isEmpty: Bool { records.isEmpty && lastAccepted.isEmpty }

  var reports: [ProgramResumeReport] {
    records.keys.sorted()
      .map { pid in
        let record = records[pid]!
        return ProgramResumeReport(
          pid: pid,
          argv: record.argv,
          workingDirectory: record.workingDirectory,
          time: record.time
        )
      }
  }

  @discardableResult
  mutating func apply(_ decision: ProgramResumeParse.Decision) -> Bool {
    switch decision {
    case .ignore: return false
    case let .reject(pid):
      guard let pid else { return false }
      return records.removeValue(forKey: pid) != nil
    case let .accept(report):
      let replacing = records[report.pid] != nil
      guard replacing || records.count < Self.capacity else { return false }
      let next = Record(report)
      let changed = records[report.pid] != next
      records[report.pid] = next
      remember(report.pid, time: report.time)
      return changed
    case let .clear(pid, time):
      let removed = records.removeValue(forKey: pid) != nil
      remember(pid, time: time)
      return removed
    }
  }

  private mutating func remember(_ pid: Int32, time: Int64) {
    if lastAccepted[pid] == nil, lastAccepted.count >= Self.capacity,
      let oldest = lastAccepted.min(by: { $0.value < $1.value })?.key
    {
      lastAccepted[oldest] = nil
    }
    lastAccepted[pid] = time
  }

  mutating func prune(now: Int64) {
    let (cutoff, overflow) = now.subtractingReportingOverflow(60)
    guard !overflow else { return }
    lastAccepted = lastAccepted.filter { $0.value >= cutoff }
  }
}

extension ProgramResumeStore {
  func checkpoint(into w: inout CheckpointWriter) {
    let records = records.sorted { $0.key < $1.key }
    w.int(records.count)
    for (pid, record) in records {
      w.int(Int(pid))
      w.int(Int(record.time))
      w.int(record.argv.count)
      for argument in record.argv { w.string(argument) }
      w.optionalString(record.workingDirectory)
    }
    let accepted = lastAccepted.sorted { $0.key < $1.key }
    w.int(accepted.count)
    for (pid, time) in accepted {
      w.int(Int(pid))
      w.int(Int(time))
    }
  }

  mutating func restore(from r: inout CheckpointReader) throws(CheckpointError)
  {
    let count = try r.count(max: Self.capacity)
    var records: [Int32: Record] = [:]
    for _ in 0 ..< count {
      let pid = try Self.pid(try r.int())
      guard records[pid] == nil else {
        throw CheckpointError("duplicate resume pid")
      }
      let time = Int64(try r.int())
      let argc = try r.count(max: ProgramResumeParse.maxArgv)
      var argv: [String] = []
      argv.reserveCapacity(argc)
      for _ in 0 ..< argc {
        argv.append(try r.string(max: ProgramResumeParse.commandLimit))
      }
      let directory = try r.optionalString(max: ProgramResumeParse.commandLimit)
      records[pid] = Record(
        ProgramResumeReport(
          pid: pid,
          argv: argv,
          workingDirectory: directory,
          time: time
        )
      )
    }
    let acceptedCount = try r.count(max: Self.capacity)
    var accepted: [Int32: Int64] = [:]
    for _ in 0 ..< acceptedCount {
      let pid = try Self.pid(try r.int())
      guard accepted[pid] == nil else {
        throw CheckpointError("duplicate resume time")
      }
      accepted[pid] = Int64(try r.int())
    }
    self.records = records
    lastAccepted = accepted
  }

  private static func pid(_ value: Int) throws(CheckpointError) -> Int32 {
    guard let pid = Int32(exactly: value), pid > 0 else {
      throw CheckpointError("resume pid")
    }
    return pid
  }
}
