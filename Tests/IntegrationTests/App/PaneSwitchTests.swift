#if os(macOS)
@testable import RoamingApp
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
}
#endif
