#if os(macOS)
import Dispatch
import Foundation
import ScreenProtocol
import SessionCore
import SwiftMuxClient
import SwiftMuxExport
import SwiftMuxProtocol

/// A roaming session's SMX connection to a SwiftMux worker (a durable
/// gateway's workspace). Screens come from the frames the worker sends
/// this controller for its active pane; the history window is the
/// controller viewport (`setViewport`); copies are `copySelection`.
///
/// Operations run one at a time in submission order on one task, as the
/// in-process client's are handled in service order. Callbacks run on
/// `queue`.
///
/// Sendable: every stored property is read and written only on `queue`;
/// tasks hop there before touching them.
package final class SMXRoamingMux: RoamingMux, @unchecked Sendable {
  package typealias Connect = @Sendable () async throws -> MuxConnection

  private let queue: DispatchQueue
  private let open: Connect
  private var connection: MuxConnection?
  private var operations:
    AsyncStream<@Sendable (MuxConnection) async -> Void>.Continuation?
  /// Runs operations in order; yields the connection it opened, if any.
  private var pump: Task<MuxConnection?, Never>?
  private var events: Task<Void, Never>?
  private var closed = false
  /// The newest frame per pane, as this controller's viewport shows it.
  private var frames: [PaneID: PaneFrame] = [:]
  private var subscribed: PaneID?
  /// Replies not yet answered, failed with `connectionLost` on close.
  private var unanswered: [UInt64: (MuxError) -> Void] = [:]
  private var nextOperation: UInt64 = 0
  /// Captures waiting for their pane's first frame.
  private var waiting: [PaneID: [@Sendable (PaneFrame?) -> Void]] = [:]
  private var presented: (pane: PaneID, top: Int?, generation: UInt64)?

  package var onEvent: ((MuxEvent) -> Void)?
  package var onPaneChanged: ((PaneID) -> Void)?
  package var onClosed: ((String) -> Void)?
  package private(set) var welcome: Welcome?
  package var isOpen: Bool { !closed }

  package init(queue: DispatchQueue, connect: @escaping Connect) {
    self.queue = queue
    open = connect
  }

  package func connect() {
    dispatchPrecondition(condition: .onQueue(queue))
    guard pump == nil, !closed else { return }
    let (stream, continuation) = AsyncStream<
      @Sendable (MuxConnection) async -> Void
    >
    .makeStream()
    operations = continuation
    let open = open
    let queue = queue
    let owner = WeakOwner(self)
    pump = Task {
      // Never cancelled by `close`: a connection being opened is finished
      // and then released, so close completes in service order.
      let opening = Task { try await open() }
      let connection: MuxConnection
      do { connection = try await opening.value } catch {
        queue.async { owner.value?.finish("connect: \(error)") }
        for await _ in stream {}
        return nil
      }
      let welcome = await connection.welcome
      queue.async {
        guard let self = owner.value, !self.closed else { return }
        self.connection = connection
        self.welcome = welcome
        self.listen(connection)
      }
      for await operation in stream { await operation(connection) }
      return connection
    }
  }

  /// Runs `operation` after every earlier one; never after close.
  private func enqueue(
    _ operation: @escaping @Sendable (MuxConnection) async -> Void
  ) -> Bool {
    guard !closed, let operations else { return false }
    if case .terminated = operations.yield(operation) { return false }
    return true
  }

  private func listen(_ connection: MuxConnection) {
    let queue = queue
    let owner = WeakOwner(self)
    events = Task {
      do {
        while let event = try await connection.nextEvent() {
          queue.async { owner.value?.receive(event) }
        }
        queue.async { owner.value?.finish("closed") }
      } catch { queue.async { owner.value?.finish("\(error)") } }
    }
  }

  private func receive(_ event: MuxEvent) {
    guard !closed else { return }
    if case let .frame(frame) = event {
      let pane = frame.identity.pane
      // A frame that only renumbers the same screen is not a change.
      var previous = frames[pane]
      previous?.identity = frame.identity
      frames[pane] = frame
      let captures = waiting.removeValue(forKey: pane) ?? []
      for capture in captures { capture(frame) }
      // Captures that waited for this frame already show it.
      let shown = previous == nil && !captures.isEmpty
      if previous != frame, !shown { onPaneChanged?(pane) }
      return
    }
    if case let .frameUnavailable(pane, _) = event {
      frames.removeValue(forKey: pane)
      for capture in waiting.removeValue(forKey: pane) ?? [] { capture(nil) }
      onPaneChanged?(pane)
      return
    }
    onEvent?(event)
  }

  package func request(
    _ command: MuxCommand,
    expiresAt: ContinuousClock.Instant?,
    isAdmitted: (@Sendable () -> Bool)?,
    _ completion: @escaping (MuxResult) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(queue))
    let queue = queue
    let id = track { completion(.failure($0)) }
    let owner = WeakOwner(self)
    let reply = UncheckedBox(completion)
    let queued = enqueue { connection in
      let result: MuxResult
      if let expiresAt, ContinuousClock.now >= expiresAt {
        result = .failure(MuxError(.unauthorized, "request deadline expired"))
      } else if let isAdmitted, !isAdmitted() {
        result = .failure(MuxError(.unauthorized, "request no longer admitted"))
      } else {
        do { result = .success(try await connection.execute(command)) } catch {
          result = .failure(Self.muxError(error))
        }
      }
      queue.async {
        guard owner.value?.answer(id) == true else { return }
        reply.value(result)
      }
    }
    if !queued, answer(id) { completion(.failure(MuxError(.connectionLost))) }
  }

  /// `MuxConnection` numbers input for its own attachment.
  package func resetInput() {}

  package func input(
    _ payload: InputPayload,
    attachment: AttachmentID,
    pane: PaneID,
    _ completion: @escaping (MuxError?) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(queue))
    let queue = queue
    let id = track { completion($0) }
    let owner = WeakOwner(self)
    let reply = UncheckedBox(completion)
    let queued = enqueue { connection in
      let failure: MuxError?
      do {
        // An RST/1 paste (at most 32 KiB) is one bounded SMX paste record;
        // a full writer refuses it at once and the RST/1 ledger retries.
        switch payload {
        case let .input(input):
          try await connection.send(input, to: pane)
          failure = nil
        default:
          failure = MuxError(.invalidRequest, "unsupported roaming input")
        }
      } catch { failure = Self.muxError(error) }
      queue.async {
        guard owner.value?.answer(id) == true else { return }
        reply.value(failure)
      }
    }
    if !queued, answer(id) { completion(MuxError(.connectionLost)) }
  }

  package func close(then completion: (() -> Void)?) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard !closed else {
      completion?()
      return
    }
    let operations = operations
    let pump = pump
    let events = events
    let queue = queue
    let done = UncheckedBox(completion)
    finish("closed", detaching: true)
    operations?.finish()
    // Withdraw an operation still waiting on the worker; its reply was
    // already failed.
    pump?.cancel()
    Task {
      let connection = await pump?.value ?? nil
      // Released in service order, so a replacement's attach never finds
      // this lease still held.
      await connection?.detach()
      await connection?.close()
      events?.cancel()
      queue.async { done.value?() }
    }
  }

  /// Drops the connection from any thread (its worker was replaced): the
  /// session sees it close and its client reattaches to the new worker.
  package func invalidate(_ reason: String) {
    queue.async { [weak self] in self?.finish(reason) }
  }

  /// `detaching`: `close` releases the lease before closing the connection.
  private func finish(_ reason: String, detaching: Bool = false) {
    guard !closed else { return }
    closed = true
    if !detaching, let connection { Task { await connection.close() } }
    frames = [:]
    let lost = MuxError(.connectionLost, reason)
    let replies = unanswered.values
    unanswered = [:]
    for fail in replies { fail(lost) }
    let pending = waiting.values.flatMap { $0 }
    waiting = [:]
    for capture in pending { capture(nil) }
    operations?.finish()
    onClosed?(reason)
  }

  /// Records a reply to fail on close; `answer` claims it exactly once.
  private func track(_ fail: @escaping (MuxError) -> Void) -> UInt64 {
    nextOperation += 1
    unanswered[nextOperation] = fail
    return nextOperation
  }

  private func answer(_ id: UInt64) -> Bool {
    unanswered.removeValue(forKey: id) != nil
  }

  // MARK: Pane reads

  /// Frames arrive only for the subscribed pane, after the attach.
  private func follow(_ pane: PaneID) {
    guard subscribed != pane, connection != nil else { return }
    subscribed = pane
    frames = frames.filter { $0.key == pane }
    for (other, captures) in waiting where other != pane {
      for capture in captures { capture(nil) }
    }
    waiting = waiting.filter { $0.key == pane }
    _ = enqueue { connection in
      _ = try? await connection.execute(.setSubscriptions([pane]))
    }
  }

  package func capture(
    pane: PaneID,
    stamp: ScreenExporter.Stamp,
    window: (top: Int, generation: UInt64)?,
    _ completion: @escaping @Sendable (RoamingSession.CapturedScreen?) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(queue))
    let export: @Sendable (PaneFrame?) -> Void = { frame in
      guard let frame,
        let (rst, header) = ScreenExporter.frame(from: frame, stamp: stamp)
      else { return completion(nil) }
      completion(.frame(rst, header))
    }
    guard !closed else { return export(nil) }
    follow(pane)
    // Like reading the pane's state: the first screen is the next frame.
    guard let frame = frames[pane] else {
      waiting[pane, default: []].append(export)
      return
    }
    export(frame)
  }

  package func copy(
    pane: PaneID,
    _ request: CopySelectionRequest,
    _ completion: @escaping @Sendable (Result<String, MuxError>?) -> Void
  ) {
    self.request(.copySelection(request), expiresAt: nil, isAdmitted: nil) {
      switch $0 {
      case let .success(.copied(text)): completion(.success(text))
      case let .failure(error) where error.code == .notFound: completion(nil)
      case let .failure(error): completion(.failure(error))
      case .success:
        completion(.failure(MuxError(.invalidRequest, "unexpected reply")))
      }
    }
  }

  package func historyTop(
    pane: PaneID,
    from top: Int?,
    generation: UInt64,
    moving lines: Int,
    _ completion: @escaping @Sendable ((top: Int?, generation: UInt64)?) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard let frame = frames[pane] else { return completion(nil) }
    completion(
      ScreenExporter.historyTop(
        frame.history,
        alternateScreen: frame.grid.alternateScreen,
        from: top,
        generation: generation,
        moving: lines
      )
    )
  }

  package func present(pane: PaneID, top: Int?, generation: UInt64) {
    dispatchPrecondition(condition: .onQueue(queue))
    follow(pane)
    if let presented, presented.pane == pane, presented.top == top,
      presented.generation == generation
    {
      return
    }
    // Live output was never moved away from: nothing to restore.
    if presented == nil, top == nil { return }
    presented = (pane, top, generation)
    let request = ViewportRequest(
      pane: pane,
      anchorRow: top,
      followTail: top == nil,
      historyGeneration: generation
    )
    _ = enqueue { connection in
      _ = try? await connection.execute(.setViewport(request))
    }
  }

  private static func muxError(_ error: any Error) -> MuxError {
    (error as? MuxError) ?? MuxError(.connectionLost, "\(error)")
  }
}

/// Carries a queue-confined callback through a task; it is called only
/// after hopping back to that queue.
private struct UncheckedBox<Value>: @unchecked Sendable {
  let value: Value
  init(_ value: Value) { self.value = value }
}
#endif

#if os(macOS)
/// A weak reference tasks carry back to the owner's queue.
private final class WeakOwner<Owner: AnyObject>: @unchecked Sendable {
  weak var value: Owner?
  init(_ value: Owner) { self.value = value }
}
#endif
