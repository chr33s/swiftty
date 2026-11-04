import AppKit
import Dispatch
import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
@testable import Swiftty
import SwifttyCore
import Synchronization
import Testing
import TestSupport

private final class OpenReplyService: Sendable {
  private struct State {
    var channels: [SMXChannel] = []
    var held = false
    var closed = 0
  }
  private let state = Mutex(State())
  private let mode: String
  private let respond: Bool
  private let server = ServerInstanceID()
  let listener: SMXListener
  let workspace = WorkspaceSnapshot(
    id: WorkspaceID(),
    name: "Open",
    tabs: [],
    activeTab: TabID(),
    panes: [],
    layoutRevision: 1
  )

  init(mode: String, respond: Bool) {
    self.mode = mode
    self.respond = respond
    let queue = DispatchQueue(label: "open-reply-service")
    listener = SMXListener(anonymousOn: queue)
    listener.activate(connectionQueue: queue) { [weak self] channel in
      guard let self else {
        channel.cancel();
        return
      }
      state.withLock { $0.channels.append(channel) }
      channel.activate { [weak self] event in
        if case .closed = event { self?.state.withLock { $0.closed += 1 } }
        if case let .message(data) = event { self?.answer(data, on: channel) }
      }
    }
  }

  var isHolding: Bool { state.withLock { $0.held } }
  var closedChannels: Int { state.withLock { $0.closed } }

  private func answer(_ data: Data, on channel: SMXChannel) {
    guard
      let message = try? SMXCodec.decode(
        ClientMessage.self,
        from: data,
        limit: 1 << 20
      )
    else { return }
    let reply: ServerMessage
    switch message {
    case .hello:
      reply = .welcome(
        .init(
          protocolVersion: SMX.protocolVersion,
          build: SMX.build,
          server: server,
          acceptedProfile: nil,
          limits: .standard,
          innerTerm: "xterm-256color"
        )
      )
    case let .request(id, command):
      let result: MuxReply
      switch command {
      case .newWorkspace:
        if mode == "create", !respond {
          state.withLock { $0.held = true };
          return
        }
        result = .created(workspace)
      case .attach:
        if mode == "attach", !respond {
          state.withLock { $0.held = true };
          return
        }
        result = .attached(attachment: AttachmentID(), workspace: workspace)
      case .inbox:
        result = .inbox(
          .init(items: [], counts: .init(), revision: 0, nextCursor: nil)
        )
      default: result = .ok
      }
      reply = .reply(id: id, result: .success(result))
    default: return
    }
    if let data = try? SMXCodec.encode(reply, limit: 1 << 20) {
      channel.send(data)
    }
  }
}

extension MuxNativeTests {
  @Test
  func releasingOpenReplyServiceClosesItsPeer() async throws {
    var service: OpenReplyService? = OpenReplyService(
      mode: "attach",
      respond: true
    )
    weak let weakService = service
    defer { weakService?.listener.cancel() }
    let connection = try await MuxConnection.connect(
      endpoint: #require(service).listener.endpoint,
      frontend: .native
    )
    try await RuntimeFixture.withCleanup {
      service = nil
      for _ in 0 ..< 100 where weakService != nil {
        try await Task.sleep(for: .milliseconds(10))
      }
      try #require(weakService == nil)
      do {
        #expect(try await connection.nextEvent(timeout: .seconds(1)) == nil)
      } catch let error as MuxError { #expect(error.code == .connectionLost) }
    } cleanup: {
      await connection.close()
    }
  }

  @Test(arguments: ["open", "cancel", "close"])
  func workspaceOpenRejectsCancellationAndClosureBeforeHandoff(
    _ action: String
  ) async throws {
    _ = NSApplication.shared
    let service = OpenReplyService(mode: "attach", respond: true)
    defer { service.listener.cancel() }
    let connection = try await MuxConnection.connect(
      endpoint: service.listener.endpoint,
      frontend: .native
    )
    let (gate, release) = AsyncStream<Void>.makeStream()
    var built: MuxWorkspaceController?
    var returned: MuxWorkspaceController?
    let task = Task {
      returned = try await MuxWorkspaceController.open(
        .id(service.workspace.id),
        configuration: Configuration(),
        createConnection: { connection },
        beforeReturnForTesting: { controller in
          built = controller
          for await _ in gate { break }
        }
      )
    }
    try await RuntimeFixture.withCleanup {
      try #require(await until { built != nil })
      if action == "cancel" { task.cancel() }
      if action == "close" { await connection.close() }
      release.yield(())
      release.finish()
      switch await task.result {
      case .success:
        #expect(action == "open")
        if action == "open" { #expect(returned?.holdsLease == true) }
      case let .failure(error):
        if action == "open" { throw error }
        if action == "cancel" { #expect(error is CancellationError) }
        if action == "close" {
          #expect((error as? MuxError)?.code == .connectionLost)
        }
        #expect(built?.isClosed == true)
        try #require(await until { service.closedChannels == 1 })
      }
    } cleanup: {
      release.finish()
      task.cancel()
      await connection.close()
      _ = await task.result
      await built?.detach()
      built?.close()
    }
  }

  @Test(arguments: ["create", "attach"], [false, true])
  func openingAWorkspaceHasBoundedCommandWaits(
    _ mode: String,
    _ respond: Bool
  ) async throws {
    _ = NSApplication.shared
    let service = OpenReplyService(mode: mode, respond: respond)
    defer { service.listener.cancel() }
    let connection = try await MuxConnection.connect(
      endpoint: service.listener.endpoint,
      frontend: .native
    )
    var completed = false
    var failure: MuxError?
    var controller: MuxWorkspaceController?
    let task = Task {
      defer { completed = true }
      do {
        controller = try await MuxWorkspaceController.open(
          mode == "create" ? nil : .id(service.workspace.id),
          configuration: Configuration(),
          createConnection: { connection }
        )
      } catch { failure = error as? MuxError }
    }
    try await RuntimeFixture.withCleanup {
      if respond {
        try #require(await until { completed })
        #expect(failure == nil)
        #expect(controller?.attachedWorkspace == service.workspace.id)
        #expect(controller?.holdsLease == true)
      } else {
        try #require(await until { service.isHolding })
        let deadline = ContinuousClock.now + .seconds(6)
        while !completed, ContinuousClock.now < deadline {
          try await Task.sleep(for: .milliseconds(10))
        }
        #expect(completed)
        if completed {
          #expect(failure?.code == .connectionLost)
          #expect(controller == nil)
          #expect(await connection.pendingCommandCountForTesting == 0)
          try #require(await until { service.closedChannels == 1 })
        }
      }
    } cleanup: {
      task.cancel()
      await connection.close()
      await task.value
      await controller?.detach()
      controller?.close()
    }
  }
}
