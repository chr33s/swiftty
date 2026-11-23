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
      // Names who has it once the service answers.
      #expect(
        await until {
          c.controlBar.message
            == "In use on another window on this Mac — type to take control"
        }
      )
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

  /// A window that observes after a takeover, and every window that
  /// replaces it, recorded in order.
  private struct Observed {
    let fixture: Fixture
    let phone: MuxConnection
    let pane: PaneID
    let windows: () -> [MuxWorkspaceController]
  }

  private func withTakenOverWindow(
    _ work: @MainActor (Observed) async throws -> Void
  ) async throws {
    let f = try await open()
    let c = f.controller
    c.observesAfterTakeover = true
    var windows: [MuxWorkspaceController] = []
    c.onReplaced = { windows.append($0) }
    var phone: MuxConnection?
    try await RuntimeFixture.withCleanup {
      let pane = try #require(c.activePane)
      let other = try await MuxConnection.connect(
        endpoint: f.endpoint,
        frontend: .native
      )
      phone = other
      guard
        case let .workspaces(list) = try await other.execute(.listWorkspaces),
        let summary = list.first(where: { $0.id == f.workspace }),
        case .attached = try await other.execute(
          .takeover(.id(f.workspace), expectedLease: summary.leaseGeneration)
        )
      else { throw MuxError(.invalidRequest, "no takeover") }
      try await work(
        Observed(fixture: f, phone: other, pane: pane, windows: { windows })
      )
    } cleanup: {
      for window in windows {
        await window.detach()
        window.close()
      }
      await phone?.close()
      await retire(f)
    }
  }

  @Test(.enabled(if: hasMetal))
  func `a window taken over keeps showing the workspace live`() async throws {
    try await withTakenOverWindow { o in
      let c = o.fixture.controller
      #expect(await until { o.windows().first?.isObserving == true })
      let observer = try #require(o.windows().first)
      #expect(c.isClosed)
      #expect(!observer.holdsLease)
      #expect(observer.controlBar.isHidden == false)
      #expect(
        await until {
          observer.controlBar.message
            == "In use on another window on this Mac — type to take control"
        }
      )
      // Output from the new holder shows up read-only.
      await o.phone.post(.text("echo live-$((70+7))\r"), to: o.pane)
      #expect(
        await until {
          (observer.views[o.pane]?.accessibilityValue() as? String)?
            .contains("live-77") == true
        }
      )
      // The holder lets go: the bar says nobody controls it.
      _ = try await o.phone.execute(.detach)
      #expect(
        await until {
          observer.controlBar.message.hasPrefix("No one is controlling")
        }
      )
    }
  }

  @Test(.enabled(if: hasMetal))
  func `typing in an observing window takes control and replays`()
    async throws
  {
    try await withTakenOverWindow { o in
      #expect(await until { o.windows().first?.isObserving == true })
      let observer = try #require(o.windows().first)
      observer.views[o.pane]?.keyDown(with: try typing("ob9"))
      #expect(await until { o.windows().last?.holdsLease == true })
      let window = try #require(o.windows().last)
      #expect(window !== observer)
      #expect(observer.isClosed)
      #expect(
        await until {
          (window.views[o.pane]?.accessibilityValue() as? String)?
            .contains("ob9") == true
        }
      )
      #expect(
        (try? await o.phone.execute(.newTab(name: nil, launch: nil))) == nil
      )
    }
  }

  @Test(.enabled(if: hasMetal))
  func `the control bar asks before displacing a holder in use`()
    async throws
  {
    try await withTakenOverWindow { o in
      #expect(await until { o.windows().first?.isObserving == true })
      let observer = try #require(o.windows().first)
      // Stands in for another device in use right now.
      observer.decideTakeControl = { .ask($0.leaseGeneration) }
      let view = try #require(observer.views[o.pane])

      // Declined in the bar: the phone keeps control, the input is dropped.
      view.keyDown(with: try typing("n"))
      #expect(await until { observer.controlBar.isAsking })
      #expect(observer.controlBar.message.hasPrefix("Take control of workspace"))
      observer.controlBar.answer(false)
      #expect(await until { !observer.requestingControl })
      #expect(observer.controlReplays.isEmpty)
      #expect(o.windows().count == 1)
      #expect(
        (try? await o.phone.execute(.newTab(name: nil, launch: nil))) != nil
      )

      // Confirmed: a new window controls the workspace.
      view.keyDown(with: try typing("y"))
      #expect(await until { observer.controlBar.isAsking })
      observer.controlBar.answer(true)
      #expect(await until { o.windows().last?.holdsLease == true })
      #expect(o.windows().count == 2)
    }
  }
}
