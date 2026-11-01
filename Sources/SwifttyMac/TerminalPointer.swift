import AppKit
import SwifttyCore

/// Shared pointer geometry and scroll intent mapping. Backends retain selection
/// history/frozen frames and encode these intents using authoritative modes.
@MainActor
package final class TerminalPointer {
  package enum SelectionUnit { case cell, word, line }
  package var reportsLeftGesture = false

  package func beginLeftGesture(
    _ event: NSEvent,
    reporting: Bool,
    openLink: () -> Bool,
    report: () -> Void,
    select: (SelectionUnit) -> Void
  ) {
    reportsLeftGesture = false
    if event.modifierFlags.contains(.command), openLink() { return }
    if reporting, !event.modifierFlags.contains(.shift) {
      reportsLeftGesture = true
      report()
    } else {
      let unit: SelectionUnit =
        switch event.clickCount {
        case 2: .word
        case 3...: .line
        default: .cell
        }
      select(unit)
    }
  }

  package func dragLeftGesture(select: () -> Void, report: () -> Void) {
    if reportsLeftGesture { report() } else { select() }
  }

  package func endLeftGesture(select: () -> Void, report: () -> Void) {
    defer { reportsLeftGesture = false }
    if reportsLeftGesture { report() } else { select() }
  }

  package enum ScrollMode { case mouse, arrows, history, disabled }
  package enum ScrollInput {
    case wheel(MouseEvent.Button)
    case key(Key)
    case history(Int)
  }

  package var vertical = ScrollAccumulator()
  package var horizontal = ScrollAccumulator()
  package init() {}

  package func reset() {
    reportsLeftGesture = false
    vertical.reset()
    horizontal.reset()
  }

  package static func cell(
    at point: NSPoint,
    in view: NSView,
    renderer: MetalRenderer
  ) -> (column: Int, row: Int) {
    let scale = view.window?.backingScaleFactor ?? 2
    return (
      TerminalGeometry.cellIndex(
        (point.x * scale - renderer.options.paddingX) / renderer.cellSize.width
      ),
      TerminalGeometry.cellIndex(
        ((view.bounds.height - point.y) * scale - renderer.options.paddingY)
          / renderer.cellSize.height
      )
    )
  }

  package func scroll(
    _ event: NSEvent,
    in view: NSView,
    renderer: MetalRenderer,
    mode: ScrollMode,
    send: (ScrollInput) -> Void
  ) {
    let scale = view.window?.backingScaleFactor ?? 2
    let lines = vertical.add(
      event.hasPreciseScrollingDeltas
        ? event.scrollingDeltaY / (renderer.cellSize.height / scale)
        : event.scrollingDeltaY
    )
    // One event must not monopolize the UI with an unbounded report loop.
    // History remains a single request, regardless of its distance.
    let reportLimit = 256
    if mode == .mouse {
      let columns = horizontal.add(
        event.hasPreciseScrollingDeltas
          ? event.scrollingDeltaX / (renderer.cellSize.width / scale)
          : event.scrollingDeltaX
      )
      for _ in 0 ..< min(reportLimit, abs(lines)) {
        send(.wheel(lines > 0 ? .wheelUp : .wheelDown))
      }
      for _ in 0 ..< min(reportLimit, abs(columns)) {
        send(.wheel(columns > 0 ? .wheelLeft : .wheelRight))
      }
    } else {
      horizontal.reset()
      guard lines != 0 else { return }
      switch mode {
      case .arrows:
        for _ in 0 ..< min(reportLimit, abs(lines)) {
          send(.key(lines > 0 ? .up : .down))
        }
      case .history: send(.history(lines))
      case .disabled, .mouse: break
      }
    }
  }
}
