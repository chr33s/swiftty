import AppKit
import SwifttyCore

/// A visible kitty graphics image, exposed as an image element inside a
/// terminal view (spec.graphics.md §13.4).
package final class TerminalImageElement: NSAccessibilityElement {
  @MainActor
  init(_ region: ImageRegion, in view: NSView, renderer: MetalRenderer) {
    super.init()
    setAccessibilityParent(view)
    setAccessibilityRole(.image)
    setAccessibilityLabel(region.label)
    let scale = view.window?.backingScaleFactor ?? 2
    let cell = renderer.cellSize
    let top =
      (renderer.options.paddingY + CGFloat(region.row) * cell.height) / scale
    let height = CGFloat(region.rows) * cell.height / scale
    setAccessibilityFrameInParentSpace(
      NSRect(
        x: (renderer.options.paddingX + CGFloat(region.column) * cell.width)
          / scale,
        y: view.bounds.height - top - height,
        width: CGFloat(region.columns) * cell.width / scale,
        height: height
      )
    )
  }
}

extension TerminalImageElement {
  @MainActor
  package static func elements(
    for snapshot: RenderSnapshot?,
    in view: NSView,
    renderer: MetalRenderer
  ) -> [Any] {
    (snapshot?.imageRegions ?? [])
      .map { TerminalImageElement($0, in: view, renderer: renderer) }
  }
}
