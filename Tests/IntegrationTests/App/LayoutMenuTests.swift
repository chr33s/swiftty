#if os(macOS)
@testable import RoamingApp
import ScreenProtocol
import SwiftMuxProtocol
import Testing

/// The roaming Workspace menu's tab and pane names, renames and the
/// confirmation before closing a pane or tab (spec.roaming.md §7.6).
@MainActor
struct LayoutMenuTests {
  let live = RemoteLayout.Pane(id: PaneID(), title: "vim")
  let done = RemoteLayout.Pane(id: PaneID(), title: "", exited: true)

  func tab(_ name: String, _ panes: [RemoteLayout.Pane]) -> RemoteLayout.Tab {
    RemoteLayout.Tab(
      id: TabID(),
      name: name,
      panes: panes,
      activePane: panes[0].id
    )
  }

  @Test
  func `numbered default tabs show their program, as on the Mac`() {
    #expect(RoamingSurfaceView.title(of: tab("0", [live]), at: 0) == "vim")
    #expect(RoamingSurfaceView.title(of: tab("", [live]), at: 0) == "vim")
    #expect(RoamingSurfaceView.title(of: tab("logs", [live]), at: 0) == "logs")
    #expect(RoamingSurfaceView.title(of: tab("1", [done]), at: 1) == "Tab 2")
    let spoof = RemoteLayout.Pane(id: PaneID(), title: "a\u{1B}[2Jb\u{202E}")
    #expect(RoamingSurfaceView.title(of: spoof, at: 0) == "a[2Jb")
    #expect(RoamingSurfaceView.title(of: done, at: 2) == "Pane 3")
  }

  @Test
  func `closing asks only while a process runs`() {
    let one = tab("0", [live])
    let pane = RoamingSurfaceView.ending(pane: live.id, of: one)
    #expect(pane.confirms)
    #expect(pane.action == .closePane(pane: live.id))
    #expect(pane.message == "End the pane “vim”?")
    let exited = tab("0", [done])
    #expect(!RoamingSurfaceView.ending(pane: done.id, of: exited).confirms)
    // A pane the layout does not list may be running.
    #expect(RoamingSurfaceView.ending(pane: PaneID(), of: exited).confirms)

    let mixed = tab("logs", [done, live])
    let layout = RemoteLayout(
      workspaceName: "w",
      revision: 1,
      tabs: [one, mixed],
      activeTab: one.id
    )
    let closing = RoamingSurfaceView.ending(tab: mixed, in: layout)
    #expect(closing.confirms)
    #expect(closing.action == .closeTab(tab: mixed.id))
    #expect(closing.message == "End the tab “logs”?")
    #expect(
      closing.detail == "Its 2 panes and their processes will be terminated."
    )
    let finished = tab("1", [done, done])
    #expect(!RoamingSurfaceView.ending(tab: finished, in: layout).confirms)
  }

  @Test
  func `a long name is cut to the wire limit instead of refused`() {
    let name = RoamingSurfaceView.renamed(
      "  " + String(repeating: "é", count: RemoteLayout.maxNameBytes) + "  "
    )
    #expect(name.utf8.count <= RemoteLayout.maxNameBytes)
    #expect(name.hasPrefix("éé"))
    #expect(LayoutAction.renameTab(tab: TabID(), name: name).isValid)
    #expect(RoamingSurfaceView.renamed("  logs \n") == "logs")
  }
}
#endif
