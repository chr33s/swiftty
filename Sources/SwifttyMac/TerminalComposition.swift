import AppKit
import SwifttyCore

/// Shared AppKit composition state and candidate geometry. This component
/// owns no terminal: callers commit through their authoritative input path.
@MainActor
package final class TerminalComposition {
  package private(set) var text = ""
  package private(set) var selection = NSRange(location: NSNotFound, length: 0)

  package init() {}

  package var markedRange: NSRange {
    text.isEmpty
      ? NSRange(location: NSNotFound, length: 0)
      : NSRange(location: 0, length: text.utf16.count)
  }

  package func set(
    _ text: String,
    selection: NSRange = NSRange(location: NSNotFound, length: 0),
    renderer: MetalRenderer,
    view: NSView
  ) {
    let length = text.utf16.count
    let start = min(length, max(0, selection.location))
    self.selection =
      length == 0
      ? NSRange(location: NSNotFound, length: 0)
      : NSRange(
        location: start,
        length: min(length - start, max(0, selection.length))
      )
    let renderedSelection = text.isEmpty ? nil : self.selection
    guard
      text != self.text
        || renderer.options.preeditSelection != renderedSelection
    else { return }
    self.text = text
    renderer.options.preedit = Array(text.unicodeScalars)
    renderer.options.preeditSelection = renderedSelection
    view.needsDisplay = true
  }

  package func discard(renderer: MetalRenderer, view: NSView) {
    set("", renderer: renderer, view: view)
    view.inputContext?.discardMarkedText()
  }

  /// Uses only the caller's displayed cursor, never a pending frame.
  package func firstRect(
    for range: NSRange,
    actualRange: NSRangePointer?,
    cursor: (x: Int, y: Int),
    renderer: MetalRenderer,
    view: NSView
  ) -> NSRect {
    let location = range.location == NSNotFound ? 0 : max(0, range.location)
    let length = range.location == NSNotFound ? 0 : max(0, range.length)
    let (end, overflow) = location.addingReportingOverflow(length)
    let scalars = renderer.options.preedit
    let startPosition = TerminalGeometry.compositionPosition(
      in: scalars,
      atUTF16Offset: location
    )
    let endPosition =
      length > 0
      ? TerminalGeometry.compositionPosition(
        in: scalars,
        atUTF16Offset: overflow ? .max : end,
        roundUp: true,
      ) : startPosition
    actualRange?.pointee = NSRange(
      location: startPosition.utf16Offset,
      length: endPosition.utf16Offset - startPosition.utf16Offset,
    )
    let scale =
      view.window?.backingScaleFactor ?? renderer.font.descriptor.scale
    let column = CGFloat(cursor.x) + CGFloat(startPosition.column)
    let row = CGFloat(cursor.y)
    let cell = renderer.cellSize
    let x: CGFloat = (renderer.options.paddingX + column * cell.width) / scale
    let top: CGFloat =
      (renderer.options.paddingY + (row + 1) * cell.height) / scale
    let width =
      CGFloat(endPosition.column - startPosition.column) * cell.width / scale
    let rect = NSRect(
      x: x,
      y: view.bounds.height - top,
      width: width,
      height: cell.height / scale
    )
    guard let window = view.window else { return rect }
    return window.convertToScreen(view.convert(rect, to: nil))
  }
}
