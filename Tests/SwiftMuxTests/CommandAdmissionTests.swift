import Dispatch
import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
import SwiftMuxXPC
import Synchronization
import Testing

struct CommandAdmissionTests {
  @Test
  func queuedCommandsReserveBeforeDispatch() async throws {
    let peer = CommandPeer()
    defer { peer.close() }
    let connection = try await connect(peer)
    let gate = DispatchSemaphore(value: 0)
    let blocked = Mutex(false)
    connection.queue.async {
      blocked.withLock { $0 = true }
      _ = gate.wait(timeout: .now() + 3)
    }
    #expect(await waitUntil { blocked.withLock { $0 } })
    let refused = Mutex<MuxError?>(nil)
    for _ in 0 ..< 64 { connection.enqueue(.status) }
    connection.enqueue(.listWorkspaces) { result in
      if case let .failure(error) = result { refused.withLock { $0 = error } }
    }
    #expect(refused.withLock { $0?.code } == .resourceLimit)
    gate.signal()
    #expect(await waitUntil { peer.requests.withLock { $0.count >= 64 } })
    #expect(peer.requests.withLock { $0 } == Array(1 ... UInt64(64)))
    peer.replyAll()
    #expect(
      await waitUntil { await connection.pendingCommandCountForTesting == 0 }
    )
    _ = try await connection.execute(.status)
    #expect(peer.requests.withLock { $0.count } == 65)
    await connection.close()
  }

  @Test(arguments: [false, true])
  func retiredCallersKeepWireAdmissionUntilReply(_ timeout: Bool) async throws {
    let peer = CommandPeer()
    defer { peer.close() }
    let connection = try await connect(peer)
    for _ in 0 ..< 63 { connection.enqueue(.status) }
    let caller = Task {
      try await connection.execute(
        .status,
        timeout: timeout ? .milliseconds(20) : nil,
      )
    }
    do {
      try #require(
        await waitUntil { peer.requests.withLock { $0.count == 64 } }
      )
      if timeout {
        await #expect { try await caller.value } throws: {
          ($0 as? MuxError)?.code == .connectionLost
        }
      } else {
        caller.cancel()
        await #expect(throws: CancellationError.self) { try await caller.value }
      }
      let refused = Mutex<MuxError?>(nil)
      connection.enqueue(.listWorkspaces) { result in
        if case let .failure(error) = result { refused.withLock { $0 = error } }
      }
      #expect(
        await waitUntil { refused.withLock { $0?.code == .resourceLimit } }
      )
      peer.replyAll()
      #expect(
        await waitUntil { await connection.pendingCommandCountForTesting == 0 }
      )
      _ = try await connection.execute(.status)
      #expect(peer.requests.withLock { $0.count } == 65)
      await connection.close()
    } catch {
      await connection.close()
      _ = try? await caller.value
      throw error
    }
  }

  @Test
  func awaitedCommandsShareTheQueuedLimit() async throws {
    let peer = CommandPeer()
    defer { peer.close() }
    let connection = try await connect(peer)
    for _ in 0 ..< 64 { connection.enqueue(.status) }
    try #require(await waitUntil { peer.requests.withLock { $0.count == 64 } })
    let finished = Mutex(false)
    let caller = Task {
      defer { finished.withLock { $0 = true } }
      return try await connection.execute(.listWorkspaces)
    }
    #expect(await waitUntil { finished.withLock { $0 } })
    await connection.close()
    await #expect { try await caller.value } throws: {
      ($0 as? MuxError)?.code == .resourceLimit
    }
    #expect(peer.requests.withLock { $0.count } == 64)
  }

  @Test
  func encodingRefusalsRefundTheCommandPool() async throws {
    let peer = CommandPeer()
    defer { peer.close() }
    let connection = try await connect(peer)
    let refused = Mutex(0)
    let name = String(repeating: "x", count: 300_000)
    for _ in 0 ..< 64 {
      connection.enqueue(.renameWorkspace(.latest, name: name)) { result in
        if case let .failure(error) = result, error.code == .resourceLimit {
          refused.withLock { $0 += 1 }
        }
      }
    }
    #expect(await waitUntil { refused.withLock { $0 == 64 } })
    #expect(await connection.pendingCommandCountForTesting == 0)
    #expect(peer.requests.withLock { $0.isEmpty })
    peer.replyAll()
    do {
      #expect(try await connection.execute(.status) == .ok)
      await connection.close()
    } catch {
      await connection.close()
      throw error
    }
  }

  @Test
  func closeRefundsCommandsWhoseCallersAlreadyRetired() async throws {
    let peer = CommandPeer()
    defer { peer.close() }
    let connection = try await connect(peer)
    for _ in 0 ..< 64 { connection.enqueue(.status) }
    #expect(await waitUntil { peer.requests.withLock { $0.count == 64 } })
    await connection.close()
    #expect(await connection.pendingCommandCountForTesting == 0)
    let result = Mutex<MuxError?>(nil)
    connection.enqueue(.status) { reply in
      if case let .failure(error) = reply { result.withLock { $0 = error } }
    }
    #expect(await waitUntil { result.withLock { $0?.code == .connectionLost } })
    #expect(result.withLock { $0 } == MuxError(.connectionLost, "closed"))
  }

  @Test
  func successfulCommandsRetireLongTimeouts() async throws {
    let peer = CommandPeer()
    defer { peer.close() }
    peer.replyAll()
    let connection = try await connect(peer)
    do {
      for _ in 0 ..< 160 {
        #expect(
          try await connection.execute(.status, timeout: .seconds(3600)) == .ok
        )
      }
      #expect(await connection.pendingCommandTimeoutCountForTesting == 0)
      await connection.close()
      #expect(await connection.pendingCommandTimeoutCountForTesting == 0)
    } catch {
      await connection.close()
      throw error
    }
  }

  @Test
  func cancellationRetiresTimeoutsWhileKeepingWireSlots() async throws {
    let peer = CommandPeer()
    defer { peer.close() }
    let connection = try await connect(peer)
    for count in 1 ... 10 {
      let caller = Task {
        try await connection.execute(.status, timeout: .seconds(3600))
      }
      #expect(await waitUntil { peer.requests.withLock { $0.count == count } })
      caller.cancel()
      await #expect(throws: CancellationError.self) { try await caller.value }
    }
    #expect(await connection.pendingCommandTimeoutCountForTesting == 0)
    #expect(await connection.pendingCommandCountForTesting == 10)
    await connection.close()
    #expect(await connection.pendingCommandTimeoutCountForTesting == 0)
  }

  @Test
  func laterCommandsDoNotExtendTheEarliestWaitDeadline() async throws {
    let peer = CommandPeer()
    defer { peer.close() }
    let connection = try await connect(peer)
    let firstFinished = Mutex(false)
    let first = Task {
      defer { firstFinished.withLock { $0 = true } }
      return try await connection.execute(.status, timeout: .milliseconds(80))
    }
    var second: Task<MuxReply, any Error>?
    do {
      try #require(await waitUntil { peer.requests.withLock { $0.count == 1 } })
      let secondFinished = Mutex(false)
      let later = Task {
        defer { secondFinished.withLock { $0 = true } }
        return try await connection.execute(.status, timeout: .seconds(2))
      }
      second = later
      try #require(await waitUntil { peer.requests.withLock { $0.count == 2 } })
      #expect(await waitUntil { firstFinished.withLock { $0 } })
      #expect(!secondFinished.withLock { $0 })
      peer.replyAll()
      await #expect { try await first.value } throws: {
        ($0 as? MuxError) == MuxError(.connectionLost, "no reply in time")
      }
      #expect(try await later.value == .ok)
      #expect(await connection.pendingCommandTimeoutCountForTesting == 0)
      #expect(
        await waitUntil { await connection.pendingCommandCountForTesting == 0 }
      )
      await connection.close()
    } catch {
      await connection.close()
      _ = try? await first.value
      _ = try? await second?.value
      throw error
    }
  }

  @Test(arguments: [false, true])
  func expiredReplyCannotCompleteTheCallerBeforeItsQueuedTimer(
    _ attach: Bool
  ) async throws {
    let peer = CommandPeer()
    defer { peer.close() }
    let connection = try await connect(peer)
    let lease = AttachmentID()
    let command: MuxCommand = attach ? .attach(AttachRequest(.latest)) : .status
    let caller = Task {
      try await connection.execute(command, timeout: .milliseconds(350))
    }
    do {
      try #require(await waitUntil { peer.requests.withLock { $0.count == 1 } })
      await connection.delayRequestTimeoutDeliveryForTesting()
      #expect(await connection.pendingCommandTimeoutCountForTesting == 1)
      try await Task.sleep(for: .milliseconds(500))
      peer.reply(
        1,
        attach ? .attached(attachment: lease, workspace: peer.workspace) : .ok
      )
      await #expect { try await caller.value } throws: {
        ($0 as? MuxError) == MuxError(.connectionLost, "no reply in time")
      }
      // Late wire completion still retires credit and establishes a lease.
      #expect(
        await waitUntil { await connection.pendingCommandCountForTesting == 0 }
      )
      #expect(await connection.pendingCommandTimeoutCountForTesting == 0)
      #expect(await connection.attachment == (attach ? lease : nil))
      await connection.close()
    } catch {
      await connection.close()
      _ = try? await caller.value
      throw error
    }
  }

  @Test(arguments: [
    Duration.seconds(Int64.max), .seconds(Int64.max / 1_000_000_000 - 1),
  ])
  func hugeTimeoutsCanStillCompleteAndRetire(_ timeout: Duration) async throws {
    let peer = CommandPeer()
    defer { peer.close() }
    peer.replyAll()
    let connection = try await connect(peer)
    do {
      #expect(try await connection.execute(.status, timeout: timeout) == .ok)
      #expect(await connection.pendingCommandTimeoutCountForTesting == 0)
      await connection.close()
    } catch {
      await connection.close()
      throw error
    }
  }

  @Test(arguments: [false, true])
  func failuresRetireWaitDeadlines(_ encoding: Bool) async throws {
    let peer = CommandPeer()
    defer { peer.close() }
    let connection = try await connect(peer)
    let command: MuxCommand =
      encoding
      ? .renameWorkspace(.latest, name: String(repeating: "x", count: 300_000))
      : .status
    let caller = Task {
      try await connection.execute(command, timeout: .seconds(3600))
    }
    do {
      if !encoding {
        try #require(
          await waitUntil { peer.requests.withLock { $0.count == 1 } }
        )
        await connection.close()
      }
      await #expect { try await caller.value } throws: {
        ($0 as? MuxError)?.code == (encoding ? .resourceLimit : .connectionLost)
      }
      #expect(await connection.pendingCommandTimeoutCountForTesting == 0)
      #expect(await connection.pendingCommandCountForTesting == 0)
      if encoding {
        peer.replyAll()
        #expect(try await connection.execute(.status) == .ok)
      }
      await connection.close()
    } catch {
      await connection.close()
      _ = try? await caller.value
      throw error
    }
  }

  @Test
  func commandBytesAreReservedBeforeDispatch() async throws {
    var limits = MuxLimits.standard
    limits.maxControlRecordBytes = 1 << 20
    let peer = CommandPeer(limits: limits)
    defer { peer.close() }
    let connection = try await connect(peer)
    let gate = DispatchSemaphore(value: 0)
    let blocked = Mutex(false)
    connection.queue.async {
      blocked.withLock { $0 = true }
      _ = gate.wait(timeout: .now() + 3)
    }
    #expect(await waitUntil { blocked.withLock { $0 } })
    let command = MuxCommand.newWorkspace(
      NewWorkspaceRequest(
        launch: LaunchSpec(environment: [
          "VALUE": String(repeating: "x", count: 800_000)
        ])
      )
    )
    let refused = Mutex<MuxError?>(nil)
    for _ in 0 ..< 5 { connection.enqueue(command) }
    connection.enqueue(command) { result in
      if case let .failure(error) = result { refused.withLock { $0 = error } }
    }
    #expect(refused.withLock { $0?.code } == .resourceLimit)
    gate.signal()
    #expect(await waitUntil { peer.requests.withLock { $0.count >= 5 } })
    peer.replyAll()
    #expect(
      await waitUntil { await connection.pendingCommandCountForTesting == 0 }
    )
    _ = try await connection.execute(command)
    #expect(peer.requests.withLock { $0.count } == 6)
    await connection.close()
  }

  @Test(arguments: [false, true])
  func retiredWaitersKeepCommandBytesUntilReply(_ timeout: Bool) async throws {
    var limits = MuxLimits.standard
    limits.maxControlRecordBytes = 1 << 20
    let peer = CommandPeer(limits: limits)
    defer { peer.close() }
    let connection = try await connect(peer)
    let command = MuxCommand.newWorkspace(
      NewWorkspaceRequest(
        launch: LaunchSpec(environment: [
          "VALUE": String(repeating: "x", count: 800_000)
        ])
      )
    )
    for _ in 0 ..< 4 { connection.enqueue(command) }
    let caller = Task {
      try await connection.execute(
        command,
        timeout: timeout ? .milliseconds(20) : nil
      )
    }
    do {
      try #require(await waitUntil { peer.requests.withLock { $0.count == 5 } })
      if timeout {
        await #expect { try await caller.value } throws: {
          ($0 as? MuxError)?.code == .connectionLost
        }
      } else {
        caller.cancel()
        await #expect(throws: CancellationError.self) { try await caller.value }
      }
      let refused = Mutex<MuxError?>(nil)
      connection.enqueue(command) { result in
        if case let .failure(error) = result { refused.withLock { $0 = error } }
      }
      #expect(
        await waitUntil { refused.withLock { $0?.code == .resourceLimit } }
      )
      peer.replyAll()
      #expect(
        await waitUntil { await connection.pendingCommandCountForTesting == 0 }
      )
      _ = try await connection.execute(command)
      #expect(peer.requests.withLock { $0.count } == 6)
      await connection.close()
    } catch {
      await connection.close()
      _ = try? await caller.value
      throw error
    }
  }

  enum OversizedPayload: CaseIterable, Sendable {
    case name, selector, environmentValue, environmentKey, directory, arguments
    case emptyArguments, geometry, subscriptions, path, palette, attention,
      cursor, search

    private static let text = String(repeating: "x", count: 5_000_000)

    var command: MuxCommand {
      switch self {
      case .name: .renameWorkspace(.latest, name: Self.text)
      case .selector: .attach(AttachRequest(.name(Self.text)))
      case .environmentValue:
        .newWorkspace(
          NewWorkspaceRequest(
            launch: LaunchSpec(environment: ["VALUE": Self.text])
          )
        )
      case .environmentKey:
        .newWorkspace(
          NewWorkspaceRequest(launch: LaunchSpec(environment: [Self.text: ""]))
        )
      case .directory:
        .split(
          pane: PaneID(),
          axis: .leftRight,
          launch: LaunchSpec(workingDirectory: Self.text)
        )
      case .arguments:
        .newTab(name: nil, launch: LaunchSpec(command: [Self.text]))
      case .emptyArguments:
        .newTab(
          name: nil,
          launch: LaunchSpec(command: Array(repeating: "", count: 300_000))
        )
      case .geometry:
        .setGeometry(
          GeometryBatch(
            layoutRevision: 1,
            generation: 1,
            entries: Array(
              repeating: .init(pane: PaneID(), columns: 80, rows: 24),
              count: 200_000
            )
          )
        )
      case .subscriptions:
        .setSubscriptions(Array(repeating: PaneID(), count: 300_000))
      case .path:
        .setSplitRatio(
          tab: TabID(),
          path: Array(repeating: false, count: 5_000_000),
          ratio: 0.5
        )
      case .palette:
        .setTheme(
          MuxTheme(
            palette: FramePalette(
              colors: Array(repeating: 0, count: 2_000_000),
              foreground: 0,
              background: 0,
              cursor: 0
            ),
            dark: true
          )
        )
      case .attention:
        .markSeen(
          AttentionReference(
            source: AttentionSource(
              serviceEpoch: ServerInstanceID(),
              pane: PaneID(),
              terminalEpoch: TerminalEpochID(),
              recordPath: Self.text,
              recordIncarnation: 1
            ),
            occurrence: OccurrenceID()
          )
        )
      case .cursor: .inbox(InboxQuery(cursor: Self.text))
      case .search: .search(pane: PaneID(), query: Self.text)
      }
    }
  }

  @Test(arguments: OversizedPayload.allCases)
  func oversizedPayloadsAreRefusedBeforeDispatchOrEncoding(
    _ shape: OversizedPayload
  ) async throws {
    let peer = CommandPeer()
    defer { peer.close() }
    let connection = try await connect(peer)
    let command = shape.command
    let gate = DispatchSemaphore(value: 0)
    let blocked = Mutex(false)
    connection.queue.async {
      blocked.withLock { $0 = true }
      _ = gate.wait(timeout: .now() + 3)
    }
    #expect(await waitUntil { blocked.withLock { $0 } })
    let refused = Mutex<MuxError?>(nil)
    connection.enqueue(command) { result in
      if case let .failure(error) = result { refused.withLock { $0 = error } }
    }
    #expect(refused.withLock { $0?.code } == .resourceLimit)
    gate.signal()
    await #expect { try await connection.execute(command) } throws: {
      ($0 as? MuxError)?.code == .resourceLimit
    }
    #expect(peer.requests.withLock { $0.isEmpty })
    #expect(await connection.pendingCommandCountForTesting == 0)
    await connection.close()
  }

  @Test(arguments: [UInt64(0), 1, UInt64.max])
  func unrelatedAttachmentRepliesCannotRetireTheCurrentLease(
    _ staleID: UInt64
  ) async throws {
    let peer = CommandPeer()
    defer { peer.close() }
    let connection = try await connect(peer)
    let old = AttachmentID()
    let current = AttachmentID()
    let first = Task {
      try await connection.execute(.attach(AttachRequest(.latest)))
    }
    var second: Task<MuxReply, any Error>?
    var input: Task<Void, any Error>?
    do {
      try #require(await waitUntil { peer.requests.withLock { $0.count == 1 } })
      peer.reply(1, .attached(attachment: old, workspace: peer.workspace))
      _ = try await first.value
      let newer = Task {
        try await connection.execute(.attach(AttachRequest(.latest)))
      }
      second = newer
      try #require(await waitUntil { peer.requests.withLock { $0.count == 2 } })
      peer.reply(2, .attached(attachment: current, workspace: peer.workspace))
      _ = try await newer.value
      let sending = Task {
        try await connection.send(.text("pending"), to: PaneID())
      }
      input = sending
      try #require(await waitUntil { peer.inputs.withLock { $0.count == 1 } })
      peer.reply(staleID, .attached(attachment: old, workspace: peer.workspace))
      peer.acknowledgeInput(1)
      // A subsequent command reply is a wire-order barrier for the stale reply.
      let barrier = Task { try await connection.execute(.status) }
      try #require(await waitUntil { peer.requests.withLock { $0.count == 3 } })
      peer.reply(3, .ok)
      _ = try await barrier.value
      #expect(await connection.attachment == current)
      try await sending.value
      await connection.close()
    } catch {
      await connection.close()
      _ = try? await first.value
      _ = try? await second?.value
      _ = try? await input?.value
      throw error
    }
  }

  @Test
  func repeatedLeaseReplyPreservesInputSequence() async throws {
    let peer = CommandPeer()
    defer { peer.close() }
    let connection = try await connect(peer)
    let attachment = AttachmentID()
    let pane = PaneID()
    var attaching: Task<MuxReply, any Error>?
    var sending: Task<Void, any Error>?
    do {
      for request in UInt64(1) ... 2 {
        let attach = Task {
          try await connection.execute(.attach(AttachRequest(.latest)))
        }
        attaching = attach
        try #require(
          await waitUntil {
            peer.requests.withLock { $0.count == Int(request) }
          }
        )
        peer.reply(
          request,
          .attached(attachment: attachment, workspace: peer.workspace)
        )
        _ = try await attach.value
        let input = Task { try await connection.send(.text("input"), to: pane) }
        sending = input
        try #require(
          await waitUntil { peer.inputs.withLock { $0.count == Int(request) } }
        )
        let record = try #require(peer.inputs.withLock { $0.last })
        // Acknowledge the actual sequence to collect both baseline and fixed tasks.
        peer.acknowledgeInput(record.sequence)
        try await input.value
      }
      #expect(peer.inputs.withLock { $0.map(\.sequence) } == [1, 2])
      #expect(
        peer.inputs.withLock { $0.allSatisfy { $0.attachment == attachment } }
      )
      await connection.close()
    } catch {
      await connection.close()
      _ = try? await attaching?.value
      _ = try? await sending?.value
      throw error
    }
  }

  @Test
  func cancelledAttachmentWaitStillAcceptsItsFirstWireReply() async throws {
    let peer = CommandPeer()
    defer { peer.close() }
    let connection = try await connect(peer)
    let caller = Task {
      try await connection.execute(.attach(AttachRequest(.latest)))
    }
    do {
      try #require(await waitUntil { peer.requests.withLock { $0.count == 1 } })
      caller.cancel()
      await #expect(throws: CancellationError.self) { try await caller.value }
      let attachment = AttachmentID()
      peer.reply(
        1,
        .attached(attachment: attachment, workspace: peer.workspace)
      )
      try #require(
        await waitUntil { await connection.pendingCommandCountForTesting == 0 }
      )
      #expect(await connection.attachment == attachment)
      await connection.close()
    } catch {
      await connection.close()
      _ = try? await caller.value
      throw error
    }
  }

  private func connect(_ peer: CommandPeer) async throws -> MuxConnection {
    try await MuxConnection.connect(
      endpoint: peer.listener.endpoint,
      frontend: .control,
    )
  }

  private func waitUntil(_ predicate: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(1)
    while await !predicate() {
      if ContinuousClock.now >= deadline { return false }
      try? await Task.sleep(for: .milliseconds(1))
    }
    return true
  }
}

private final class CommandPeer: Sendable {
  let listener: SMXListener
  let requests = Mutex<[UInt64]>([])
  let inputs = Mutex<[InputRecord]>([])
  let workspace = WorkspaceSnapshot(
    id: WorkspaceID(),
    name: "Commands",
    tabs: [],
    activeTab: TabID(),
    panes: [],
    layoutRevision: 1,
  )
  private let channels = Mutex<[SMXChannel]>([])
  private let replies = Mutex(false)

  init(limits: MuxLimits = .standard) {
    let queue = DispatchQueue(label: "command-admission-peer")
    listener = SMXListener(anonymousOn: queue)
    listener.activate(connectionQueue: queue) { [weak self] channel in
      guard let self else {
        channel.cancel();
        return
      }
      channels.withLock { $0.append(channel) }
      channel.activate { [weak self] event in
        guard let self, case let .message(data) = event,
          let message = try? SMXCodec.decode(
            ClientMessage.self,
            from: data,
            limit: 1 << 20,
          )
        else { return }
        switch message {
        case .hello:
          send(
            .welcome(
              Welcome(
                protocolVersion: SMX.protocolVersion,
                build: SMX.build,
                server: ServerInstanceID(),
                acceptedProfile: nil,
                limits: limits,
                innerTerm: SMX.innerTerm,
              )
            ),
            on: channel
          )
        case let .request(id, _):
          requests.withLock { $0.append(id) }
          if replies.withLock({ $0 }) {
            send(.reply(id: id, result: .success(.ok)), on: channel, )
          }
        case let .input(record): inputs.withLock { $0.append(record) }
        default: break
        }
      }
    }
  }

  func replyAll() {
    replies.withLock { $0 = true }
    for id in requests.withLock({ $0 }) {
      for channel in channels.withLock({ $0 }) {
        send(.reply(id: id, result: .success(.ok)), on: channel, )
      }
    }
  }

  func reply(_ id: UInt64, _ reply: MuxReply) {
    for channel in channels.withLock({ $0 }) {
      send(.reply(id: id, result: .success(reply)), on: channel)
    }
  }

  func acknowledgeInput(_ sequence: UInt64) {
    for channel in channels.withLock({ $0 }) {
      send(.inputAck(sequence: sequence, error: nil), on: channel)
    }
  }

  private func send(_ message: ServerMessage, on channel: SMXChannel) {
    do { try channel.send(SMXCodec.encode(message, limit: 1 << 20)) } catch {
      Issue.record("Could not send command reply: \(error)")
    }
  }

  func close() {
    channels.withLock { $0 }.forEach { $0.cancel() }
    listener.cancel()
  }
}
