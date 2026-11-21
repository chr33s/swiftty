#if os(macOS)
@testable import RoamingApp
import SwiftMuxProtocol
import SwifttyCore
import Testing

/// Swiping between panes walks the shown tab's panes in order, wrapping.
struct PaneSwitchTests {
  @Test
  func `neighbors wrap around the tab's panes`() {
    let panes = ["a", "b", "c"]
    #expect(
      RoamingTerminalController.neighbor(of: "a", in: panes, next: true) == "b"
    )
    #expect(
      RoamingTerminalController.neighbor(of: "c", in: panes, next: true) == "a"
    )
    #expect(
      RoamingTerminalController.neighbor(of: "a", in: panes, next: false) == "c"
    )
    #expect(
      RoamingTerminalController.neighbor(of: "b", in: panes, next: false) == "a"
    )
  }

  @Test
  func `a lone or unknown pane has no neighbor`() {
    #expect(
      RoamingTerminalController.neighbor(of: "a", in: ["a"], next: true) == nil
    )
    #expect(
      RoamingTerminalController.neighbor(of: "z", in: ["a", "b"], next: true)
        == nil
    )
  }

  /// The host sends a Layout before the newly active pane's screen, so the
  /// newest frame is filed under the pane it shows, not the Layout's.
  @Test
  func `a frame is kept for the pane it shows`() throws {
    let tap = FrameTap(
      forward: TerminalSession(presentationColumns: 2, rows: 1)
    )
    let first = PaneID()
    let second = PaneID()
    func frame(_ text: String) -> PresentationFrame {
      PresentationFrame(
        columns: 2,
        rows: 1,
        cells: [.init(text: text), .init()],
        wrapped: [false],
        styles: [.init()],
        cursorX: 0,
        cursorY: 0,
        cursorStyle: .bar
      )
    }
    #expect(tap.install(frame("x")))
    #expect(tap.latestPaneFrame == nil)
    tap.show(first)
    #expect(tap.install(frame("a")))
    tap.show(second)
    let kept = try #require(tap.latestPaneFrame)
    #expect(kept.0 == first && kept.1 == frame("a"))
    #expect(tap.install(frame("b")))
    let next = try #require(tap.latestPaneFrame)
    #expect(next.0 == second && next.1 == frame("b"))
  }
}
#endif
