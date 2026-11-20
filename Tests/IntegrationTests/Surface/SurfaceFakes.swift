import Foundation
import ScreenProtocol
import SessionCore
import Synchronization
import SwifttyCore
import TerminalSurface
import Testing

// MARK: Timing

/// Fast deterministic-enough time: simulated time runs `factor` times
/// faster than real time, consistently for `now` and `sleep`. Records
/// every requested sleep (in simulated seconds).
final class TestClock: Sendable {
  let factor: Double
  let origin = ContinuousClock.now
  let wallOffset = Mutex<Double>(0)
  let sleeps = Mutex<[Double]>([])

  init(factor: Double = 20) { self.factor = factor }

  var timing: SurfaceTiming {
    SurfaceTiming(
      now: { [self] in origin + (ContinuousClock.now - origin) * factor },
      wallClock: { [self] in
        Date().timeIntervalSince1970 + wallOffset.withLock { $0 }
      },
      sleep: { [self] duration in
        let c = duration.components
        sleeps.withLock {
          $0.append(Double(c.seconds) + Double(c.attoseconds) / 1e18)
        }
        try await Task.sleep(for: duration * (1 / factor))
      }
    )
  }

  func advanceWallClock(by seconds: Double) {
    wallOffset.withLock { $0 += seconds }
  }

  /// Requested backoff delays (the schedule's values; jitter disabled).
  var backoffSleeps: [Double] {
    let schedule = Set(ReconnectBackoff.schedule)
    return sleeps.withLock { $0 }.filter { schedule.contains($0) }
  }
}

/// Configuration whose other timers cannot be mistaken for backoff.
func testConfiguration(jitter: Double = 0) -> RoamingClientConfiguration {
  RoamingClientConfiguration(
    initialGrid: GridSize(columns: 20, rows: 4),
    detachDeadline: .seconds(3),
    attachTimeout: .seconds(10),
    livenessTick: .milliseconds(250),
    backoffJitter: jitter
  )
}

/// Polls `condition` for up to `timeout` of real time.
func eventually(
  _ timeout: Duration = .seconds(5),
  _ condition: () async -> Bool
) async -> Bool {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(5))
  }
  return await condition()
}

// MARK: Fake host

/// A small RST/1 host: ledgered input applied to a one-line screen,
/// snapshots via `SnapshotFrame.encode`, and knobs for failure injection.
actor FakeHost {
  struct Link: Sendable {
    var connection: InMemoryRSTConnection
    var reader = ControlRecordReader()
    var epoch: UInt64?
    var blackHole = false
  }

  struct Received: Equatable {
    var epoch: UInt64
    var sequence: UInt64
    var operation: InputOperation
  }

  let sessionID = SessionID.random()
  let instanceID = ServerInstanceID.random()
  var writer = WriterID.random()
  var token = ApplicationToken.random()
  var tokenExpiresAt = Date().timeIntervalSince1970 + 3600
  var ledger = HostInputLedger()
  var epoch: UInt64 = 0
  var screenRevision: UInt64 = 0
  var resizeRevision: UInt64 = 0
  var columns = 20
  var rows = 4
  var nextStream: UInt64 = 0
  var limits = NegotiatedLimits()

  /// Oracle: sequences in the order the PTY applied them.
  private(set) var applied: [UInt64] = []
  private(set) var text = ""
  private(set) var received: [Received] = []
  private(set) var resizes: [InputOperation] = []
  private(set) var attachCount = 0
  private(set) var detachCount = 0
  private(set) var terminateCount = 0
  private(set) var screenAckCount = 0
  /// `Viewport` movements received, in order.
  private(set) var viewports: [Int64] = []
  /// Features advertised in `Attached`.
  var features: RSTFeatures = []

  var links: [ObjectIdentifier: Link] = [:]
  var current: ObjectIdentifier?

  var withholdAcks = false
  var dropInputsAfter: UInt64?
  var sendSnapshotOnAttach = true
  var withholdAttached = false
  private var pendingAttached: (ControlMessage, ObjectIdentifier)?
  var sessionGone = false

  init() throws { try ledger.authorize(writer) }

  deinit { for link in links.values { link.connection.close() } }

  func set(features: RSTFeatures) { self.features = features }

  func set(
    withholdAcks: Bool? = nil,
    dropInputsAfter: UInt64?? = nil,
    sendSnapshotOnAttach: Bool? = nil,
    sessionGone: Bool? = nil,
    withholdAttached: Bool? = nil,
    resizeRevision: UInt64? = nil,
    limits: NegotiatedLimits? = nil
  ) {
    if let withholdAcks { self.withholdAcks = withholdAcks }
    if let dropInputsAfter { self.dropInputsAfter = dropInputsAfter }
    if let sendSnapshotOnAttach {
      self.sendSnapshotOnAttach = sendSnapshotOnAttach
    }
    if let sessionGone { self.sessionGone = sessionGone }
    if let withholdAttached { self.withholdAttached = withholdAttached }
    if let resizeRevision { self.resizeRevision = resizeRevision }
    if let limits { self.limits = limits }
  }

  func releaseAttached() async {
    guard let (message, id) = pendingAttached else { return }
    pendingAttached = nil
    await send(message, to: id)
  }

  func makeGrant() -> BootstrapGrant {
    BootstrapGrant(
      serverInstanceID: instanceID,
      sessionID: sessionID,
      writerID: writer,
      endpoint: BootstrapEndpoint(host: "127.0.0.1", port: 51222),
      serverCertificateDER: Data([1, 2, 3]),
      serverCertificateSHA256: hexString([1, 2, 3]),
      applicationToken: token,
      tokenExpiresAt: tokenExpiresAt,
      initialGrid: GridSize(columns: columns, rows: rows),
      limits: limits
    )
  }

  /// SSH bootstrap: create or resume; resume revokes the old token.
  func bootstrap(_ request: BootstrapRequest) -> BootstrapResponse {
    switch request.operation {
    case .create: return .granted(makeGrant())
    case .resume:
      guard !sessionGone, request.sessionID == sessionID else {
        return .failure(.unknownSession)
      }
      if let requested = request.writerID, requested != writer {
        guard (try? ledger.authorize(requested)) != nil else {
          return .failure(.writerBusy)
        }
        writer = requested
      } else if request.writerID == nil {
        let fresh = WriterID.random()
        guard (try? ledger.authorize(fresh)) != nil else {
          return .failure(.writerBusy)
        }
        writer = fresh
      }
      token = ApplicationToken.random()
      tokenExpiresAt = Date().timeIntervalSince1970 + 3600
      return .granted(makeGrant())
    case .terminate:
      terminateCount += 1
      return .terminated(sessionID)
    case .list: return .sessions([])
    case .attention: return .failure(.unsupportedVersion)
    }
  }

  func accept(_ connection: InMemoryRSTConnection) {
    let id = ObjectIdentifier(connection)
    links[id] = Link(connection: connection)
    connection.start(
      RSTConnectionHandler(
        onControl: { [weak self] bytes in await self?.receive(bytes, from: id)
        },
        onClosed: { [weak self] _ in Task { await self?.forget(id) } }
      )
    )
  }

  private func forget(_ id: ObjectIdentifier) {
    links.removeValue(forKey: id)
    if current == id { current = nil }
    if pendingAttached?.1 == id { pendingAttached = nil }
  }

  /// Another client (e.g. the Mac app) resized the session.
  func resizeExternally(columns: Int, rows: Int) {
    self.columns = columns
    self.rows = rows
    resizeRevision += 1
  }

  /// Abrupt path loss on the current connection.
  func severCurrent() {
    guard let current, let link = links[current] else { return }
    link.connection.sever()
  }

  /// The current connection silently drops everything from now on.
  func blackHoleCurrent() {
    guard let current else { return }
    links[current]?.blackHole = true
  }

  func exit(status: Int32) async {
    guard let current, let epoch = links[current]?.epoch else { return }
    await send(
      .sessionExited(
        epoch: epoch,
        status: status,
        finalScreenRevision: screenRevision
      ),
      to: current
    )
  }

  /// Delivers the exact frame whose header a test used to set its limits.
  func sendEncodedSnapshotForTesting(_ payload: [UInt8]) async throws {
    let id = try #require(current)
    let link = try #require(links[id])
    nextStream += 1
    try await link.connection.sendSnapshot(payload, stream: nextStream)
  }

  func sendScreen() async {
    guard let current, let epoch = links[current]?.epoch else { return }
    screenRevision += 1
    await sendSnapshot(
      makeSnapshot(epoch: epoch, revision: screenRevision),
      to: current
    )
  }

  /// Sends an arbitrary screen (stale-frame tests) without touching the
  /// host's revision counter.
  func sendScreen(epoch: UInt64, revision: UInt64, text: String) async {
    guard let current else { return }
    var snapshot = makeSnapshot(epoch: epoch, revision: revision)
    snapshot.cells[0] = Self.row(text, columns: columns)
    await sendSnapshot(snapshot, to: current)
  }

  /// Sends a frame while leaving input/probe responses blackholed.
  func sendUnansweredScreen(
    epoch: UInt64,
    revision: UInt64,
    malformed: Bool = false,
    wrongSession: Bool = false
  ) async throws {
    let id = try #require(current)
    let link = try #require(links[id])
    var snapshot = makeSnapshot(epoch: epoch, revision: revision)
    if wrongSession { snapshot.sessionID = SessionID.random() }
    let payload = malformed ? [0] : try SnapshotFrame.encode(snapshot)
    nextStream += 1
    try await link.connection.sendSnapshot(payload, stream: nextStream)
  }

  var currentEpoch: UInt64? { current.flatMap { links[$0]?.epoch } }

  func sendControlForTesting(_ message: ControlMessage) async {
    guard let current else { return }
    await send(message, to: current)
  }

  func sendSnapshotForTesting(_ snapshot: ScreenSnapshot) async {
    guard let current else { return }
    await sendSnapshot(snapshot, to: current)
  }

  func snapshotForTesting() -> ScreenSnapshot {
    makeSnapshot(epoch: max(1, epoch), revision: screenRevision + 1)
  }

  // MARK: Protocol

  private func receive(_ bytes: [UInt8], from id: ObjectIdentifier) async {
    guard var link = links[id], !link.blackHole else { return }
    let messages = (try? link.reader.append(bytes)) ?? []
    links[id] = link
    for message in messages { await handle(message, from: id) }
  }

  private func handle(
    _ message: ControlMessage,
    from id: ObjectIdentifier
  ) async {
    switch message {
    case let .attach(attach):
      attachCount += 1
      if sessionGone {
        await send(.error(.init(.unknownSession)), to: id)
        return
      }
      guard attach.sessionID == sessionID,
        attach.serverInstanceID == instanceID,
        attach.applicationToken.matches(token)
      else {
        await send(.error(.init(.unauthorized)), to: id)
        return
      }
      guard (try? ledger.authorize(attach.writerID)) != nil else {
        await send(.error(.init(.writerBusy)), to: id)
        return
      }
      epoch += 1
      links[id]?.epoch = epoch
      current = id
      let attached = ControlMessage.attached(
        .init(
          attachmentEpoch: epoch,
          writerID: attach.writerID,
          lastFullyAppliedInputSequence: ledger.lastApplied,
          partialInputSequence: ledger.partialSequence,
          resizeRevision: resizeRevision,
          features: features
        )
      )
      if withholdAttached {
        pendingAttached = (attached, id)
      } else {
        await send(attached, to: id)
      }
      if sendSnapshotOnAttach { await sendScreen() }
    case let .input(input):
      received.append(
        Received(
          epoch: input.attachmentEpoch,
          sequence: input.sequence,
          operation: input.operation
        )
      )
      guard id == current, input.attachmentEpoch == links[id]?.epoch else {
        await send(.error(.init(.staleEpoch, sequence: input.sequence)), to: id)
        return
      }
      if let limit = dropInputsAfter, input.sequence > limit { return }
      await apply(input, from: id)
    case let .ping(e, nonce): await send(.pong(epoch: e, nonce: nonce), to: id)
    case let .detach(e):
      detachCount += 1
      await send(.detached(epoch: e), to: id)
    case let .terminate(e):
      terminateCount += 1
      await send(.terminated(epoch: e), to: id)
    case let .viewport(_, lines): viewports.append(lines)
    case .screenAck: screenAckCount += 1
    default: await send(.error(.init(.malformed)), to: id)
    }
  }

  private func apply(
    _ input: ControlMessage.Input,
    from id: ObjectIdentifier
  ) async {
    let epoch = input.attachmentEpoch
    switch ledger.classify(
      writer: writer,
      sequence: input.sequence,
      operation: input.operation
    ) {
    case .admit:
      var bytes: [UInt8] = []
      switch input.operation {
      case let .committedText(t), let .paste(t): bytes = Array(t.utf8)
      case .key: bytes = [0x0D]
      case let .resize(c, r, revision):
        columns = c
        rows = r
        resizeRevision = revision
        resizes.append(input.operation)
      }
      ledger.record(input.sequence, operation: input.operation, bytes: bytes)
      let done =
        bytes.isEmpty ? ledger.completeHead() : ledger.wrote(bytes.count)
      precondition(done == input.sequence)
      applied.append(input.sequence)
      if case let .committedText(t) = input.operation { text += t }
      if case let .paste(t) = input.operation { text += t }
      if !withholdAcks {
        await send(.inputAck(epoch: epoch, sequence: input.sequence), to: id)
      }
      await sendScreen()
    case .alreadyApplied:
      await send(.inputAck(epoch: epoch, sequence: input.sequence), to: id)
    case .inProgress: break
    case let .rejected(rejection):
      await send(
        .error(.init(RSTErrorCode(rejection), sequence: input.sequence)),
        to: id
      )
    }
  }

  private func send(_ message: ControlMessage, to id: ObjectIdentifier) async {
    guard let link = links[id], !link.blackHole else { return }
    let record: [UInt8]
    do { record = try ControlRecord.encode(message) } catch {
      Issue.record(error)
      return
    }
    try? await link.connection.sendControl(record)
  }

  private func sendSnapshot(
    _ snapshot: ScreenSnapshot,
    to id: ObjectIdentifier
  ) async {
    guard let link = links[id], !link.blackHole else { return }
    nextStream += 1
    let stream = nextStream
    let payload: [UInt8]
    do { payload = try SnapshotFrame.encode(snapshot) } catch {
      Issue.record(error)
      return
    }
    try? await link.connection.sendSnapshot(payload, stream: stream)
  }

  private func makeSnapshot(epoch: UInt64, revision: UInt64) -> ScreenSnapshot {
    var snapshot = ScreenSnapshot.blank(
      sessionID: sessionID,
      columns: columns,
      rows: rows
    )
    snapshot.attachmentEpoch = epoch
    snapshot.screenRevision = revision
    snapshot.resizeRevision = resizeRevision
    let line = String(text.suffix(columns))
    snapshot.cells[0] = Self.row(line, columns: columns)
    snapshot.cursor = ScreenCursor(row: 0, column: line.count)
    snapshot.title = "host"
    snapshot.lastFullyAppliedInputSequence = ledger.lastApplied
    return snapshot
  }

  static func row(_ text: String, columns: Int) -> [ScreenCell] {
    var cells = text.prefix(columns).map { ScreenCell(String($0)) }
    while cells.count < columns { cells.append(.blank) }
    return cells
  }
}

// MARK: Fake SSH bootstrap and QUIC connector

final class FakeBootstrapper: RemoteBootstrapper {
  let host: FakeHost
  let unreachableCount = Mutex(0)
  let requests = Mutex<[BootstrapRequest]>([])

  init(host: FakeHost) { self.host = host }

  func bootstrap(_ request: BootstrapRequest) async throws -> BootstrapResponse
  {
    requests.withLock { $0.append(request) }
    let fail = unreachableCount.withLock { n -> Bool in
      guard n > 0 else { return false }
      n -= 1
      return true
    }
    if fail { throw RemoteBootstrapError.unreachable }
    return await host.bootstrap(request)
  }
}

actor FakeConnector: RSTConnector {
  let host: FakeHost
  private(set) var currentConnection: InMemoryRSTConnection?
  private(set) var connectCount = 0
  private(set) var inFlight = 0
  private(set) var maxInFlight = 0
  var failuresRemaining = 0
  private var blocked = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(host: FakeHost) { self.host = host }

  func fail(next count: Int) { failuresRemaining = count }

  func block() { blocked = true }

  func release() {
    blocked = false
    let pending = waiters
    waiters = []
    for waiter in pending { waiter.resume() }
  }

  func connect(to grant: BootstrapGrant) async throws -> any RSTConnection {
    connectCount += 1
    inFlight += 1
    maxInFlight = max(maxInFlight, inFlight)
    defer { inFlight -= 1 }
    if blocked { await withCheckedContinuation { waiters.append($0) } }
    // Hold the slot briefly so overlapping attempts would be observed.
    try? await Task.sleep(for: .milliseconds(2))
    if failuresRemaining > 0 {
      failuresRemaining -= 1
      throw RSTTransportError.handshake("unreachable")
    }
    let (client, server) = InMemoryRSTConnection.pair()
    await host.accept(server)
    currentConnection = client
    return client
  }
}

// MARK: Presentation sink

final class RecordingSink: PresentationSink {
  let frames = Mutex<[PresentationFrame]>([])

  func install(_ frame: PresentationFrame) -> Bool {
    frames.withLock { $0.append(frame) }
    return true
  }

  var count: Int { frames.withLock { $0.count } }
  var last: PresentationFrame? { frames.withLock { $0.last } }
  var lastLine: String? { last.map { $0.line(0) } }
}

extension PresentationFrame {
  func line(_ row: Int) -> String {
    var out = ""
    for x in 0 ..< columns {
      let cell = cells[row * columns + x]
      if cell.width == 0 { continue }
      out += cell.text.isEmpty ? " " : cell.text
    }
    while out.last == " " { out.removeLast() }
    return out
  }
}

// MARK: Fixture

struct RoamingFixture {
  let clock = TestClock()
  let host: FakeHost
  let bootstrapper: FakeBootstrapper
  let connector: FakeConnector
  let sink = RecordingSink()
  let client: RoamingClient

  init(jitter: Double = 0, initialGrid: GridSize? = nil) throws {
    host = try FakeHost()
    bootstrapper = FakeBootstrapper(host: host)
    connector = FakeConnector(host: host)
    var configuration = testConfiguration(jitter: jitter)
    if let initialGrid { configuration.initialGrid = initialGrid }
    client = RoamingClient(
      bootstrapper: bootstrapper,
      connector: connector,
      sink: sink,
      configuration: configuration,
      timing: clock.timing
    )
  }

  func startActive() async throws -> Bool {
    try await client.start(.create(GridSize(columns: 20, rows: 4)))
    return await eventually { await client.state == .active }
  }

  func waitFor(_ state: ClientConnectionState) async -> Bool {
    await eventually { await client.state == state }
  }
}

// MARK: Ordinary SSH channel

/// A credit-respecting channel: output is delivered only while credit
/// remains (overshooting by at most one chunk, like a transport read).
final class FakeByteChannel: TerminalByteChannel {
  private enum Delivery {
    case output([UInt8])
    case exit(TerminalChannelExit)
  }

  struct State {
    var handler: TerminalChannelHandler?
    var credit = 0
    var pending: [[UInt8]] = []
    var pendingExit: TerminalChannelExit?
    var finished = false
    var delivering = false
    var delivered = 0
    var writes: [[UInt8]] = []
    var resizes: [GridSize] = []
    var closed = false
  }

  let state = Mutex(State())

  func start(_ handler: TerminalChannelHandler) {
    state.withLock { if !$0.finished { $0.handler = handler } }
    pumpOutput()
  }

  func grantCredit(_ bytes: Int) {
    state.withLock { $0.credit += bytes }
    pumpOutput()
  }

  /// Remote program output.
  func feed(_ chunk: [UInt8]) {
    state.withLock { s in
      guard !s.finished, s.pendingExit == nil else { return }
      s.pending.append(chunk)
    }
    pumpOutput()
  }

  func exit(_ exit: TerminalChannelExit) {
    state.withLock { s in
      guard !s.finished, s.pendingExit == nil else { return }
      s.pendingExit = exit
    }
    pumpOutput()
  }

  private func pumpOutput() {
    let claimed = state.withLock { s -> Bool in
      guard !s.delivering, !s.finished else { return false }
      s.delivering = true
      return true
    }
    guard claimed else { return }
    while true {
      let next = state.withLock { s -> (Delivery, TerminalChannelHandler)? in
        guard let handler = s.handler else {
          s.delivering = false
          return nil
        }
        if !s.pending.isEmpty {
          guard s.credit > 0 else {
            s.delivering = false
            return nil
          }
          let chunk = s.pending.removeFirst()
          s.credit -= chunk.count
          s.delivered += chunk.count
          return (.output(chunk), handler)
        }
        if let exit = s.pendingExit {
          s.pendingExit = nil
          s.finished = true
          s.handler = nil
          return (.exit(exit), handler)
        }
        s.delivering = false
        return nil
      }
      guard let (delivery, handler) = next else { break }
      switch delivery {
      case let .output(chunk): handler.onOutput(chunk)
      case let .exit(exit): handler.onExit(exit)
      }
    }
  }

  func write(_ bytes: [UInt8]) async throws {
    state.withLock { $0.writes.append(bytes) }
  }

  func resize(columns: Int, rows: Int) async throws {
    state.withLock { $0.resizes.append(GridSize(columns: columns, rows: rows)) }
  }

  // Keep credit-driven delivery available as a probe: backpressure tests
  // must detect credit incorrectly returned by a backend after close.
  func close() async { state.withLock { $0.closed = true } }

  var delivered: Int { state.withLock { $0.delivered } }
  var written: [UInt8] { state.withLock { $0.writes.flatMap { $0 } } }
  var resizes: [GridSize] { state.withLock { $0.resizes } }
}
