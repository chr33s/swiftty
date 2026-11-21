#if os(macOS)
import Foundation
@testable import RoamingKit
import ScreenProtocol
import SessionCore
import SwiftMuxProtocol
import SwifttyEngine
import Synchronization
@testable import TerminalHost
import Testing

// An impaired RST/1 path between a real host registry and a real
// `RoamingClient` (spec.roaming.md §7, A3/A20/A22). RST/1 runs over QUIC:
// one reliable control stream and one snapshot stream per screen, so the
// impairments a client and host can observe at this layer are
//
// - snapshot streams that complete late (reordering screens across
//   streams), are reset by the transport (nothing delivered), or are
//   cancelled by the host yet still complete at the client because the
//   bytes were already accepted (§7.1, `RSTConnection.cancelSnapshot`);
// - control records that arrive late, in order, relative to snapshots;
// - client records the protocol must tolerate seeing twice: identical
//   `Input` retries (§8 rule 1/4), duplicate and older `ScreenAck`s
//   (§7.3) and repeated `RequestFullScreen` (§7.4);
// - abrupt connection loss at acknowledgement boundaries, after which
//   the client reattaches with a new epoch (§8, §9).
//
// Every decision is drawn from one seeded generator per link, so a seed
// reproduces the same sequence of decisions; thread scheduling still
// decides which record each decision falls on.

/// What the link does to traffic. Delays are uniform in their range, in
/// milliseconds; rates are per record or stream.
struct ImpairmentProfile: Sendable {
  var snapshotDelay: ClosedRange<Int> = 0 ... 0
  /// The transport resets a snapshot stream: the host's send fails with
  /// `canceled` and the client receives nothing.
  var snapshotResetRate = 0.0
  /// A stream the host cancels while it is delayed still completes at
  /// the client.
  var lateCompletionRate = 0.0
  var controlDelay: ClosedRange<Int> = 0 ... 0
  /// Client to host: `Input`, `ScreenAck` and `RequestFullScreen` sent
  /// twice in a row.
  var duplicateRate = 0.0
  /// Client to host: an `Input` or `ScreenAck` sent again after the next
  /// record (an older duplicate).
  var lateDuplicateRate = 0.0
  /// Abrupt loss at a `ScreenAck` (client) or `InputAck` (host) boundary,
  /// before or after the record is forwarded; at most `maxKills`.
  var killRate = 0.0
  var maxKills = 0
  /// Feature names removed from `Attach` (as from a client without them)
  /// and from `Attached` (as from a host without them).
  var stripFromAttach: RSTFeatures = []
  var stripFromAttached: RSTFeatures = []

  /// The A3 loss/duplication/reordering profile, without random kills.
  static let a3 = ImpairmentProfile(
    snapshotDelay: 0 ... 100,
    snapshotResetRate: 0.1,
    lateCompletionRate: 0.5,
    controlDelay: 0 ... 6,
    duplicateRate: 0.15,
    lateDuplicateRate: 0.1
  )

  /// A3 with kills at acknowledgement boundaries.
  static let a3Kills: ImpairmentProfile = {
    var p = a3
    p.killRate = 0.03
    p.maxKills = 3
    return p
  }()
}

/// Shared state of one client's impaired path, across reconnections:
/// the generator, kill budget, armed faults and a log of what crossed.
final class ImpairedLink: Sendable {
  enum Direction: Sendable { case toHost, toClient }

  struct ControlEvent: Sendable {
    var connection: Int
    var direction: Direction
    var message: ControlMessage
    var duplicate: Bool
  }

  enum Fate: Sendable, Equatable {
    case delivered
    /// Reset by the transport; the client saw nothing.
    case reset
    /// Cancelled by the host before completing.
    case canceled
    /// Cancelled by the host, but completed at the client anyway.
    case lateAfterCancel
  }

  struct SnapshotEvent: Sendable {
    var connection: Int
    var revision: UInt64
    var epoch: UInt64
    var delta: Bool
    var base: UInt64?
    var fate: Fate
    /// Wire size of the record (zlib applied by the host when it helps).
    var bytes = 0
    /// The record, kept only while `capturePayloads` is set.
    var payload: [UInt8]?
  }

  enum Corruption: Sendable, Equatable {
    /// The delta names a base the client never had.
    case missingBase
    /// The delta's row-identity checksum does not match.
    case badChecksum
  }

  enum KillPoint: Sendable, Equatable {
    case screenAck(afterForward: Bool)
    case inputAck(afterForward: Bool)
    case copyChunk(index: UInt64, afterForward: Bool)
  }

  private struct State {
    var rng: SplitMix64
    var profile: ImpairmentProfile
    var randomKills = true
    var kills = 0
    var connections = 0
    var control: [ControlEvent] = []
    var snapshots: [SnapshotEvent] = []
    var corrupt: Corruption?
    var corrupted: [(revision: UInt64, kind: Corruption)] = []
    var killAt: KillPoint?
    var killed: [KillPoint] = []
    /// Fixed host-to-client control pacing, replacing the random delay.
    var pace: Duration?
    var capturePayloads = false
    /// Extra delay for the next client `ScreenAck` (it stalls the ordered
    /// control stream behind it, as a slow return path would).
    var screenAckHold: Duration?
    var heldScreenAcks = 0
  }

  let seed: UInt64
  private let state: Mutex<State>

  init(seed: UInt64, profile: ImpairmentProfile) {
    self.seed = seed
    state = Mutex(State(rng: SplitMix64(seed: seed), profile: profile))
  }

  var profile: ImpairmentProfile {
    get { state.withLock { $0.profile } }
    set { state.withLock { $0.profile = newValue } }
  }

  // MARK: Test controls

  func setRandomKills(_ on: Bool) { state.withLock { $0.randomKills = on } }

  func corruptNextDelta(_ kind: Corruption) {
    state.withLock { $0.corrupt = kind }
  }

  func killAt(_ point: KillPoint) { state.withLock { $0.killAt = point } }

  /// Paces host-to-client control records at `interval` each (a slow
  /// return path), or restores the profile's delays.
  func pace(_ interval: Duration?) { state.withLock { $0.pace = interval } }

  /// Holds the next client `ScreenAck` back by `duration`.
  func holdNextScreenAck(for duration: Duration) {
    state.withLock { $0.screenAckHold = duration }
  }

  var heldScreenAcks: Int { state.withLock { $0.heldScreenAcks } }

  func takeScreenAckHold(_ message: ControlMessage) -> Duration? {
    guard case .screenAck = message else { return nil }
    return state.withLock { s in
      defer { s.screenAckHold = nil }
      if s.screenAckHold != nil { s.heldScreenAcks += 1 }
      return s.screenAckHold
    }
  }

  // MARK: Observations

  var control: [ControlEvent] { state.withLock { $0.control } }
  var snapshots: [SnapshotEvent] { state.withLock { $0.snapshots } }
  var corrupted: [(revision: UInt64, kind: Corruption)] {
    state.withLock { $0.corrupted }
  }
  var killed: [KillPoint] { state.withLock { $0.killed } }
  var connections: Int { state.withLock { $0.connections } }

  func messages(_ direction: Direction) -> [ControlMessage] {
    control.filter { $0.direction == direction }.map(\.message)
  }

  // MARK: Decisions (one generator, so a seed replays them)

  func nextConnection() -> Int {
    state.withLock {
      $0.connections += 1
      return $0.connections
    }
  }

  private static func draw(_ rng: inout SplitMix64, _ p: Double) -> Bool {
    p > 0 && Double(rng.next() >> 11) / Double(1 << 53) < p
  }

  private static func delay(
    _ rng: inout SplitMix64,
    _ range: ClosedRange<Int>
  ) -> Duration {
    guard range.upperBound > 0 else { return .zero }
    return .milliseconds(Int.random(in: range, using: &rng))
  }

  struct SnapshotPlan {
    var reset: Bool
    var delay: Duration
    var lateIfCanceled: Bool
  }

  func planSnapshot() -> SnapshotPlan {
    state.withLock { s in
      SnapshotPlan(
        reset: Self.draw(&s.rng, s.profile.snapshotResetRate),
        delay: Self.delay(&s.rng, s.profile.snapshotDelay),
        lateIfCanceled: Self.draw(&s.rng, s.profile.lateCompletionRate)
      )
    }
  }

  func controlDelay(_ direction: Direction) -> Duration {
    state.withLock { s in
      if direction == .toClient, let pace = s.pace { return pace }
      return Self.delay(&s.rng, s.profile.controlDelay)
    }
  }

  enum Duplicate { case none, now, later }

  func planDuplicate(_ message: ControlMessage) -> Duplicate {
    state.withLock { s in
      switch message {
      case .input, .screenAck:
        if Self.draw(&s.rng, s.profile.duplicateRate) { return .now }
        if Self.draw(&s.rng, s.profile.lateDuplicateRate) { return .later }
        return .none
      case .requestFullScreen:
        return Self.draw(&s.rng, s.profile.duplicateRate) ? .now : .none
      default: return .none
      }
    }
  }

  /// Whether to kill at this record, and whether after forwarding it.
  func planKill(_ message: ControlMessage) -> Bool? {
    state.withLock { s -> Bool? in
      if let armed = s.killAt {
        let hit: Bool? =
          switch (armed, message) {
          case let (.screenAck(after), .screenAck): after
          case let (.inputAck(after), .inputAck): after
          case let (.copyChunk(index, after), .copyChunk(_, _, i, _))
          where i == index: after
          default: nil
          }
        if let hit {
          s.killAt = nil
          s.killed.append(armed)
          return hit
        }
      }
      switch message {
      case .screenAck, .inputAck:
        guard s.randomKills, s.kills < s.profile.maxKills,
          Self.draw(&s.rng, s.profile.killRate)
        else { return nil }
        s.kills += 1
        let after = Self.draw(&s.rng, 0.5)
        s.killed.append(
          message.isScreenAck
            ? .screenAck(afterForward: after) : .inputAck(afterForward: after)
        )
        return after
      default: return nil
      }
    }
  }

  func takeCorruption() -> Corruption? {
    state.withLock { s in
      defer { s.corrupt = nil }
      return s.corrupt
    }
  }

  func noteCorrupted(_ revision: UInt64, _ kind: Corruption) {
    state.withLock { $0.corrupted.append((revision, kind)) }
  }

  func log(_ event: ControlEvent) {
    state.withLock { $0.control.append(event) }
  }

  func log(_ event: SnapshotEvent) {
    state.withLock { $0.snapshots.append(event) }
  }

  /// Keeps each logged record's bytes, for replaying the client's work.
  func capturePayloads() { state.withLock { $0.capturePayloads = true } }

  var isCapturingPayloads: Bool { state.withLock { $0.capturePayloads } }
}

extension ControlMessage {
  fileprivate var isScreenAck: Bool {
    if case .screenAck = self { true } else { false }
  }
}

/// One end of an in-memory RST/1 pair with the link's impairments applied
/// to what this end sends. Delivery to this end is unchanged.
final class ImpairedRSTConnection: RSTConnection, Sendable {
  let inner: InMemoryRSTConnection
  let link: ImpairedLink
  let index: Int
  let direction: ImpairedLink.Direction
  private struct State {
    var canceled: Set<UInt64> = []
    var heldDuplicate: [UInt8]?
  }
  private let state = Mutex(State())
  /// Stream IDs for late completions, clear of the host's own IDs.
  private static let lateStreamBit: UInt64 = 1 << 62

  init(
    _ inner: InMemoryRSTConnection,
    link: ImpairedLink,
    index: Int,
    direction: ImpairedLink.Direction
  ) {
    self.inner = inner
    self.link = link
    self.index = index
    self.direction = direction
  }

  var isClosed: Bool { inner.isClosed }

  func start(_ handler: RSTConnectionHandler) { inner.start(handler) }

  func close() { inner.close() }

  /// Abrupt loss: both ends observe an error.
  func sever() { inner.sever() }

  // MARK: Control

  func sendControl(_ record: [UInt8]) async throws {
    guard !inner.isClosed else { throw RSTTransportError.closed }
    var record = record
    var reader = ControlRecordReader()
    // Each call carries exactly one record from both peers' senders.
    guard let message = (try? reader.append(record))?.first else {
      return try await forward(record)
    }
    var sent = message
    let profile = link.profile
    switch message {
    case var .attach(attach) where !profile.stripFromAttach.isEmpty:
      attach.features.subtract(profile.stripFromAttach)
      sent = .attach(attach)
      record = try ControlRecord.encode(sent)
    case var .attached(attached) where !profile.stripFromAttached.isEmpty:
      attached.features.subtract(profile.stripFromAttached)
      sent = .attached(attached)
      record = try ControlRecord.encode(sent)
    default: break
    }
    let delay = link.controlDelay(direction)
    if delay > .zero { try? await Task.sleep(for: delay) }
    if direction == .toHost, let hold = link.takeScreenAckHold(sent) {
      try? await Task.sleep(for: hold)
    }
    let kill = link.planKill(sent)
    if kill == false {
      sever()
      throw RSTTransportError.closed
    }
    try await forward(record)
    log(sent, duplicate: false)
    if kill == true {
      sever()
      return
    }
    guard direction == .toHost else { return }
    let held = state.withLock { s in
      defer { s.heldDuplicate = nil }
      return s.heldDuplicate
    }
    switch link.planDuplicate(sent) {
    case .now:
      try await forward(record)
      log(sent, duplicate: true)
    case .later: state.withLock { $0.heldDuplicate = record }
    case .none: break
    }
    if let held, let message = (try? reader.append(held))?.first {
      try await forward(held)
      log(message, duplicate: true)
    }
  }

  private func log(_ message: ControlMessage, duplicate: Bool) {
    link.log(
      .init(
        connection: index,
        direction: direction,
        message: message,
        duplicate: duplicate
      )
    )
  }

  /// The in-memory window refuses rather than waits; wait like flow
  /// control instead.
  private func forward(_ record: [UInt8]) async throws {
    while true {
      do { return try await inner.sendControl(record) } catch RSTTransportError
        .resourceLimit
      { try await Task.sleep(for: .milliseconds(1)) }
    }
  }

  // MARK: Snapshots (host to client)

  func sendSnapshot(_ payload: [UInt8], stream id: UInt64) async throws {
    var payload = payload
    var info = Self.describe(payload)
    var corruption: ImpairedLink.Corruption?
    if info?.delta == true, let kind = link.takeCorruption(),
      let corrupted = Self.corrupt(payload, kind)
    {
      payload = corrupted
      corruption = kind
      info = Self.describe(payload)
    }
    let plan = link.planSnapshot()
    func log(_ fate: ImpairedLink.Fate) {
      if let corruption {
        // Only a corruption the client receives counts; otherwise the
        // next delta carries it.
        if fate == .delivered || fate == .lateAfterCancel {
          link.noteCorrupted(info?.revision ?? 0, corruption)
        } else {
          link.corruptNextDelta(corruption)
        }
      }
      guard let info else { return }
      link.log(
        .init(
          connection: index,
          revision: info.revision,
          epoch: info.epoch,
          delta: info.delta,
          base: info.base,
          fate: fate,
          bytes: payload.count,
          payload: link.isCapturingPayloads ? payload : nil
        )
      )
    }
    if plan.reset {
      log(.reset)
      throw RSTTransportError.canceled
    }
    var interrupted = false
    if plan.delay > .zero {
      do { try await Task.sleep(for: plan.delay) } catch { interrupted = true }
    }
    let canceled = state.withLock { $0.canceled.contains(id) }
    if interrupted || canceled || Task.isCancelled {
      if plan.lateIfCanceled, !inner.isClosed {
        // Already accepted by the transport: it completes anyway, as a
        // stream the host no longer tracks.
        let inner = inner
        let late = id | Self.lateStreamBit
        log(.lateAfterCancel)
        Task.detached { try? await inner.sendSnapshot(payload, stream: late) }
      } else {
        log(.canceled)
      }
      throw RSTTransportError.canceled
    }
    do {
      while true {
        do {
          try await inner.sendSnapshot(payload, stream: id)
          break
        } catch RSTTransportError.resourceLimit {
          try await Task.sleep(for: .milliseconds(1))
        }
      }
    } catch {
      log(.canceled)
      throw error
    }
    log(.delivered)
  }

  func cancelSnapshot(stream id: UInt64) {
    state.withLock { _ = $0.canceled.insert(id) }
    inner.cancelSnapshot(stream: id)
  }

  struct RecordInfo {
    var revision: UInt64
    var epoch: UInt64
    var delta: Bool
    var base: UInt64?
  }

  static func describe(_ payload: [UInt8]) -> RecordInfo? {
    switch try? SnapshotFrame.decodeRecord(payload) {
    case let .frame(_, h)?:
      RecordInfo(
        revision: h.screenRevision,
        epoch: h.attachmentEpoch,
        delta: false
      )
    case let .delta(d, h)?:
      RecordInfo(
        revision: h.screenRevision,
        epoch: h.attachmentEpoch,
        delta: true,
        base: d.baseRevision
      )
    case let .snapshot(s)?:
      RecordInfo(
        revision: s.screenRevision,
        epoch: s.attachmentEpoch,
        delta: false
      )
    case nil: nil
    }
  }

  /// Re-encodes a delta with a base the client never had, or with a
  /// checksum that cannot match.
  static func corrupt(
    _ payload: [UInt8],
    _ kind: ImpairedLink.Corruption
  ) -> [UInt8]? {
    guard
      case .delta(var delta, let header)? = try? SnapshotFrame.decodeRecord(
        payload
      )
    else { return nil }
    switch kind {
    case .missingBase: delta.baseRevision = header.screenRevision &+ 1_000_000
    case .badChecksum: delta.identityChecksum ^= 0x5A5A_5A5A
    }
    return try? SnapshotFrame.encode(
      frame: [UInt8](SMXB.encode(delta, envelope: .rst(header.bytes)))
    )
  }
}

/// Connects the client to the registry through a fresh impaired pair for
/// every attempt, all sharing one link.
final class ImpairedConnector: RSTConnector {
  let registry: SessionRegistry
  let link: ImpairedLink
  private let current = Mutex<ImpairedRSTConnection?>(nil)

  init(registry: SessionRegistry, link: ImpairedLink) {
    self.registry = registry
    self.link = link
  }

  func connect(to grant: BootstrapGrant) async throws -> any RSTConnection {
    let index = link.nextConnection()
    let (client, server) = InMemoryRSTConnection.pair()
    registry.accept(
      ImpairedRSTConnection(
        server,
        link: link,
        index: index,
        direction: .toClient
      )
    )
    let end = ImpairedRSTConnection(
      client,
      link: link,
      index: index,
      direction: .toHost
    )
    current.withLock { $0 = end }
    return end
  }

  func sever() { current.withLock { $0 }?.sever() }
}

// MARK: Host oracle

/// The host's complete screen at every revision it submitted for sending,
/// mapped as the client maps a complete frame for display.
final class HostScreenOracle: Sendable {
  struct Screen: Sendable {
    var epoch: UInt64
    /// Nil for a legacy snapshot (a screen the frame budgets cannot
    /// express, §7.4 "Limits").
    var frame: PaneFrame?
    var display: PresentationFrame
  }

  private let screens = Mutex<[UInt64: Screen]>([:])
  private let unmapped = Mutex(0)

  func record(_ screen: RoamingSession.CapturedScreen) {
    let entry: Screen?
    switch screen {
    case let .frame(frame, header):
      entry = RoamingClient.screen(frame, header: header)
        .map {
          Screen(epoch: header.attachmentEpoch, frame: frame, display: $0.frame)
        }
    case let .snapshot(snapshot):
      entry = Screen(
        epoch: snapshot.attachmentEpoch,
        frame: nil,
        display: PresentationMapper.map(snapshot)
      )
    }
    guard let entry else {
      unmapped.withLock { $0 += 1 }
      return
    }
    screens.withLock { $0[screen.screenRevision] = entry }
  }

  var all: [UInt64: Screen] { screens.withLock { $0 } }
  var unmappedCount: Int { unmapped.withLock { $0 } }

  /// Assigns every installed screen to a host revision with identical
  /// display, strictly increasing (installs never repeat a revision).
  /// Greedy earliest assignment finds one whenever any exists. Returns the
  /// assigned revisions, or the index of the first install with none.
  func assign(
    _ installs: [PresentationFrame]
  ) -> Result<[UInt64], AssignmentFailure> {
    let screens = all.sorted { $0.key < $1.key }
    var floor: UInt64 = 0
    var out: [UInt64] = []
    for (i, frame) in installs.enumerated() {
      guard
        let match = screens.first(where: {
          $0.key > floor && $0.value.display == frame
        })
      else {
        let anywhere = screens.filter { $0.value.display == frame }.map(\.key)
        return .failure(
          AssignmentFailure(
            install: i,
            after: floor,
            matchesAnywhere: anywhere,
            text: (0 ..< frame.rows).map { frame.line($0) }
          )
        )
      }
      floor = match.key
      out.append(match.key)
    }
    return .success(out)
  }

  struct AssignmentFailure: Error, CustomStringConvertible {
    var install: Int
    var after: UInt64
    var matchesAnywhere: [UInt64]
    var text: [String]
    var description: String {
      "install \(install) after revision \(after) matches no later host "
        + "screen (equal content at \(matchesAnywhere)):\n"
        + text.joined(separator: "\n")
    }
  }
}

/// Bootstraps through the registry's service, then attaches the oracle to
/// the granted session before the client can connect.
struct ObservingBootstrapper: RemoteBootstrapper {
  let service: BootstrapService
  let registry: SessionRegistry
  let oracle: HostScreenOracle

  func bootstrap(_ request: BootstrapRequest) async throws -> BootstrapResponse
  {
    let response = try await EnvelopeBootstrapper(service: service)
      .bootstrap(request)
    if case let .granted(grant) = response,
      let session = registry.session(grant.sessionID)
    {
      let oracle = oracle
      session.submittedScreenObserver.withLock { $0 = { oracle.record($0) } }
    }
    return response
  }
}

/// Records every installed screen in order, and optionally forwards it to
/// a display.
final class InstallLog: PresentationSink {
  private let frames = Mutex<[PresentationFrame]>([])
  let display: (any PresentationSink)?

  init(display: (any PresentationSink)? = nil) { self.display = display }

  func install(_ frame: PresentationFrame) -> Bool {
    frames.withLock { $0.append(frame) }
    display?.install(frame)
    return true
  }

  var all: [PresentationFrame] { frames.withLock { $0 } }
  var last: PresentationFrame? { frames.withLock { $0.last } }
  var lines: [String] {
    guard let last else { return [] }
    return (0 ..< last.rows).map { last.line($0) }
  }
}

// MARK: Driving a client through the link

/// A registry, an impaired link and a real `RoamingClient`.
struct ImpairedRoamingRig: RoamingTestRig {
  let registry: SessionRegistry
  let link: ImpairedLink
  let connector: ImpairedConnector
  let oracle = HostScreenOracle()
  let installs: InstallLog
  let client: RoamingClient

  init(
    registry: SessionRegistry,
    seed: UInt64,
    profile: ImpairmentProfile,
    grid: GridSize,
    display: (any PresentationSink)? = nil
  ) {
    self.registry = registry
    link = ImpairedLink(seed: seed, profile: profile)
    connector = ImpairedConnector(registry: registry, link: link)
    installs = InstallLog(display: display)
    client = RoamingClient(
      bootstrapper: ObservingBootstrapper(
        service: BootstrapService(registry: registry),
        registry: registry,
        oracle: oracle
      ),
      connector: connector,
      sink: installs,
      configuration: RoamingClientConfiguration(
        initialGrid: grid,
        backoffJitter: 0
      )
    )
  }

  var label: String { "seed \(link.seed)" }

  func loseConnection(at point: ImpairedLink.KillPoint) { link.killAt(point) }
}

/// A real `RoamingClient` attached to a registry through some transport
/// (the impaired in-process link, or shaped QUIC), with the host's screen
/// oracle and a log of every installed screen.
protocol RoamingTestRig {
  var registry: SessionRegistry { get }
  var oracle: HostScreenOracle { get }
  var installs: InstallLog { get }
  var client: RoamingClient { get }
  /// Identifies the run in failure messages.
  var label: String { get }
  /// Loses the connection at `point`: exactly there on the impaired link;
  /// as soon as possible on a transport that cannot place it.
  func loseConnection(at point: ImpairedLink.KillPoint)
}

extension RoamingTestRig {
  func start(_ grid: GridSize) async throws {
    try await client.start(.create(grid))
    try await active()
  }

  func active(timeout: Duration = .seconds(20)) async throws {
    try await hostEventuallyAsync("client active", timeout: timeout) {
      await client.state == .active ? true : nil
    }
  }

  /// Submits once the client is active; returns the input's sequence.
  @discardableResult
  func submit(_ input: SurfaceInput) async throws -> UInt64 {
    try await hostEventuallyAsync("input accepted", timeout: .seconds(30)) {
      switch await client.submit(input) {
      case let .accepted(sequence): return sequence ?? 0
      case .refused(.notActive), .refused(.backpressure): return nil
      case let .refused(reason):
        Issue.record("input refused: \(reason)")
        throw CancellationError()
      }
    }
  }

  func run(_ command: String) async throws {
    try await submit(.text(command))
    try await submit(.key(SemanticKey(.enter)))
  }

  /// Waits until the newest installed screen satisfies `predicate`.
  @discardableResult
  func screen(
    _ what: String,
    timeout: Duration = .seconds(30),
    where predicate: @escaping ([String]) -> Bool
  ) async throws -> [String] {
    try await hostEventually(what, timeout: timeout) {
      let lines = installs.lines
      return predicate(lines) ? lines : nil
    }
  }

  func shows(_ text: String, timeout: Duration = .seconds(30)) async throws {
    try await screen(text, timeout: timeout) { lines in
      lines.contains { $0.contains(text) }
    }
  }

  /// Fails the test unless every installed screen equals the host's
  /// complete screen at a strictly increasing revision.
  func expectInstallsMatchHost(
    sourceLocation: SourceLocation = #_sourceLocation
  ) -> [UInt64] {
    let installed = installs.all
    #expect(!installed.isEmpty, sourceLocation: sourceLocation)
    #expect(oracle.unmappedCount == 0, sourceLocation: sourceLocation)
    switch oracle.assign(installed) {
    case let .success(revisions): return revisions
    case let .failure(failure):
      Issue.record("\(label): \(failure)", sourceLocation: sourceLocation)
      return []
    }
  }

  /// The host grid's text between two absolute points of the active pane.
  func hostText(
    from start: TerminalPoint,
    to end: TerminalPoint
  ) async throws -> String {
    let id = try #require(await client.status.sessionID)
    let session = try #require(registry.session(id))
    let pane = try #require(session.diagnostics.activePane)
    let service = registry.service
    let text: String? = await withCheckedContinuation { continuation in
      service.inspect(
        pane: pane,
        { $0.text(from: start, to: end) },
        completion: { continuation.resume(returning: $0) }
      )
    }
    return try #require(text)
  }
}
#endif
