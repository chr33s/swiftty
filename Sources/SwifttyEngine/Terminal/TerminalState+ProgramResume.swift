import Foundation

extension TerminalCheckpoint { static let programResumeSection: UInt8 = 16 }

extension TerminalState {
  /// Accepted OSC 7577 commands, oldest pid first.
  public var programResumeReports: [ProgramResumeReport] {
    programResume.reports
  }

  /// True when accepted resume records changed since the last call.
  package mutating func takeProgramResumeChange() -> Bool {
    defer { programResumeChanged = false }
    return programResumeChanged
  }

  /// `OSC 7577 ; body`. No reply. A missing token ignores the report
  /// without parsing it. The command runs only later, for a slot the user
  /// chose, after this process is gone.
  package mutating func programResumeCommand(
    _ data: UnsafeBufferPointer<UInt8>,
    sequenceBytes: Int
  ) {
    guard let token = programResumeToken else { return }
    let now = programResumeTime ?? Int64(Date().timeIntervalSince1970)
    programResume.prune(now: now)
    let decision = ProgramResumeParse.decide(
      body: Array(data),
      sequenceBytes: sequenceBytes,
      token: token,
      now: now,
      lastAccepted: programResume.lastAccepted
    )
    if programResume.apply(decision) { programResumeChanged = true }
  }

  func checkpointProgramResume(into w: inout CheckpointWriter) {
    guard programResumeToken != nil || !programResume.isEmpty else { return }
    var nested = CheckpointWriter()
    nested.optionalString(programResumeToken)
    programResume.checkpoint(into: &nested)
    w.u8(TerminalCheckpoint.programResumeSection)
    w.data(nested.bytes)
  }

  mutating func restoreProgramResume(
    from r: inout CheckpointReader
  ) throws(CheckpointError) {
    guard r.peekU8() == TerminalCheckpoint.programResumeSection else { return }
    var section = try r.section(TerminalCheckpoint.programResumeSection)
    programResumeToken = try section.optionalString(max: 64)
    try programResume.restore(from: &section)
    try section.finish()
  }
}
