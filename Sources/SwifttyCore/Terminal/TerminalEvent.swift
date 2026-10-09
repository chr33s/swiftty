/// Side effects the frontend must handle, drained after each parse batch.
public enum TerminalEvent: Sendable, Equatable {
    case title(String)
    case bell
    case clipboard(String)
    case workingDirectory(String)
    /// Child exit status, or -1 when it cannot be collected (for example,
    /// another child reaper in the embedding application collected it).
    case exited(Int32)
    /// `DCS 1000 p`: tmux control mode began; its stream follows through
    /// `TerminalState.controlModeData` until `.controlModeEnded`.
    case controlModeStarted
    case controlModeEnded
    /// OSC 9 / OSC 777;notify desktop notification.
    case notification(title: String, body: String)
    /// OSC 9;4 progress: state 0 remove, 1 set, 2 error, 3 indeterminate,
    /// 4 pause; `percent` is nil when not given.
    case progress(state: Int, percent: Int?)
    /// OSC 22: the application asked for this mouse pointer shape (a CSS
    /// cursor name such as `text`, `pointer`, `default`).
    case pointerShape(String)
    /// OSC 133 ; D: a command finished with this exit status (the latest,
    /// once per batch).
    case commandFinished(exitCode: Int?)
}
