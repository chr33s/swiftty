#if os(macOS)
import ScreenProtocol
import SessionCore
import SwiftMuxService
@testable import TerminalHost
import TestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct RegistryFixtureCleanupTests {
  private enum Probe: Error { case failedBody }

  @Test
  func failedFixtureKeepsItsErrorAndAwaitsIgnoringPaneRetirement() async throws
  {
    var service: MuxService?
    var pid: Int32?
    try await RuntimeFixture.withCleanup(
      {
        do {
          try await withRegistry(
            launch: {
              shellLaunch(
                "trap '' HUP; printf 'cleanup-ready\\n'; exec /bin/sleep 60"
              )
            },
            { registry in
              service = registry.service
              let grant = try await registry.create(
                grid: GridSize(columns: 80, rows: 24)
              )
              let client = TestClient(registry)
              defer { client.connection.close() }
              _ = try await client.attached(grant)
              _ = try await client.snapshot("ignoring cleanup pane ready") {
                screenText($0).contains("cleanup-ready")
              }
              let session = try #require(registry.session(grant.sessionID))
              // Pin the type: assigning to an optional would make #require a no-op.
              pid = try #require(await shellPID(registry, session)) as Int32
              throw Probe.failedBody
            }
          )
          Issue.record("expected the fixture body error")
        } catch { #expect(error as? Probe == .failedBody) }
        let ownedPID = try #require(pid)
        #expect(
          !isAlive(ownedPID),
          "fixture returned before its pane was reaped"
        )
      },
      cleanup: {
        // Retain the owned service while observing any outstanding native
        // retirement after a failed regression. Never signal a numeric PID.
        if let pid {
          do {
            try await RuntimeFixture.wait(
              "owned cleanup pane absent",
              timeout: .seconds(5)
            ) { !isAlive(pid) }
          } catch { Issue.record(error) }
        }
        withExtendedLifetime(service) {}
      }
    )
  }

  @Test
  func endToEndShutdownIsAwaitableByConcurrentAndRepeatedCallers() async throws
  {
    let harness = try await RoamingEndToEndTests.Harness()
    try await RuntimeFixture.withCleanup(
      {
        _ = try await harness.registry.create(
          grid: GridSize(columns: 80, rows: 24)
        )
        async let first: Void = harness.shutdown()
        async let second: Void = harness.shutdown()
        _ = await (first, second)
        await harness.shutdown()
        #expect(try await harness.registry.list().isEmpty)
        #expect(harness.listener.activeConnectionCount == 0)
      },
      cleanup: { await harness.shutdown() }
    )
  }
}
#endif
