// swiftmux-bench: spec §10 measurements on the machine it runs on.
//
// Runs the real service in-process behind an anonymous XPC endpoint, with
// real shells on PTYs. Reports parser throughput (detached and attached),
// input-to-frame latency, frame export/import cost, service CPU and memory
// at the pane limit, and GPU time for imported frames.
import Darwin
import Foundation
@preconcurrency import Metal
import SwiftMuxBridge
import SwiftMuxClient
import SwiftMuxProtocol
import SwiftMuxService
import SwifttyCore
import Synchronization

func percentile(_ values: [Double], _ p: Double) -> Double {
  let sorted = values.sorted()
  return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
}

func ms(_ v: Double) -> String { String(format: "%.3f ms", v) }

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

/// Physical footprint of this process (service plus bench client).
func footprint() -> Double {
  var info = task_vm_info_data_t()
  var count = mach_msg_type_number_t(
    MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
  )
  let kr = withUnsafeMutablePointer(to: &info) {
    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
      task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
    }
  }
  return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
}

func cpuSeconds() -> Double {
  var usage = rusage()
  getrusage(RUSAGE_SELF, &usage)
  return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
    + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
}

let exe = URL(fileURLWithPath: CommandLine.arguments[0])
  .resolvingSymlinksInPath()
let launcher = exe.deletingLastPathComponent().appending(path: "swmux-launcher")
  .path
var config = MuxServiceConfiguration(launcherPath: launcher)
let service = try MuxService(configuration: config)
let endpoint = service.listenAnonymously()
let env = [
  "PATH": "/usr/bin:/bin", "PS1": "$ ", "HOME": NSTemporaryDirectory(),
  "LANG": "en_US.UTF-8",
]

func spec(_ script: String) -> LaunchSpec {
  LaunchSpec(
    command: ["/bin/sh", "-c", script],
    workingDirectory: "/tmp",
    environment: env
  )
}

func connect(_ kind: FrontendKind = .native) async throws -> MuxConnection {
  try await MuxConnection.connect(endpoint: endpoint, frontend: kind)
}

func create(
  _ c: MuxConnection,
  _ launch: LaunchSpec,
  columns: Int = 200,
  rows: Int = 50
) async throws -> WorkspaceSnapshot {
  guard
    case let .created(ws) = try await c.execute(
      .newWorkspace(
        NewWorkspaceRequest(columns: columns, rows: rows, launch: launch)
      )
    )
  else { throw MuxError(.invalidRequest, "benchmark create reply") }
  return ws
}

func show(
  _ c: MuxConnection,
  _ ws: WorkspaceSnapshot,
  panes: [PaneID],
  columns: Int = 200,
  rows: Int = 50
) async throws {
  guard
    case let .attached(_, snap) = try await c.execute(
      .attach(AttachRequest(.id(ws.id)))
    )
  else { throw MuxError(.invalidRequest, "unexpected benchmark reply") }
  try await c.execute(
    .setGeometry(
      GeometryBatch(
        layoutRevision: snap.layoutRevision,
        generation: 1,
        entries: panes.map { .init(pane: $0, columns: columns, rows: rows) }
      )
    )
  )
  try await c.execute(.setSubscriptions(panes))
}

// MARK: Corpus

let corpusURL = URL(fileURLWithPath: NSTemporaryDirectory())
  .appending(path: "swiftmux-bench-\(UUID().uuidString).txt")
let corpusShellPath =
  "'" + corpusURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
let corpusResult: Result<Int, any Error> = Result {
  var line = ""
  for i in 0 ..< 400 {
    line += i % 7 == 0 ? "\u{1B}[3\(i % 8)m" : ""
    line += i % 11 == 0 ? "界面 " : "word\(i % 97) "
    line += i % 13 == 0 ? "\u{1B}[0m" : ""
  }
  var block = ""
  for _ in 0 ..< 64 { block += line + "\r\n" }
  let data = Data(block.utf8)
  var out = Data()
  while out.count < 32 << 20 { out.append(data) }
  try out.write(to: corpusURL)
  return out.count
}
let corpusBytes = (try? corpusResult.get()) ?? 0

// MARK: Throughput

func throughput(attached: Bool) async throws -> (mbps: Double, frames: Int) {
  let c = try await connect()
  let start = now()
  let ws = try await create(c, spec("cat \(corpusShellPath)"))
  let pane = ws.tabs[0].activePane
  var frames = 0
  let deadline = ContinuousClock.now + .seconds(30)
  if attached {
    try await show(c, ws, panes: [pane])
    loop: while true {
      let event = try await benchmarkEvent(c, until: deadline)
      switch event {
      case .frame: frames += 1
      case .paneExited: break loop
      default: break
      }
    }
  } else {
    while true {
      guard ContinuousClock.now < deadline else {
        throw MuxConnection.EventWaitError.timedOut
      }
      guard
        case let .status(s) = try await c.execute(
          .status,
          timeout: deadline - ContinuousClock.now
        )
      else { throw MuxError(.invalidRequest, "benchmark status reply") }
      if s.panes == 0 { break }
      try await Task.sleep(for: .milliseconds(2))
    }
  }
  let elapsed = now() - start
  await c.close()
  return (Double(corpusBytes) / 1_048_576 / elapsed, frames)
}

// MARK: Latency

func latency(samples: Int) async throws -> [Double] {
  let c = try await connect()
  // Echo through the line discipline: the shell is not involved.
  let ws = try await create(
    c,
    spec("stty -icanon; exec cat > /dev/null"),
    columns: 120,
    rows: 40
  )
  let pane = ws.tabs[0].activePane
  try await show(c, ws, panes: [pane], columns: 120, rows: 40)
  var lastX = -1
  var lastY = -1
  // The first complete frame is the baseline.
  let ready = ContinuousClock.now + .seconds(30)
  while true {
    if case let .frame(f) = try await benchmarkEvent(c, until: ready) {
      lastX = f.cursor.x
      lastY = f.cursor.y
      break
    }
  }
  try await Task.sleep(for: .milliseconds(200))
  var times: [Double] = []
  for i in 0 ..< samples {
    let t0 = now()
    try await c.send(.text(i % 100 == 99 ? "\r" : "x"), to: pane)
    let deadline = ContinuousClock.now + .seconds(5)
    while true {
      guard case let .frame(f) = try await benchmarkEvent(c, until: deadline)
      else { continue }
      if f.cursor.x != lastX || f.cursor.y != lastY {
        lastX = f.cursor.x
        lastY = f.cursor.y
        break
      }
    }
    times.append((now() - t0) * 1000)
    // Stay below the 60 Hz export cap so each sample measures a fresh frame.
    try await Task.sleep(for: .milliseconds(20))
  }
  _ = try? await c.execute(.endWorkspace(.id(ws.id)))
  await c.close()
  return times
}

// MARK: Export/import and GPU

func filledState(columns: Int, rows: Int) -> TerminalSession {
  let session = TerminalSession(columns: columns, rows: rows)
  var text = ""
  for y in 0 ..< rows {
    text +=
      "\u{1B}[\(y + 1);1H\u{1B}[38;5;\(y % 256)m\u{1B}[48;2;10;\(y % 255);40m"
    var line = ""
    while line.unicodeScalars.count < columns - 4 {
      line += y % 5 == 0 ? "界👍🏽 " : "abc\(y) "
    }
    text += line
  }
  session.feed(Array(text.utf8))
  return session
}

/// p95 of each frame stage at one size (export, version stamping,
/// encode, decode with validation, renderer import).
func frameStages(columns: Int, rows: Int) throws -> [(String, Double)] {
  let session = filledState(columns: columns, rows: rows)
  let identity = FrameIdentity(
    server: ServerInstanceID(),
    attachment: AttachmentID(),
    pane: PaneID(),
    revision: 1,
    layoutRevision: 1,
    geometryGeneration: 1,
    viewportRevision: 0
  )
  var times: [String: [Double]] = [:]
  func timed<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
    let t0 = now()
    let value = try body()
    times[name, default: []].append((now() - t0) * 1000)
    return value
  }
  var tracker = RowVersionTracker()
  for _ in 0 ..< 50 {
    let owned = timed("capture") {
      session.withState { $0.captureOwnedScreen() }
    }
    var frame = try timed("export") {
      try FrameExporter.frame(from: owned, identity: identity)
    }
    frame.rowVersions = timed("stamp") { tracker.stamp(owned) }
    let data = timed("encode") { SMXB.encode(frame) }
    let record = try timed("decode+validate") { try SMXB.decode(data) }
    guard case let .frame(decoded) = record.payload else { continue }
    _ = try timed("import") {
      try FrameImporter.snapshot(from: decoded, sequence: 1)
    }
    // The app's path: `MuxConnection` delivers frames already validated.
    _ = timed("import (validated)") {
      FrameImporter.snapshot(fromValidated: decoded, sequence: 1)
    }
  }
  return [
    "capture", "export", "stamp", "encode", "decode+validate", "import",
    "import (validated)",
  ]
  .map { ($0, percentile(times[$0] ?? [], 0.95)) }
}

/// `copySelection` text extraction over a pane's whole history at the
/// service's history budgets (10,000 rows, 16 MiB), with every screen
/// row's version checked: p50, p95, rows and bytes copied.
func copyLatency(
  columns: Int,
  rows: Int
) throws -> (p50: Double, p95: Double, rows: Int, bytes: Int) {
  let limits = MuxLimits.standard
  var state = TerminalState(
    columns: columns,
    rows: rows,
    scrollbackLimitBytes: limits.historyBytesPerPane,
    scrollbackLimitRows: limits.historyRowsPerPane
  )
  var parser = Parser()
  let line = String(repeating: "x", count: max(1, columns - 12))
  var text = ""
  for n in 0 ..< limits.historyRowsPerPane + rows + 10 {
    text += "\(n) \(line)\r\n"
  }
  let bytes = Array(text.utf8)
  bytes.withUnsafeBufferPointer {
    parser.consume(Span(_unsafeElements: $0), into: &state)
  }
  let tracker = RowVersionBox()
  let versions = tracker.stamp(state.captureOwnedScreen())
  let generation = state.addressingGeneration
  let top = state.firstAbsoluteRow
  let screenTop = state.absoluteRow(viewportRow: 0)
  func address(_ row: Int) -> HistoryAddress {
    HistoryAddress(generation: generation, alternateScreen: false, row: row)
  }
  let request = CopySelectionRequest(
    pane: PaneID(),
    start: SelectionPoint(address: address(top), column: 0),
    end: SelectionPoint(
      address: address(screenTop + rows - 1),
      column: columns - 1
    ),
    unit: .character,
    screenRowVersions: (0 ..< rows)
      .map {
        RowIdentity(address: address(screenTop + $0), version: versions[$0])
      }
  )
  var times: [Double] = []
  var copied = 0
  for _ in 0 ..< 20 {
    let t0 = now()
    let result = SelectionCopy.text(request, in: state) {
      tracker.matches($0, in: state)
    }
    times.append((now() - t0) * 1000)
    guard case let .success(text) = result else {
      throw MuxError(.invalidRequest, "copy refused")
    }
    copied = text.utf8.count
  }
  return (
    percentile(times, 0.5), percentile(times, 0.95),
    state.scrollbackCount + rows, copied
  )
}

/// Encoded `SMXB/1` delta sizes for typical updates of a 200x50 pane.
func deltaSizes() throws -> [(String, Int)] {
  let session = TerminalSession(columns: 200, rows: 50)
  for n in 1 ... 40 {
    session.feed(Array("line \(n) of earlier output\r\n".utf8))
  }
  session.feed(Array("$ ".utf8))
  var tracker = RowVersionTracker()
  var revision: UInt64 = 0
  func frame() throws -> PaneFrame {
    revision += 1
    let owned = session.withState { $0.captureOwnedScreen() }
    var f = try FrameExporter.frame(
      from: owned,
      identity: FrameIdentity(
        server: ServerInstanceID(),
        attachment: AttachmentID(),
        pane: PaneID(),
        revision: revision,
        layoutRevision: 1,
        geometryGeneration: 1,
        viewportRevision: 0
      )
    )
    f.rowVersions = tracker.stamp(owned)
    return f
  }
  var results: [(String, Int)] = []
  func measure(_ name: String, _ text: String) throws {
    let base = try frame()
    session.feed(Array(text.utf8))
    let next = try frame()
    let size =
      FrameBaseline(base)
      .flatMap { FrameDeltaBuilder.delta(from: next, base: $0) }
      .map { SMXB.encode($0).count } ?? SMXB.encode(next).count
    results.append((name, size))
  }
  try measure("typing echo", "e")
  try measure("one-line scroll", "\r\nnext line of output")
  try measure("CR progress bar", "\r[##########          ]")
  results.append(("full frame", SMXB.encode(try frame()).count))
  return results
}

func exportImport(
  columns: Int,
  rows: Int,
  binary: Bool = false
) throws -> (export: [Double], importing: [Double], bytes: Int, gpu: [Double]) {
  let session = filledState(columns: columns, rows: rows)
  var exportTimes: [Double] = []
  var importTimes: [Double] = []
  var bytes = 0
  var frame: PaneFrame?
  let identity = FrameIdentity(
    server: ServerInstanceID(),
    attachment: AttachmentID(),
    pane: PaneID(),
    revision: 1,
    layoutRevision: 1,
    geometryGeneration: 1,
    viewportRevision: 0
  )
  var tracker = RowVersionTracker()
  for _ in 0 ..< 50 {
    let t0 = now()
    let data = try session.withState { state in
      let owned = state.captureOwnedScreen()
      var f = try FrameExporter.frame(from: owned, identity: identity)
      // The service stamps row versions on every exported frame.
      f.rowVersions = tracker.stamp(owned)
      if binary { return SMXB.encode(f) }
      return try SMXCodec.encode(
        ServerMessage.event(.frame(f)),
        limit: 32 << 20
      )
    }
    exportTimes.append((now() - t0) * 1000)
    bytes = data.count
    let t1 = now()
    let decoded: PaneFrame
    if binary {
      guard case let .frame(f) = try SMXB.decode(data).payload else {
        throw MuxError(.invalidRequest, "unexpected benchmark record")
      }
      decoded = f
    } else {
      guard
        case let .event(.frame(f)) = try SMXCodec.decode(
          ServerMessage.self,
          from: data,
          limit: 32 << 20
        )
      else { throw MuxError(.invalidRequest, "unexpected benchmark reply") }
      decoded = f
    }
    _ = try FrameImporter.snapshot(from: decoded, sequence: 1)
    importTimes.append((now() - t1) * 1000)
    frame = decoded
  }
  var gpu: [Double] = []
  if let device = MTLCreateSystemDefaultDevice(), let frame {
    let renderer = try MetalRenderer(
      device: device,
      fontManager: CoreTextFontManager(),
      font: FontDescriptor()
    )
    let d = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm,
      width: Int(renderer.cellSize.width) * columns + 16,
      height: Int(renderer.cellSize.height) * rows + 16,
      mipmapped: false
    )
    d.usage = [.renderTarget, .shaderRead]
    d.storageMode = .private
    guard let texture = device.makeTexture(descriptor: d) else {
      throw RendererError.resourceUnavailable("benchmark target texture")
    }
    for i in 0 ..< 45 {
      let snapshot = try FrameImporter.snapshot(
        from: frame,
        sequence: UInt64(i + 1)
      )
      let t0 = now()
      try checkedRender(renderer, snapshot, to: texture)
      if i >= 5 { gpu.append((now() - t0) * 1000) }
    }
  }
  return (
    Array(exportTimes.dropFirst(5)), Array(importTimes.dropFirst(5)), bytes, gpu
  )
}

// MARK: Load at the pane limit

func load(
  seconds: Double,
  visible: Int
) async throws -> (cpu: Double, mb: Double, framesPerSecond: Double) {
  let limits = MuxLimits.standard
  let c = try await connect()
  let noisy = spec("while :; do cat \(corpusShellPath); done")
  var workspaces: [WorkspaceSnapshot] = []
  for _ in 0 ..< limits.maxPanes {
    workspaces.append(try await create(c, noisy, columns: 120, rows: 40))
  }
  // One workspace gets `visible` panes by splitting; others stay detached.
  var frames = 0
  if visible > 0 {
    let target = workspaces[0]
    // Other workspaces' panes cannot be reused: attach to one, subscribe its
    // single pane, and run the remaining load detached.
    try await show(
      c,
      target,
      panes: [target.tabs[0].activePane],
      columns: 120,
      rows: 40
    )
  }
  let cpu0 = cpuSeconds()
  let t0 = now()
  if visible > 0 {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
      do {
        if case .frame = try await benchmarkEvent(c, until: deadline) {
          frames += 1
        }
      } catch MuxConnection.EventWaitError.timedOut
        where ContinuousClock.now >= deadline
      { break }
    }
  } else {
    try await Task.sleep(for: .seconds(seconds))
  }
  let elapsed = now() - t0
  let cpu = (cpuSeconds() - cpu0) / elapsed * 100
  let mb = footprint()
  if visible > 0 { try await c.execute(.detach) }
  try await c.execute(.endAllWorkspaces)
  try await c.execute(.quiesce(false))
  try await awaitPaneCleanup(c)
  await c.close()
  return (cpu, mb, Double(frames) / elapsed)
}

// MARK: Configured limits

/// A full 1 MiB paste (32 KiB chunks under writer credit) into a reader.
func pasteLimit() async throws -> Double {
  let c = try await connect()
  let ws = try await create(
    c,
    spec("stty raw -echo; exec cat > /dev/null"),
    columns: 120,
    rows: 40
  )
  let pane = ws.tabs[0].activePane
  try await show(c, ws, panes: [pane], columns: 120, rows: 40)
  try await Task.sleep(for: .milliseconds(200))
  let text = String(repeating: "paste line of text\n", count: (1 << 20) / 19)
  let t0 = now()
  let state = try await c.paste(String(text.prefix(1 << 20)), to: pane)
  let elapsed = (now() - t0) * 1000
  guard state == .completed else {
    throw MuxError(.invalidRequest, "benchmark paste incomplete")
  }
  _ = try? await c.execute(.endWorkspace(.id(ws.id)))
  await c.close()
  return elapsed
}

/// Literal search across a full history (10,000 rows retained).
func historySearch() async throws -> (rows: Int, ms: Double) {
  let c = try await connect()
  let ws = try await create(
    c,
    spec(
      "i=0; while [ $i -lt 12000 ]; do echo history-row-$i; i=$((i+1)); done; exec cat"
    ),
    columns: 120,
    rows: 40
  )
  let pane = ws.tabs[0].activePane
  try await show(c, ws, panes: [pane], columns: 80, rows: 24)
  var rows = 0
  let deadline = ContinuousClock.now + .seconds(30)
  while rows < MuxLimits.standard.historyRowsPerPane {
    if case let .frame(f) = try await benchmarkEvent(c, until: deadline) {
      rows = f.history.scrollbackRows
    }
  }
  try await Task.sleep(for: .milliseconds(300))
  let t0 = now()
  guard
    case let .search(result) = try await c.execute(
      .search(pane: pane, query: "history-row-1999")
    )
  else { throw MuxError(.invalidRequest, "unexpected benchmark reply") }
  let elapsed = (now() - t0) * 1000
  guard result.matchCount >= 1 else {
    throw MuxError(.invalidRequest, "benchmark search found no match")
  }
  _ = try? await c.execute(.endWorkspace(.id(ws.id)))
  await c.close()
  return (rows, elapsed)
}

/// 32 visible noisy panes in one tab at the 512x256 maximum area.
func visibleLimit(
  seconds: Double
) async throws -> (cpu: Double, mb: Double, fps: Double, panes: Int) {
  let c = try await connect()
  let noisy = spec("while :; do cat \(corpusShellPath); done")
  var ws = try await create(c, noisy, columns: 512, rows: 255)
  guard
    case let .attached(_, snap) = try await c.execute(
      .attach(AttachRequest(.id(ws.id)))
    )
  else { throw MuxError(.invalidRequest, "unexpected benchmark reply") }
  ws = snap
  var panes = ws.tabs[0].layout.panes
  var axis = SplitAxis.leftRight
  while panes.count < MuxLimits.standard.maxPanes {
    var next: [PaneID] = []
    for pane in panes
    where panes.count + next.count < MuxLimits.standard.maxPanes {
      guard
        case let .layout(l) = try await c.execute(
          .split(pane: pane, axis: axis, launch: noisy)
        )
      else { throw MuxError(.invalidRequest, "unexpected benchmark reply") }
      ws = l
      next.append(l.tabs[0].activePane)
    }
    panes += next
    axis = axis == .leftRight ? .topBottom : .leftRight
  }
  let tab = ws.tabs[0]
  let frames = LayoutGeometry.frames(
    tab.layout,
    in: LayoutRect(x: 0, y: 0, width: 512, height: 255),
    divider: 1
  )
  try await c.execute(
    .setGeometry(
      GeometryBatch(
        layoutRevision: ws.layoutRevision,
        generation: 1,
        entries: tab.layout.panes.map {
          .init(
            pane: $0,
            columns: max(1, frames[$0]!.width),
            rows: max(1, frames[$0]!.height)
          )
        }
      )
    )
  )
  try await c.execute(.setSubscriptions(tab.layout.panes))
  let cpu0 = cpuSeconds()
  let t0 = now()
  var count = 0
  let deadline = ContinuousClock.now + .seconds(seconds)
  while ContinuousClock.now < deadline {
    do {
      if case .frame = try await benchmarkEvent(c, until: deadline) {
        count += 1
      }
    } catch MuxConnection.EventWaitError.timedOut
      where ContinuousClock.now >= deadline
    { break }
  }
  let elapsed = now() - t0
  let result = (
    (cpuSeconds() - cpu0) / elapsed * 100, footprint(), Double(count) / elapsed,
    tab.layout.panes.count
  )
  try await c.execute(.detach)
  try await c.execute(.endAllWorkspaces)
  try await c.execute(.quiesce(false))
  try await awaitPaneCleanup(c)
  await c.close()
  return result
}

// MARK: Noisy GPU

/// 200x50 pane render time while another renderer saturates the GPU with
/// back-to-back 512x256 frames (a busy neighbouring pane or app).
func noisyGPU() throws -> (quiet: [Double], noisy: [Double])? {
  guard let device = MTLCreateSystemDefaultDevice() else { return nil }
  func target(
    _ r: MetalRenderer,
    _ columns: Int,
    _ rows: Int
  ) throws -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm,
      width: Int(r.cellSize.width) * columns + 16,
      height: Int(r.cellSize.height) * rows + 16,
      mipmapped: false
    )
    d.usage = [.renderTarget, .shaderRead]
    d.storageMode = .private
    guard let texture = device.makeTexture(descriptor: d) else {
      throw RendererError.resourceUnavailable("benchmark target texture")
    }
    return texture
  }
  func snapshot(_ columns: Int, _ rows: Int) throws -> RenderSnapshot {
    let session = filledState(columns: columns, rows: rows)
    let identity = FrameIdentity(
      server: ServerInstanceID(),
      attachment: AttachmentID(),
      pane: PaneID(),
      revision: 1,
      layoutRevision: 1,
      geometryGeneration: 1,
      viewportRevision: 0
    )
    let frame = try session.withState {
      try FrameExporter.frame(from: $0.captureOwnedScreen(), identity: identity)
    }
    return try FrameImporter.snapshot(from: frame, sequence: 1)
  }
  let pane = try MetalRenderer(
    device: device,
    fontManager: CoreTextFontManager(),
    font: FontDescriptor()
  )
  let noise = Mutex(
    try MetalRenderer(
      device: device,
      fontManager: CoreTextFontManager(),
      font: FontDescriptor()
    )
  )
  let small = try snapshot(200, 50)
  let large = try snapshot(512, 256)
  let paneTexture = try target(pane, 200, 50)
  let noiseTexture = try noise.withLock { try target($0, 512, 256) }
  func measure() throws -> [Double] {
    var times: [Double] = []
    for i in 0 ..< 65 {
      let t0 = now()
      try checkedRender(pane, small, to: paneTexture)
      if i >= 5 { times.append((now() - t0) * 1000) }
    }
    return times
  }
  let quiet = try measure()
  let stop = Atomic(false)
  let finished = DispatchSemaphore(value: 0)
  let noiseError = Mutex<(any Error)?>(nil)
  let noiseThread = Thread {
    defer { finished.signal() }
    do {
      try noise.withLock { renderer in
        while !stop.load(ordering: .relaxed) {
          try checkedRender(renderer, large, to: noiseTexture)
        }
      }
    } catch { noiseError.withLock { $0 = error } }
  }
  noiseThread.start()
  Thread.sleep(forTimeInterval: 0.2)
  let noisy: Result<[Double], any Error>
  do { noisy = .success(try measure()) } catch { noisy = .failure(error) }
  stop.store(true, ordering: .relaxed)
  guard finished.wait(timeout: .now() + .seconds(35)) == .success else {
    throw RendererError.resourceUnavailable("benchmark noise thread timeout")
  }
  if let error = noiseError.withLock({ $0 }) { throw error }
  return (quiet, try noisy.get())
}

// MARK: Run

do {
  _ = try corpusResult.get()
  signal(SIGPIPE, SIG_IGN)
  setvbuf(stdout, nil, _IOLBF, 0)
  print(
    "swiftmux-bench (\(SMX.build)); host \(ProcessInfo.processInfo.hostName)"
  )
  print(
    "  \(ProcessInfo.processInfo.operatingSystemVersionString), \(ProcessInfo.processInfo.activeProcessorCount) cores"
  )
  #if DEBUG
  print("  WARNING: debug build; use swift run -c release swiftmux-bench")
  #endif
  print("corpus: \(corpusBytes / 1_048_576) MiB of SGR/UTF-8/wide text")
  let idleMB = footprint()
  if CommandLine.arguments.contains("--frame-stages") {
    for (cols, rows) in [(200, 50), (512, 256)] {
      let stages = try frameStages(columns: cols, rows: rows)
      print(
        "stages \(cols)x\(rows) p95: "
          + stages.map { "\($0.0) \(ms($0.1))" }.joined(separator: ", ")
      )
    }
    for (cols, rows) in [(80, 24), (512, 256)] {
      let copy = try copyLatency(columns: cols, rows: rows)
      print(
        "copySelection \(cols)x\(rows) over \(copy.rows) rows "
          + "(\(copy.bytes / 1024) KiB): p50 \(ms(copy.p50)) p95 \(ms(copy.p95))"
      )
    }
    exit(0)
  }
  let detached = try await throughput(attached: false)
  print(
    String(
      format: "throughput, detached pane:            %7.1f MiB/s",
      detached.mbps
    )
  )
  let attached = try await throughput(attached: true)
  print(
    String(
      format: "throughput, attached 200x50 client:   %7.1f MiB/s (%d frames)",
      attached.mbps,
      attached.frames
    )
  )
  let lat = try await latency(samples: 200)
  print(
    "input-to-frame latency (XPC, PTY echo, export, decode): p50 \(ms(percentile(lat, 0.5))) p95 \(ms(percentile(lat, 0.95))) p99 \(ms(percentile(lat, 0.99)))"
  )
  for (cols, rows, binary) in [
    (200, 50, false), (200, 50, true), (512, 256, false), (512, 256, true),
  ] {
    let r = try exportImport(columns: cols, rows: rows, binary: binary)
    print(
      "frame \(cols)x\(rows) \(binary ? "SMXB/1" : "JSON  "): \(r.bytes / 1024) KiB; "
        + "export+encode p50 \(ms(percentile(r.export, 0.5))) "
        + "p95 \(ms(percentile(r.export, 0.95))); "
        + "decode+validate+import p50 \(ms(percentile(r.importing, 0.5))) "
        + "p95 \(ms(percentile(r.importing, 0.95)))"
        + (r.gpu.isEmpty
          ? ""
          : "; GPU render p50 \(ms(percentile(r.gpu, 0.5))) p95 \(ms(percentile(r.gpu, 0.95)))")
    )
  }
  for (name, bytes) in try deltaSizes() {
    print("delta 200x50 \(name): \(bytes) bytes")
  }
  let noClient = try await load(seconds: 5, visible: 0)
  print(
    String(
      format:
        "32 noisy panes, no client:   service CPU %6.1f%%, footprint %6.1f MiB",
      noClient.cpu,
      noClient.mb
    )
  )
  let withClient = try await load(seconds: 5, visible: 1)
  print(
    String(
      format:
        "32 noisy panes, 1 visible:   service CPU %6.1f%%, footprint %6.1f MiB, %.1f frames/s",
      withClient.cpu,
      withClient.mb,
      withClient.framesPerSecond
    )
  )
  if let gpu = try noisyGPU() {
    print(
      "200x50 GPU render, quiet p50 \(ms(percentile(gpu.quiet, 0.5))) p95 \(ms(percentile(gpu.quiet, 0.95))); "
        + "with a saturating 512x256 renderer p50 \(ms(percentile(gpu.noisy, 0.5))) p95 \(ms(percentile(gpu.noisy, 0.95)))"
    )
  }
  let pasteMs = try await pasteLimit()
  print(
    String(
      format: "1 MiB paste (32 KiB chunks, acknowledged): %.1f ms",
      pasteMs
    )
  )
  let search = try await historySearch()
  print(
    String(
      format: "literal search over %d history rows: %.2f ms",
      search.rows,
      search.ms
    )
  )
  let visible = try await visibleLimit(seconds: 5)
  print(
    String(
      format:
        "%d visible noisy panes (512x255 area): service+client CPU %.1f%%, footprint %.1f MiB, %.1f frames/s",
      visible.panes,
      visible.cpu,
      visible.mb,
      visible.fps
    )
  )
  print(String(format: "idle footprint before load: %.1f MiB", idleMB))
  guard await finishBenchmark() else {
    try? FileManager.default.removeItem(at: corpusURL)
    exit(1)
  }
  try? FileManager.default.removeItem(at: corpusURL)
  exit(0)

} catch {
  fputs("swiftmux-bench failed: \(error)\n", stderr)
  _ = await finishBenchmark()
  try? FileManager.default.removeItem(at: corpusURL)
  exit(1)
}

private func checkedRender(
  _ renderer: MetalRenderer,
  _ snapshot: RenderSnapshot,
  to texture: MTLTexture
) throws {
  let command = try renderer.render(snapshot, to: texture)
  guard renderer.waitUntilIdle(timeout: .now() + .seconds(30)) else {
    throw RendererError.resourceUnavailable("benchmark GPU timeout")
  }
  guard command.status == .completed else {
    throw RendererError.resourceUnavailable(
      "benchmark GPU command failed: \(command.status.rawValue): \(String(describing: command.error))"
    )
  }
}

private func benchmarkEvent(
  _ connection: MuxConnection,
  until deadline: ContinuousClock.Instant
) async throws -> MuxEvent {
  let remaining = deadline - ContinuousClock.now
  guard remaining > .zero else { throw MuxConnection.EventWaitError.timedOut }
  guard let event = try await connection.nextEvent(timeout: remaining) else {
    throw MuxError(.connectionLost, "benchmark event EOF")
  }
  return event
}

private func awaitPaneCleanup(_ connection: MuxConnection) async throws {
  let deadline = ContinuousClock.now + .seconds(30)
  while true {
    let remaining = deadline - ContinuousClock.now
    guard remaining > .zero else { throw MuxConnection.EventWaitError.timedOut }
    guard
      case let .status(status) = try await connection.execute(
        .status,
        timeout: remaining
      )
    else { throw MuxError(.invalidRequest, "benchmark cleanup status reply") }
    if status.panes == 0 { return }
    try await Task.sleep(for: .milliseconds(50))
  }
}

private func finishBenchmark() async -> Bool {
  let ready = Atomic(false)
  service.prepareToExit { ready.store(true, ordering: .releasing) }
  let deadline = ContinuousClock.now + .seconds(30)
  while !ready.load(ordering: .acquiring), ContinuousClock.now < deadline {
    do { try await Task.sleep(for: .milliseconds(20)) } catch { break }
  }
  guard ready.load(ordering: .acquiring) else {
    fputs("swiftmux-bench child cleanup timed out\n", stderr)
    return false
  }
  return true
}
