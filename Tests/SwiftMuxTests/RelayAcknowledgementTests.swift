import Darwin
import SwiftMuxClient
import SwiftMuxProtocol
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct RelayAcknowledgementTests {
  private func relay(_ harness: Harness) async throws -> MuxConnection {
    let control = try await harness.connect()
    let server = try #require(await control.welcome?.server)
    await control.close()
    return try await MuxConnection.connectWorker(
      endpoint: harness.endpoint,
      expectedPID: getpid(),
      expectedServer: server,
      peerRequirement: nil,
      frontend: .native,
      relaysAcknowledgements: true
    )
  }

  @Test
  func consumingAFrameDoesNotReleaseWorkerCreditOrReady() async throws {
    let harness = try Harness()
    let connection = try await relay(harness)
    guard
      case let .created(workspace) = try await connection.execute(
        .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
      )
    else { throw MuxError(.invalidRequest, "missing workspace") }
    let pane = workspace.tabs[0].activePane
    _ = try await connection.execute(.attach(AttachRequest(.id(workspace.id))))
    _ = try await connection.execute(
      .setGeometry(
        GeometryBatch(
          layoutRevision: workspace.layoutRevision,
          generation: 1,
          entries: [.init(pane: pane, columns: 80, rows: 24)]
        )
      )
    )
    _ = try await connection.execute(.setSubscriptions([pane]))
    let first = try await connection.frame(of: pane) { _ in true }
    #expect(await connection.readiness == nil)
    try await connection.send(.text("echo relay-credit-held\r"), to: pane)
    await #expect(throws: MuxConnection.EventWaitError.timedOut) {
      try await connection.nextEvent(timeout: .milliseconds(50))
    }
    var wrong = first.identity
    wrong.revision += 1
    await #expect(throws: MuxError.self) {
      try await connection.acknowledgeRelayedFrame(wrong)
    }
    #expect(await connection.readiness == nil)
    try await connection.acknowledgeRelayedFrame(first.identity)
    await #expect(throws: MuxError.self) {
      try await connection.acknowledgeRelayedFrame(first.identity)
    }
    var second = try await connection.frame(of: pane) { _ in true }
    let deadline = ContinuousClock.now + .seconds(5)
    while !second.lines.contains("relay-credit-held") {
      guard ContinuousClock.now < deadline else {
        throw MuxError(.connectionLost, "relay output did not arrive")
      }
      try await connection.acknowledgeRelayedFrame(second.identity)
      second = try await connection.frame(of: pane) { _ in true }
    }
    try await connection.acknowledgeRelayedFrame(second.identity)
    _ = try await connection.execute(.detach)
    await #expect(throws: MuxError.self) {
      try await connection.acknowledgeRelayedFrame(second.identity)
    }
    _ = try await connection.execute(.endAllWorkspaces)
    await connection.close()
  }

  @Test
  func inboxCreditRequiresOrderedDownstreamAcknowledgements() async throws {
    var limits = MuxLimits.standard
    limits.inboxPendingUpdates = 2
    let harness = try Harness(limits: limits)
    let connection = try await relay(harness)
    _ = try await connection.execute(.subscribeInbox(true))
    var launch = shellLaunch()
    launch.command = [
      "/bin/sh", "-c",
      "sleep 0.1; printf '\\033]7501;state=error:id=a\\007'; sleep 0.1; printf '\\033]7501;state=error:id=b\\007'; sleep 0.1; printf '\\033]7501;state=error:id=c\\007'; exec sleep 30",
    ]
    _ = try await connection.execute(
      .newWorkspace(NewWorkspaceRequest(launch: launch))
    )
    let deadline = ContinuousClock.now + .seconds(5)
    while true {
      guard
        case let .inbox(page) = try await connection.execute(
          .inbox(InboxQuery())
        )
      else { throw MuxError(.invalidRequest, "missing inbox") }
      if page.counts.needsYou == 3 { break }
      guard ContinuousClock.now < deadline else {
        throw MuxError(.connectionLost, "reports did not arrive")
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    guard
      case let .inbox(first) = try await connection.nextEvent(
        timeout: .seconds(2)
      ),
      case let .inbox(second) = try await connection.nextEvent(
        timeout: .seconds(2)
      )
    else { throw MuxError(.invalidRequest, "missing inbox updates") }
    await #expect(throws: MuxConnection.EventWaitError.timedOut) {
      try await connection.nextEvent(timeout: .milliseconds(50))
    }
    await #expect(throws: MuxError.self) {
      try await connection.acknowledgeRelayedInbox(
        revision: second.revision,
        token: second.acknowledgementToken
      )
    }
    try await connection.acknowledgeRelayedInbox(
      revision: first.revision,
      token: first.acknowledgementToken
    )
    await #expect(throws: MuxError.self) {
      try await connection.acknowledgeRelayedInbox(
        revision: first.revision,
        token: first.acknowledgementToken
      )
    }
    guard
      case let .inbox(resync) = try await connection.nextEvent(
        timeout: .seconds(2)
      )
    else { throw MuxError(.invalidRequest, "missing deferred resync") }
    #expect(resync.resync)
    #expect(resync.counts.needsYou == 3)
    try await connection.acknowledgeRelayedInbox(
      revision: second.revision,
      token: second.acknowledgementToken
    )
    try await connection.acknowledgeRelayedInbox(
      revision: resync.revision,
      token: resync.acknowledgementToken
    )
    _ = try await connection.execute(.subscribeInbox(false))
    _ = try await connection.execute(.subscribeInbox(true))
    var followingLaunch = shellLaunch()
    followingLaunch.command = [
      "/bin/sh", "-c",
      "printf '\\033]7501;state=error:id=new\\007'; exec sleep 30",
    ]
    _ = try await connection.execute(
      .newWorkspace(NewWorkspaceRequest(launch: followingLaunch))
    )
    guard
      case let .inbox(following) = try await connection.nextEvent(
        timeout: .seconds(2)
      )
    else {
      throw MuxError(.invalidRequest, "missing new subscription delivery")
    }
    #expect(following.acknowledgementToken != resync.acknowledgementToken)
    await #expect(throws: MuxError.self) {
      try await connection.acknowledgeRelayedInbox(
        revision: following.revision,
        token: resync.acknowledgementToken
      )
    }
    try await connection.acknowledgeRelayedInbox(
      revision: following.revision,
      token: following.acknowledgementToken
    )
    _ = try await connection.execute(.endAllWorkspaces)
    await connection.close()
  }
}
