import Foundation
import NIOSSH
@testable import RoamingApp
import SessionCore
import SSHClient
import SSHIdentity
import SwiftUI
import Testing

extension MainActorIntegrationTests {
  @MainActor
  @Suite(.serialized, .timeLimit(.minutes(1)))
  struct SSHShellControllerTests {
    enum Rejection: CaseIterable, Sendable { case channel, pty, shell }

    @Test
    func terminationClosesTheShellWhileTheMainQueueWaits() async throws {
      try await withController { server, app, controller in
        try await signIn(controller, app: app)
        try #require(try await eventually { controller.phase == .running })
        app.open(controller.model.host, kind: .ordinarySSH)
        let screen = try #require(app.activeSession)
        screen.controller = controller
        let connection = try #require(controller.connection)
        await withCheckedContinuation { continuation in
          DispatchQueue.main.async {
            let start = ContinuousClock.now
            app.detachBeforeExit()
            #expect(start.duration(to: .now) < .seconds(1))
            // Closed before the quit callback returns, not merely begun.
            #expect(!connection.isActive)
            #expect(screen.controller == nil)
            continuation.resume()
          }
        }
        #expect(
          try await eventually {
            server.state.connections.withLock { $0.channels.isEmpty }
          }
        )
      }
    }

    @Test
    func repeatedCloseWaitsForTheSameCleanup() async throws {
      try await withController { server, app, controller in
        try await signIn(controller, app: app)
        #expect(try await eventually { controller.phase == .running })
        server.state.faults.withLock { $0.dropAllServerWrites = true }
        var firstFinished = false
        let first = Task {
          await controller.close(.detach)
          firstFinished = true
        }
        do {
          #expect(
            try await eventually {
              server.state.droppedServerWrites.withLock { $0 > 0 }
            }
          )
          var secondStarted = false
          var secondFinished = false
          let second = Task {
            secondStarted = true
            await controller.close(.detach)
            secondFinished = true
          }
          do {
            #expect(try await eventually { secondStarted })
            #expect(!firstFinished)
            #expect(!secondFinished)
          } catch {
            await second.value
            throw error
          }
          await second.value
          #expect(secondFinished)
        } catch {
          await first.value
          throw error
        }
        await first.value
        #expect(firstFinished)
      }
    }

    @Test
    func directViewRefusalShowsNoticeWithoutEndingShell() async throws {
      try await withController { server, app, controller in
        // The view reports focus as it appears; that is not a refusal.
        controller.session.send(.focus(true))
        await withCheckedContinuation { continuation in
          DispatchQueue.main.async { continuation.resume() }
        }
        #expect(controller.inputNotice == nil)
        controller.session.send(.text("early"))
        #expect(
          try await eventually {
            controller.inputNotice.map { String(localized: $0) }?
              .contains("not ready") == true
          }
        )
        controller.dismissInputNotice()
        #expect(controller.inputNotice == nil)
        try await signIn(controller, app: app)
        #expect(try await eventually { controller.phase == .running })
        controller.session.send(
          .bytes(Array(repeating: 0, count: RSTLimits.maxPasteBytes + 1))
        )
        #expect(
          try await eventually {
            controller.inputNotice.map { String(localized: $0) }?
              .contains("limits") == true
          }
        )
        #expect(controller.phase == .running)
        #expect(controller.model.connectionState == .active)
        #expect(server.state.connections.withLock { $0.channels.count == 1 })
        controller.dismissInputNotice()
        controller.session.send(.text("ok"))
        #expect(
          try await eventually {
            controller.session.withState {
              $0.screenLines.contains { $0.contains("ok") }
            }
          }
        )
        #expect(controller.inputNotice == nil)
        await controller.close(.detach)
        controller.session.send(.text("late"))
        await withCheckedContinuation { continuation in
          DispatchQueue.main.async { continuation.resume() }
        }
        #expect(controller.inputNotice == nil)
      }
    }

    @Test(arguments: Rejection.allCases)
    func failedSetupClosesItsAuthenticatedConnection(
      rejection: Rejection,
    ) async throws {
      try await withController { server, app, controller in
        server.state.faults.withLock {
          switch rejection {
          case .channel: $0.rejectSessionChannel = true
          case .pty: $0.rejectPTY = true
          case .shell: $0.rejectShell = true
          }
        }
        try await signIn(controller, app: app)
        #expect(
          try await eventually {
            if case .failed = controller.phase { return true }
            return false
          }
        )
        #expect(server.state.authRequests.withLock { $0 > 0 })
        // Check physical server-side parents before closing the screen.
        #expect(
          try await eventually {
            server.state.connections.withLock { $0.channels.isEmpty }
          }
        )
        #expect(controller.model.connectionState == .sessionLost)
      }
    }

    @Test(arguments: [false, true])
    func closingDuringSetupReleasesTheParent(shell: Bool) async throws {
      try await withController { server, app, controller in
        server.state.faults.withLock {
          $0.withholdPTYReply = !shell
          $0.withholdShellReply = shell
        }
        try await signIn(controller, app: app)
        #expect(
          try await eventually {
            shell
              ? server.state.shellRequests.withLock { $0 > 0 }
              : server.state.ptyRequest.withLock { $0 != nil }
          }
        )
        await controller.close(.detach)
        #expect(
          try await eventually {
            server.state.connections.withLock { $0.channels.isEmpty }
          }
        )
        if case .failed = controller.phase {
          Issue.record(
            "Closing a pending shell must not publish a setup failure"
          )
        }
      }
    }

    @Test
    func successfulSetupKeepsTheConnectionUntilScreenClosure() async throws {
      try await withController { server, app, controller in
        try await signIn(controller, app: app)
        #expect(
          try await eventually {
            controller.phase == .running
              && controller.model.connectionState == .active
          }
        )
        #expect(server.state.connections.withLock { $0.channels.count == 1 })
        #expect(server.state.shellRequests.withLock { $0 == 1 })
        await controller.close(.detach)
        #expect(
          try await eventually {
            server.state.connections.withLock { $0.channels.isEmpty }
          }
        )
      }
    }

    @Test(arguments: [false, true])
    func finishedShellReleasesItsParentWithoutClosingTheScreen(
      status: Bool,
    ) async throws {
      try await withController { server, app, controller in
        try await signIn(controller, app: app)
        #expect(
          try await eventually { controller.model.connectionState == .active }
        )
        let child = try #require(
          server.state.sessionChannels.withLock { $0.values.first }
        )
        if status {
          try await child.pipeline
            .triggerUserOutboundEvent(
              SSHChannelRequestEvent.ExitStatus(exitStatus: 42),
            )
            .get()
        }
        do { try await child.close().get() } catch let error as NIOSSHError
          where error.type == .tcpShutdown
        {
          // Parent cleanup can race the server's child-close acknowledgement.
        }
        #expect(
          try await eventually {
            controller.model.connectionState
              == (status ? .sessionExited : .sessionLost)
          }
        )
        #expect(controller.model.exitStatus == (status ? 42 : nil))
        #expect(
          try await eventually {
            server.state.connections.withLock { $0.channels.isEmpty }
          }
        )
        if case let .failed(problem) = controller.phase {
          #expect(
            String(localized: problem.title)
              == (status ? "Shell exited" : "SSH connection lost")
          )
        } else {
          Issue.record("A finished shell must retain its failure explanation")
        }
      }
    }

    @Test
    func exitDuringOpeningReleasesItsParent() async throws {
      try await withController { server, app, controller in
        server.state.shellExitStatus.withLock { $0 = 42 }
        try await signIn(controller, app: app)
        #expect(
          try await eventually {
            controller.model.connectionState == .sessionExited
          }
        )
        #expect(controller.model.exitStatus == 42)
        #expect(
          try await eventually {
            server.state.connections.withLock { $0.channels.isEmpty }
          }
        )
      }
    }

    /// spec.roaming.md §9.1: a dropped connection opens a new shell in the
    /// same screen and says so; the old shell is not resumed.
    @Test
    func droppedConnectionOpensANewShellAndSaysSo() async throws {
      try await withController { server, app, controller in
        try await signIn(controller, app: app)
        #expect(try await eventually { controller.phase == .running })
        let first = try #require(controller.connection)
        for channel in server.state.connections.withLock({
          Array($0.channels.values)
        }) { channel.close(promise: nil) }
        #expect(
          try await eventually(within: .seconds(10)) {
            controller.replacementShells == 1 && controller.phase == .running
          }
        )
        let second = try #require(controller.connection)
        #expect(first !== second)
        #expect(!first.isActive)
        #expect(controller.recovery == nil)
        // Reported natively, never as a resumed session.
        #expect(controller.inputNotice != nil)
        // The remembered password was reused; nobody was asked again.
        #expect(app.pendingPassword == nil)
      }
    }

    /// Backgrounding cancels the attempt in flight; returning to the
    /// foreground before it unwinds still leads to a live attempt.
    @Test
    func foregroundingDuringACancelledAttemptStillReconnects() async throws {
      try await withController { server, app, controller in
        let scene = UUID()
        controller.scenePhaseChanged(.active, scene: scene)
        try await signIn(controller, app: app)
        #expect(try await eventually { controller.phase == .running })
        defer {
          let held = server.state.heldSessionOpens.withLock { value in
            defer { value.removeAll() }
            return value
          }
          for promise in held { promise.succeed() }
        }
        // The first recovery attempt stops at opening its shell channel.
        server.state.faults.withLock { $0.holdSessionChannelOpen = true }
        for channel in server.state.connections.withLock({
          Array($0.channels.values)
        }) { channel.close(promise: nil) }
        #expect(
          try await eventually(within: .seconds(10)) {
            server.state.heldSessionOpens.withLock { !$0.isEmpty }
          }
        )
        server.state.faults.withLock { $0.holdSessionChannelOpen = false }
        // Away and back before the cancelled attempt unwinds.
        controller.scenePhaseChanged(.background, scene: scene)
        controller.scenePhaseChanged(.active, scene: scene)
        #expect(
          try await eventually(within: .seconds(10)) {
            controller.replacementShells == 1 && controller.phase == .running
          }
        )
      }
    }

    @Test
    func withoutAutomaticReconnectALostShellStaysLost() async throws {
      try await withController(
        resilience: ConnectionResilienceSettings(autoReconnect: false)
      ) { server, app, controller in
        try await signIn(controller, app: app)
        #expect(try await eventually { controller.phase == .running })
        for channel in server.state.connections.withLock({
          Array($0.channels.values)
        }) { channel.close(promise: nil) }
        #expect(
          try await eventually {
            controller.phase == .failed(SSHShellController.connectionLost)
          }
        )
        #expect(controller.recovery == nil)
        #expect(controller.replacementShells == 0)
      }
    }

    /// A rejected credential needs the user: recovery stops rather than
    /// retrying forever.
    @Test
    func recoveryStopsWhenTheUserMustAct() async throws {
      #expect(SSHShellController.blocksRecovery(SSHAccessError.hostKeyChanged))
      #expect(
        SSHShellController.blocksRecovery(
          SSHAccessError.authenticationFailed(publicKeyLine: nil)
        )
      )
      #expect(SSHShellController.blocksRecovery(CancellationError()))
      #expect(!SSHShellController.blocksRecovery(SSHAccessError.unreachable))
      #expect(
        !SSHShellController.blocksRecovery(
          SSHClientError.channelRequestRejected("session")
        )
      )
    }

    private func signIn(
      _ controller: SSHShellController,
      app: RoamingAppModel,
    ) async throws {
      controller.start()
      #expect(try await eventually { app.pendingPassword != nil })
      app.resolvePassword(TestSSHServer.password)
    }

    private func withController(
      resilience: ConnectionResilienceSettings = .default,
      _ operation: (TestSSHServer, RoamingAppModel, SSHShellController, )
        async throws -> Void,
    ) async throws {
      let server = try await TestSSHServer.start()
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("shell-controller-" + UUID().uuidString)
      let suite = "shell-controller-" + UUID().uuidString
      defer {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
      }
      var controller: SSHShellController?
      do {
        let defaults = try #require(UserDefaults(suiteName: suite))
        let app = RoamingAppModel(
          store: ConnectionStore(
            fileURL: directory.appendingPathComponent("hosts.json")
          ),
          resumeStore: SessionResumeStore(defaults: defaults),
          savedPasswords: InMemorySavedPasswordStore(),
          settingsDefaults: defaults,
        )
        app.resilience = resilience
        let host = HostProfile(
          nickname: "Host",
          host: "127.0.0.1",
          port: server.port,
          username: TestSSHServer.username,
        )
        let model = TerminalScreenModel(
          host: host,
          profile: .profile(for: .mobile),
          kind: .ordinarySSH,
        )
        let trust = FileHostTrustStore(
          fileURL: directory.appendingPathComponent("keys.json")
        )
        try await trust.setTrustedKey(server.hostKeyLine, for: server.identity)
        let access = SSHAccess(app: app, trustStore: trust)
        let surface = SSHShellController(model: model, app: app, access: access)
        controller = surface
        try await operation(server, app, surface)
      } catch {
        await controller?.close(.detach)
        await server.shutdown()
        throw error
      }
      await controller?.close(.detach)
      await server.shutdown()
    }

    private func eventually(
      within limit: Duration = .seconds(2),
      _ condition: () -> Bool
    ) async throws -> Bool {
      let deadline = ContinuousClock.now + limit
      while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try await Task.sleep(for: .milliseconds(5))
      }
      return true
    }
  }
}
