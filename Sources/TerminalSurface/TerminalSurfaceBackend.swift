import ScreenProtocol
import SessionCore
import SwifttyCore

/// How the view obtains what to draw.
public enum SurfaceDisplay: Sendable {
  /// Render this session directly (local PTY or ordinary SSH).
  case session(TerminalSession)
  /// Render owned frames from `currentFrame()`.
  case frames
}

/// The view-facing session abstraction (spec §A.4.1).
///
/// | Responsibility | Member |
/// |---|---|
/// | Frame access | `display`, `currentFrame()` |
/// | Invalidation | `onInvalidate`, coalesced until the next frame read |
/// | Input submission | `submit(_:)` with semantic `SurfaceInput` |
/// | Grid proposal | `proposeGrid(columns:rows:)`; the host's resize revision stays authoritative |
/// | Selection/copy | `selectedText(_:)` reads the displayed frame only |
/// | Capabilities | `capabilities` |
/// | Lifecycle | `lifecycle`, `onLifecycleChange` |
public protocol TerminalSurfaceBackend: AnyObject, Sendable {
  var capabilities: SurfaceCapabilities { get }
  var display: SurfaceDisplay { get }

  /// The newest complete frame for `.frames` displays (nil before the
  /// first one, and always nil for `.session` displays). Reading it
  /// re-arms `onInvalidate`.
  func currentFrame() -> SurfaceFrame?

  /// Called, from any executor, when a newer frame exists. At most one
  /// notification is outstanding until `currentFrame()` is read; frames
  /// are never queued.
  var onInvalidate: (@Sendable () -> Void)? { get set }

  var lifecycle: SurfaceLifecycle { get }
  var onLifecycleChange: (@Sendable (SurfaceLifecycle) -> Void)? { get set }

  /// Submits semantic input. Refusals are reported, never queued.
  func submit(_ input: SurfaceInput) async -> SurfaceInputResult

  /// Requests a grid size from local view geometry. The displayed grid
  /// changes only when the authoritative terminal reports it.
  func proposeGrid(columns: Int, rows: Int) async

  /// Ends this attachment or channel. Idempotent.
  func close() async
}

extension TerminalSurfaceBackend {
  /// Local copy of the displayed frame; never touches the host terminal.
  /// Nil for `.session` displays, whose view selects on its own session.
  public func selectedText(_ selection: SurfaceSelection) -> String? {
    currentFrame().map { $0.frame.text(in: selection) }
  }
}
