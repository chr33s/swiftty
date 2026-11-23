import AppKit

/// Moves a window's close, minimize and zoom buttons down so they centre
/// on a row of the content (tabs on the left: the pane headers and the
/// sidebar's top row). AppKit lays the titlebar out again on resize, full
/// screen and key changes, so callers apply it after each.
@MainActor
enum MuxWindowControls {
  /// Centres the buttons `centerY` points below the window's top edge by
  /// sizing the titlebar container to twice that, buttons in its middle.
  /// Leaves AppKit's own placement alone in full screen.
  static func center(_ window: NSWindow, at centerY: CGFloat) {
    guard !window.styleMask.contains(.fullScreen),
      let close = window.standardWindowButton(.closeButton),
      let titlebar = close.superview, let container = titlebar.superview
    else { return }
    let buttons = [.closeButton, .miniaturizeButton, .zoomButton]
      .compactMap { window.standardWindowButton($0) }
    let height = (2 * centerY).rounded()
    let frameHeight = container.superview?.bounds.height ?? window.frame.height
    var frame = container.frame
    if abs(frame.height - height) > 0.5
      || abs(frame.origin.y - (frameHeight - height)) > 0.5
    {
      frame.size.height = height
      frame.origin.y = frameHeight - height
      container.frame = frame
    }
    for button in buttons {
      let y = ((titlebar.bounds.height - button.frame.height) / 2).rounded()
      if abs(button.frame.origin.y - y) > 0.5 {
        button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: y))
      }
    }
  }
}
