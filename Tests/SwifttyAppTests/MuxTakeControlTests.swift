import AppKit
import SwiftMuxClient
import SwiftMuxProtocol
@testable import Swiftty
import SwifttyCore
import Testing
import TestSupport

/// Taking control back by typing in a window that lost it: who may be
/// displaced silently, and the typed input reaching the window that wins.
extension MuxNativeTests {
  private func summary(
    attached: Bool = true,
    holder: LeaseHolder?
  ) -> WorkspaceSummary {
    WorkspaceSummary(
      id: WorkspaceID(),
      name: "w",
      tabCount: 1,
      paneCount: 1,
      createdAt: Date(),
      isAttached: attached,
      leaseGeneration: 7,
      leaseHolder: holder
    )
  }

  @Test
  func `take control asks only for a holder that may be in use`() {
    let now = Date()
    let recent = now.addingTimeInterval(-5)
    let old = now.addingTimeInterval(-MuxTakeControl.idleInterval - 1)
    func decide(_ ws: WorkspaceSummary) -> MuxTakeControl.Decision {
      MuxTakeControl.decide(ws, now: now)
    }
    // Free: attach; another native window on this Mac: silent.
    #expect(decide(summary(attached: false, holder: nil)) == .attach(7))
    #expect(
      decide(
        summary(holder: .init(transport: .local, frontend: .native, since: now))
      ) == .take(7)
    )
    // Another device: asked while recently typed in, silent once idle.
    #expect(
      decide(
        summary(
          holder: .init(
            transport: .remote,
            frontend: .native,
            since: old,
            lastInput: recent
          )
        )
      ) == .ask(7)
    )
    #expect(
      decide(
        summary(
          holder: .init(
            transport: .remote,
            frontend: .native,
            since: old,
            lastInput: old
          )
        )
      ) == .take(7)
    )
    // Never typed: idle counts from when it took control.
    #expect(
      decide(
        summary(
          holder: .init(transport: .local, frontend: .terminal, since: recent)
        )
      ) == .ask(7)
    )
    #expect(
      decide(
        summary(
          holder: .init(transport: .local, frontend: .terminal, since: old)
        )
      ) == .take(7)
    )
    // An older service names no holder: ask.
    #expect(decide(summary(holder: nil)) == .ask(7))
  }

  private func typing(_ text: String) throws -> NSEvent {
    try #require(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: text,
        charactersIgnoringModifiers: text,
        isARepeat: false,
        keyCode: 0
      )
    )
  }

  @Test(.enabled(if: hasMetal))
  func `a window that lost control shows the control bar over its last frame`()
    async throws
  {
    try await withDetachedFixture { d in
      let c = d.fixture.controller
      #expect(c.controlBar.isHidden == false)
      #expect(c.controlBar.message.hasPrefix("Controlled elsewhere"))
      #expect(c.layoutView.alphaValue < 1)
      // The last frame stays rather than going blank.
      #expect(c.views[d.pane]?.presented != nil)
    }
  }

  @Test(.enabled(if: hasMetal))
  func `typing in a window that lost control takes it back and replays`()
    async throws
  {
    try await withDetachedFixture { d in
      let c = d.fixture.controller
      var shown: MuxWorkspaceController?
      defer { shown?.close() }
      let endpoint = d.fixture.endpoint
      c.connectService = {
        try await MuxConnection.connect(endpoint: endpoint, frontend: .native)
      }
      c.onReplaced = { shown = $0 }
      var asked: [String] = []
      c.confirmDestructive = { message in
        asked.append(message)
        return false
      }
      let frame = try #require(c.window?.frame)

      // The holder is another native window on this Mac: no prompt.
      c.views[d.pane]?.keyDown(with: try typing("zq7"))
      #expect(await until { shown?.holdsLease == true })
      let window = try #require(shown)
      #expect(asked.isEmpty)
      #expect(window !== c)
      #expect(window.window?.frame == frame)
      #expect(window.controlBar.isHidden)
      // The typed text reached the shell in the window that took over.
      #expect(
        await until {
          (window.views[d.pane]?.accessibilityValue() as? String)?
            .contains("zq7") == true
        }
      )
      // The phone no longer controls the workspace.
      #expect(
        (try? await d.phone.execute(.newTab(name: nil, launch: nil))) == nil
      )
    }
  }

  @Test(.enabled(if: hasMetal))
  func `declining take control keeps the other holder and drops the input`()
    async throws
  {
    try await withDetachedFixture { d in
      let c = d.fixture.controller
      var shown: MuxWorkspaceController?
      defer { shown?.close() }
      let endpoint = d.fixture.endpoint
      c.connectService = {
        try await MuxConnection.connect(endpoint: endpoint, frontend: .native)
      }
      c.onReplaced = { shown = $0 }
      // Stands in for another device in use right now.
      c.decideTakeControl = { .ask($0.leaseGeneration) }
      var asked: [String] = []
      c.confirmDestructive = { message in
        asked.append(message)
        return false
      }
      let view = try #require(c.views[d.pane])
      view.keyDown(with: try typing("a"))
      view.keyDown(with: try typing("b"))
      #expect(await until { asked.count == 1 && !c.requestingControl })
      #expect(asked.first?.hasPrefix("Take control of workspace") == true)
      #expect(c.controlReplays.isEmpty)
      try await Task.sleep(for: .milliseconds(200))
      #expect(shown == nil)
      #expect(
        (try? await d.phone.execute(.newTab(name: nil, launch: nil))) != nil
      )
    }
  }
}
