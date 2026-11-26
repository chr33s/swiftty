import AppKit
import SwiftMuxProtocol
@testable import Swiftty
import SwifttyCore
import Testing

/// The screenshot-style workspace: native tab strip, pane headers,
/// splitters, focus routing and lifetime, against real shells.
extension MuxNativeTests {
  /// Polls on the main actor until `predicate` holds.
  func until(
    _ timeout: Duration = .seconds(10),
    _ predicate: () async -> Bool
  ) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if await predicate() { return true }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return false
  }

  /// Splits into the reference composition: a left stack (`top`,
  /// `bottom`) beside one tall pane (`right`).
  func referenceComposition(
    _ c: MuxWorkspaceController
  ) async throws -> (top: PaneID, bottom: PaneID, right: PaneID) {
    let top = try #require(c.activePane)
    c.split(.leftRight)
    #expect(await until { c.views.count == 2 })
    let right = try #require(c.views.keys.first { $0 != top })
    c.split(.topBottom, pane: top)
    #expect(await until { c.views.count == 3 })
    let bottom = try #require(c.views.keys.first { $0 != top && $0 != right })
    return (top, bottom, right)
  }

  @Test(.enabled(if: hasMetal))
  func `reference layout routes input to three distinct shells`() async throws {
    let f = try await open()
    defer { f.controller.close() }
    let c = f.controller
    let (top, bottom, right) = try await referenceComposition(c)
    let tree = try #require(c.activeTab?.layout)
    guard case let .split(.leftRight, _, left, .pane(tall)) = tree,
      case let .split(.topBottom, _, .pane(t), .pane(b)) = left
    else {
      Issue.record("unexpected tree \(tree)")
      return
    }
    #expect((t, b, tall) == (top, bottom, right))
    // Left column stacked, right pane full height.
    c.window?.contentView?.layoutSubtreeIfNeeded()
    let ft = try #require(c.containers[top]?.frame)
    let fb = try #require(c.containers[bottom]?.frame)
    let fr = try #require(c.containers[right]?.frame)
    #expect(ft.minX == fb.minX && ft.minY > fb.maxY)
    #expect(fr.minX > ft.maxX && fr.height >= ft.height + fb.height)
    // Three shells, three processes; each sees only its own input.
    var pids: Set<Int32> = []
    for pane in [top, bottom, right] {
      if let pid = await f.service.panePID(pane) { pids.insert(pid) }
    }
    #expect(pids.count == 3)
    let marks = [
      (top, "route-top"), (bottom, "route-bottom"), (right, "route-right"),
    ]
    for (pane, mark) in marks { c.send(.text("echo \(mark)\r"), to: pane) }
    for (pane, mark) in marks {
      let view = try #require(c.views[pane])
      let frame = try #require(
        await waitPresented(view) { $0.lines.contains(mark) }
      )
      for (_, other) in marks where other != mark {
        #expect(!frame.lines.contains { $0.contains(other) })
      }
    }
    // Directional focus follows the geometry.
    c.focus(.right)
    #expect(await until { c.activePane == right })
    c.focus(.left)
    #expect(await until { c.activePane != right })
  }

  @Test(.enabled(if: hasMetal))
  func `hidden tabs keep running, mark activity and converge on return`()
    async throws
  {
    let f = try await open()
    defer { f.controller.close() }
    let c = f.controller
    let first = try #require(c.activePane)
    let firstTab = try #require(c.activeTab?.id)
    _ = await waitPresented(try #require(c.views[first])) { _ in true }
    let pid = await f.service.panePID(first)
    c.newTab()
    #expect(
      await until { c.workspace?.tabs.count == 2 && c.activePane != first }
    )
    #expect(c.views[first] == nil)  // hidden: no view, no subscription
    c.send(.text("echo while-hidden-$((6*7))\r"), to: first)
    #expect(await until { c.activity.contains(first) })
    let item = c.tabStrip.buttons.compactMap(\.item).first { $0.id == firstTab }
    #expect(item?.hasActivity == true)
    c.selectTab(firstTab)
    #expect(await until { c.views[first] != nil })
    let view = try #require(c.views[first])
    #expect(
      await waitPresented(view) { $0.lines.contains("while-hidden-42") } != nil
    )
    #expect(!c.activity.contains(first))
    #expect(await f.service.panePID(first) == pid)
  }

  @Test(.enabled(if: hasMetal))
  func `pasted shortcut characters never change the workspace`() async throws {
    let f = try await open()
    defer { f.controller.close() }
    let c = f.controller
    let view = try #require(activeView(c))
    _ = await waitPresented(view) { _ in true }
    let before = try #require(c.workspace)
    c.paste("echo '⌘T ⌘D \u{2}c \u{2}% \u{2}\" split-paste'\r", to: view.pane)
    #expect(
      await waitPresented(view) {
        $0.lines.contains {
          $0.hasSuffix("split-paste") && !$0.contains("echo")
        }
      } != nil
    )
    let after = try #require(c.workspace)
    #expect(after.tabs.count == before.tabs.count)
    #expect(after.tabs[0].layout == before.tabs[0].layout)
  }

  @Test(.enabled(if: hasMetal))
  func `destructive actions confirm and end only their target`() async throws {
    let f = try await open()
    defer { f.controller.close() }
    let c = f.controller
    let first = try #require(c.activePane)
    c.split(.leftRight)
    #expect(await until { c.views.count == 2 })
    let second = try #require(c.views.keys.first { $0 != first })
    let firstPID = await f.service.panePID(first)
    // Declined: nothing ends.
    var asked: [String] = []
    c.confirmDestructive = { message in
      asked.append(message)
      return false
    }
    c.endPane(second)
    #expect(await until { asked.count == 1 })
    try await Task.sleep(for: .milliseconds(200))
    #expect(c.activeTab?.layout?.panes.count == 2)
    // Disposing a view is not termination.
    c.containers[second]?.removeFromSuperview()
    c.containers[second]?.paneView.removeFromSuperview()
    try await Task.sleep(for: .milliseconds(100))
    #expect(await f.service.panePID(second) != nil)
    // Accepted: only the target ends.
    c.confirmDestructive = { _ in true }
    c.endPane(second)
    #expect(await until { c.activeTab?.layout?.panes == [first] })
    #expect(await f.service.panePID(first) == firstPID)
    // A tab whose shell already exited closes without asking.
    asked = []
    c.confirmDestructive = { message in
      asked.append(message)
      return true
    }
    c.newTab()
    #expect(await until { c.workspace?.tabs.count == 2 })
    let tab = try #require(c.activeTab)
    c.send(.text("exit\r"), to: tab.activePane)
    #expect(await until { c.workspace?.tabs.count == 1 })
    #expect(asked.isEmpty)
  }

  @Test(.enabled(if: hasMetal))
  func `headers, tab strip and splitters expose titles and controls`()
    async throws
  {
    let f = try await open()
    defer { f.controller.close() }
    let c = f.controller
    let first = try #require(c.activePane)
    // A single pane needs no header.
    #expect(c.containers[first]?.showsHeader == false)
    // Controls inside a program title never reach the chrome.
    c.send(.text("printf '\\033]0;snake game\\007'\r"), to: first)
    #expect(await until { c.title(of: first) == "snake game" })
    let item = try #require(c.tabStrip.buttons.first?.item)
    #expect(item.title == "snake game")
    #expect(item.icons.map(\.symbol) == ["gamecontroller"])
    #expect(c.tabStrip.buttons.first?.accessibilityLabel() == "snake game")
    // The window names the workspace, then what its active pane shows.
    let workspace = DisplayText.workspaceName(try #require(c.workspace?.name))
    #expect(c.window?.title == "\(workspace) — snake game")
    c.split(.leftRight)
    #expect(await until { c.views.count == 2 })
    // A split tab shows both panes' icons, the active (new) pane's first.
    #expect(
      await until {
        c.tabStrip.buttons.first?.item?.icons.map(\.symbol) == [
          "terminal", "gamecontroller",
        ]
      }
    )
    let container = try #require(c.containers[first])
    #expect(container.showsHeader)
    #expect(container.header.state.title == "snake game")
    #expect(container.header.actionButtons.count == 4)
    // The header sits above the Metal view, outside the cell grid.
    c.window?.contentView?.layoutSubtreeIfNeeded()
    #expect(container.paneView.frame.maxY <= container.header.frame.minY)
    // The whole card is the terminal's background; the terminal clears to
    // it rather than laying a translucent background twice.
    #expect(container.terminalBackground == c.terminalBackground)
    #expect(container.paneView.inCard)
    #expect(container.paneView.renderer.options.backgroundOpacity == 0)
    // A program's default background (OSC 11) wears the card too.
    c.send(.text("printf '\\033]11;rgb:12/34/56\\007'\r"), to: first)
    #expect(await until { container.paneView.drawnBackground == 0x12_3456 })
    let card = try #require(container.cardBackground)
    #expect(abs(card.redComponent - 0x12 / 255) < 0.001)
    #expect(abs(card.greenComponent - 0x34 / 255) < 0.001)
    #expect(abs(card.blueComponent - 0x56 / 255) < 0.001)
    #expect(card.alphaComponent == c.terminalBackground.alphaComponent)
    container.displayIfNeeded()
    #expect(container.layer?.backgroundColor == card.cgColor)
    // The terminal's transparent pixels on an opaque layer would composite
    // black, even with an opaque background.
    var opaque = Configuration()
    opaque.backgroundOpacity = 1
    c.apply(opaque)
    #expect(container.paneView.layer?.isOpaque == false)
    #expect(container.paneView.renderer.options.backgroundOpacity == 0)
    #expect(container.terminalBackground?.alphaComponent == 1)
    // The divider is a keyboard/VoiceOver adjustable splitter.
    let splitter = try #require(
      c.layoutView.accessibilityChildren()?
        .compactMap { $0 as? MuxDividerElement }.first
    )
    #expect(splitter.accessibilityRole() == .splitter)
    let start = try #require(c.ratio(at: []))
    #expect(splitter.accessibilityPerformIncrement())
    #expect(abs((c.ratio(at: []) ?? 0) - (start + 0.05)) < 0.001)
    // Rapid drags show locally and converge on the last ratio.
    for step in 0 ..< 40 { c.setRatio(0.3 + Double(step) * 0.005, path: []) }
    #expect(abs((c.ratio(at: []) ?? 0) - 0.495) < 0.001)
    #expect(
      await until {
        guard let layout = c.activeTab?.layout,
          case let .split(_, r, _, _) = layout
        else { return false }
        return abs(r - 0.495) < 0.001
      }
    )
    // Keyboard resize moves the divider beside the active pane.
    let before = try #require(c.ratio(at: []))
    c.resizeActivePane(.left)
    #expect((c.ratio(at: []) ?? 1) < before)
  }

  @Test(.enabled(if: hasMetal))
  func `header float button floats a pane and then docks it back`() async throws
  {
    let f = try await open()
    defer { f.controller.close() }
    let c = f.controller
    c.split(.leftRight)
    #expect(await until { c.activeTab?.tiledPanes.count == 2 })
    let target = try #require(c.activePane)
    let button = try #require(
      c.containers[target]?.header.actionButtons[.float]
    )
    #expect(!button.isHidden)
    #expect(button.toolTip == "Float pane")
    button.performClick(nil)
    #expect(await until { c.activeTab?.layer(containing: target) != nil })
    #expect(
      c.containers[target]?.header.actionButtons[.float]?.toolTip == "Dock pane"
    )
    button.performClick(nil)
    #expect(await until { c.activeTab?.layer(containing: target) == nil })
    #expect(c.activeTab?.tiledPanes.contains(target) == true)
    #expect(
      c.containers[target]?.header.actionButtons[.float]?.toolTip
        == "Float pane"
    )
  }
}

extension MuxNativeTests {
  @Test(.enabled(if: hasMetal))
  func `listing-only clipboard reads are answered without a prompt`()
    async throws
  {
    let f = try await open()
    defer { f.controller.close() }
    let c = f.controller
    let pane = try #require(c.activePane)
    let view = try #require(c.views[pane])
    c.send(
      .text(
        "stty raw -echo; printf '\\033]5522;type=read:id=r1;Lg==\\007'; cat -v\r"
      ),
      to: pane
    )
    #expect(
      await waitPresented(view) {
        $0.lines.joined().contains("type=read:status=OK:id=r1")
          && $0.lines.joined().contains("type=read:status=DONE:id=r1")
      } != nil
    )
  }
}
