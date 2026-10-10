import Foundation
import Metal
import SwifttyCore
import Testing

/// Frame time for the renderer on the device running the tests (§14: also
/// measured on an iPad): a full 120×40 redraw per frame, rendered offscreen
/// and waited for, plus scrolling output that dirties every row.
@Suite(.serialized)
struct FrameTimeTests {
  static let device = MTLCreateSystemDefaultDevice()

  @Test(.enabled(if: device != nil))
  func `dense search highlights fit a 60 Hz frame`() throws {
    let renderer = try MetalRenderer(
      device: #require(Self.device),
      fontManager: CoreTextFontManager(),
      font: FontDescriptor()
    )
    let columns = 120
    let rows = 40
    let session = TerminalSession(columns: columns, rows: rows)
    session.feed(
      Array(
        ("\u{1B}[?25l" + String(repeating: "a", count: columns * rows)).utf8
      )
    )
    session.mutate { $0.search("a") }
    let snapshot = session.snapshot()
    #expect(snapshot.searchMatches.count == columns * rows)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm,
      width: Int(renderer.cellSize.width) * columns + 16,
      height: Int(renderer.cellSize.height) * rows + 16,
      mipmapped: false,
    )
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .private
    let texture = try #require(
      renderer.device.makeTexture(descriptor: descriptor)
    )
    var times: [Double] = []
    for _ in 0 ..< 40 {
      let start = DispatchTime.now().uptimeNanoseconds
      let command = renderer.render(snapshot, to: texture)
      command.waitUntilCompleted()
      try #require(
        command.status == .completed,
        "\(String(describing: command.error).debugDescription)"
      )
      times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
    }
    times = Array(times.dropFirst(5)).sorted()
    let p95 = times[times.count * 95 / 100]
    print("search-highlight p95_ms=\(String(format: "%.3f", p95))")
    #expect(p95 < 16.7)
  }

  @Test(.enabled(if: device != nil))
  func `full redraws fit a 60 Hz frame`() throws {
    let device = try #require(Self.device)
    let renderer = try MetalRenderer(
      device: device,
      fontManager: CoreTextFontManager(),
      font: FontDescriptor(size: 13, scale: 2)
    )
    let columns = 120
    let rows = 40
    let session = TerminalSession(columns: columns, rows: rows)
    let d = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm,
      width: Int(renderer.cellSize.width) * columns + 16,
      height: Int(renderer.cellSize.height) * rows + 16,
      mipmapped: false,
    )
    d.usage = [.renderTarget, .shaderRead]
    d.storageMode = .private
    let texture = try #require(device.makeTexture(descriptor: d))
    var times: [Double] = []
    for frame in 0 ..< 240 {
      var line = "\u{1B}[H"
      for y in 0 ..< rows {
        line +=
          "\u{1B}[3\(y % 8)m\(String(repeating: "frame\(frame) ", count: 12).prefix(columns))\r\n"
      }
      session.feed(Array(line.utf8))
      let start = DispatchTime.now().uptimeNanoseconds
      let command = renderer.render(session.snapshot(), to: texture)
      command.waitUntilCompleted()
      try #require(
        command.status == .completed,
        "\(String(describing: command.error).debugDescription)"
      )
      times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
    }
    times = Array(times.dropFirst(20)).sorted()  // warm-up: atlas fill
    let p50 = times[times.count / 2]
    let p95 = times[times.count * 95 / 100]
    print(
      "frame-time p50_ms=\(String(format: "%.3f", p50)) p95_ms=\(String(format: "%.3f", p95))"
    )
    #expect(p95 < 16.7)
  }
}
