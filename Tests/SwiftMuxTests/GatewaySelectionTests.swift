import Foundation
@testable import SwiftMuxGateway
@testable import SwiftMuxGuardian
import SwiftMuxProtocol
import Testing

struct GatewaySelectionTests {
  private func record(
    _ name: String?,
    time: TimeInterval = 1,
    id: WorkspaceID = WorkspaceID(),
    state: GatewayWorkspaceDirectory.State? = nil
  ) -> GatewayWorkspaceDirectory.Record {
    let summary = name.map {
      WorkspaceSummary(
        id: id,
        name: $0,
        tabCount: 1,
        paneCount: 1,
        createdAt: Date(timeIntervalSince1970: time),
        isAttached: false
      )
    }
    return .init(
      inventory: .init(
        authority: .init(incarnation: UUID(), workspace: id, generation: 1),
        available: true,
        worker: nil,
        panes: []
      ),
      state: state ?? summary.map { .available($0) } ?? .discovering,
      graph: nil,
      lastKnownSummary: summary
    )
  }

  @Test
  func unavailableLatestAndDuplicateNamesNeverFallBackToHealthyWorkspace()
    throws
  {
    let healthy = record("work", time: 1)
    let failed = record(
      "work",
      time: 2,
      state: .unavailable(.init(.connectionLost))
    )
    let records = [healthy, failed]
    let latest = try GatewayWorkspaceDirectory.select(.latest, from: records)
    #expect(latest.inventory.authority == failed.inventory.authority)
    #expect(
      throws: MuxError(
        .invalidRequest,
        "workspace selector is ambiguous; use an explicit ID"
      )
    ) { try GatewayWorkspaceDirectory.select(.name("work"), from: records) }
    let explicit = try GatewayWorkspaceDirectory.select(
      .id(failed.inventory.authority.workspace),
      from: records
    )
    #expect(explicit.inventory.authority == failed.inventory.authority)
  }

  @Test
  func
    unknownMetadataRequiresExplicitIdentityAndEqualCreationTimesAreAmbiguous()
    throws
  {
    let known = record("known")
    let unknown = record(nil, state: .unavailable(.init(.connectionLost)))
    for selector in [WorkspaceSelector.latest, .name("known")] {
      do {
        _ = try GatewayWorkspaceDirectory.select(
          selector,
          from: [known, unknown]
        )
        Issue.record("incomplete inventory silently selected a workspace")
      } catch let error as MuxError { #expect(error.code == .quiescing) }
    }
    #expect(
      try GatewayWorkspaceDirectory
        .select(
          .id(unknown.inventory.authority.workspace),
          from: [known, unknown]
        )
        .inventory.authority == unknown.inventory.authority
    )
    let empty = record(nil, state: .empty)
    #expect(
      try GatewayWorkspaceDirectory.select(.latest, from: [known, empty])
        .inventory.authority == known.inventory.authority
    )
    #expect(throws: MuxError.self) {
      try GatewayWorkspaceDirectory.select(
        .latest,
        from: [known, record("same time")]
      )
    }
  }

  @Test
  func exactNamesPrecedePrefixesAndSharedPrefixesAreRejected() throws {
    let first = record(
      "first",
      id: WorkspaceID("12345678-0000-0000-0000-000000000001")!
    )
    let second = record(
      "second",
      id: WorkspaceID("12345678-0000-0000-0000-000000000002")!
    )
    let named = record("12345678")
    #expect(
      try GatewayWorkspaceDirectory
        .select(.name("12345678"), from: [first, second, named]).inventory
        .authority == named.inventory.authority
    )
    #expect(throws: MuxError.self) {
      try GatewayWorkspaceDirectory.select(
        .name("12345678"),
        from: [first, second]
      )
    }
    #expect(
      try GatewayWorkspaceDirectory.select(.name("12345678"), from: [first])
        .inventory.authority == first.inventory.authority
    )
    for name in ["1234567", "", "nonexistent"] {
      #expect(throws: MuxError.self) {
        try GatewayWorkspaceDirectory.select(.name(name), from: [first])
      }
    }
  }
}
