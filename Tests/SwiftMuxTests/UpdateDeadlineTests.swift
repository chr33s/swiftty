import Dispatch
import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
import SwiftMuxXPC
import Synchronization
import Testing

struct UpdateDeadlineTests {
  @Test(arguments: [false, true])
  func closedConnectionAtHandshakeHandoffIsRejected(
    _ peerClose: Bool
  ) async throws {
    let peer = UpdateDeadlinePeer(held: "none")
    defer { peer.close() }
    let observed = Mutex(false)
    await #expect {
      _ = try await MuxConnection.connect(
        endpoint: peer.listener.endpoint,
        frontend: .control,
        beforeHandshakeTimeoutForTesting: nil,
        beforeReturnForTesting: { connection in
          if peerClose {
            peer.close()
            do {
              let event = try await connection.nextEvent(timeout: .seconds(1))
              try #require(event == nil)
            } catch {
              let error = try #require(error as? MuxError)
              try #require(error.code == .connectionLost)
            }
          } else {
            await connection.close()
          }
          observed.withLock { $0 = true }
        }
      )
    } throws: {
      guard let error = $0 as? MuxError else { return false }
      return error.code == .connectionLost
        && (peerClose || error.message == "closed")
    }
    #expect(observed.withLock { $0 })
  }

  @Test
  func handshakeDeadlineRejectsLateWelcomeBeforeTimeoutCallback() async throws {
    let peer = UpdateDeadlinePeer(held: "hello")
    defer { peer.close() }
    let gate = AsyncStream<Void>.makeStream()
    defer { gate.continuation.finish() }
    let entered = Mutex(false)
    let connect = Task {
      try await MuxConnection.connect(
        endpoint: peer.listener.endpoint,
        frontend: .control,
        beforeHandshakeTimeoutForTesting: {
          entered.withLock { $0 = true }
          for await _ in gate.stream { break }
        }
      )
    }
    defer { connect.cancel() }
    let deadline =
      ContinuousClock.now + .seconds(MuxConnection.handshakeTimeout + 1)
    while !entered.withLock({ $0 }), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(entered.withLock { $0 })
    try #require(peer.hasHeldReply)
    peer.releaseHeldReply()
    switch await connect.result {
    case let .success(connection):
      await connection.close()
      Issue.record(
        "welcome after the five-second deadline completed the handshake"
      )
    case let .failure(error):
      #expect((error as? MuxError)?.code == .connectionLost)
    }
    #expect(await waitUntil { peer.closed.withLock { $0 } })
  }

  @Test(arguments: [
    "unregistration", "replacement", "registration", "verification",
  ])
  func commitFailuresReportTheFailedStepAndCloseTheOldConnection(
    _ step: String
  ) async throws {
    let peer = UpdateDeadlinePeer(held: "none")
    defer { peer.close() }
    let reached = Mutex<[String]>([])
    let connections = Mutex(0)
    let failStep: @Sendable (String) throws -> Void = { current in
      reached.withLock { $0.append(current) }
      if current == step { throw MuxError(.invalidRequest, "injected failure") }
    }
    let update = UpdateCoordinator(
      connect: {
        if connections.withLock({
          $0 += 1;
          return $0 > 1
        }) {
          try failStep("verification")
        }
        return try await MuxConnection.connect(
          endpoint: peer.listener.endpoint,
          frontend: .control
        )
      },
      registration: CommitRegistration(
        onUnregister: { try failStep("unregistration") },
        onRegister: { try failStep("registration") }
      ),
      replace: { _ in try failStep("replacement") }
    )
    await update.stage(URL(fileURLWithPath: "/tmp/FailedCommit.app"))
    guard case let .failed(message) = await update.install(endWorkspaces: false)
    else {
      Issue.record("expected commit failure")
      return
    }
    #expect(message.contains("during \(step):"))
    #expect(message.contains("injected failure"))
    let order = [
      "unregistration", "replacement", "registration", "verification",
    ]
    let index = try #require(order.firstIndex(of: step))
    #expect(reached.withLock { $0 } == Array(order.prefix(index + 1)))
    #expect(await waitUntil { peer.closed.withLock { $0 } })
  }

  @Test(
    arguments: ["unregister", "replace", "register", "verify"],
    [false, true]
  )
  func cancellationAfterCommitBeginsDoesNotInterruptInstallation(
    stage: String,
    cancelTask: Bool
  ) async throws {
    let old = UpdateDeadlinePeer(held: "none")
    let fresh = UpdateDeadlinePeer(held: "none")
    defer {
      old.close();
      fresh.close()
    }
    let gate = AsyncStream<Void>.makeStream()
    defer { gate.continuation.finish() }
    let entered = Mutex(false)
    let connections = Mutex(0)
    let log = Mutex<[String]>([])
    let pause: @Sendable () async throws -> Void = {
      entered.withLock { $0 = true }
      for await _ in gate.stream { break }
      try Task.checkCancellation()
    }
    let registration = CommitRegistration(
      onUnregister: {
        if stage == "unregister" { try await pause() }
        try Task.checkCancellation()
        log.withLock { $0.append("unregister") }
      },
      onRegister: {
        if stage == "register" { try await pause() }
        try Task.checkCancellation()
        log.withLock { $0.append("register") }
      }
    )
    let update = UpdateCoordinator(
      connect: {
        let verifying = connections.withLock {
          $0 += 1;
          return $0 > 1
        }
        if verifying, stage == "verify" { try await pause() }
        return try await MuxConnection.connect(
          endpoint: verifying ? fresh.listener.endpoint : old.listener.endpoint,
          frontend: .control
        )
      },
      registration: registration,
      replace: { _ in
        if stage == "replace" { try await pause() }
        try Task.checkCancellation()
        log.withLock { $0.append("replace") }
      }
    )
    await update.stage(URL(fileURLWithPath: "/tmp/Commit.app"))
    let install = Task { await update.install(endWorkspaces: false) }
    defer { install.cancel() }
    try #require(await waitUntil { entered.withLock { $0 } })
    if cancelTask { install.cancel() } else { await update.cancel() }
    gate.continuation.finish()
    let phase = await install.value
    if case .finished = phase {
    } else {
      Issue.record("commit interrupted: \(phase)")
    }
    #expect(log.withLock { $0 } == ["unregister", "replace", "register"])
    #expect(connections.withLock { $0 } == 2)
  }

  @Test(arguments: ["quiesce", "end", "status", "slow"])
  func preUnregistrationCommandsShareABoundedBarrier(
    _ held: String
  ) async throws {
    let peer = UpdateDeadlinePeer(held: held)
    defer { peer.close() }
    let registration = DeadlineRegistration()
    let replacements = Mutex(0)
    let update = UpdateCoordinator(
      connect: {
        try await MuxConnection.connect(
          endpoint: peer.listener.endpoint,
          frontend: .control
        )
      },
      registration: registration,
      replace: { _ in replacements.withLock { $0 += 1 } },
    )
    await update.setBarrierTimeout(.milliseconds(150))
    await update.stage(URL(fileURLWithPath: "/tmp/Deadline.app"))
    let finished = Mutex(false)
    let install = Task {
      let phase = await update.install(endWorkspaces: true)
      finished.withLock { $0 = true }
      return phase
    }
    let deadline = ContinuousClock.now + .milliseconds(700)
    while !finished.withLock({ $0 }), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(2))
    }
    #expect(
      finished.withLock { $0 },
      "the barrier must expire despite missing or slow replies"
    )
    // Cancel only to collect the deliberately stuck baseline task safely.
    if !finished.withLock({ $0 }) { install.cancel() }
    let phase = await install.value
    guard case .failed = phase else {
      Issue.record("expected bounded barrier failure, got \(phase)")
      return
    }
    #expect(peer.commands.withLock { $0.last } == "resume")
    #expect(registration.calls.withLock { $0 } == 0)
    #expect(replacements.withLock { $0 } == 0)
    #expect(!peer.quiescing.withLock { $0 })
    let closeDeadline = ContinuousClock.now + .seconds(1)
    while !peer.closed.withLock({ $0 }), ContinuousClock.now < closeDeadline {
      try await Task.sleep(for: .milliseconds(2))
    }
    #expect(peer.closed.withLock { $0 })
  }

  @Test(arguments: ["quiesce", "end", "status"], [false, true])
  func cancellationInterruptsAnOutstandingCommand(
    _ held: String,
    _ cancelTask: Bool
  ) async throws {
    let peer = UpdateDeadlinePeer(held: held)
    defer { peer.close() }
    let registration = DeadlineRegistration()
    let replacements = Mutex(0)
    let update = UpdateCoordinator(
      connect: {
        try await MuxConnection.connect(
          endpoint: peer.listener.endpoint,
          frontend: .control
        )
      },
      registration: registration,
      replace: { _ in replacements.withLock { $0 += 1 } },
    )
    await update.stage(URL(fileURLWithPath: "/tmp/Cancelled.app"))
    let finished = Mutex(false)
    let install = Task {
      let phase = await update.install(endWorkspaces: true)
      finished.withLock { $0 = true }
      return phase
    }
    let requested = await waitUntil {
      peer.commands.withLock { $0.contains(held) }
    }
    #expect(requested)
    if cancelTask { install.cancel() } else { await update.cancel() }
    let interrupted = await waitUntil { finished.withLock { $0 } }
    #expect(interrupted, "cancellation must interrupt the command wait")
    if !interrupted { install.cancel() }
    #expect(await install.value == .cancelled)
    let expected =
      switch held {
      case "quiesce": ["quiesce", "resume"]
      case "end": ["quiesce", "end", "resume"]
      default: ["quiesce", "end", "status", "resume"]
      }
    #expect(peer.commands.withLock { $0 } == expected)
    #expect(!peer.quiescing.withLock { $0 })
    #expect(registration.calls.withLock { $0 } == 0)
    #expect(replacements.withLock { $0 } == 0)
    #expect(await waitUntil { peer.closed.withLock { $0 } })
  }

  @Test
  func cancellationBeforeAnEmptyReplyPreventsUnregistration() async throws {
    let peer = UpdateDeadlinePeer(held: "status")
    defer { peer.close() }
    let registration = DeadlineRegistration()
    let replacements = Mutex(0)
    let update = UpdateCoordinator(
      connect: {
        try await MuxConnection.connect(
          endpoint: peer.listener.endpoint,
          frontend: .control
        )
      },
      registration: registration,
      replace: { _ in replacements.withLock { $0 += 1 } },
    )
    await update.stage(URL(fileURLWithPath: "/tmp/Cancelled.app"))
    let install = Task { await update.install(endWorkspaces: true) }
    #expect(await waitUntil { peer.hasHeldReply })
    await update.cancel()
    peer.releaseHeldReply()
    #expect(await install.value == .cancelled)
    #expect(peer.commands.withLock { $0.last } == "resume")
    #expect(!peer.quiescing.withLock { $0 })
    #expect(registration.calls.withLock { $0 } == 0)
    #expect(replacements.withLock { $0 } == 0)
  }

  @Test(arguments: [false, true])
  func cancellationDuringConnectionSetupSendsNoMutation(
    _ cancelTask: Bool
  ) async throws {
    let peer = UpdateDeadlinePeer(held: "none")
    defer { peer.close() }
    let registration = DeadlineRegistration()
    let replacements = Mutex(0)
    let entered = Mutex(false)
    let gate = AsyncStream<Void>.makeStream()
    let update = UpdateCoordinator(
      connect: {
        let connection = try await MuxConnection.connect(
          endpoint: peer.listener.endpoint,
          frontend: .control
        )
        entered.withLock { $0 = true }
        for await _ in gate.stream { break }
        return connection
      },
      registration: registration,
      replace: { _ in replacements.withLock { $0 += 1 } },
    )
    await update.stage(URL(fileURLWithPath: "/tmp/Cancelled.app"))
    let finished = Mutex(false)
    let install = Task {
      let phase = await update.install(endWorkspaces: true)
      finished.withLock { $0 = true }
      return phase
    }
    #expect(await waitUntil { entered.withLock { $0 } })
    if cancelTask { install.cancel() } else { await update.cancel() }
    let interrupted = await waitUntil { finished.withLock { $0 } }
    #expect(
      interrupted,
      "cancel must also collect a connector returning a live connection"
    )
    if !interrupted { install.cancel() }
    gate.continuation.finish()
    #expect(await install.value == .cancelled)
    #expect(peer.commands.withLock { $0.isEmpty })
    #expect(!peer.quiescing.withLock { $0 })
    #expect(registration.calls.withLock { $0 } == 0)
    #expect(replacements.withLock { $0 } == 0)
    #expect(await waitUntil { peer.closed.withLock { $0 } })
  }

  @Test(arguments: [false, true])
  func cancellationInterruptsConnectionHandshake(
    _ cancelTask: Bool
  ) async throws {
    let peer = UpdateDeadlinePeer(held: "hello")
    defer { peer.close() }
    let registration = DeadlineRegistration()
    let replacements = Mutex(0)
    let finished = Mutex(false)
    let update = UpdateCoordinator(
      connect: {
        try await MuxConnection.connect(
          endpoint: peer.listener.endpoint,
          frontend: .control
        )
      },
      registration: registration,
      replace: { _ in replacements.withLock { $0 += 1 } },
    )
    await update.stage(URL(fileURLWithPath: "/tmp/Connecting.app"))
    let install = Task {
      let phase = await update.install(endWorkspaces: true)
      finished.withLock { $0 = true }
      return phase
    }
    #expect(await waitUntil { peer.helloReceived.withLock { $0 } })
    if cancelTask { install.cancel() } else { await update.cancel() }
    let interrupted = await waitUntil { finished.withLock { $0 } }
    #expect(interrupted, "cancellation must interrupt the initial handshake")
    if !interrupted { install.cancel() }
    #expect(await install.value == .cancelled)
    #expect(peer.commands.withLock { $0.isEmpty })
    #expect(registration.calls.withLock { $0 } == 0)
    #expect(replacements.withLock { $0 } == 0)
    #expect(await waitUntil { peer.closed.withLock { $0 } })
  }

  @Test(arguments: ["quiesceReply", "endReply", "notQuiescing", "wrongServer"])
  func barrierRepliesMustProveTheExpectedCommandsAndService(
    _ fault: String
  ) async throws {
    let peer = UpdateDeadlinePeer(held: fault)
    defer { peer.close() }
    let registration = DeadlineRegistration()
    let replacements = Mutex(0)
    let update = UpdateCoordinator(
      connect: {
        try await MuxConnection.connect(
          endpoint: peer.listener.endpoint,
          frontend: .control
        )
      },
      registration: registration,
      replace: { _ in replacements.withLock { $0 += 1 } },
    )
    await update.stage(URL(fileURLWithPath: "/tmp/InvalidBarrier.app"))
    guard case .failed = await update.install(endWorkspaces: true) else {
      Issue.record("expected invalid barrier failure")
      return
    }
    #expect(registration.calls.withLock { $0 } == 0)
    #expect(replacements.withLock { $0 } == 0)
    let expected =
      switch fault {
      case "quiesceReply": ["quiesce", "resume"]
      case "endReply": ["quiesce", "end", "resume"]
      default: ["quiesce", "end", "status", "resume"]
      }
    #expect(peer.commands.withLock { $0 } == expected)
    #expect(!peer.quiescing.withLock { $0 })
    #expect(await waitUntil { peer.closed.withLock { $0 } })
  }

  @Test(arguments: [false, true])
  func cancellationInterruptsPreUnregistrationValidation(
    _ cancelTask: Bool
  ) async throws {
    let peer = UpdateDeadlinePeer(held: "none")
    defer { peer.close() }
    let registration = DeadlineRegistration()
    let replacements = Mutex(0)
    let validating = Mutex(false)
    let finished = Mutex(false)
    let update = UpdateCoordinator(
      connect: {
        try await MuxConnection.connect(
          endpoint: peer.listener.endpoint,
          frontend: .control
        )
      },
      registration: registration,
      replace: { _ in replacements.withLock { $0 += 1 } },
      validate: { _ in
        validating.withLock { $0 = true }
        try await Task.sleep(for: .seconds(3600))
      },
    )
    await update.stage(URL(fileURLWithPath: "/tmp/Validating.app"))
    let install = Task {
      let phase = await update.install(endWorkspaces: true)
      finished.withLock { $0 = true }
      return phase
    }
    #expect(await waitUntil { validating.withLock { $0 } })
    if cancelTask { install.cancel() } else { await update.cancel() }
    let interrupted = await waitUntil { finished.withLock { $0 } }
    #expect(
      interrupted,
      "cancellation must interrupt validation before unregistration"
    )
    if !interrupted { install.cancel() }
    #expect(await install.value == .cancelled)
    #expect(
      peer.commands.withLock { $0 } == ["quiesce", "end", "status", "resume"]
    )
    #expect(!peer.quiescing.withLock { $0 })
    #expect(registration.calls.withLock { $0 } == 0)
    #expect(replacements.withLock { $0 } == 0)
    #expect(await waitUntil { peer.closed.withLock { $0 } })
  }

  private func waitUntil(_ predicate: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(1)
    while !predicate(), ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(2))
    }
    return predicate()
  }
}

private struct CommitRegistration: AgentRegistration {
  let onUnregister: @Sendable () async throws -> Void
  let onRegister: @Sendable () async throws -> Void
  func unregister() async throws { try await onUnregister() }
  func register() async throws { try await onRegister() }
}

private final class DeadlineRegistration: AgentRegistration, Sendable {
  let calls = Mutex(0)
  func unregister() async throws { calls.withLock { $0 += 1 } }
  func register() async throws { calls.withLock { $0 += 1 } }
}

private final class UpdateDeadlinePeer: Sendable {
  let listener: SMXListener
  let commands = Mutex<[String]>([])
  let quiescing = Mutex(false)
  let closed = Mutex(false)
  let helloReceived = Mutex(false)
  private let channels = Mutex<[SMXChannel]>([])
  private let server = ServerInstanceID()
  private let heldReply = Mutex<(ServerMessage, SMXChannel)?>(nil)
  var hasHeldReply: Bool { heldReply.withLock { $0 != nil } }

  init(held: String) {
    let queue = DispatchQueue(label: "update-deadline-peer")
    listener = SMXListener(anonymousOn: queue)
    listener.activate(connectionQueue: queue) { [weak self] channel in
      guard let self else {
        channel.cancel();
        return
      }
      channels.withLock { $0.append(channel) }
      channel.activate { [weak self] event in
        guard let self else { return }
        if case .closed = event {
          closed.withLock { $0 = true };
          return
        }
        guard case let .message(data) = event,
          let message = try? SMXCodec.decode(
            ClientMessage.self,
            from: data,
            limit: 1 << 20
          )
        else { return }
        switch message {
        case .hello:
          helloReceived.withLock { $0 = true }
          let welcome = ServerMessage.welcome(
            Welcome(
              protocolVersion: SMX.protocolVersion,
              build: SMX.build,
              server: server,
              acceptedProfile: nil,
              limits: .standard,
              innerTerm: SMX.innerTerm,
            )
          )
          if held == "hello" {
            heldReply.withLock { $0 = (welcome, channel) }
            return
          }
          send(welcome, on: channel)
        case let .request(id, command):
          let name: String
          let reply: MuxReply
          switch command {
          case let .quiesce(on):
            quiescing.withLock { $0 = on }
            name = on ? "quiesce" : "resume"
            reply = on && held == "quiesceReply" ? .workspaces([]) : .ok
          case .endAllWorkspaces:
            name = "end"
            reply = held == "endReply" ? .workspaces([]) : .ok
          case .status:
            name = "status"
            if held == "notQuiescing" { quiescing.withLock { $0 = false } }
            reply = .status(
              ServiceStatus(
                server: held == "wrongServer" ? ServerInstanceID() : server,
                build: SMX.build,
                pid: getpid(),
                startedAt: Date(),
                workspaces: 0,
                panes: 0,
                attached: false,
                quiescing: quiescing.withLock { $0 },
                innerTerm: SMX.innerTerm,
              )
            )
          default:
            Issue.record("unexpected update command")
            return
          }
          commands.withLock { $0.append(name) }
          let message = ServerMessage.reply(id: id, result: .success(reply))
          if name == held {
            heldReply.withLock { $0 = (message, channel) }
            return
          }
          if held == "slow", name != "resume" {
            queue.asyncAfter(deadline: .now() + .milliseconds(70)) {
              [weak self] in self?.send(message, on: channel)
            }
          } else {
            send(message, on: channel)
          }
        default: break
        }
      }
    }
  }

  private func send(_ message: ServerMessage, on channel: SMXChannel) {
    do { try channel.send(SMXCodec.encode(message, limit: 1 << 20)) } catch {
      Issue.record("could not send update reply: \(error)")
    }
  }

  func releaseHeldReply() {
    let reply = heldReply.withLock { value in
      defer { value = nil }
      return value
    }
    if let (message, channel) = reply { send(message, on: channel) }
  }

  func close() {
    channels.withLock { $0 }.forEach { $0.cancel() }
    listener.cancel()
  }
}
