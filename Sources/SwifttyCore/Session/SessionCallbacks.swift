import Foundation

/// Handlers can be replaced from any thread, including during invocation.
final class SessionCallbacks: @unchecked Sendable {
  struct State: Sendable {
    var onUpdate: (@Sendable () -> Void)?
    var onUpdateRevision: UInt64 = 0
    var onEvent: (@Sendable (TerminalEvent) -> Void)?
    var onWrite: (@Sendable ([UInt8]) -> Void)?
    var onTerminalReply: (@Sendable ([UInt8]) -> Void)?
    var onProgramStatusChange: (@Sendable (ProgramStatusSnapshot) -> Void)?
    var onStateChange: (@Sendable (borrowing TerminalState) -> Void)?
    var onProgramOutput: (@Sendable ([UInt8]) -> Void)?
    var onControlModeData: (@Sendable ([UInt8]) -> Void)?
  }

  private let lock = NSLock()
  private var state = State()

  /// Copy handlers while locked to avoid reabstraction allocations. Release
  /// replaced handlers after unlocking so captured deinitializers can set
  /// callbacks.
  var onUpdate: (@Sendable () -> Void)? {
    get {
      lock.lock()
      let handler = state.onUpdate
      lock.unlock()
      return handler
    }
    set {
      lock.lock()
      let previous = state.onUpdate
      state.onUpdate = newValue
      state.onUpdateRevision &+= 1
      lock.unlock()
      withExtendedLifetime(previous) {}
    }
  }

  /// Capture the handler and its identity together so replacing a handler
  /// cannot inherit a redraw notification delivered to the previous one.
  var updateHandler: (handler: (@Sendable () -> Void)?, revision: UInt64) {
    lock.lock()
    let handler = state.onUpdate
    let revision = state.onUpdateRevision
    lock.unlock()
    return (handler, revision)
  }

  var onEvent: (@Sendable (TerminalEvent) -> Void)? {
    get {
      lock.lock()
      let handler = state.onEvent
      lock.unlock()
      return handler
    }
    set {
      lock.lock()
      let previous = state.onEvent
      state.onEvent = newValue
      lock.unlock()
      withExtendedLifetime(previous) {}
    }
  }

  var onWrite: (@Sendable ([UInt8]) -> Void)? {
    get {
      lock.lock()
      let handler = state.onWrite
      lock.unlock()
      return handler
    }
    set {
      lock.lock()
      let previous = state.onWrite
      state.onWrite = newValue
      lock.unlock()
      withExtendedLifetime(previous) {}
    }
  }

  var onTerminalReply: (@Sendable ([UInt8]) -> Void)? {
    get {
      lock.lock()
      let handler = state.onTerminalReply
      lock.unlock()
      return handler
    }
    set {
      lock.lock()
      let previous = state.onTerminalReply
      state.onTerminalReply = newValue
      lock.unlock()
      withExtendedLifetime(previous) {}
    }
  }

  var onProgramStatusChange: (@Sendable (ProgramStatusSnapshot) -> Void)? {
    get {
      lock.lock()
      let handler = state.onProgramStatusChange
      lock.unlock()
      return handler
    }
    set {
      lock.lock()
      let previous = state.onProgramStatusChange
      state.onProgramStatusChange = newValue
      lock.unlock()
      withExtendedLifetime(previous) {}
    }
  }

  var onStateChange: (@Sendable (borrowing TerminalState) -> Void)? {
    get {
      lock.lock()
      let handler = state.onStateChange
      lock.unlock()
      return handler
    }
    set {
      lock.lock()
      let previous = state.onStateChange
      state.onStateChange = newValue
      lock.unlock()
      withExtendedLifetime(previous) {}
    }
  }

  var onProgramOutput: (@Sendable ([UInt8]) -> Void)? {
    get {
      lock.lock()
      let handler = state.onProgramOutput
      lock.unlock()
      return handler
    }
    set {
      lock.lock()
      let previous = state.onProgramOutput
      state.onProgramOutput = newValue
      lock.unlock()
      withExtendedLifetime(previous) {}
    }
  }

  var onControlModeData: (@Sendable ([UInt8]) -> Void)? {
    get {
      lock.lock()
      let handler = state.onControlModeData
      lock.unlock()
      return handler
    }
    set {
      lock.lock()
      let previous = state.onControlModeData
      state.onControlModeData = newValue
      lock.unlock()
      withExtendedLifetime(previous) {}
    }
  }
}
