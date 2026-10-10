/// OSC 7501 program status: reports, the support query, and lifecycle
/// cleanup, all applied in stream order (see `ProgramStatus.swift`).
extension TerminalState {
  /// `OSC 7501 ; data`. Ignored entirely (no reply) while disabled.
  internal mutating func programStatusCommand(
    _ data: UnsafeBufferPointer<UInt8>,
    terminator st: String
  ) {
    guard programStatusEnabled,
      let command = ProgramStatusCommand(data, terminatorBytes: st.utf8.count)
    else { return }
    if command == .query {
      // The support reply repeats the query, terminator included.
      if discardsReplies, answersProgramStatusWhileDiscarding {
        output.append(contentsOf: "\u{1B}]7501;?\(st)".utf8)
      } else {
        reply("\u{1B}]7501;?\(st)")
      }
    } else if programStatus.apply(command) {
      programStatusChanged = true
    }
  }

  /// OSC 133 ; A starting a new prompt: the previous command is over.
  internal mutating func programStatusPromptStarted() {
    if programStatus.removeTransient() { programStatusChanged = true }
  }

  /// The program on this terminal exited (or the transport closed)
  /// without a final prompt: drops `working`, `blocked` and `idle`
  /// records. Never invents `done` or `error`. `TerminalSession` calls
  /// this when its child exits; external transports call it themselves.
  /// Also releases synchronized output, ends tmux control mode and
  /// discards an unfinished DCS request.
  public mutating func programExited() {
    discardControlString()
    if modes.contains(.synchronizedOutput) {
      modes.remove(.synchronizedOutput)
      damage.setFull()
    }
    if programStatus.removeTransient() { programStatusChanged = true }
  }

  /// RIS for reconstructing a screen the program drew elsewhere (e.g.
  /// replaying a tmux capture): everything but the OSC 7501 records,
  /// which no program retracted.
  public mutating func resetPreservingProgramStatus() {
    let status = programStatus
    let changed = programStatusChanged
    fullReset()
    programStatus = status
    programStatusChanged = changed
  }

  /// Replaces the records with `snapshot`'s (e.g. ones a stand-in
  /// terminal collected while this one was being reconstructed). Record
  /// revisions are kept; the store's revision never goes backwards.
  public mutating func replaceProgramStatus(
    with snapshot: ProgramStatusSnapshot
  ) {
    guard programStatusEnabled, programStatus.replaceAll(with: snapshot) else {
      return
    }
    programStatusChanged = true
  }

  /// The current records if they changed since the last call.
  public mutating func takeProgramStatusChange() -> ProgramStatusSnapshot? {
    guard programStatusChanged else { return nil }
    programStatusChanged = false
    return programStatus.snapshot
  }
}
