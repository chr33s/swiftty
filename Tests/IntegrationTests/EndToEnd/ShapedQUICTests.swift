#if os(macOS)
import AppleTransport
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
      #expect(echo < copied, "the echo waited for the whole copy")
      print(
        "shaped QUIC A22: echo during a \(expected.utf8.count)-byte copy "
          + "after \(echo); copy finished after \(copied)"
      )
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
    try await listener.start { connection in
      connections.list.withLock { $0.append(connection) }
      registry.accept(connection)
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
    connector: RecordingConnector,
    oracle: HostScreenOracle,
    installs: InstallLog,
    client: RoamingClient
  ) {
    self.registry = registry
    self.listener = listener
    self.serverConnections = serverConnections
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
  }

  private struct State {
    var connections = 0
    var lastConnect: ContinuousClock.Instant?
    var received: [Received] = []
    var control: [ControlMessage] = []
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
  var controlMessages: [ControlMessage] { state.withLock { $0.control } }

  func connect(to grant: BootstrapGrant) async throws -> any RSTConnection {
    state.withLock {
      $0.connections += 1
      $0.lastConnect = .now
    }
    return RecordingConnection(try await inner.connect(to: grant), owner: self)
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
    state.withLock { $0.control.append(contentsOf: messages) }
  }
}

private final class RecordingConnection: RSTConnection, Sendable {
  let inner: any RSTConnection
  let owner: RecordingConnector

  init(_ inner: any RSTConnection, owner: RecordingConnector) {
    self.inner = inner
    self.owner = owner
  }

  var isClosed: Bool { inner.isClosed }

  func start(_ handler: RSTConnectionHandler) {
    let owner = owner
    let reader = Mutex(ControlRecordReader())
    inner.start(
      RSTConnectionHandler(
        onControl: { bytes in
          let messages = reader.withLock { (try? $0.append(bytes)) ?? [] }
          owner.record(control: messages)
          await handler.onControl(bytes)
        },
        onSnapshot: { payload in
          owner.record(snapshot: payload)
          await handler.onSnapshot(payload)
        },
        onClosed: handler.onClosed
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
#endif
