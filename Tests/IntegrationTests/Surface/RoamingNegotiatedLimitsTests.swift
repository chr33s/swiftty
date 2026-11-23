import ScreenProtocol
import SessionCore
@testable import RoamingKit
@testable import TerminalSurface
import Testing
import TestSupport

struct RoamingNegotiatedLimitsTests {
  @Test
  func invalidSemanticKeysAreRefusedBeforeQueueing() async throws {
    let f = try RoamingFixture()
    defer { Task { await f.client.close() } }
    try #require(try await f.startActive())
    for key in [
      SemanticKey(.function(0)), SemanticKey(.function(13)),
      SemanticKey(.function(.min)), SemanticKey(.function(.max)),
      SemanticKey(.enter, modifiers: .init(rawValue: 8)),
      SemanticKey(.enter, modifiers: .init(rawValue: 255)),
    ] { #expect(await f.client.submit(.key(key)) == .refused(.invalid)) }
    #expect(await f.client.status.pendingInputCount == 0)
    #expect(await f.host.received.isEmpty)
    #expect(
      await f.client.submit(.key(.init(.enter))) == .accepted(sequence: 1)
    )
    try #require(await eventually { await f.host.applied == [1] })
    await f.client.close()
  }

  @Test(arguments: 0 ..< 3)
  func grantMustFitInitialGridAndAttachmentRecord(_ bound: Int) async throws {
    let f = try RoamingFixture()
    defer { Task { await f.client.close() } }
    var limits = NegotiatedLimits()
    switch bound {
    case 0: limits.maxColumns = 19
    case 1: limits.maxRows = 3
    default: limits.maxControlRecordBytes = 1
    }
    await f.host.set(limits: limits)
    await #expect(throws: RoamingClientError.protocolViolation) {
      try await f.client.start(.create(.init(columns: 20, rows: 4)))
    }
    #expect(await f.connector.connectCount == 0)
  }

  @Test(arguments: [false, true])
  func zeroBudgetsDisableInputWithoutPreventingAttachment(
    _ pending: Bool
  ) async throws {
    let f = try RoamingFixture()
    defer { Task { await f.client.close() } }
    var limits = NegotiatedLimits()
    if pending {
      limits.maxPendingInputBytes = 0
    } else {
      limits.maxPasteBytes = 0
    }
    await f.host.set(limits: limits)
    try #require(try await f.startActive())
    #expect(await f.client.submit(.text("x")) == .refused(.invalid))
    #expect(await f.client.submit(.paste("")) == .refused(.invalid))
    let key = await f.client.submit(.key(.init(.enter)))
    #expect(key == (pending ? .refused(.invalid) : .accepted(sequence: 1)))
    await f.client.close()
  }

  @Test(arguments: [false, true])
  func createAndResumeApplyInputAndGridCaps(_ resume: Bool) async throws {
    let f = try RoamingFixture()
    defer { Task { await f.client.close() } }
    var limits = NegotiatedLimits()
    limits.maxColumns = 24
    limits.maxRows = 5
    limits.maxPendingInputBytes = 128
    limits.maxPasteBytes = 16
    limits.maxControlRecordBytes = 512
    await f.host.set(limits: limits)
    try await f.client.start(
      resume
        ? .resume(f.host.sessionID) : .create(.init(columns: 200, rows: 80))
    )
    try #require(await f.waitFor(.active))
    #expect(
      await f.client.submit(.paste(String(repeating: "x", count: 17)))
        == .refused(.invalid)
    )
    #expect(
      await f.client.submit(.text(String(repeating: "x", count: 17)))
        == .refused(.invalid)
    )
    await f.client.proposeGrid(columns: 200, rows: 80)
    try #require(
      await eventually {
        let columns = await f.host.columns
        let rows = await f.host.rows
        return columns == 24 && rows == 5
      }
    )
    try #require(
      await eventually { await f.client.status.pendingInputCount == 0 }
    )
    await f.host.set(withholdAcks: true)
    for sequence in 2 ... 5 {
      #expect(
        await f.client.submit(.text(String(repeating: "x", count: 16)))
          == .accepted(sequence: UInt64(sequence))
      )
    }
    #expect(await f.client.submit(.text("x")) == .refused(.backpressure))
    #expect(await f.client.status.pendingInputCount == 4)
    await f.client.close()
  }

  @Test(arguments: 0 ..< 7)
  func malformedGrantBoundsDoNotReachConnector(_ index: Int) async throws {
    let f = try RoamingFixture()
    defer { Task { await f.client.close() } }
    let fields: [WritableKeyPath<NegotiatedLimits, Int>] = [
      \.maxColumns, \.maxRows, \.maxControlRecordBytes,
      \.maxSnapshotEncodedBytes, \.maxSnapshotDecodedBytes,
      \.maxPendingInputBytes, \.maxPasteBytes,
    ]
    var limits = NegotiatedLimits()
    limits[keyPath: fields[index]] = -1
    await f.host.set(limits: limits)
    await #expect(throws: RoamingClientError.protocolViolation) {
      try await f.client.start(.create(.init(columns: 20, rows: 4)))
    }
    #expect(await f.connector.connectCount == 0)
  }

  @Test
  func refreshLowersQueueBudgetWithoutDroppingAcceptedInput() async throws {
    let f = try RoamingFixture()
    defer { Task { await f.client.close() } }
    await f.host.set(withholdAcks: true, dropInputsAfter: .some(0))
    try #require(try await f.startActive())
    for sequence in 1 ... 3 {
      #expect(
        await f.client.submit(.text("12345678"))
          == .accepted(sequence: UInt64(sequence))
      )
    }
    try #require(await eventually { await f.host.received.count == 3 })
    var limits = NegotiatedLimits()
    limits.maxPendingInputBytes = 32
    limits.maxPasteBytes = 8
    await f.host.set(dropInputsAfter: .some(nil), limits: limits)
    f.clock.advanceWallClock(by: 9 * 3600)
    await f.host.severCurrent()
    try #require(
      await eventually {
        let count = await f.host.attachCount
        let state = await f.client.state
        return count == 2 && state == .active
      }
    )
    try #require(await eventually { await f.host.applied == [1, 2, 3] })
    #expect(await f.client.status.pendingInputCount == 3)
    #expect(await f.client.submit(.text("x")) == .refused(.backpressure))
    let epoch = try #require(await f.host.currentEpoch)
    await f.host.sendControlForTesting(.inputAck(epoch: epoch, sequence: 3))
    try #require(
      await eventually { await f.client.status.pendingInputCount == 0 }
    )
    #expect(await f.client.submit(.text("12345678")) == .accepted(sequence: 4))
    #expect(await f.client.submit(.text("x")) == .refused(.backpressure))
    await f.client.close()
  }

  @Test
  func incompatibleRefreshReportsFailureAndPreservesPendingSequence()
    async throws
  {
    let f = try RoamingFixture()
    defer { Task { await f.client.close() } }
    await f.host.set(dropInputsAfter: .some(0))
    try #require(try await f.startActive())
    #expect(
      await f.client.submit(.text("retained-input")) == .accepted(sequence: 1)
    )
    try #require(await eventually { await f.host.received.count == 1 })
    var limits = NegotiatedLimits()
    limits.maxPasteBytes = 8
    await f.host.set(limits: limits)
    f.clock.advanceWallClock(by: 9 * 3600)
    await f.host.severCurrent()
    try #require(
      await eventually {
        await f.client.status.lastFailure == .protocolViolation
      }
    )
    #expect(await f.client.status.pendingInputCount == 1)
    #expect(await f.host.received.count == 1)
    await f.host.set(dropInputsAfter: .some(nil), limits: NegotiatedLimits())
    try #require(
      await eventually {
        let state = await f.client.state
        let applied = await f.host.applied
        return state == .active && applied == [1]
      }
    )
    #expect(await f.client.submit(.text("next")) == .accepted(sequence: 2))
    await f.client.close()
  }

  @Test
  func escapedInputAndIncomingControlUseNegotiatedRecordCap() async throws {
    let f = try RoamingFixture()
    defer {
      Task {
        await f.client.close();
        await f.connector.release()
      }
    }
    var limits = NegotiatedLimits()
    limits.maxControlRecordBytes = 512
    await f.host.set(limits: limits)
    try #require(try await f.startActive())
    let escaped = String(repeating: "\u{1}", count: 128)
    #expect(await f.client.submit(.text(escaped)) == .refused(.invalid))
    #expect(await f.client.submit(.paste(escaped)) == .refused(.invalid))
    #expect(await f.client.status.pendingInputCount == 0)
    await f.connector.block()
    // Length 513 alone must close immediately, without waiting for JSON.
    let result = await f.client.handleControlForTesting([0, 0, 2, 1])
    #expect(result.closed)
    #expect(await f.client.status.lastFailure == .protocolViolation)
    await f.client.close()
    await f.connector.release()
  }

  @Test(arguments: 0 ..< 3)
  func snapshotBoundsAreCheckedBeforePresentationOrAcknowledgment(
    _ bound: Int
  ) async throws {
    let f = try RoamingFixture()
    try await RuntimeFixture.withCleanup {
      var limits = NegotiatedLimits()
      limits.maxColumns = 20
      limits.maxRows = 4
      // Compression size can vary across encodings of the same snapshot.
      // Derive the ceiling from the exact bytes delivered to the client.
      let initial = try rstFrameRecord(await f.host.snapshotForTesting())
      let initialHeader = try #require(try SnapshotFrame.header(initial))
      if bound == 1 {
        limits.maxSnapshotEncodedBytes = initialHeader.encodedLength
      }
      if bound == 2 {
        limits.maxSnapshotDecodedBytes = initialHeader.decodedLength
      }
      await f.host.set(sendSnapshotOnAttach: false, limits: limits)
      try await f.client.start(.create(.init(columns: 20, rows: 4)))
      try #require(await eventually { await f.host.currentEpoch == 1 })
      try await f.host.sendEncodedSnapshotForTesting(initial)
      try #require(await f.waitFor(.active))
      try #require(await eventually { await f.host.screenAckCount == 1 })
      let installed = f.sink.count
      var snapshot = ScreenSnapshot.blank(
        sessionID: f.host.sessionID,
        columns: bound == 0 ? 21 : 20,
        rows: 4
      )
      if bound != 0 {
        snapshot.title = String(
          (0 ..< 512).map { Character(Unicode.Scalar(33 + ($0 * 17) % 90)!) }
        )
      }
      snapshot.attachmentEpoch = try #require(await f.host.currentEpoch)
      snapshot.screenRevision = 10
      let rejected = try rstFrameRecord(snapshot)
      if bound != 0 {
        let larger = try #require(try SnapshotFrame.header(rejected))
        #expect(larger.encodedLength > initialHeader.encodedLength)
        #expect(larger.decodedLength > initialHeader.decodedLength)
      }
      try await f.host.sendEncodedSnapshotForTesting(rejected)
      try #require(
        await eventually {
          await f.client.status.lastFailure == .snapshotRejected
        }
      )
      #expect(f.sink.count == installed)
      #expect(await f.host.screenAckCount == 1)
      #expect(await f.client.state == .active)
    } cleanup: {
      await f.client.close()
    }
  }

  @Test
  func initialSnapshotOneByteOverEncodedLimitIsNotPresentedOrAcknowledged()
    async throws
  {
    let f = try RoamingFixture()
    try await RuntimeFixture.withCleanup {
      let payload = try rstFrameRecord(await f.host.snapshotForTesting())
      let header = try #require(try SnapshotFrame.header(payload))
      try #require(header.encodedLength > 0)
      var limits = NegotiatedLimits()
      limits.maxSnapshotEncodedBytes = header.encodedLength - 1
      await f.host.set(sendSnapshotOnAttach: false, limits: limits)
      try await f.client.start(.create(.init(columns: 20, rows: 4)))
      try #require(await eventually { await f.host.currentEpoch == 1 })
      try await f.host.sendEncodedSnapshotForTesting(payload)
      try #require(
        await eventually {
          await f.client.status.lastFailure == .snapshotRejected
        }
      )
      #expect(f.sink.count == 0)
      #expect(await f.host.screenAckCount == 0)
      #expect(await f.client.state != .active)
    } cleanup: {
      await f.client.close()
    }
  }
}
