#if os(macOS)
@testable import AppleTransport
import Darwin
import Foundation
@testable import RoamingKit
import RoamingConnect
import ScreenProtocol
import SessionCore
import Synchronization
import SwiftMuxProtocol
import SwifttyCore
import SwifttyEngine
@testable import TerminalHost
import TestSupport
import Testing

/// A20, A22, the `screenDeltas` cost report and the recovery target
/// (spec.roaming.md §13) over real loopback QUIC, with packet-level loss,
/// delay and reordering from dummynet at the recovery-target profile:
/// 200 ms RTT, 5% independent loss, about 2% reordering, 1 Mbit/s.
///
/// Shaping needs root, so the suite runs only on request:
/// `sudo Scripts/quic-shaper.sh up`, then `Scripts/test-shaped-quic.sh`
/// (which sets `SWIFTTY_SHAPED_QUIC=1` and the shaped port). The first test
/// measures the port's one-way delay and fails if it is not shaped.
@Suite(
  .serialized,
  .timeLimit(.minutes(30)),
  .enabled(
    if: ProcessInfo.processInfo.environment["SWIFTTY_SHAPED_QUIC"] == "1"
  )
)
struct ShapedQUICTests {
  static let port: UInt16 = {
    let value = ProcessInfo.processInfo.environment["SWIFTTY_SHAPED_QUIC_PORT"]
    return value.flatMap(UInt16.init) ?? 47431
  }()

  // MARK: Profile check

  /// Median one-way delay of datagrams sent to the shaped port, and how
  /// many of `count` arrived.
  static func probeOneWayDelay(
    count: Int = 40
  ) throws -> (median: Duration, received: Int) {
    let receiver = socket(AF_INET, SOCK_DGRAM, 0)
    let sender = socket(AF_INET, SOCK_DGRAM, 0)
    defer {
      close(receiver)
      close(sender)
    }
    try #require(receiver >= 0 && sender >= 0)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(receiver, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    try #require(bound == 0, "port \(port) is in use (errno \(errno))")
    var timeout = timeval(tv_sec: 0, tv_usec: 20_000)
    setsockopt(
      receiver,
      SOL_SOCKET,
      SO_RCVTIMEO,
      &timeout,
      socklen_t(MemoryLayout<timeval>.size)
    )
    let clock = ContinuousClock()
    let origin = clock.now
    var sent: [Duration] = []
    var delays: [Duration] = []
    var buffer = [UInt8](repeating: 0, count: 64)
    func drain() {
      while true {
        let n = recv(receiver, &buffer, buffer.count, 0)
        guard n >= 2 else { return }
        let index = Int(buffer[0]) << 8 | Int(buffer[1])
        if index < sent.count {
          delays.append(clock.now - origin - sent[index])
        }
      }
    }
    for index in 0 ..< count {
      var payload: [UInt8] = [UInt8(index >> 8), UInt8(index & 0xFF)]
      sent.append(clock.now - origin)
      _ = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          sendto(
            sender,
            &payload,
            payload.count,
            0,
            $0,
            socklen_t(MemoryLayout<sockaddr_in>.size)
          )
        }
      }
      drain()
    }
    let deadline = clock.now + .milliseconds(500)
    while clock.now < deadline { drain() }
    delays.sort()
    return (delays.isEmpty ? .zero : delays[delays.count / 2], delays.count)
  }

  @Test
  func `the port is shaped to the recovery-target profile`() throws {
    let (median, received) = try Self.probeOneWayDelay()
    print("shaped QUIC probe: median one-way \(median), \(received)/40 arrived")
    // 100 ms each way; a loopback port without shaping answers in microseconds.
    #expect(
      median >= .milliseconds(90) && median <= .milliseconds(250),
      "port \(Self.port) is not shaped: run `sudo Scripts/quic-shaper.sh up`"
    )
    #expect(received < 40 && received >= 30, "expected about 5% loss")
  }

  // MARK: A20

  @Test
  func `A20: every installed screen is the host's screen at that revision`()
    async throws
  {
    try await ShapedQUICRig.with(grid: GridSize(columns: 60, rows: 12)) { rig in
      try await ImpairedScreenDeltaTests.workload(rig)
      let stats = await rig.client.deltaStatistics
      #expect(stats.applied > 0)
      // Both connection losses were followed by a reattachment.
      #expect(rig.connector.connections >= 3)
      let revisions = rig.expectInstallsMatchHost()
      #expect(
        revisions == revisions.sorted()
          && Set(revisions).count == revisions.count
      )
      print(
        "shaped QUIC A20: \(rig.installs.all.count) screens, "
          + "\(stats.applied) deltas applied, \(stats.requestedFull) full "
          + "requests, \(rig.connector.connections) connections"
      )
    }
  }

  @Test
  func `A20: a client without screenDeltas exchanges full screens only`()
    async throws
  {
    try await ShapedQUICRig.with(
      grid: GridSize(columns: 80, rows: 24),
      stripFromAttach: [.screenDeltas]
    ) { rig in
      try await rig.run("seq 1 200; echo plain-$((2+2))")
      try await rig.shows("plain-4")
      #expect(await rig.client.deltaStatistics.applied == 0)
      #expect(rig.connector.received.allSatisfy { !$0.delta })
      _ = rig.expectInstallsMatchHost()
    }
  }

  // MARK: A22

  @Test
  func `A22: a history copy during output equals the host's grid text`()
    async throws
  {
    let grid = ImpairedCopySelectionTests.grid
    try await ShapedQUICRig.with(grid: grid) { rig in
      try await rig.run("seq -f 'row %06g' 1 6000; echo mark-$((1+2))")
      let (marked, markRow) = try await ImpairedCopySelectionTests.frame(
        rig,
        showing: "mark-3"
      )
      let h = marked.history
      let selection = ImpairedCopySelectionTests.request(
        marked,
        rows: h.firstRow ... markRow
      )
      try await rig.run(
        "(i=0; while [ $i -lt 100 ]; do i=$((i+1)); echo tick-$i; "
          + "sleep 0.02; done; echo tock-$((2+5))) &"
      )
      try await rig.shows("tick-")
      let started = ContinuousClock.now
      let text = try await rig.client.copySelection(selection)
      let elapsed = ContinuousClock.now - started
      let host = try await rig.hostText(
        from: TerminalPoint(row: h.firstRow, column: 0),
        to: TerminalPoint(row: markRow, column: 79)
      )
      #expect(text == host)
      let seq = (1 ... 6000).map { "row " + String(format: "%06d", $0) }
        .joined(separator: "\n")
      #expect(text.hasSuffix(seq + "\nmark-3"))
      #expect(text.utf8.count > ControlMessage.maxCopyChunkBytes)
      print("shaped QUIC A22: copied \(text.utf8.count) bytes in \(elapsed)")
      try await rig.shows("tock-7", timeout: .seconds(60))

      // An edit under the selection yields no text.
      try await rig.run("echo calm-$((3+3))")
      let (calm, prompt) = try await ImpairedCopySelectionTests.frame(
        rig,
        showing: "$"
      ) { lines in
        lines.contains("calm-6") && lines.last(where: { !$0.isEmpty }) == "$"
      }
      let edited = ImpairedCopySelectionTests.request(
        calm,
        rows: prompt - 1 ... prompt
      )
      try await rig.submit(.text("echo edited-x"))
      try await rig.shows("$ echo edited-x")
      try await ImpairedCopySelectionTests.expectFailure(
        .selectionChanged,
        rig,
        edited
      )
      try await rig.submit(.key(SemanticKey(.enter)))
    }
  }

  @Test
  func `A22: typing during a large copy waits behind at most one chunk`()
    async throws
  {
    let grid = ImpairedCopySelectionTests.grid
    try await ShapedQUICRig.with(grid: grid) { rig in
      let row = String(repeating: "─", count: 79)
      try await rig.run(
        "awk 'BEGIN{s=\"\";for(i=0;i<79;i++)s=s\"─\";"
          + "for(n=0;n<8700;n++)print s}'; echo big-$((4+5))"
      )
      let (big, bigRow) = try await ImpairedCopySelectionTests.frame(
        rig,
        showing: "big-9"
      )
      let rows = bigRow - 8700 ... bigRow - 1
      let expected = Array(repeating: row, count: 8700).joined(separator: "\n")
      let client = rig.client
      let copy = Task {
        let text = try await client.copySelection(
          ImpairedCopySelectionTests.request(big, rows: rows)
        )
        return (text, ContinuousClock.now)
      }
      // Once chunks flow, time one key's echo against the copy.
      try await hostEventually("copy under way", timeout: .seconds(30)) {
        rig.connector.controlMessages.contains {
          if case .copyChunk(_, _, 1, _) = $0 { true } else { false }
        } ? true : nil
      }
      let typed = ContinuousClock.now
      try await rig.submit(.text("t"))
      try await rig.shows("$ t", timeout: .seconds(30))
      let echo = ContinuousClock.now - typed
      let (text, finished) = try await copy.value
      let copied = finished - typed
      #expect(text == expected)
      #expect(expected.utf8.count > 2_000_000)
      // spec.roaming.md A22: typing waits behind at most one chunk. At
      // 1 Mbit/s a 48 KiB chunk takes about 0.4 s; allow two chunks plus a
      // second for the round trip, the echoed screen and loss recovery.
      let chunk = Double(ControlMessage.maxCopyChunkBytes * 8) / 1_000_000
      let bound = Duration.seconds(2 * chunk + 1)
      #expect(
        echo <= bound,
        "the echo took \(echo) (bound \(bound)); the copy took \(copied)"
      )
      print(
        "shaped QUIC A22: echo during a \(expected.utf8.count)-byte copy "
          + "after \(echo); copy finished after \(copied)"
      )
      // Where the time went: when the host's transport accepted each
      // record, against when the client read it.
      func isChunk(_ m: ControlMessage) -> Bool {
        if case .copyChunk = m { true } else { false }
      }
      func isInputAck(_ m: ControlMessage) -> Bool {
        if case .inputAck = m { true } else { false }
      }
      let sent = rig.hostSends.all
      let read = rig.connector.controlTimes
      func at(_ t: ContinuousClock.Instant?) -> String {
        t.map { "\($0 - typed)" } ?? "none"
      }
      print(
        "shaped QUIC A22 timeline (from the key): host accepted chunks "
          + "\(at(sent.first { isChunk($0.1) }?.0)) to "
          + "\(at(sent.last { isChunk($0.1) }?.0)), client read chunks "
          + "\(at(read.first { isChunk($0.1) }?.0)) to "
          + "\(at(read.last { isChunk($0.1) }?.0)); input ack accepted "
          + "\(at(sent.last { isInputAck($0.1) }?.0)), read "
          + "\(at(read.last { isInputAck($0.1) }?.0))"
      )
      // The key's acknowledgement, too, waits behind at most one chunk.
      let inputAck = read.last { isInputAck($0.1) }.map { $0.0 - typed }
      #expect(
        inputAck.map { $0 <= bound } == true,
        "the input acknowledgement was read after \(String(describing: inputAck))"
      )
      let window = typed - .seconds(1)
      for (started, ended, bytes) in rig.hostSends.snapshots.withLock({ $0 })
      where started > window {
        print(
          "shaped QUIC A22 timeline: host snapshot \(bytes) B started "
            + "\(at(started)), returned \(at(ended))"
        )
      }
      for r in rig.connector.received where r.at > window {
        print(
          "shaped QUIC A22 timeline: client read snapshot "
            + "\(r.payload.count) B at \(at(r.at))"
        )
      }
      for (t, frame) in zip(rig.installs.times, rig.installs.all)
      where t > window {
        let shows = (0 ..< frame.rows)
          .contains { frame.line($0).hasPrefix("$ t") }
        print("shaped QUIC A22 timeline: installed at \(at(t)) echo=\(shows)")
      }
      try await rig.submit(.key(SemanticKey(.backspace)))
    }
  }

  // MARK: screenDeltas cost

  @Test(arguments: ScreenDeltaCostReport.Workload.allCases)
  func `screenDeltas cost report`(
    workload: ScreenDeltaCostReport.Workload
  ) async throws {
    var rows: [ScreenDeltaCostReport.Row] = []
    for deltas in [false, true] {
      try await ShapedQUICRig.with(
        grid: workload.grid,
        stripFromAttach: deltas ? [] : [.screenDeltas]
      ) { rig in
        try await workload.run(rig)
        let received = rig.connector.received
        rows.append(
          ScreenDeltaCostReport.Row(
            workload: workload,
            deltas: deltas,
            screens: received.count,
            deltaScreens: received.filter(\.delta).count,
            bytes: received.reduce(0) { $0 + $1.payload.count },
            cpuMicroseconds: ScreenDeltaCostReport.clientCPU(
              received.map(\.payload)
            )
          )
        )
      }
    }
    for row in rows { print("shaped QUIC screenDeltas report: \(row)") }
    #expect(rows.allSatisfy { $0.screens > 0 })
    #expect(rows.last?.deltaScreens ?? 0 > 0)
  }

  // MARK: Recovery target

  /// Warm reattachment plus an 80×24 current screen, 100 times. The
  /// target (p95 within 3 s) is reported, not asserted: §13 calls it a
  /// target, not a measured claim. Every recovery must succeed.
  @Test
  func `recovery target: warm reattachment and a current screen`() async throws
  {
    try await ShapedQUICRig.with(grid: GridSize(columns: 80, rows: 24)) { rig in
      try await rig.run("echo ready-$((1+1))")
      try await rig.shows("ready-2")
      var fromConnect: [Duration] = []
      var fromLoss: [Duration] = []
      /// Per recovery: connection attempts, and the client's last failure.
      var runs: [(total: Duration, attempts: Int, failure: String)] = []
      for attempt in 1 ... 100 {
        let connections = rig.connector.connections
        let installed = rig.installs.all.count
        let lost = ContinuousClock.now
        rig.loseConnection(at: .screenAck(afterForward: true))
        let connected = try await hostEventually(
          "reconnect \(attempt)",
          timeout: .seconds(60)
        ) {
          rig.connector.connections > connections
            ? rig.connector.lastConnect : nil
        }
        try await hostEventuallyAsync(
          "recovery \(attempt)",
          timeout: .seconds(60)
        ) {
          await rig.client.state == .active
            && rig.installs.all.count > installed ? true : nil
        }
        let now = ContinuousClock.now
        fromConnect.append(now - connected)
        fromLoss.append(now - lost)
        if now - connected > .seconds(3) {
          let attempts = rig.connector.attempts[connections...]
          print(
            "shaped QUIC recovery \(attempt) took \(now - connected) from "
              + "the reconnect (times from the loss):"
          )
          for (n, a) in attempts.enumerated() {
            print("  attempt \(n + 1): \(a.describe(from: lost))")
            print("  attempt \(n + 1) client QUIC: \(a.quic.prefix(4000))")
          }
          for server in rig.serverConnections.list.withLock({ $0 })
            .suffix(attempts.count)
          {
            let quic =
              (server as? QUICRSTConnection)?.snapshotDiagnosticsForTesting
              ?? "n/a"
            print("  server QUIC: \(quic.prefix(4000))")
          }
        }
        let status = await rig.client.status
        runs.append(
          (
            now - connected, rig.connector.connections - connections,
            [status.lastFailure.map { "\($0)" }, status.lastFailureDetail]
              .compactMap { $0 }.joined(separator: ": ")
          )
        )
      }
      func p(_ samples: [Duration], _ q: Double) -> Duration {
        let sorted = samples.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))]
      }
      print(
        "shaped QUIC recovery (\(fromConnect.count) runs), reconnect to "
          + "current screen: p50 \(p(fromConnect, 0.5)), p95 "
          + "\(p(fromConnect, 0.95)), max \(fromConnect.max()!); from loss: "
          + "p50 \(p(fromLoss, 0.5)), p95 \(p(fromLoss, 0.95))"
      )
      if p(fromConnect, 0.95) > .seconds(3) {
        print("shaped QUIC recovery: p95 misses the 3 s target")
      }
      let attempts = Dictionary(grouping: runs, by: \.attempts)
        .mapValues(\.count).sorted { $0.key < $1.key }
      print(
        "shaped QUIC recovery: connection attempts per recovery \(attempts)"
      )
      for run in runs.sorted(by: { $0.total > $1.total }).prefix(8) {
        print(
          "shaped QUIC recovery slow run: \(run.total), \(run.attempts) "
            + "attempts, last failure \(run.failure.isEmpty ? "none" : run.failure)"
        )
      }
      // The same shell survived every reattachment and still answers.
      try await rig.run("echo after-$((50+50))")
      try await rig.shows("after-100", timeout: .seconds(30))
    }
  }
}

// MARK: Rig

/// A registry served by a real QUIC listener on the shaped port, and a
/// real `RoamingClient` that reaches it through `QUICGrantConnector`.
struct ShapedQUICRig: RoamingTestRig {
  let registry: SessionRegistry
  let listener: QUICRSTListener
  let serverConnections: ConnectionLog
  /// When each host control record's `sendControl` returned.
  let hostSends: HostSendLog
  let connector: RecordingConnector
  let oracle: HostScreenOracle
  let installs: InstallLog
  let client: RoamingClient

  var label: String { "shaped QUIC" }

  /// Closes every server connection now. QUIC cannot place the loss at an
  /// acknowledgement boundary; the client reattaches on its own.
  func loseConnection(at point: ImpairedLink.KillPoint) {
    for connection in serverConnections.list.withLock({ $0 }) {
      connection.close()
    }
  }

  static func with(
    grid: GridSize,
    stripFromAttach: RSTFeatures = [],
    _ body: (ShapedQUICRig) async throws -> Void
  ) async throws {
    let identity = try AppleTransport.HostIdentity.generate(ipAddresses: [
      "127.0.0.1"
    ])
    let listener = QUICRSTListener(
      identity: identity,
      configuration: .init(host: "127.0.0.1", port: ShapedQUICTests.port)
    )
    let registry = SessionRegistry(
      service: try makeService(),
      identity: TerminalHost.HostIdentity(
        endpoint: BootstrapEndpoint(
          host: "127.0.0.1",
          port: ShapedQUICTests.port
        ),
        certificate: HostCertificate(der: identity.certificateDER)
      ),
      launch: { shellLaunch() }
    )
    let connections = ConnectionLog()
    let hostSends = HostSendLog()
    try await listener.start { connection in
      connections.list.withLock { $0.append(connection) }
      registry.accept(HostSendLog.Connection(connection, log: hostSends))
    }
    let oracle = HostScreenOracle()
    let installs = InstallLog()
    let connector = RecordingConnector(stripFromAttach: stripFromAttach)
    let client = RoamingClient(
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
    let rig = ShapedQUICRig(
      registry: registry,
      listener: listener,
      serverConnections: connections,
      hostSends: hostSends,
      connector: connector,
      oracle: oracle,
      installs: installs,
      client: client
    )
    try await RuntimeFixture.withCleanup(
      {
        try await rig.start(grid)
        try await body(rig)
      },
      cleanup: {
        await client.close(.detach)
        registry.stopSweeping()
        await withCheckedContinuation { continuation in
          registry.service.prepareToExit { continuation.resume() }
        }
        listener.stop()
      }
    )
  }

  private init(
    registry: SessionRegistry,
    listener: QUICRSTListener,
    serverConnections: ConnectionLog,
    hostSends: HostSendLog,
    connector: RecordingConnector,
    oracle: HostScreenOracle,
    installs: InstallLog,
    client: RoamingClient
  ) {
    self.registry = registry
    self.listener = listener
    self.serverConnections = serverConnections
    self.hostSends = hostSends
    self.connector = connector
    self.oracle = oracle
    self.installs = installs
    self.client = client
  }
}

/// `QUICGrantConnector`, recording each snapshot record the client receives
/// and the control messages the host sends, and optionally removing
/// features from `Attach` as a client without them would.
final class RecordingConnector: RSTConnector, Sendable {
  struct Received: Sendable {
    var payload: [UInt8]
    var delta: Bool
    var at = ContinuousClock.now
  }

  /// One `connect` call and what followed on its connection.
  struct Attempt: Sendable {
    var started = ContinuousClock.now
    var handshake: ContinuousClock.Instant?
    var connectError: String?
    var attached: ContinuousClock.Instant?
    var firstSnapshot: ContinuousClock.Instant?
    var closed: ContinuousClock.Instant?
    var closeError: String?
    var connection: (any RSTConnection)?

    /// Diagnostics of the QUIC connection, lifecycle log included.
    var quic: String {
      (connection as? QUICRSTConnection)?.snapshotDiagnosticsForTesting ?? "n/a"
    }

    func describe(from origin: ContinuousClock.Instant) -> String {
      func at(_ t: ContinuousClock.Instant?) -> String {
        t.map { "\($0 - origin)" } ?? "-"
      }
      return "started \(at(started)), handshake \(at(handshake))"
        + (connectError.map { " (connect failed: \($0))" } ?? "")
        + ", attached \(at(attached)), first screen \(at(firstSnapshot)), "
        + "closed \(at(closed))" + (closeError.map { " (\($0))" } ?? "")
    }
  }

  private struct State {
    var connections = 0
    var lastConnect: ContinuousClock.Instant?
    var attempts: [Attempt] = []
    var received: [Received] = []
    var control: [ControlMessage] = []
    var controlTimes: [(ContinuousClock.Instant, ControlMessage)] = []
  }

  private let inner = QUICGrantConnector()
  private let stripFromAttach: RSTFeatures
  private let state = Mutex(State())

  init(stripFromAttach: RSTFeatures) { self.stripFromAttach = stripFromAttach }

  var connections: Int { state.withLock { $0.connections } }
  var lastConnect: ContinuousClock.Instant? {
    state.withLock { $0.lastConnect }
  }
  var received: [Received] { state.withLock { $0.received } }
  var attempts: [Attempt] { state.withLock { $0.attempts } }
  var controlMessages: [ControlMessage] { state.withLock { $0.control } }
  var controlTimes: [(ContinuousClock.Instant, ControlMessage)] {
    state.withLock { $0.controlTimes }
  }

  func connect(to grant: BootstrapGrant) async throws -> any RSTConnection {
    let index = state.withLock {
      $0.connections += 1
      $0.lastConnect = .now
      $0.attempts.append(Attempt())
      return $0.attempts.count - 1
    }
    do {
      let connection = try await inner.connect(to: grant)
      update(index) {
        $0.handshake = .now
        $0.connection = connection
      }
      return RecordingConnection(connection, owner: self, attempt: index)
    } catch {
      update(index) {
        $0.handshake = .now
        $0.connectError = "\(error)"
      }
      throw error
    }
  }

  fileprivate func update(_ index: Int, _ body: (inout Attempt) -> Void) {
    state.withLock { body(&$0.attempts[index]) }
  }

  fileprivate func strip(_ record: [UInt8]) -> [UInt8] {
    guard !stripFromAttach.isEmpty else { return record }
    var reader = ControlRecordReader()
    guard case var .attach(attach)? = (try? reader.append(record))?.first,
      let encoded = try? ControlRecord.encode(
        .attach(
          {
            attach.features.subtract(stripFromAttach)
            return attach
          }()
        )
      )
    else { return record }
    return encoded
  }

  fileprivate func record(snapshot payload: [UInt8]) {
    let delta = ImpairedRSTConnection.describe(payload)?.delta ?? false
    state.withLock {
      $0.received.append(Received(payload: payload, delta: delta))
    }
  }

  fileprivate func record(control messages: [ControlMessage]) {
    let now = ContinuousClock.now
    state.withLock {
      $0.control.append(contentsOf: messages)
      $0.controlTimes.append(contentsOf: messages.map { (now, $0) })
    }
  }
}

private final class RecordingConnection: RSTConnection, Sendable {
  let inner: any RSTConnection
  let owner: RecordingConnector
  let attempt: Int

  init(_ inner: any RSTConnection, owner: RecordingConnector, attempt: Int) {
    self.inner = inner
    self.owner = owner
    self.attempt = attempt
  }

  var isClosed: Bool { inner.isClosed }

  func start(_ handler: RSTConnectionHandler) {
    let owner = owner
    let attempt = attempt
    let reader = Mutex(ControlRecordReader())
    inner.start(
      RSTConnectionHandler(
        onControl: { bytes in
          let messages = reader.withLock { (try? $0.append(bytes)) ?? [] }
          if messages.contains(where: {
            if case .attached = $0 { true } else { false }
          }) {
            owner.update(attempt) { $0.attached = $0.attached ?? .now }
          }
          owner.record(control: messages)
          await handler.onControl(bytes)
        },
        onSnapshot: { payload in
          owner.update(attempt) { $0.firstSnapshot = $0.firstSnapshot ?? .now }
          owner.record(snapshot: payload)
          await handler.onSnapshot(payload)
        },
        onClosed: { error in
          owner.update(attempt) {
            $0.closed = .now
            $0.closeError = error.map { "\($0)" }
          }
          handler.onClosed(error)
        }
      )
    )
  }

  func sendControl(_ record: [UInt8]) async throws {
    try await inner.sendControl(owner.strip(record))
  }

  func sendSnapshot(_ payload: [UInt8], stream id: UInt64) async throws {
    try await inner.sendSnapshot(payload, stream: id)
  }

  func cancelSnapshot(stream id: UInt64) { inner.cancelSnapshot(stream: id) }

  func close() { inner.close() }
}
/// Times at which the host's `sendControl` calls returned (the transport
/// accepted the record), by message.
final class HostSendLog: Sendable {
  private let entries = Mutex<[(ContinuousClock.Instant, ControlMessage)]>([])

  var all: [(ContinuousClock.Instant, ControlMessage)] {
    entries.withLock { $0 }
  }

  fileprivate func record(_ record: [UInt8]) {
    var reader = ControlRecordReader()
    guard let message = (try? reader.append(record))?.first else { return }
    let now = ContinuousClock.now
    entries.withLock { $0.append((now, message)) }
  }

  /// Forwards to the server's QUIC connection, logging control sends.
  final class Connection: RSTConnection, Sendable {
    let inner: any RSTConnection
    let log: HostSendLog

    init(_ inner: any RSTConnection, log: HostSendLog) {
      self.inner = inner
      self.log = log
    }

    var isClosed: Bool { inner.isClosed }
    func start(_ handler: RSTConnectionHandler) { inner.start(handler) }
    func sendControl(_ record: [UInt8]) async throws {
      try await inner.sendControl(record)
      log.record(record)
    }
    func sendSnapshot(_ payload: [UInt8], stream id: UInt64) async throws {
      let started = ContinuousClock.now
      defer {
        let ended = ContinuousClock.now
        log.snapshots.withLock { $0.append((started, ended, payload.count)) }
      }
      try await inner.sendSnapshot(payload, stream: id)
    }
    func cancelSnapshot(stream id: UInt64) { inner.cancelSnapshot(stream: id) }
    func close() { inner.close() }
  }

  /// Each snapshot send: started, returned, bytes.
  let snapshots = Mutex<
    [(ContinuousClock.Instant, ContinuousClock.Instant, Int)]
  >([])
}
#endif
