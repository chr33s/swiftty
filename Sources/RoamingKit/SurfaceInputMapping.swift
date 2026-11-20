import SessionCore
import SwifttyEngine
import Synchronization

// Frontend input from a presentation-mode `TerminalSession`
// (`semanticInputHandler`) mapped onto the semantic operations a roaming
// client submits (spec §8, §A.4.4).

extension SemanticModifiers {
  /// Shift, Alt and Control. Command never reaches a remote terminal: it
  /// selects local shortcuts.
  public init(_ modifiers: KeyModifiers) {
    var out = SemanticModifiers()
    if modifiers.contains(.shift) { out.insert(.shift) }
    if modifiers.contains(.alt) { out.insert(.alt) }
    if modifiers.contains(.control) { out.insert(.control) }
    self = out
  }
}

extension SemanticKeyName {
  /// The semantic name of a frontend key, or `nil` for keys RST/1 cannot
  /// carry (function keys outside F1–F12, control-character scalars).
  public init?(_ key: Key) {
    switch key {
    case let .character(scalar):
      // C0/C1 controls and DEL are produced by the host's encoder from a
      // key plus Control, never sent as characters.
      guard scalar.value >= 0x20, scalar.value != 0x7F,
        !(0x80 ... 0x9F).contains(scalar.value)
      else { return nil }
      self = .character(scalar)
    case .enter: self = .enter
    case .tab: self = .tab
    case .backspace: self = .backspace
    case .escape: self = .escape
    case .up: self = .up
    case .down: self = .down
    case .left: self = .left
    case .right: self = .right
    case .home: self = .home
    case .end: self = .end
    case .pageUp: self = .pageUp
    case .pageDown: self = .pageDown
    case .insert: self = .insert
    case .delete: self = .delete
    case let .function(n):
      guard (1 ... 12).contains(n) else { return nil }
      self = .function(n)
    case let .keypad(key):
      // `RoamingClient` sends the main-keyboard key to hosts without
      // `keypadKeys`.
      guard let keypad = SemanticKeypadKey(rawValue: key.rawValue) else {
        return nil
      }
      self = .keypad(keypad)
    }
  }
}

extension SemanticKey {
  /// The semantic key for a frontend key event, or `nil` when the event
  /// must not become remote input: releases, Command shortcuts, and keys
  /// `SemanticKeyName` cannot represent. Presses and repeats map alike;
  /// the host encodes the result with its own terminal modes.
  public init?(_ event: KeyEvent) {
    guard event.action != .release, !event.modifiers.contains(.command),
      let name = SemanticKeyName(event.key)
    else { return nil }
    self.init(name, modifiers: SemanticModifiers(event.modifiers))
  }
}

extension SurfaceInput {
  /// The semantic input for a presentation session's frontend input, or
  /// `nil` for input that never reaches the host: empty text, mouse and
  /// focus reports, raw bytes, and unmappable keys.
  public init?(_ input: TerminalInput) {
    switch input {
    case let .text(text):
      guard !text.isEmpty else { return nil }
      self = .text(text)
    case let .paste(text):
      guard !text.isEmpty else { return nil }
      self = .paste(text)
    case let .key(event):
      guard let key = SemanticKey(event) else { return nil }
      self = .key(key)
    case .mouse, .focus, .bytes: return nil
    }
  }
}

/// Submits input in arrival order from any thread to an asynchronous
/// consumer (a `RoamingClient`), one operation at a time.
///
/// Frontend callbacks are synchronous; spawning one task per key would
/// let operations race. The pump keeps a bounded FIFO and a single
/// draining task. Input beyond `limit` is refused immediately and
/// reported, never silently dropped or queued without bound (spec §8).
public final class OrderedInputPump: Sendable {
  public static let defaultLimit = 256

  private struct State: Sendable {
    var queue: [SurfaceInput] = []
    var draining = false
    var closed = false
  }

  public let limit: Int
  private let state = Mutex(State())
  private let submit: @Sendable (SurfaceInput) async -> SurfaceInputResult
  private let onResult: @Sendable (SurfaceInput, SurfaceInputResult) -> Void

  /// - Parameters:
  ///   - limit: Maximum queued operations; must be positive.
  ///   - submit: Called serially, in enqueue order.
  ///   - onResult: Called with each outcome, including immediate
  ///     refusals when the pump is full or closed.
  public init(
    limit: Int = OrderedInputPump.defaultLimit,
    submit: @escaping @Sendable (SurfaceInput) async -> SurfaceInputResult,
    onResult: @escaping @Sendable (SurfaceInput, SurfaceInputResult) -> Void = {
      _,
      _ in
    }
  ) {
    precondition(limit > 0)
    self.limit = limit
    self.submit = submit
    self.onResult = onResult
  }

  public var queuedCount: Int { state.withLock { $0.queue.count } }

  /// Queues `input`; returns false (and reports a refusal) when the pump
  /// is full or closed.
  @discardableResult
  public func enqueue(_ input: SurfaceInput) -> Bool {
    let valid: Bool
    do {
      try input.operation.validate()
      valid = true
    } catch { valid = false }
    enum Outcome {
      case start, queued
      case refused(InputRefusal)
    }
    let outcome = state.withLock { s -> Outcome in
      if s.closed { return .refused(.closed) }
      guard s.queue.count < limit else { return .refused(.backpressure) }
      guard valid else { return .refused(.invalid) }
      s.queue.append(input)
      guard !s.draining else { return .queued }
      s.draining = true
      return .start
    }
    switch outcome {
    case .start:
      Task { await self.drain() }
      return true
    case .queued: return true
    case let .refused(refusal):
      onResult(input, .refused(refusal))
      return false
    }
  }

  /// Refuses further input and discards anything not yet submitted.
  public func close() {
    let dropped = state.withLock { s -> [SurfaceInput] in
      s.closed = true
      defer { s.queue = [] }
      return s.queue
    }
    for input in dropped { onResult(input, .refused(.closed)) }
  }

  private func drain() async {
    while true {
      let next = state.withLock { s -> SurfaceInput? in
        guard !s.queue.isEmpty else {
          s.draining = false
          return nil
        }
        return s.queue.removeFirst()
      }
      guard let next else { return }
      onResult(next, await submit(next))
    }
  }
}
