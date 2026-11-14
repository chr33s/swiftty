import Darwin
import Dispatch
import Foundation
import MuxAttention
import SwiftMuxExport
import SwiftMuxProtocol
import SwifttyEngine
import SwifttyJS
import Synchronization

/// Admitted input, paste transactions and the bounded PTY write path.
extension PaneRuntime {
  // MARK: Input

  /// Admission happened in the service; `estimate` was reserved.
  func write(_ input: MuxInput, estimate: Int) {
    queue.async { [self] in
      noteScrollbackActivity()
      guard master >= 0, exitStatus == nil else {
        release(estimate)
        return
      }
      var bytes: [UInt8] = []
      let terminalInputs: [TerminalInput] =
        switch input {
        case let .text(s): [.text(s)]
        case let .key(key, mods):
          [.key(KeyEvent(Self.key(key), modifiers: Self.modifiers(mods)))]
        case let .focus(f): [.focus(f)]
        case let .paste(s): [.paste(s)]
        case let .mouse(m):
          // Reported only while the program asks; the frontend's view of
          // the modes may be a frame behind.
          state.modes.isDisjoint(with: .mouseTracking)
            ? [] : [.mouse(Self.mouse(m))]
        case let .moveCursor(address, column):
          promptClick(to: address, column: column)
        case let .clipboardPaste(types):
          // Nothing when the program turned paste events off meanwhile.
          state.kittyPasteEvent(available: types).map { [.bytes($0)] } ?? []
        case let .drag(drag): dragReport(drag).map { [.bytes($0)] } ?? []
        }
      // Enhanced keyboard reporting is disabled in this profile.
      for terminalInput in terminalInputs {
        InputEncoder.encode(
          terminalInput,
          modes: state.modes,
          keyboardFlags: 0,
          into: &bytes,
        )
      }
      switch input {
      case .focus, .mouse, .drag: break
      case .moveCursor where bytes.isEmpty: break
      default:
        guard state.viewportOffset != 0 else { break }
        state.scrollViewportToBottom()
        advanceViewport()
        noteChange()
      }
      var reserved = estimate
      if let javaScriptRuntime {
        let filtered = javaScriptRuntime.filter(
          Data(bytes),
          stream: .stdin,
          pane: id.description,
          maximumBytes: limits.inputBytesPerPane
        )
        if filtered.count <= estimate {
          bytes = Array(filtered)
        } else if reserve(filtered.count - estimate) {
          reserved = filtered.count
          bytes = Array(filtered)
        }
      }
      adjust(by: bytes.count - reserved)
      guard !bytes.isEmpty else { return }
      writer.appendInput(bytes)
      flush()
    }
  }

  /// Arrow keys moving the shell's cursor to a cell of its command line,
  /// or its `click_events` report; none when the address is stale or
  /// outside it.
  private func promptClick(
    to address: HistoryAddress,
    column: Int
  ) -> [TerminalInput] {
    guard address.generation == state.addressingGeneration,
      address.alternateScreen == state.isAlternateScreen,
      let action = state.promptClickAction(
        at: TerminalPoint(row: address.row, column: column)
      )
    else { return [] }
    let moves: Int
    switch action {
    case let .report(bytes): return [.bytes(bytes)]
    case let .moves(count): moves = count
    }
    guard moves.magnitude <= MuxInput.maxCursorMoves else { return [] }
    return Array(
      repeating: .key(KeyEvent(moves < 0 ? .left : .right)),
      count: Int(moves.magnitude)
    )
  }

  static func mouse(_ m: MuxMouse) -> MouseEvent {
    let action: MouseEvent.Action =
      switch m.action {
      case .press: .press
      case .release: .release
      case .motion: .motion
      }
    let button: MouseEvent.Button =
      switch m.button {
      case .left: .left
      case .middle: .middle
      case .right: .right
      case .none: .none
      case .wheelUp: .wheelUp
      case .wheelDown: .wheelDown
      case .wheelLeft: .wheelLeft
      case .wheelRight: .wheelRight
      }
    return MouseEvent(
      action,
      button,
      column: max(0, m.column),
      row: max(0, m.row),
      modifiers: modifiers(m.modifiers)
    )
  }

  func pasteBegin(id: UInt64, estimate: Int) {
    queue.async { [self] in
      guard master >= 0, !finished, !writer.hasOpenPaste else {
        release(estimate)
        return
      }
      if state.viewportOffset != 0 {
        state.scrollViewportToBottom()
        advanceViewport()
        noteChange()
      }
      let before = writer.pendingInputBytes
      writer.beginPaste(
        id: id,
        bracketed: state.modes.contains(.bracketedPaste),
      )
      adjust(by: (writer.pendingInputBytes - before) - estimate)
      flush()
    }
  }

  func pasteChunk(id: UInt64, text: String, estimate: Int) {
    queue.async { [self] in
      guard master >= 0, !finished, writer.paste?.id == id else {
        release(estimate)
        return
      }
      var payload = text
      var reserved = estimate
      if let javaScriptRuntime {
        let filtered = javaScriptRuntime.filter(
          Data(text.utf8),
          stream: .stdin,
          pane: self.id.description,
          maximumBytes: limits.inputBytesPerPane / 2
        )
        let estimateAfterFilter =
          filtered.count + filtered.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        if estimateAfterFilter <= estimate {
          payload = String(decoding: filtered, as: UTF8.self)
        } else if reserve(estimateAfterFilter - reserved) {
          reserved = estimateAfterFilter
          payload = String(decoding: filtered, as: UTF8.self)
        }
      }
      let before = writer.pendingInputBytes
      writer.appendPaste(id: id, text: payload)
      adjust(by: (writer.pendingInputBytes - before) - reserved)
      flush()
    }
  }

  func pasteEnd(id: UInt64) {
    queue.async { [self] in
      writer.endPaste(id: id)
      flush()
    }
  }

  /// Disconnect, cancellation or limit failure. `completion` reports the
  /// outcome by what reached the program: `partial` once any payload
  /// byte was written (it cannot be rolled back), `aborted` when none was.
  /// A cancelled paste is never `completed`: its sender gave up on the
  /// rest, as the client reports it.
  func pasteCancel(
    id: UInt64,
    discardDeferredInput: Bool = false,
    completion: @escaping @Sendable (PasteState) -> Void,
  ) {
    queue.async { [self] in
      let (discarded, wrote) = writer.cancelPaste(
        id: id,
        discardDeferredInput: discardDeferredInput
      )
      release(discarded)
      flush()
      completion(wrote ? .partial : .aborted)
    }
  }

  /// Drops this pane's unwritten user input. Queued ahead of any later
  /// writer's bytes when a lease is released.
  func discardUnwrittenInput() {
    queue.async { [self] in
      release(writer.discardUnwrittenInput())
      flush()
    }
  }

  func flush() {
    guard master >= 0 else { return }
    let fd = master
    guard
      let released = writer.flush({ buffer in
        var offset = 0
        while offset < buffer.count {
          let n = Darwin.write(
            fd,
            buffer.baseAddress! + offset,
            buffer.count - offset,
          )
          if n > 0 {
            observeIO(
              .written,
              bytes: UnsafeRawBufferPointer(
                rebasing: buffer[offset ..< offset + n]
              )
            )
            offset += n
            continue
          }
          if n < 0, errno == EINTR { continue }
          if n < 0, errno == EAGAIN {
            observeIO(
              .writeBlocked,
              bytes: UnsafeRawBufferPointer(rebasing: buffer[offset...]),
              error: errno
            )
            break
          }
          observeIO(
            .writeFailed,
            bytes: UnsafeRawBufferPointer(rebasing: buffer[offset...]),
            error: n < 0 ? errno : nil
          )
          return offset > 0 ? offset : nil
        }
        return offset
      })
    else {
      release(writer.discardAll())
      setWriteActive(false)
      if !readSourceActive { readAvailable() }
      return
    }
    release(released)
    setWriteActive(!writer.isEmpty)
    if !readSourceActive { readAvailable() }
  }

  func setWriteActive(_ active: Bool) {
    guard let writeSource, active != writeActive else { return }
    writeActive = active
    if active { writeSource.resume() } else { writeSource.suspend() }
  }

  func observeIO(
    _ phase: PaneIOObservation.Phase,
    bytes: UnsafeRawBufferPointer,
    error: Int32? = nil
  ) {
    guard let observePaneIO else { return }
    observePaneIO(
      id,
      PaneIOObservation(
        phase: phase,
        byteCount: bytes.count,
        prefix: Array(bytes.prefix(256)),
        error: error
      )
    )
  }

  func release(_ n: Int) { adjust(by: -n) }

  private func adjust(by delta: Int) {
    guard delta != 0 else { return }
    outstandingInput.withLock { $0 = max(0, $0 + delta) }
  }

  /// Reserves credit for admission; false when over the per-pane budget.
  func reserve(_ bytes: Int) -> Bool {
    outstandingInput.withLock { value in
      guard value + bytes <= limits.inputBytesPerPane else { return false }
      value += bytes
      return true
    }
  }

  // MARK: Input mapping

  static func key(_ key: MuxKey) -> Key {
    switch key {
    case let .character(v): .character(Unicode.Scalar(v) ?? " ")
    case .enter: .enter
    case .tab: .tab
    case .backspace: .backspace
    case .escape: .escape
    case .up: .up
    case .down: .down
    case .left: .left
    case .right: .right
    case .home: .home
    case .end: .end
    case .pageUp: .pageUp
    case .pageDown: .pageDown
    case .insert: .insert
    case .delete: .delete
    case let .function(n): .function(min(max(n, 1), 12))
    case let .keypad(k):
      KeypadKey(rawValue: k.rawValue).map(Key.keypad) ?? .enter
    }
  }

  static func modifiers(_ m: MuxKeyModifiers) -> KeyModifiers {
    var out: KeyModifiers = []
    if m.contains(.shift) { out.insert(.shift) }
    if m.contains(.alt) { out.insert(.alt) }
    if m.contains(.control) { out.insert(.control) }
    return out
  }
}
