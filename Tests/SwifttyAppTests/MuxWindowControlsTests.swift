import AppKit
@testable import Swiftty
import SwifttyCore
import Testing

extension MuxNativeTests {
  @Test(.enabled(if: hasMetal))
  func `tabs on the left centre the window controls on the header row`()
    async throws
  {
    let f = try await open()
    defer { f.controller.close() }
    let c = f.controller
    let window = try #require(c.window)
    let theme = try #require(window.contentView?.superview)
    let pane = try #require(c.activePane)
    let close = try #require(window.standardWindowButton(.closeButton))
    func closeCenter() -> CGFloat {
      theme.layoutSubtreeIfNeeded()
      return theme.bounds.maxY - close.convert(close.bounds, to: theme).midY
    }
    // On top, the toolbar places them.
    let onTop = closeCenter()
    var configuration = Configuration()
    configuration.tabPosition = .left
    c.apply(configuration)
    theme.layoutSubtreeIfNeeded()
    /// The buttons' and the header's centres below the window's top edge.
    func centers() throws -> (buttons: [CGFloat], header: CGFloat) {
      theme.layoutSubtreeIfNeeded()
      let top = theme.bounds.maxY
      let buttons = try [.closeButton, .miniaturizeButton, .zoomButton]
        .map { try #require(window.standardWindowButton($0)) }
        .map { top - $0.convert($0.bounds, to: theme).midY }
      let header = try #require(c.containers[pane]?.header)
      return (buttons, top - header.convert(header.bounds, to: theme).midY)
    }
    let expected = MuxWorkspaceController.windowControlsCenter
    for collapsed in [false, true] {
      if c.sidebarCollapsed != collapsed { c.toggleSidebar() }
      let (buttons, header) = try centers()
      #expect(buttons.allSatisfy { abs($0 - expected) < 1 }, "\(buttons)")
      #expect(abs(header - expected) < 1, "header \(header)")
    }
    // AppKit lays the titlebar out again on resize; they stay put.
    window.setContentSize(NSSize(width: 820, height: 520))
    #expect(try centers().buttons.allSatisfy { abs($0 - expected) < 1 })
    // Back on top, AppKit's toolbar places them where it did.
    c.apply(Configuration())
    #expect(abs(closeCenter() - onTop) < 1, "\(closeCenter()) vs \(onTop)")
  }
}
