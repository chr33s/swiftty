@testable import SSHClient
import Synchronization
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct SessionSetupTests {
  enum Stage: CaseIterable, Sendable { case acceptance, pty, shell }
  enum Service: CaseIterable, Sendable { case exec, sftp, shell }

  @Test(arguments: [-1, Int.min])
  func negativeShellReadCreditIsRejectedBeforeOpening(credit: Int) async throws
  {
    let server = try await TestSSHServer.start()
    do {
      let connection = try await server.connect()
      await #expect(
        throws: SSHClientError.invalidConfiguration(
          "negative shell read credit"
        )
      ) {
        _ = try await connection.openShell(
          columns: 80,
          rows: 24,
          initialReadCredit: credit
        ) { _ in }
      }
      #expect(server.state.sessionChannels.withLock { $0.isEmpty })
      let shell = try await connection.openShell(
        columns: 80,
        rows: 24,
        initialReadCredit: 0
      ) { _ in }
      shell.grantReadCredit(1024)
      await shell.close()
      await connection.close()
    } catch {
      await server.shutdown()
      throw error
    }
    await server.shutdown()
  }

  @Test(arguments: Service.allCases)
  func closedSSHReportsConnectionClosed(service: Service) async throws {
    let server = try await TestSSHServer.start()
    do {
      let connection = try await server.connect()
      await connection.close()
      await #expect(throws: SSHClientError.connectionClosed) {
        switch service {
        case .exec: _ = try await connection.execute(command: "echo-split")
        case .sftp: _ = try await connection.openSFTP()
        case .shell:
          _ = try await connection.openShell(columns: 80, rows: 24) { _ in }
        }
      }
    } catch {
      await server.shutdown()
      throw error
    }
    await server.shutdown()
  }

  @Test(arguments: [false, true])
  func execAndSFTPAcceptanceCanBeCancelled(sftp: Bool) async throws {
    let server = try await TestSSHServer.start()
    do {
      let connection = try await server.connect()
      server.state.faults.withLock { $0.holdSessionChannelOpen = true }
      let finished = Mutex(false)
      let request = Task {
        defer { finished.withLock { $0 = true } }
        if sftp {
          _ = try await connection.openSFTP()
        } else {
          _ = try await connection.execute(command: "echo-split")
        }
      }
      #expect(
        try await waitUntil {
          server.state.heldSessionOpens.withLock { !$0.isEmpty }
        }
      )
      request.cancel()
      #expect(
        try await waitUntil(timeout: .seconds(1)) { finished.withLock { $0 } }
      )
      await #expect(throws: CancellationError.self) { try await request.value }
      #expect(try await waitUntil { !connection.isActive })
      #expect(
        try await waitUntil {
          server.state.sessionChannels.withLock { $0.isEmpty }
        }
      )
      await connection.close()
    } catch {
      await server.shutdown()
      throw error
    }
    await server.shutdown()
  }

  @Test
  func cancellingAnAcceptedExecKeepsSSHUsable() async throws {
    let server = try await TestSSHServer.start()
    do {
      let connection = try await server.connect()
      let request = Task {
        try await connection.execute(command: "wait-forever")
      }
      #expect(
        try await waitUntil {
          server.state.sessionChannels.withLock { !$0.isEmpty }
        }
      )
      // Acceptance may still be in flight: observe exec setup in the handler.
      #expect(
        try await waitUntil {
          server.state.lastExecCommand.withLock { $0 == "wait-forever" }
        }
      )
      request.cancel()
      await #expect(throws: CancellationError.self) {
        _ = try await request.value
      }
      #expect(
        try await waitUntil {
          server.state.sessionChannels.withLock { $0.isEmpty }
        }
      )
      let client = try await connection.openSFTP()
      #expect(client.isActive)
      await client.close()
      await connection.close()
    } catch {
      await server.shutdown()
      throw error
    }
    await server.shutdown()
  }

  @Test(arguments: Stage.allCases)
  func everyShellSetupStageHasADeadline(stage: Stage) async throws {
    let server = try await TestSSHServer.start()
    do {
      let connection = try await server.connect()
      server.state.faults.withLock {
        $0.holdSessionChannelOpen = stage == .acceptance
        $0.withholdPTYReply = stage == .pty
        $0.withholdShellReply = stage == .shell
      }
      await #expect(throws: SSHClientError.channelSetupTimeout) {
        _ = try await connection.openShell(
          columns: 80,
          rows: 24,
          setupTimeout: .seconds(1)
        ) { _ in }
      }
      #expect(
        try await waitUntil {
          server.state.sessionChannels.withLock { $0.isEmpty }
        }
      )
      #expect(connection.isActive == (stage != .acceptance))
      if stage != .acceptance {
        let client = try await connection.openSFTP()
        #expect(client.isActive)
        await client.close()
      }
      await connection.close()
    } catch {
      await server.shutdown()
      throw error
    }
    await server.shutdown()
  }

  @Test(arguments: [false, true])
  func execAndSFTPChannelAcceptanceHaveDeadlines(sftp: Bool) async throws {
    let server = try await TestSSHServer.start()
    do {
      let connection = try await server.connect()
      server.state.faults.withLock { $0.holdSessionChannelOpen = true }
      if sftp {
        await #expect(throws: SFTPError.requestTimedOut) {
          _ = try await connection.openSFTP(requestTimeout: .seconds(1))
        }
      } else {
        await #expect(throws: SSHClientError.execTimeout) {
          _ = try await connection.execute(
            command: "echo-split",
            limits: .init(timeout: .seconds(1))
          )
        }
      }
      #expect(try await waitUntil { !connection.isActive })
      #expect(
        try await waitUntil {
          server.state.sessionChannels.withLock { $0.isEmpty }
        }
      )
      await connection.close()
    } catch {
      await server.shutdown()
      throw error
    }
    await server.shutdown()
  }

  @Test(arguments: Stage.allCases)
  func cancellationWhileOpeningAShellClosesOwnedResources(
    stage: Stage
  ) async throws {
    let server = try await TestSSHServer.start()
    do {
      let connection = try await server.connect()
      server.state.faults.withLock {
        $0.holdSessionChannelOpen = stage == .acceptance
        $0.withholdPTYReply = stage == .pty
        $0.withholdShellReply = stage == .shell
      }
      let finished = Mutex(false)
      let request = Task {
        defer { finished.withLock { $0 = true } }
        return try await connection.openShell(columns: 80, rows: 24) { _ in }
      }
      #expect(
        try await waitUntil {
          switch stage {
          case .acceptance:
            server.state.heldSessionOpens.withLock { !$0.isEmpty }
          case .pty: server.state.ptyRequest.withLock { $0 != nil }
          case .shell: server.state.shellRequests.withLock { $0 > 0 }
          }
        }
      )
      request.cancel()
      #expect(
        try await waitUntil(timeout: .seconds(1)) { finished.withLock { $0 } }
      )
      // Release the old implementation too, so a regression blocks no task.
      let held = server.state.heldSessionOpens.withLock { value in
        let held = value
        value.removeAll()
        return held
      }
      for promise in held { promise.succeed() }
      if !finished.withLock({ $0 }) { await connection.close() }
      if case let .failure(error) = await request.result {
        #expect(error is CancellationError)
      } else {
        Issue.record("Cancelled shell setup succeeded")
      }
      #expect(
        try await waitUntil {
          server.state.sessionChannels.withLock { $0.isEmpty }
        }
      )
      #expect(connection.isActive == (stage != .acceptance))
      if stage != .acceptance {
        let client = try await connection.openSFTP()
        #expect(client.isActive)
        await client.close()
      }
      await connection.close()
    } catch {
      await server.shutdown()
      throw error
    }
    await server.shutdown()
  }
}
