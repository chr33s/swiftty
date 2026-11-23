import AppKit
import Dispatch
import MuxNavigation
import SwiftMuxClient
import SwiftMuxProtocol
@testable import Swiftty
import SwifttyCore
import Synchronization
import Testing
import TestSupport

extension MuxNativeTests {
  @Test
  func repeatedNewWorkspaceActionsShareOnePendingOpen() async throws {
    let gate = AsyncStream<Void>.makeStream()
    defer { gate.continuation.finish() }
    var opens = 0
    var reports = 0
    weak var reentrantDelegate: AppDelegate?
    let delegate = AppDelegate(
      openMuxWorkspace: { _, _, _ in
        opens += 1
        for await _ in gate.stream { break }
        throw MuxError(.connectionLost, "held open failed")
      },
      reportMuxOpenError: { _ in
        reports += 1
        if reports == 1 { reentrantDelegate?.newWorkspace(nil) }
      }
    )
    reentrantDelegate = delegate
    delegate.newWorkspace(nil)
    try #require(await until { opens == 1 })
    for _ in 0 ..< 20 { delegate.newWorkspace(nil) }
    await Task.yield()
    gate.continuation.finish()
    try #require(await until { reports > 0 })
    #expect(opens == 1)
    #expect(reports == 1)
    delegate.newWorkspace(nil)
    try #require(await until { reports > 1 })
    #expect(opens == 2)
    #expect(reports == 2)
  }

  @Test
  func repeatedAttachActionsShareOnePendingWorkspaceQuery() async throws {
    let gate = AsyncStream<Void>.makeStream()
    defer { gate.continuation.finish() }
    var queries = 0
    var reports = 0
    weak var reentrantDelegate: AppDelegate?
    let delegate = AppDelegate(
      listMuxWorkspaces: {
        queries += 1
        for await _ in gate.stream { break }
        throw MuxError(.connectionLost, "held query failed")
      },
      reportMuxAttachError: { _ in
        reports += 1
        if reports == 1 { reentrantDelegate?.openWorkspace(nil) }
      }
    )
    reentrantDelegate = delegate
    delegate.openWorkspace(nil)
    try #require(await until { queries == 1 })
    for _ in 0 ..< 20 { delegate.openWorkspace(nil) }
    // Drain the main actor's admitted query jobs before observing the count.
    await Task.yield()
    gate.continuation.finish()
    try #require(await until { reports > 0 })
    #expect(queries == 1)
    #expect(reports == 1)
    delegate.openWorkspace(nil)
    try #require(await until { reports > 1 })
    #expect(queries == 2)
    #expect(reports == 2)
  }

  @Test
  func canceledServiceConnectPreservesCancellationError() async throws {
    await #expect(throws: CancellationError.self) {
      try await MuxWorkspaceController.connect(createConnection: {
        throw CancellationError()
      })
    }
  }

  @Test(.enabled(if: hasMetal))
  func closingADetachedWindowClosesItsMetadataConnection() async throws {
    try await withDetachedFixture { d in
      let c = d.fixture.controller
      // Losing the lease keeps metadata usable while the window is open.
      await c.reloadInbox()
      #expect(c.inboxMessage == nil)
      await c.detach()
      await c.reloadInbox()
      #expect(c.inboxMessage == "The SwiftMux service is not reachable.")
    }
  }

  @Test(.enabled(if: hasMetal))
  func closingAWindowRetiresItsPendingTakeoverConfirmation() async throws {
    try await withDetachedFixture { d in
      let controller = d.fixture.controller
      var shown: MuxWorkspaceController?
      defer { shown?.close() }
      let gate = AsyncStream<Void>.makeStream()
      defer { gate.continuation.finish() }
      var asked = false
      var returned = false
      var connects = 0
      let endpoint = d.fixture.endpoint
      controller.connectService = {
        connects += 1
        return try await MuxConnection.connect(
          endpoint: endpoint,
          frontend: .native
        )
      }
      controller.onReplaced = { shown = $0 }
      // The phone stands in for another device in use: always asked.
      controller.decideTakeControl = { .ask($0.leaseGeneration) }
      controller.confirmDestructive = { _ in
        asked = true
        for await _ in gate.stream { break }
        returned = true
        return true
      }
      controller.openAttention(d.item)
      try #require(await until { asked })
      #expect(connects == 1)
      await controller.detach()
      controller.close()
      gate.continuation.finish()
      try #require(await until { returned })
      // Let the confirmation's main-actor continuation and any replacement
      // connection it schedules run before observing the closed window.
      try await Task.sleep(for: .milliseconds(200))
      #expect(connects == 1)
      #expect(shown == nil)
      #expect((try? await d.phone.execute(.focusPane(d.pane))) != nil)
    }
  }

  @Test(.enabled(if: hasMetal), arguments: [false, true], [false, true])
  func closingAWindowRejectsAReplacementConnectionThatArrivesLate(
    fails: Bool,
    cooperative: Bool
  ) async throws {
    try await withDetachedFixture { d in
      let controller = d.fixture.controller
      var shown: MuxWorkspaceController?
      var candidate: MuxConnection?
      try await RuntimeFixture.withCleanup {
        try await d.phone.execute(.detach)
        let gate = AsyncStream<Void>.makeStream()
        var release: (() -> Void)?
        defer {
          release?();
          gate.continuation.finish()
        }
        var entered = false
        var returned = false
        var alerts = 0
        let endpoint = d.fixture.endpoint
        controller.connectService = {
          let connection = try await MuxConnection.connect(
            endpoint: endpoint,
            frontend: .native
          )
          candidate = connection
          entered = true
          if cooperative {
            for await _ in gate.stream { break }
          } else {
            await withCheckedContinuation { continuation in
              release = { continuation.resume() }
            }
          }
          returned = true
          if fails {
            await connection.close()
            throw MuxError(.connectionLost, "delayed setup failure")
          }
          return connection
        }
        controller.onReplaced = { shown = $0 }
        controller.confirmDestructive = { _ in
          alerts += 1;
          return false
        }
        controller.openAttention(d.item)
        try #require(await until { entered })
        await controller.detach()
        controller.close()
        if cooperative {
          #expect(await until { returned })
        } else {
          #expect(!returned)
        }
        release?()
        release = nil
        gate.continuation.finish()
        try #require(await until { returned })
        try await Task.sleep(for: .milliseconds(200))
        let late = try #require(candidate)
        #expect(shown == nil)
        #expect(alerts == 0)
        #expect(await late.attachment == nil)
        await #expect { try await late.execute(.status) } throws: {
          ($0 as? MuxError)?.code == .connectionLost
        }
      } cleanup: {
        await controller.detach()
        controller.close()
        await candidate?.close()
        await shown?.detach()
        shown?.close()
      }
    }
  }

  @Test(.enabled(if: hasMetal))
  func cancelingAConnectionAttemptCancelsItsConnectorAndDisposesTheResult()
    async throws
  {
    try await withFixture { f in
      let attempts = MuxConnectionAttempts()
      let gate = AsyncStream<Void>.makeStream()
      var candidate: MuxConnection?
      var entered = false
      var returned = false
      var ownedCaller: Task<MuxConnection, any Error>?
      try await RuntimeFixture.withCleanup {
        let caller = Task {
          try await attempts.connect {
            let connection = try await MuxConnection.connect(
              endpoint: f.endpoint,
              frontend: .native
            )
            candidate = connection
            entered = true
            for await _ in gate.stream { break }
            returned = true
            return connection
          }
        }
        ownedCaller = caller
        try #require(await until { entered })
        caller.cancel()
        await #expect(throws: CancellationError.self) { try await caller.value }
        try #require(
          await until { returned && attempts.pendingCountForTesting == 0 }
        )
        let late = try #require(candidate)
        await #expect { try await late.execute(.status) } throws: {
          ($0 as? MuxError)?.code == .connectionLost
        }
      } cleanup: {
        attempts.cancel()
        ownedCaller?.cancel()
        gate.continuation.finish()
        _ = try? await ownedCaller?.value
        #expect(
          await until {
            await Task.yield()
            return attempts.pendingCountForTesting == 0
          }
        )
        await candidate?.close()
      }
    }
  }

  @Test(.enabled(if: hasMetal), arguments: [false, true])
  func canceledConnectionWaitFinishesBeforeANoncooperativeConnector(
    _ ownerCanceled: Bool
  ) async throws {
    try await withFixture { f in
      let attempts = MuxConnectionAttempts()
      var release: CheckedContinuation<Void, Never>?
      var candidate: MuxConnection?
      var entered = false
      var returned = false
      var finished = false
      var ownedCaller: Task<MuxConnection, any Error>?
      try await RuntimeFixture.withCleanup {
        let caller = Task {
          defer { finished = true }
          return try await attempts.connect {
            let connection = try await MuxConnection.connect(
              endpoint: f.endpoint,
              frontend: .native
            )
            candidate = connection
            entered = true
            await withCheckedContinuation { release = $0 }
            returned = true
            return connection
          }
        }
        ownedCaller = caller
        try #require(await until { entered })
        if ownerCanceled { attempts.cancel() } else { caller.cancel() }
        #expect(await until { finished })
        #expect(!returned)
        #expect(attempts.pendingCountForTesting == 1)
        release?.resume()
        release = nil
        await #expect(throws: CancellationError.self) { try await caller.value }
        try #require(
          await until { returned && attempts.pendingCountForTesting == 0 }
        )
        // A later status failure observes disposal of the live late result.
        let late = try #require(candidate)
        #expect(
          await until {
            do {
              _ = try await late.execute(.status);
              return false
            } catch { return (error as? MuxError)?.code == .connectionLost }
          }
        )
      } cleanup: {
        attempts.cancel()
        ownedCaller?.cancel()
        release?.resume()
        release = nil
        _ = try? await ownedCaller?.value
        #expect(
          await until {
            release?.resume()
            release = nil
            await Task.yield()
            return attempts.pendingCountForTesting == 0
          }
        )
        await candidate?.close()
      }
    }
  }

  @Test(.enabled(if: hasMetal), arguments: [false, true])
  func pendingConnectionAttemptsHaveBoundedAdmission(
    _ canceled: Bool
  ) async throws {
    try await withFixture { f in
      let attempts = MuxConnectionAttempts()
      let limit = MuxConnection.maxPendingCommands
      var releases: [CheckedContinuation<Void, Never>] = []
      let create: @MainActor () async throws -> MuxConnection = {
        await withCheckedContinuation { releases.append($0) }
        return try await MuxConnection.connect(
          endpoint: f.endpoint,
          frontend: .native
        )
      }
      let callers = (0 ..< limit)
        .map { _ in Task { try await attempts.connect(create) } }
      var ownedExcess: Task<Void, Never>?
      try await RuntimeFixture.withCleanup {
        try #require(await until { releases.count == limit })
        if canceled { attempts.cancel() }
        var excessFinished = false
        var excessError: MuxError?
        let excess = Task {
          defer { excessFinished = true }
          do {
            let connection = try await attempts.connect(create)
            await connection.close()
          } catch { excessError = error as? MuxError }
        }
        ownedExcess = excess
        try #require(await until { excessFinished || releases.count > limit })
        #expect(releases.count == limit)
        for release in releases { release.resume() }
        releases.removeAll()
        for caller in callers {
          if canceled {
            await #expect(throws: CancellationError.self) {
              try await caller.value
            }
          } else {
            let connection = try await caller.value
            try await RuntimeFixture.withCleanup {
              _ = try await connection.execute(.status)
            } cleanup: {
              await connection.close()
            }
          }
        }
        await excess.value
        #expect(excessError?.code == .resourceLimit)
        try #require(await until { attempts.pendingCountForTesting == 0 })
        let fresh = try await attempts.connect {
          try await MuxConnection.connect(
            endpoint: f.endpoint,
            frontend: .native
          )
        }
        try await RuntimeFixture.withCleanup {
          _ = try await fresh.execute(.status)
        } cleanup: {
          await fresh.close()
        }
      } cleanup: {
        attempts.cancel()
        for caller in callers { caller.cancel() }
        ownedExcess?.cancel()
        let held = releases
        releases.removeAll()
        for release in held { release.resume() }
        for caller in callers {
          if let connection = try? await caller.value {
            await connection.close()
          }
        }
        await ownedExcess?.value
        #expect(
          await until {
            let held = releases
            releases.removeAll()
            for release in held { release.resume() }
            await Task.yield()
            return attempts.pendingCountForTesting == 0
          }
        )
      }
    }
  }

  @Test(.enabled(if: hasMetal))
  func windowCloseSynchronouslyRetiresRevealAdmission() async throws {
    try await withFixture { fixture in
      let controller = fixture.controller
      let pane = try #require(controller.activePane)
      let observer = try await MuxConnection.connect(
        endpoint: fixture.endpoint,
        frontend: .control
      )
      try await RuntimeFixture.withCleanup {
        var connects = 0
        controller.close()
        // The delegate must retire admission before its asynchronous detach
        // task can run, so another same-turn action cannot reopen the window.
        #expect(controller.isClosed)
        #expect(!controller.holdsLease)
        await #expect(throws: CancellationError.self) {
          _ = try await MuxWorkspaceController.reveal(
            PaneTarget(workspace: fixture.workspace, tab: nil, pane: pane),
            in: controller,
            configuration: Configuration(),
            connect: {
              connects += 1
              throw MuxError(
                .invalidRequest,
                "closed source must not reconnect"
              )
            }
          )
        }
        #expect(connects == 0)
        #expect(controller.window?.isVisible == false)
        // Synchronous UI retirement must still permit asynchronous transport
        // cleanup, leaving the actual service-owned shell running.
        #expect(
          await until {
            guard
              case let .status(status) = try? await observer.execute(.status)
            else { return false }
            return !status.attached && status.workspaces == 1
              && status.panes == 1
          }
        )
      } cleanup: {
        await observer.close()
      }
    }
  }

  @Test(.enabled(if: hasMetal), arguments: [false, true], [false, true])
  func closedWindowsDoNotStartDestructivePrompts(
    _ queuedBeforeClose: Bool,
    _ endTab: Bool
  ) async throws {
    try await withFixture { fixture in
      let controller = fixture.controller
      let observer = try await MuxConnection.connect(
        endpoint: fixture.endpoint,
        frontend: .control
      )
      try await RuntimeFixture.withCleanup {
        var prompts = 0
        controller.confirmDestructive = { _ in
          prompts += 1;
          return true
        }
        let action = {
          if endTab { controller.closeTab() } else { controller.endPane() }
        }
        if queuedBeforeClose { action() }
        controller.close()
        if !queuedBeforeClose { action() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(prompts == 0)
        #expect(controller.isClosed)
        #expect(controller.window?.isVisible == false)
        guard case let .status(status) = try await observer.execute(.status)
        else {
          Issue.record("expected status from the retained service")
          return
        }
        #expect(status.workspaces == 1 && status.panes == 1 && !status.attached)
      } cleanup: {
        await observer.close()
      }
    }
  }

  @Test(.enabled(if: hasMetal))
  func cancelledInFlightRevealReturnsBeforeTheReply() async throws {
    let f = try await open()
    defer { f.controller.close() }
    let c = f.controller
    let original = try #require(c.activePane)
    c.split(.leftRight)
    #expect(await until { c.workspace?.panes.count == 2 })
    c.window?.orderOut(nil)
    let release = DispatchSemaphore(value: 0)
    let blocked = Mutex(false)
    f.service.queue.async {
      blocked.withLock { $0 = true }
      _ = release.wait(timeout: .now() + 10)
    }
    defer { release.signal() }
    #expect(await until { blocked.withLock { $0 } })
    var entered = false
    var finished = false
    let task = Task {
      entered = true
      defer { finished = true }
      do {
        try await c.revealAttention(pane: original, tab: nil)
        return false
      } catch { return error is CancellationError }
    }
    #expect(await until { entered })
    task.cancel()
    // Cancellation must resume the caller while the independent command
    // consumer still awaits the service. On-wire commands may commit.
    #expect(await until { finished })
    #expect(c.window?.isVisible == false)
    release.signal()
    #expect(await task.value)
  }

  @Test(.enabled(if: hasMetal))
  func cancelledRevealDoesNotShowTheCurrentWindow() async throws {
    let f = try await open()
    defer { f.controller.close() }
    let pane = try #require(f.controller.activePane)
    f.controller.window?.orderOut(nil)
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      _ = try await MuxWorkspaceController.reveal(
        PaneTarget(workspace: f.workspace, tab: nil, pane: pane),
        in: f.controller,
        configuration: Configuration(),
        connect: { throw MuxError(.invalidRequest, "must reuse current") },
      )
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(f.controller.window?.isVisible == false)
    #expect(f.controller.holdsLease)
  }

  @Test(.enabled(if: hasMetal))
  func cancelledQueuedRevealDoesNotFocusAnotherPane() async throws {
    let f = try await open()
    defer { f.controller.close() }
    let c = f.controller
    let original = try #require(c.activePane)
    c.split(.leftRight)
    #expect(await until { c.workspace?.panes.count == 2 })
    let other = try #require(c.activePane)
    #expect(other != original)
    c.window?.orderOut(nil)
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await c.revealAttention(pane: original, tab: nil)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    // Wait for a subsequent queued operation to finish; the cancelled
    // focus must not be sent by the independent command consumer.
    try await c.revealAttention(pane: other, tab: nil)
    #expect(c.activePane == other)
  }
}
