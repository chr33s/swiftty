import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
@testable import SwiftMuxService
import Synchronization
import Testing

final class LeakFlag: @unchecked Sendable { var value = false }

func create(_ c: MuxConnection) async throws -> (WorkspaceID, PaneID) {
  guard
    case let .created(ws) = try await c.execute(
      .newWorkspace(NewWorkspaceRequest(name: "ext", launch: shellLaunch()))
    )
  else { throw MuxError(.invalidRequest, "create") }
  return (ws.id, ws.tabs[0].activePane)
}

func observe(
  _ h: Harness,
  _ ws: WorkspaceID,
  panes: [PaneID]
) async throws -> MuxConnection {
  let c = try await h.connect()
  guard
    case let .attached(_, snap) = try await c.execute(
      .attach(AttachRequest(.id(ws), role: .observer))
    )
  else { throw MuxError(.invalidRequest, "observe") }
  #expect(snap.attachmentRole == .observer)
  try await c.execute(.setSubscriptions(panes))
  return c
}

func leaseGeneration(
  _ c: MuxConnection,
  _ id: WorkspaceID
) async throws -> UInt64 {
  guard case let .workspaces(list) = try await c.execute(.listWorkspaces),
    let summary = list.first(where: { $0.id == id })
  else { throw MuxError(.notFound, "workspace") }
  return summary.leaseGeneration
}

func rejection(_ body: () async throws -> Void) async -> MuxError.Code? {
  do {
    try await body()
    return nil
  } catch let error as MuxError { return error.code } catch { return nil }
}

func waitInstall(_ c: MuxConnection, pane: PaneID) async throws -> FrameIdentity
{
  let deadline = ContinuousClock.now + .seconds(5)
  while ContinuousClock.now < deadline {
    if let identity = await c.installation.visible[pane] { return identity }
    try await Task.sleep(for: .milliseconds(20))
  }
  throw MuxError(.notFound, "frame")
}

func pin(
  _ c: MuxConnection,
  pane: PaneID,
  anchor: Int? = nil,
  followTail: Bool = false,
  generation: UInt64,
  rows: Int? = nil,
  columns: Int? = nil
) async throws {
  try await c.execute(
    .setViewport(
      ViewportRequest(
        pane: pane,
        anchorRow: anchor,
        followTail: followTail,
        historyGeneration: generation,
        rows: rows,
        columns: columns
      )
    )
  )
}

/// Resizes the PTY, then requires the viewer's old anchor to fail closed.
func expectReflowDropsAnchor(
  controller: MuxConnection,
  viewer: MuxConnection,
  pane: PaneID,
  layoutRevision: UInt64,
  generation: UInt64,
  anchor: Int
) async throws {
  try await controller.execute(
    .setGeometry(
      GeometryBatch(
        layoutRevision: layoutRevision,
        generation: 2,
        entries: [.init(pane: pane, columns: 50, rows: 8)]
      )
    )
  )
  var replaced = false
  var unavailable = false
  let deadline = ContinuousClock.now + .seconds(5)
  while ContinuousClock.now < deadline, !unavailable {
    let event: MuxEvent?
    do {
      event = try await viewer.nextEvent(timeout: .milliseconds(200))
    } catch is MuxConnection.EventWaitError { continue }
    switch event {
    case let .frameUnavailable(id, error) where id == pane:
      unavailable = error.code == .historyUnavailable
    case let .frame(frame) where frame.identity.pane == pane:
      if frame.history.generation != generation,
        frame.lines.contains(where: { $0.contains("tail-marker-99") })
      {
        replaced = true
      }
    default: break
    }
  }
  #expect(unavailable)
  #expect(!replaced)
  #expect(
    await rejection {
      try await pin(viewer, pane: pane, anchor: anchor, generation: generation)
    } == .historyUnavailable
  )
}

func expectObserverCannotMutate(
  _ observer: MuxConnection,
  pane: PaneID,
  tab: TabID,
  workspace: WorkspaceID,
  generation: UInt64
) async {
  #expect(
    await rejection {
      try await observer.send(.text("echo observer-write\r"), to: pane)
    } == .unauthorized
  )
  #expect(
    await rejection { try await observer.send(.focus(true), to: pane) }
      == .unauthorized
  )
  #expect(
    await rejection { _ = try await observer.paste("observer-paste", to: pane) }
      == .unauthorized
  )
  #expect(
    await rejection {
      try await observer.execute(
        .setGeometry(
          GeometryBatch(
            layoutRevision: 1,
            generation: 9,
            entries: [.init(pane: pane, columns: 20, rows: 4)]
          )
        )
      )
    } == .unauthorized
  )
  #expect(
    await rejection { try await observer.execute(.focusPane(pane)) }
      == .unauthorized
  )
  #expect(
    await rejection {
      try await observer.execute(
        .split(pane: pane, axis: .leftRight, launch: nil)
      )
    } == .unauthorized
  )
  #expect(
    await rejection { try await observer.execute(.toggleZoom(tab)) }
      == .unauthorized
  )
  #expect(
    await rejection {
      _ = try await observer.execute(
        .takeover(.id(workspace), expectedLease: generation)
      )
    } == .unauthorized
  )
  #expect(
    await rejection { try await observer.execute(.endPane(pane)) }
      == .unauthorized
  )
  #expect(
    await rejection {
      try await observer.execute(.endWorkspace(.id(workspace)))
    } == .unauthorized
  )
}

/// Workspace lists a watcher receives within half a second.
func workspaceLists(
  _ watcher: MuxConnection
) async throws -> [[WorkspaceSummary]] {
  var lists: [[WorkspaceSummary]] = []
  let deadline = ContinuousClock.now + .milliseconds(500)
  while ContinuousClock.now < deadline {
    do {
      guard let event = try await watcher.nextEvent(timeout: .milliseconds(50))
      else { break }  // connection closed
      if case let .workspaces(list) = event { lists.append(list) }
    } catch is MuxConnection.EventWaitError { continue }
  }
  return lists
}

func waitReady(_ c: MuxConnection) async throws -> ReadyNotice {
  let deadline = ContinuousClock.now + .seconds(5)
  while ContinuousClock.now < deadline {
    if let ready = await c.readiness { return ready }
    try await Task.sleep(for: .milliseconds(20))
  }
  throw MuxError(.notFound, "ready")
}

/// In-process controller. Frames stay on the XPC observer; this client
/// only drives the lease.
final class LocalController: @unchecked Sendable {
  private let queue = DispatchQueue(label: "swiftmux.local-controller")
  private var connection: MuxLocalConnection?
  private var nextRequest: UInt64 = 1
  private var requests: [UInt64: CheckedContinuation<MuxResult, Never>] = [:]
  private var nextInput: UInt64 = 1
  private var inputs: [UInt64: CheckedContinuation<MuxError?, Never>] = [:]
  private var welcomeWait: CheckedContinuation<Welcome, Error>?
  private var closed = false

  func connect(
    _ service: MuxService,
    capabilities: ClientCapabilities = .supported
  ) async throws -> Welcome {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { [self] in
        let sink = LocalClientSink(
          onMessage: { [weak self] message in
            guard let self else { return }
            self.queue.async { self.receive(message) }
          },
          onPaneChanged: { _ in },
          onClosed: { [weak self] reason in
            guard let self else { return }
            self.queue.async { self.finish(MuxError(.connectionLost, reason)) }
          }
        )
        let connection = service.connectLocal(remote: false, sink: sink)
        self.connection = connection
        self.welcomeWait = continuation
        connection.send(
          .hello(Hello(frontend: .native, capabilities: capabilities))
        )
      }
    }
  }

  func execute(_ command: MuxCommand) async throws -> MuxReply {
    let result = await withCheckedContinuation { continuation in
      queue.async {
        guard let connection = self.connection, !self.closed else {
          continuation.resume(
            returning: MuxResult.failure(MuxError(.connectionLost))
          )
          return
        }
        let id = self.nextRequest
        self.nextRequest += 1
        self.requests[id] = continuation
        connection.sendRequest(id: id, command: command)
      }
    }
    return try result.get()
  }

  func send(
    _ input: MuxInput,
    attachment: AttachmentID,
    pane: PaneID
  ) async throws {
    let error = await withCheckedContinuation {
      (continuation: CheckedContinuation<MuxError?, Never>) in
      queue.async {
        guard let connection = self.connection, !self.closed else {
          continuation.resume(returning: MuxError(.connectionLost))
          return
        }
        let sequence = self.nextInput
        self.nextInput += 1
        self.inputs[sequence] = continuation
        connection.send(
          .input(
            InputRecord(
              sequence: sequence,
              attachment: attachment,
              pane: pane,
              payload: .input(input)
            )
          )
        )
      }
    }
    if let error { throw error }
  }

  func close() async {
    await withCheckedContinuation {
      (continuation: CheckedContinuation<Void, Never>) in
      queue.async {
        guard let connection = self.connection else {
          self.finish(MuxError(.connectionLost, "closed"))
          continuation.resume()
          return
        }
        self.connection = nil
        self.finish(MuxError(.connectionLost, "closed"))
        connection.close { continuation.resume() }
      }
    }
  }

  private func receive(_ message: ServerMessage) {
    switch message {
    case let .welcome(welcome):
      welcomeWait?.resume(returning: welcome)
      welcomeWait = nil
    case let .rejected(error):
      welcomeWait?.resume(throwing: error)
      welcomeWait = nil
      finish(error)
    case let .reply(id, result):
      requests.removeValue(forKey: id)?.resume(returning: result)
    case let .inputAck(sequence, error):
      inputs.removeValue(forKey: sequence)?.resume(returning: error)
    case .event: break
    }
  }

  private func finish(_ error: MuxError) {
    guard !closed else { return }
    closed = true
    let pending = requests
    requests = [:]
    for continuation in pending.values {
      continuation.resume(returning: .failure(error))
    }
    let pendingInputs = inputs
    inputs = [:]
    for continuation in pendingInputs.values {
      continuation.resume(returning: error)
    }
    if let welcomeWait {
      self.welcomeWait = nil
      welcomeWait.resume(throwing: error)
    }
  }
}

/// Window-command failures a stalled-queue test observes.
final class FailureLog: Sendable {
  private let codes = Mutex<[MuxError.Code]>([])

  func record(_ code: MuxError.Code) { codes.withLock { $0.append(code) } }

  /// Failures so far, cleared.
  func take() -> [MuxError.Code] {
    codes.withLock { codes in
      defer { codes = [] }
      return codes
    }
  }
}

extension MuxService {
  /// The first observer's Ready resize floor for `pane` (tests).
  func observerFloor(_ wsID: WorkspaceID, _ pane: PaneID) -> UInt64? {
    viewers[wsID]?.first?.readiness.minimumGeometry[pane]
  }

  /// The first observer's client (tests).
  func observerClient(_ wsID: WorkspaceID) -> UUID? {
    viewers[wsID]?.first?.client
  }

  /// The first observer's window id for `pane` (tests).
  func observerWindow(_ wsID: WorkspaceID, _ pane: PaneID) -> UInt64? {
    viewers[wsID]?.first?.viewports[pane]?.id
  }

  /// Queues `count` window commands that never finish themselves; every
  /// failure reply goes to `log` (tests).
  func queueStalledWindowCommands(
    _ count: Int,
    client: UUID,
    workspace wsID: WorkspaceID,
    pane: PaneID,
    log: FailureLog
  ) {
    for _ in 0 ..< count {
      inWindowOrder(
        client,
        wsID,
        pane,
        { result in
          if case let .failure(error) = result { log.record(error.code) }
        },
        { _, _, _ in }
      )
    }
  }
}
