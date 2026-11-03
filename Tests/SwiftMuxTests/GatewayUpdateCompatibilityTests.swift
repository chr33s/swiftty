import Foundation
import SwiftMuxGateway
@testable import SwiftMuxGuardian
import SwiftMuxProtocol
import Testing

struct GatewayUpdateCompatibilityTests {
  @Test
  func retainedUnavailableBuildsCannotBeIgnored() throws {
    let live = record(version: 2, available: true)
    let unavailable = record(version: 3, available: false)
    do {
      try GatewayUpdateCompatibility.validate(
        guardianProtocol: GuardianWire.version,
        workerProtocols: [2],
        inventory: [live, unavailable]
      )
      Issue.record("update excluded the unavailable retained build")
    } catch let error as MuxError {
      #expect(error.code == .incompatibleVersion)
      #expect(
        error.message.contains(unavailable.authority.workspace.description)
      )
    }
    try GatewayUpdateCompatibility.validate(
      guardianProtocol: GuardianWire.version,
      workerProtocols: [2, 3],
      inventory: [live, unavailable]
    )
  }

  @Test(arguments: [false, true])
  func unknownAndStartingWorkersDeferUpdate(starting: Bool) throws {
    var unknown = record(version: nil, available: false)
    unknown.starting = starting
    do {
      try GatewayUpdateCompatibility.validate(
        guardianProtocol: GuardianWire.version,
        workerProtocols: [2],
        inventory: [unknown]
      )
      Issue.record("unknown metadata was treated as compatibility")
    } catch let error as MuxError { #expect(error.code == .quiescing) }
  }

  @Test
  func emptyInventoryStillRequiresGuardianCompatibility() throws {
    #expect(throws: MuxError.self) {
      try GatewayUpdateCompatibility.validate(
        guardianProtocol: GuardianWire.version + 1,
        workerProtocols: [2],
        inventory: []
      )
    }
    try GatewayUpdateCompatibility.validate(
      guardianProtocol: GuardianWire.version,
      workerProtocols: [2],
      inventory: []
    )
    for versions: Set<Int> in [[], [0], [-1], Set(1 ... 65)] {
      #expect(throws: MuxError.self) {
        try GatewayUpdateCompatibility.validate(
          guardianProtocol: GuardianWire.version,
          workerProtocols: versions,
          inventory: []
        )
      }
    }
  }

  @Test
  func olderInventoryDecodesAsUnknownInsteadOfAssumingCurrentVersion() throws {
    let value = record(version: nil, available: true)
    let encoded = try JSONEncoder().encode(value)
    let object = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    #expect(object["workerProtocol"] == nil)
    let decoded = try JSONDecoder()
      .decode(GuardianWorkspaceInventory.self, from: encoded)
    #expect(decoded.workerProtocol == nil)
    #expect(throws: MuxError.self) {
      try GatewayUpdateCompatibility.validate(
        guardianProtocol: GuardianWire.version,
        workerProtocols: Set(SMX.compatibleVersions),
        inventory: [decoded]
      )
    }
  }

  private func record(
    version: Int?,
    available: Bool
  ) -> GuardianWorkspaceInventory {
    GuardianWorkspaceInventory(
      authority: GuardianAuthority(
        incarnation: UUID(),
        workspace: WorkspaceID(),
        generation: 1
      ),
      available: available,
      worker: nil,
      panes: [],
      workerProtocol: version
    )
  }
}
