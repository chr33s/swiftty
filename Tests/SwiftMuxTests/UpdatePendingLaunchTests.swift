import Dispatch
import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
import SwiftMuxXPC
import SwiftMuxService
import Synchronization
import Testing

struct UpdatePendingLaunchTests {
  @Test(arguments: [false, true])
  func updateWaitsForAnAdmittedLaunchAndItsTeardown(
    _ endWorkspaces: Bool
  ) async throws {
    let started = Mutex(false)
    let release = DispatchSemaphore(value: 0)
    var configuration = MuxServiceConfiguration(
      launcherPath: try launcherPath()
    )
    configuration.beforeLaunch = {
      started.withLock { $0 = true }
      _ = release.wait(timeout: .now() + 5)
    }
    let service = try MuxService(configuration: configuration)
    let registration = PendingLaunchRegistration(service)
    let connection = try await registration.connect()
    defer { release.signal() }
    var launch = shellLaunch()
    launch.command = ["/bin/sh", "-c", "exec /bin/sleep 60"]
    let creating = Task {
      try await connection.execute(
        .newWorkspace(NewWorkspaceRequest(launch: launch))
      )
    }
    let replacements = Mutex(0)
    let update = UpdateCoordinator(
      connect: { try await registration.connect() },
      registration: registration,
      replace: { _ in replacements.withLock { $0 += 1 } },
    )
    await update.setBarrierTimeout(.seconds(3))
    await update.stage(URL(fileURLWithPath: "/tmp/Pending.app"))
    var installing: Task<UpdateCoordinator.Phase, Never>?
    do {
      try #require(await until { started.withLock { $0 } })
      let install = Task { await update.install(endWorkspaces: endWorkspaces) }
      installing = install
      try #require(
        await until {
          switch await update.phase {
          case .awaitingBarrier, .finished, .failed: true
          default: false
          }
        }
      )
      guard case let .status(status) = try await connection.execute(.status)
      else { throw MuxError(.invalidRequest, "unexpected status") }
      #expect(status.workspaces == 0)
      #expect(
        status.panes == 1,
        "the admitted launch must remain in the wire barrier"
      )
      #expect(status.quiescing)
      #expect(!status.attached)
      #expect(await !service.isEmpty)
      #expect(await update.phase == .awaitingBarrier)
      #expect(registration.log.isEmpty)
      #expect(replacements.withLock { $0 } == 0)
      release.signal()
      await #expect { try await creating.value } throws: {
        ($0 as? MuxError)?.code == .quiescing
      }
      guard case .finished = await install.value else {
        Issue.record("expected update after launch retirement")
        await connection.close()
        return
      }
      #expect(await until { await service.isEmpty })
      #expect(registration.emptyAtUnregister == true)
      #expect(registration.log == ["unregister", "register"])
      #expect(replacements.withLock { $0 } == 1)
      await connection.close()
    } catch {
      release.signal()
      installing?.cancel()
      _ = await installing?.value
      _ = try? await creating.value
      service.prepareToExit {}
      await connection.close()
      throw error
    }
  }

  private func until(_ predicate: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(2)
    while await !predicate(), ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(2))
    }
    return await predicate()
  }
}

private final class PendingLaunchRegistration: AgentRegistration, Sendable {
  private let state:
    Mutex<
      (service: MuxService, endpoint: SMXEndpoint, log: [String], empty: Bool?)
    >

  init(_ service: MuxService) {
    state = Mutex((service, service.listenAnonymously(), [], nil))
  }

  var log: [String] { state.withLock { $0.log } }
  var emptyAtUnregister: Bool? { state.withLock { $0.empty } }

  func connect() async throws -> MuxConnection {
    try await MuxConnection.connect(
      endpoint: state.withLock { $0.endpoint },
      frontend: .control
    )
  }

  func unregister() async throws {
    let old = state.withLock { $0.service }
    let empty = await old.isEmpty
    state.withLock {
      $0.log.append("unregister");
      $0.empty = empty
    }
  }

  func register() async throws {
    let fresh = try Harness()
    state.withLock {
      $0.service = fresh.service
      $0.endpoint = fresh.endpoint
      $0.log.append("register")
    }
  }
}
