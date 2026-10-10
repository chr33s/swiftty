// Microbenchmarks for SwifttyCore (spec §14). Run on a release build:
//
//   mise run bench                # 100 MB streams
//   swift run -c release swiftty-bench --mb 10 --only ascii,utf8
//
// Reports throughput, CPU time, heap allocations in the measured loop,
// peak RSS, frame times and PTY input-to-snapshot latency.
import CAllocCounter
import Darwin
import Foundation
import Metal
import SwifttyCore

// MARK: Options

struct Options: Sendable {
  var megabytes = 100
  var only: Set<String>?
  var repeats = 1

  static let names: Set<String> = [
    "ascii", "utf8", "utf8-cjk", "utf8-latin", "compiler-log", "cat-source",
    "csi-heavy", "osc-heavy", "scroll", "redraw", "scroll-frames", "resize",
    "latency", "storage",
  ]

  static func parse(
    _ input: ArraySlice<String>,
    generating: Bool = false
  ) -> Options {
    var options = Options()
    var arguments = input
    func value(for option: String) -> String {
      guard let value = arguments.popFirst(), !value.isEmpty else {
        argumentError("missing value for \(option)")
      }
      return value
    }
    while let arg = arguments.popFirst() {
      switch arg {
      case "--mb":
        let raw = value(for: arg)
        guard let n = Int(raw), (1 ... (Int.max >> 20)).contains(n) else {
          argumentError("invalid megabyte count: \(raw)")
        }
        options.megabytes = n
      case "--repeat" where !generating:
        let raw = value(for: arg)
        guard let n = Int(raw), n > 0 else {
          argumentError("invalid repeat count: \(raw)")
        }
        options.repeats = n
      case "--only" where !generating:
        let raw = value(for: arg)
        let names = Set(
          raw.split(separator: ",", omittingEmptySubsequences: false)
            .map(String.init)
        )
        guard names.isSubset(of: Self.names) else {
          argumentError("unknown benchmark in --only: \(raw)")
        }
        options.only = names
      case "--help", "-h":
        print(
          """
          usage: swiftty-bench [--mb N] [--repeat N] [--only name,name]
                 swiftty-bench stream --data <file> [--terminal-cols N] [--terminal-rows N] [--scrollback-bytes N]
                 swiftty-bench gen <name> [--mb N]
          """
        )
        exit(0)
      default: argumentError("unknown option \(arg)")
      }
    }
    return options
  }
}

func argumentError(_ message: String) -> Never {
  FileHandle.standardError.write(Data("swiftty-bench: \(message)\n".utf8))
  exit(2)
}

// Subcommands run before any benchmark globals (e.g. the Metal device)
// are initialized, so their startup cost stays comparable.
switch CommandLine.arguments.dropFirst().first {
case "stream": runStreamFile(Array(CommandLine.arguments.dropFirst(2)))
case "gen": runGenerate(Array(CommandLine.arguments.dropFirst(2)))
default: break
}
let options = Options.parse(CommandLine.arguments.dropFirst())
let streamBytes = options.megabytes << 20

// MARK: Measurement

struct Usage {
  let wall: Double
  let cpu: Double

  static func now() -> Usage {
    var ru = rusage()
    getrusage(RUSAGE_SELF, &ru)
    let cpu =
      Double(ru.ru_utime.tv_sec + ru.ru_stime.tv_sec) + Double(
        ru.ru_utime.tv_usec + ru.ru_stime.tv_usec
      ) / 1e6
    return Usage(
      wall: Double(DispatchTime.now().uptimeNanoseconds) / 1e9,
      cpu: cpu
    )
  }
}

func peakRSSMB() -> Double {
  var ru = rusage()
  getrusage(RUSAGE_SELF, &ru)
  return Double(ru.ru_maxrss) / 1_048_576  // bytes on macOS
}

func percentile(_ values: [Double], _ p: Double) -> Double {
  guard !values.isEmpty else { return 0 }
  let sorted = values.sorted()
  return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
}

func row(_ name: String, _ columns: [(String, String)]) {
  let cells = columns.map { "\($0.0)=\($0.1)" }.joined(separator: "  ")
  let label =
    name.count < 14
    ? name.padding(toLength: 14, withPad: " ", startingAt: 0) : name + "  "
  print(label + cells)
  fflush(stdout)
}

func fmt(_ v: Double, _ digits: Int = 1) -> String {
  String(format: "%.\(digits)f", v)
}

func selected(_ name: String) -> Bool { options.only?.contains(name) ?? true }

// MARK: Input generation

struct LCG {
  var state: UInt64 = 0x9E37_79B9_7F4A_7C15
  mutating func next(_ bound: Int) -> Int {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return Int((state >> 33) % UInt64(bound))
  }
}

/// Repeats a generated chunk up to `bytes`; generating 100 MB of random
/// text would dominate the run otherwise.
func stream(_ bytes: Int, chunk: () -> [UInt8]) -> [UInt8] {
  let unit = chunk()
  var out = [UInt8]()
  out.reserveCapacity(bytes)
  while out.count < bytes {
    out.append(contentsOf: unit.prefix(bytes - out.count))
  }
  return out
}

func asciiChunk() -> [UInt8] {
  var rng = LCG()
  var out = [UInt8]()
  for _ in 0 ..< 20000 {
    for _ in 0 ..< (20 + rng.next(100)) {
      out.append(UInt8(0x20 + rng.next(95)))
    }
    out.append(contentsOf: [0x0D, 0x0A])
  }
  return out
}

func utf8Chunk() -> [UInt8] {
  let words = [
    "hello", "wörld", "naïve", "日本語", "中文字符", "한국어", "Ελληνικά", "русский", "😀",
    "🚀", "e\u{301}", "ﬁ", "→", "│",
  ]
  var rng = LCG()
  var s = ""
  for _ in 0 ..< 20000 {
    for _ in 0 ..< (4 + rng.next(12)) {
      s += words[rng.next(words.count)] + " "
    }
    s += "\r\n"
  }
  return Array(s.utf8)
}

/// Single-script streams to separate wide-char and narrow non-ASCII costs.
func scriptChunk(_ alphabet: [Character]) -> [UInt8] {
  var rng = LCG()
  var s = ""
  for _ in 0 ..< 20000 {
    for _ in 0 ..< (20 + rng.next(40)) {
      s.append(alphabet[rng.next(alphabet.count)])
    }
    s += "\r\n"
  }
  return Array(s.utf8)
}

func compilerLogChunk() -> [UInt8] {
  var rng = LCG()
  var s = ""
  for i in 0 ..< 10000 {
    let file = "Sources/Module\(rng.next(40))/File\(rng.next(300)).swift"
    switch rng.next(5) {
    case 0:
      s +=
        "\u{1B}[1m\(file):\(i % 900):\(rng.next(80)): \u{1B}[31merror: \u{1B}[0m"
      s +=
        "\u{1B}[1mcannot convert value of type 'Int' to expected argument type 'String'\u{1B}[0m\r\n"
      s +=
        "    let value: String = count\r\n\u{1B}[32m                        ^~~~~\u{1B}[0m\r\n"
    case 1:
      s +=
        "\u{1B}[1m\(file):\(i % 900):\(rng.next(80)): \u{1B}[35mwarning: \u{1B}[0m\u{1B}[1mvariable 'x' was never mutated\u{1B}[0m\r\n"
    default: s += "[\(i)/10000] Compiling Module\(rng.next(40)) \(file)\r\n"
    }
  }
  return Array(s.utf8)
}

func sourceChunk() -> [UInt8] {
  // "cat" of real files: this package's sources.
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent()
  var out = [UInt8]()
  if let files = FileManager.default.enumerator(
    at: root,
    includingPropertiesForKeys: nil
  ) {
    for case let url as URL in files
    where url.pathExtension == "swift" || url.pathExtension == "metal" {
      if let data = try? Data(contentsOf: url) {
        for b in data {
          if b == 0x0A { out.append(0x0D) };
          out.append(b)
        }  // onlcr
      }
    }
  }
  return out.isEmpty ? asciiChunk() : out
}

func csiChunk() -> [UInt8] {
  var rng = LCG()
  var s = ""
  for _ in 0 ..< 50000 {
    s += "\u{1B}[\(1 + rng.next(60));\(1 + rng.next(200))H"
    s += "\u{1B}[\(rng.next(2));3\(rng.next(8));4\(rng.next(8))m"
    s += "\u{1B}[38;2;\(rng.next(256));\(rng.next(256));\(rng.next(256))mx"
    s +=
      [
        "\u{1B}[K", "\u{1B}[2X", "\u{1B}[1@", "\u{1B}[1P", "\u{1B}[A",
        "\u{1B}[3C", "",
      ][rng.next(7)]
    s += "\u{1B}[0m"
  }
  return Array(s.utf8)
}

func oscChunk() -> [UInt8] {
  var s = ""
  for i in 0 ..< 20000 {
    s += "\u{1B}]0;user@host: ~/src/project-\(i)\u{07}"
    s += "\u{1B}]133;A\u{1B}\\$ \u{1B}]133;B\u{1B}\\ls\r\n\u{1B}]133;C\u{1B}\\"
    s += "\u{1B}]7;file://host/Users/me/dir\(i % 50)\u{1B}\\"
    s += "\u{1B}]8;;https://example.com/\(i)\u{1B}\\link\u{1B}]8;;\u{1B}\\\r\n"
  }
  return Array(s.utf8)
}

func scrollChunk() -> [UInt8] {
  var s = ""
  for i in 0 ..< 100_000 { s += "\(i)\r\n" }
  return Array(s.utf8)
}

// MARK: Stream benchmark

func runStream(
  _ name: String,
  _ makeInput: @autoclosure () -> [UInt8],
  columns: Int = 200,
  rows: Int = 60
) {
  guard selected(name) else { return }
  let input = makeInput()
  var state = TerminalState(columns: columns, rows: rows)
  var parser = Parser()
  let chunk = 64 * 1024  // PTY read size

  // Warm up parsing and the per-read drains as well as scrollback, so
  // their first-use metadata allocations stay outside the measured loop.
  input.withUnsafeBufferPointer { buf in
    parser.consume(
      UnsafeBufferPointer(rebasing: buf[0 ..< min(buf.count, 16 << 20)]),
      into: &state
    )
  }
  _ = state.takeDamage()
  state.output.removeAll(keepingCapacity: true)
  _ = state.takeEvents()

  let start = Usage.now()
  alloc_counter_start()
  for _ in 0 ..< options.repeats {
    input.withUnsafeBufferPointer { buf in
      var offset = 0
      while offset < buf.count {
        let end = min(offset + chunk, buf.count)
        let span = Span(
          _unsafeElements: UnsafeBufferPointer(rebasing: buf[offset ..< end])
        )
        parser.consume(span, into: &state)
        _ = state.takeDamage()
        state.output.removeAll(keepingCapacity: true)
        _ = state.takeEvents()  // as the session does once per read
        offset = end
      }
    }
  }
  let allocations = alloc_counter_stop()
  let end = Usage.now()
  let mb = Double(input.count) * Double(options.repeats) / 1_048_576
  row(
    name,
    [
      ("MB", fmt(mb, 0)), ("MB/s", fmt(mb / (end.wall - start.wall))),
      ("cpu_s", fmt(end.cpu - start.cpu, 3)), ("allocs", "\(allocations)"),
      ("peak_rss_MB", fmt(peakRSSMB())),
    ]
  )
}

// MARK: Frame benchmarks

let device = MTLCreateSystemDefaultDevice()

/// Waiting also returns after GPU errors; only successful frames are samples.
func waitForFrame(_ command: MTLCommandBuffer, benchmark: String) {
  command.waitUntilCompleted()
  guard command.status == .completed else {
    row(
      benchmark,
      [
        (
          "error",
          command.error?.localizedDescription
            ?? "GPU command status \(command.status.rawValue)"
        )
      ]
    )
    exit(1)
  }
}

func offscreenTarget(
  _ renderer: MetalRenderer,
  columns: Int,
  rows: Int
) -> MTLTexture? {
  let w = Int(renderer.cellSize.width) * columns + 16
  let h = Int(renderer.cellSize.height) * rows + 16
  let d = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .bgra8Unorm,
    width: w,
    height: h,
    mipmapped: false
  )
  d.usage = .renderTarget
  d.storageMode = .private
  return renderer.device.makeTexture(descriptor: d)
}

func runRedraw() {
  guard selected("redraw") else { return }
  let columns = 200
  let rows = 60
  let session = TerminalSession(columns: columns, rows: rows)
  let renderer = device.flatMap {
    try? MetalRenderer(
      device: $0,
      fontManager: CoreTextFontManager(),
      font: FontDescriptor()
    )
  }
  let target = renderer.flatMap {
    offscreenTarget($0, columns: columns, rows: rows)
  }
  var rng = LCG()
  var frames: [[UInt8]] = []
  for f in 0 ..< 64 {
    var s = "\u{1B}[H"
    for y in 0 ..< rows {
      s += "\u{1B}[\(y + 1);1H\u{1B}[3\(rng.next(8))m"
      for x in 0 ..< columns {
        s += String(UnicodeScalar(UInt8(0x21 + (x + y + f) % 90)))
      }
    }
    frames.append(Array(s.utf8))
  }
  var core: [Double] = []
  var gpu: [Double] = []
  var bytes = 0
  let start = Usage.now()
  for i in 0 ..< 1000 {
    let t0 = DispatchTime.now().uptimeNanoseconds
    session.feed(frames[i % frames.count])
    let snapshot = session.snapshot()
    let t1 = DispatchTime.now().uptimeNanoseconds
    if let renderer, let target {
      waitForFrame(renderer.render(snapshot, to: target), benchmark: "redraw")
    }
    let t2 = DispatchTime.now().uptimeNanoseconds
    core.append(Double(t1 - t0) / 1e6)
    gpu.append(Double(t2 - t1) / 1e6)
    bytes += frames[i % frames.count].count
  }
  let end = Usage.now()
  row(
    "redraw",
    [
      ("frames", "1000"), ("grid", "\(columns)x\(rows)"),
      ("parse+snap_p50_ms", fmt(percentile(core, 0.5), 3)),
      ("parse+snap_p95_ms", fmt(percentile(core, 0.95), 3)),
      (
        "render_p95_ms",
        renderer == nil || target == nil ? "n/a" : fmt(percentile(gpu, 0.95), 3)
      ), ("MB/s", fmt(Double(bytes) / 1_048_576 / (end.wall - start.wall))),
      ("cpu_s", fmt(end.cpu - start.cpu, 3)),
    ]
  )
}

func runScrollFrames() {
  guard selected("scroll-frames") else { return }
  let session = TerminalSession(columns: 120, rows: 40)
  let renderer = device.flatMap {
    try? MetalRenderer(
      device: $0,
      fontManager: CoreTextFontManager(),
      font: FontDescriptor()
    )
  }
  let target = renderer.flatMap { offscreenTarget($0, columns: 120, rows: 40) }
  var lines = 0
  var frameTimes: [Double] = []
  let start = Usage.now()
  for i in 0 ..< 2000 {
    var s = ""
    for k in 0 ..< 20 {
      s +=
        "scroll line \(i * 20 + k) "
        + String(repeating: "=", count: (i + k) % 80) + "\r\n"
    }
    lines += 20
    let t0 = DispatchTime.now().uptimeNanoseconds
    session.feed(Array(s.utf8))
    let snapshot = session.snapshot()
    if let renderer, let target {
      waitForFrame(
        renderer.render(snapshot, to: target),
        benchmark: "scroll-frames"
      )
    }
    frameTimes.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
  }
  let end = Usage.now()
  row(
    "scroll-frames",
    [
      ("lines", "\(lines)"),
      ("rendered", renderer != nil && target != nil ? "true" : "false"),
      ("lines/s", fmt(Double(lines) / (end.wall - start.wall), 0)),
      ("frame_p50_ms", fmt(percentile(frameTimes, 0.5), 3)),
      ("frame_p95_ms", fmt(percentile(frameTimes, 0.95), 3)),
      ("cpu_s", fmt(end.cpu - start.cpu, 3)),
    ]
  )
}

func runResize() {
  guard selected("resize") else { return }
  var state = TerminalState(columns: 120, rows: 40)
  var parser = Parser()
  // scrollback at its 10 MB limit
  let fill = stream(12 << 20, chunk: asciiChunk)
  parser.consume(fill.span, into: &state)
  let sizes = [(80, 24), (120, 40), (200, 60), (100, 30), (160, 50)]
  var times: [Double] = []
  let start = Usage.now()
  for i in 0 ..< 100 {
    let (c, r) = sizes[i % sizes.count]
    let t0 = DispatchTime.now().uptimeNanoseconds
    state.resize(columns: c, rows: r)
    times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
  }
  let end = Usage.now()
  row(
    "resize",
    [
      ("resizes", "100"), ("scrollback_lines", "\(state.scrollbackCount)"),
      ("p50_ms", fmt(percentile(times, 0.5), 2)),
      ("p95_ms", fmt(percentile(times, 0.95), 2)),
      ("cpu_s", fmt(end.cpu - start.cpu, 3)), ("peak_rss_MB", fmt(peakRSSMB())),
    ]
  )
}

/// Keystroke → PTY → echo → parse → snapshot shows it.
func runLatency() {
  guard selected("latency") else { return }
  let session = TerminalSession(columns: 80, rows: 24)
  let updated = DispatchSemaphore(value: 0)
  session.onUpdate = { updated.signal() }
  do {
    try session.start(
      SessionConfiguration(command: [
        "/bin/sh", "-c", "stty raw -echo; exec cat",
      ])
    )
  } catch {
    row("latency", [("error", "\(error)")])
    exit(1)
  }
  usleep(300_000)
  _ = session.snapshot()
  while updated.wait(timeout: .now()) == .success {}
  var samples: [Double] = []
  let letters = Array("abcdefghijklmnopqrstuvwxyz")
  for i in 0 ..< 400 {
    let ch = letters[i % letters.count]
    let t0 = DispatchTime.now().uptimeNanoseconds
    session.send(.text(String(ch)))
    let deadline = DispatchTime.now() + 1
    let expected = ch.unicodeScalars.first!.value
    var seen = false
    while !seen {
      guard updated.wait(timeout: deadline) == .success else { break }
      let snapshot = session.snapshot()
      // The last column leaves the cursor in pending-wrap state.
      // Only the character's cell proves that its echo was parsed.
      seen = snapshot.cells(row: i / 80)[i % 80].glyph == expected
    }
    guard seen else {
      session.stop()
      row(
        "latency",
        [
          ("error", "timed out waiting for echo \(i + 1)/400"),
          ("samples", "\(samples.count)"),
        ]
      )
      exit(1)
    }
    samples.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
    if i % 80 == 79 {
      session.send(.text("\r\n"));
      usleep(20000);
      _ = session.snapshot();
      while updated.wait(timeout: .now()) == .success {}
    }
  }
  session.stop()
  row(
    "latency",
    [
      ("samples", "\(samples.count)"),
      ("p50_ms", fmt(percentile(samples, 0.5), 3)),
      ("p95_ms", fmt(percentile(samples, 0.95), 3)),
      ("max_ms", fmt(samples.max() ?? 0, 3)),
    ]
  )
}

// MARK: Stream mode (comparable to `ghostty-bench terminal-stream`)

/// Reads `path` in 64 KiB chunks (the PTY read size) and feeds every chunk
/// through the parser into terminal state, mirroring Ghostty's
/// `terminal-stream` benchmark so both can be timed with hyperfine.
func runStreamFile(_ arguments: [String]) -> Never {
  var path: String?
  var columns = 120
  var rows = 80
  var scrollbackBytes = 10000
  var it = arguments.makeIterator()
  while let arg = it.next() {
    if arg == "--help" || arg == "-h" { _ = Options.parse([arg]) }
    let parts = arg.split(
      separator: "=",
      maxSplits: 1,
      omittingEmptySubsequences: false
    )
    let option = String(parts[0])
    guard
      ["--data", "--terminal-cols", "--terminal-rows", "--scrollback-bytes"]
        .contains(option)
    else { argumentError("unknown option \(arg)") }
    guard let value = parts.count == 2 ? String(parts[1]) : it.next(),
      !value.isEmpty
    else { argumentError("missing value for \(option)") }
    switch option {
    case "--data": path = value
    case "--terminal-cols", "--terminal-rows":
      guard let n = Int(value), (1 ... Int(UInt16.max)).contains(n) else {
        argumentError("invalid \(option): \(value)")
      }
      if option == "--terminal-cols" { columns = n } else { rows = n }
    default:
      guard let n = Int(value), n >= 0 else {
        argumentError("invalid \(option): \(value)")
      }
      scrollbackBytes = n
    }
  }
  guard let path else { argumentError("stream requires --data <file>") }
  let fd = open(path, O_RDONLY)
  guard fd >= 0 else {
    perror(path);
    exit(1)
  }
  var state = TerminalState(
    columns: columns,
    rows: rows,
    scrollbackLimitBytes: scrollbackBytes
  )
  var parser = Parser()
  let buffer = UnsafeMutableRawBufferPointer.allocate(
    byteCount: 64 * 1024,
    alignment: 16
  )
  while true {
    let n = read(fd, buffer.baseAddress, buffer.count)
    if n < 0 {
      if errno == EINTR { continue }
      perror(path)
      close(fd)
      exit(1)
    }
    if n == 0 { break }
    let bytes = UnsafeBufferPointer(
      start: buffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
      count: n
    )
    parser.consume(Span(_unsafeElements: bytes), into: &state)
    // What the session does per read: drain replies, events and damage.
    state.output.removeAll(keepingCapacity: true)
    _ = state.takeEvents()
    _ = state.takeDamage()
  }
  close(fd)
  exit(0)
}

/// Writes a benchmark corpus to stdout so other terminals can consume the
/// exact same bytes: `swiftty-bench gen <name> [--mb N]`.
func runGenerate(_ arguments: [String]) -> Never {
  if let first = arguments.first, first == "--help" || first == "-h" {
    _ = Options.parse(arguments.prefix(1), generating: true)
  }
  let generators: [String: () -> [UInt8]] = [
    "ascii": asciiChunk, "utf8": utf8Chunk, "compiler-log": compilerLogChunk,
    "cat-source": sourceChunk, "csi-heavy": csiChunk, "osc-heavy": oscChunk,
    "scroll": scrollChunk,
    "utf8-cjk": { scriptChunk(Array("日本語中文字符한국어漢字東京大阪")) },
    "utf8-latin": { scriptChunk(Array("éèêëàâäôöûüçñßøåæœ")) },
  ]
  guard let name = arguments.first, let generate = generators[name] else {
    FileHandle.standardError.write(
      Data(
        "usage: swiftty-bench gen <\(generators.keys.sorted().joined(separator: "|"))> [--mb N]\n"
          .utf8
      )
    )
    exit(2)
  }
  let options = Options.parse(arguments.dropFirst(), generating: true)
  let bytes = stream(options.megabytes << 20, chunk: generate)
  bytes.withUnsafeBytes { raw in
    var offset = 0
    while offset < raw.count {
      let n = write(1, raw.baseAddress! + offset, raw.count - offset)
      if n < 0, errno == EINTR { continue }
      guard n > 0 else {
        perror("stdout");
        exit(1)
      }
      offset += n
    }
  }
  exit(0)
}

// MARK: Run

#if DEBUG
print(
  "warning: debug build; use `swift run -c release swiftty-bench` for meaningful numbers"
)
#endif
print(
  "swiftty-bench  streams=\(options.megabytes)MB  \(ProcessInfo.processInfo.processorCount) cores"
)

runStream("ascii", stream(streamBytes, chunk: asciiChunk))
runStream("utf8", stream(streamBytes, chunk: utf8Chunk))
runStream(
  "utf8-cjk",
  stream(streamBytes) { scriptChunk(Array("日本語中文字符한국어漢字東京大阪")) }
)
runStream(
  "utf8-latin",
  stream(streamBytes) { scriptChunk(Array("éèêëàâäôöûüçñßøåæœ")) }
)
runStream("compiler-log", stream(streamBytes, chunk: compilerLogChunk))
runStream("cat-source", stream(streamBytes, chunk: sourceChunk))
runStream("csi-heavy", stream(streamBytes, chunk: csiChunk))
runStream("osc-heavy", stream(streamBytes, chunk: oscChunk))
runStream(
  "scroll",
  stream(streamBytes, chunk: scrollChunk),
  columns: 120,
  rows: 40
)
runRedraw()
runScrollFrames()
runResize()
runLatency()
runStorageBenchmarks()
