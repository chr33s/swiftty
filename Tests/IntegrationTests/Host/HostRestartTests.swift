#if os(macOS)
import Foundation
import ScreenProtocol
import SessionCore
import SwiftMuxProtocol
@testable import SwiftMuxGateway
@testable import SwiftMuxGatewayRoaming
@testable import TerminalHost
import Testing

/// Roaming hosts whose sessions outlive them (the durable gateway).
struct HostRestartTests {
  @Test
  func `a grant for a live workspace the host forgot asks for a fresh grant`()
    async throws
  {
    try await withRegistry { registry in
      let grant = try await registry.create(
        grid: GridSize(columns: 80, rows: 24)
      )
      // The same service and epoch, but a host that never issued this grant
      // (as after a gateway restart): the client must renew over SSH, not
      // lose a session whose workspace is still running.
      let restarted = SessionRegistry(
        service: registry.service,
        identity: testIdentity()
      )
      let client = TestClient(restarted)
      defer { client.connection.close() }
      try await client.attach(grant)
      #expect(try await client.errorCode() == .expired)
      // An unknown workspace is still lost.
      var unknown = grant
      unknown.sessionID = SessionID(WorkspaceID())
      let other = TestClient(restarted)
      defer { other.connection.close() }
      try await other.attach(unknown)
      #expect(try await other.errorCode() == .unknownSession)
    }
  }

  @Test
  func `gateway sessions start above an earlier run's counters`() {
    let earlier = Date(timeIntervalSinceReferenceDate: 800_000_000)
    var seen = GatewayRoamingWorkspaces.floor(at: earlier)
    // A long first run: a million screens and resizes, a thousand attaches.
    seen.screenRevision += 1_000_000
    seen.resizeRevision += 1_000_000
    seen.epoch += 1000
    let next = GatewayRoamingWorkspaces.floor(at: earlier.addingTimeInterval(5))
    #expect(next.screenRevision > seen.screenRevision)
    #expect(next.resizeRevision > seen.resizeRevision)
    #expect(next.epoch > seen.epoch)
  }

  @Test
  func `updates get room to finish or defer`() throws {
    #expect(GatewayControlServer.deadline(for: .listWorkspaces) == 30)
    #expect(
      GatewayControlServer.deadline(
        for: .prepareUpdate(
          GatewayUpdateRequest(
            candidate: "/tmp/x",
            workerBuild: nil,
            workerProtocol: nil
          )
        )
      ) > 60
    )
  }
}
#endif
