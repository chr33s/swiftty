import CoreGraphics
import Foundation
import ImageIO
import Metal
import SwifttyCore
import Testing
#if canImport(UIKit)
import UIKit
#endif

/// Kitty graphics gates on the device running the tests (spec.graphics.md
/// §21.3, KG28): run on an iPad by `Scripts/test-ipad-frame-time.sh`.
/// Results print as `kitty-device …` lines.
@Suite(.serialized)
struct KittyDeviceTests {
  static let device = MTLCreateSystemDefaultDevice()
  #if SWIFTTY_REQUIRE_FRAME_BENCHMARK
  static let measurable = true
  #elseif DEBUG || targetEnvironment(simulator)
  static let measurable = false
  #else
  static let measurable = device != nil
  #endif

  private static func gradient(_ w: Int, _ h: Int) -> [UInt8] {
    var out = [UInt8](repeating: 255, count: w * h * 4)
    for y in 0 ..< h {
      for x in 0 ..< w {
        let i = (y * w + x) * 4
        out[i] = UInt8(x & 0xFF)
        out[i + 1] = UInt8(y & 0xFF)
        out[i + 2] = UInt8((x ^ y) & 0xFF)
      }
    }
    return out
  }

  private static func png(_ w: Int, _ h: Int) throws -> Data {
    let provider = try #require(
      CGDataProvider(data: Data(gradient(w, h)) as CFData)
    )
    let image = try #require(
      CGImage(
        width: w,
        height: h,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: w * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
      )
    )
    let data = NSMutableData()
    let dest = try #require(
      CGImageDestinationCreateWithData(
        data as CFMutableData,
        "public.png" as CFString,
        1,
        nil
      )
    )
    CGImageDestinationAddImage(dest, image, nil)
    #expect(CGImageDestinationFinalize(dest))
    return data as Data
  }

  /// Chunked direct transmission, as kitty's clients send it.
  private static func transmission(id: Int, width: Int, height: Int) -> [UInt8]
  {
    let encoded = Array(
      Data(gradient(width, height)).base64EncodedString().utf8
    )
    var out: [UInt8] = []
    out.reserveCapacity(encoded.count + encoded.count / 4096 * 16 + 64)
    var i = 0
    while i < encoded.count {
      let end = min(encoded.count, i + 4096)
      let more = end < encoded.count ? 1 : 0
      let keys =
        i == 0
        ? "a=t,f=32,s=\(width),v=\(height),i=\(id),q=2,m=\(more)" : "m=\(more)"
      out +=
        Array("\u{1B}_G\(keys);".utf8) + encoded[i ..< end]
        + Array("\u{1B}\\".utf8)
      i = end
    }
    return out
  }

  private static func ms(_ start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
  }

  private static func percentile(_ samples: [Double], _ p: Double) -> Double {
    let s = samples.sorted()
    return s[min(s.count - 1, Int(Double(s.count - 1) * p))]
  }

  @Test(.enabled(if: measurable))
  func `a 2000 by 2000 PNG decodes within 60 ms at p95`() throws {
    let png = try Self.png(2000, 2000)
    let bytes =
      Array("\u{1B}_Ga=t,f=100,i=1,q=2;".utf8)
      + Array(png.base64EncodedString().utf8) + Array("\u{1B}\\".utf8)
    var samples: [Double] = []
    for _ in 0 ..< 12 {
      var state = TerminalState(columns: 120, rows: 40)
      var parser = Parser()
      let start = DispatchTime.now().uptimeNanoseconds
      parser.consume(bytes.span, into: &state)
      samples.append(Self.ms(start))
      #expect(state.output.isEmpty)
    }
    let p95 = Self.percentile(samples, 0.95)
    print(
      "kitty-device png p50_ms=\(Self.percentile(samples, 0.5)) p95_ms=\(p95)"
    )
    #expect(p95 <= 60)
  }

  @Test(.enabled(if: measurable))
  func `a 4K image transmits and uploads within one display frame`()
    async throws
  {
    // The display's own frame: 120 Hz on ProMotion, 60 Hz otherwise.
    #if canImport(UIKit)
    let hz = Double(
      await MainActor.run { UIScreen.main.maximumFramesPerSecond }
    )
    #else
    let hz = 120.0
    #endif
    try Self.measureUpload(hz: hz)
  }

  private static func measureUpload(hz: Double) throws {
    let renderer = try MetalRenderer(
      device: #require(device),
      fontManager: CoreTextFontManager(),
      font: FontDescriptor()
    )
    let (columns, rows) = (120, 40)
    let session = TerminalSession(columns: columns, rows: rows)
    session.setCellPixelSize(
      width: Int(renderer.cellSize.width),
      height: Int(renderer.cellSize.height)
    )
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm,
      width: Int(renderer.cellSize.width) * columns + 16,
      height: Int(renderer.cellSize.height) * rows + 16,
      mipmapped: false
    )
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .private
    let target = try #require(
      renderer.device.makeTexture(descriptor: descriptor)
    )
    var transmits: [Double] = []
    var uploads: [Double] = []
    var steady: [Double] = []
    for i in 0 ..< 5 {
      // One image at a time: five would exceed the 128 MB iOS budget.
      session.feed(Array("\u{1B}_Ga=d,d=A,q=2\u{1B}\\".utf8))
      let bytes = Self.transmission(id: i + 1, width: 3840, height: 2160)
      var start = DispatchTime.now().uptimeNanoseconds
      session.feed(bytes)
      _ = session.snapshot()
      transmits.append(Self.ms(start))
      session.feed(
        Array(
          "\u{1B}[H\u{1B}_Ga=p,i=\(i + 1),c=\(columns),r=\(rows),C=1,q=2\u{1B}\\"
            .utf8
        )
      )
      let snapshot = session.snapshot()
      #expect(snapshot.images.count == 1)
      start = DispatchTime.now().uptimeNanoseconds
      var command = try renderer.render(snapshot, to: target)
      command.waitUntilCompleted()
      uploads.append(Self.ms(start))
      start = DispatchTime.now().uptimeNanoseconds
      command = try renderer.render(snapshot, to: target)
      command.waitUntilCompleted()
      steady.append(Self.ms(start))
      #expect(command.status == .completed)
    }
    let upload = Self.percentile(uploads, 0.5)
    print(
      "kitty-device 4k transmit_ms=\(Self.percentile(transmits, 0.5)) upload_frame_ms=\(upload) steady_frame_ms=\(Self.percentile(steady, 0.5)) display_hz=\(hz)"
    )
    #expect(upload <= 1000 / hz)
  }

  @Test(.enabled(if: measurable))
  func
    `a placeholder screen snapshots within 10 percent of ASCII while typing`()
  {
    func session(_ fill: (TerminalSession) -> Void) -> TerminalSession {
      let s = TerminalSession(columns: 80, rows: 40)
      s.setCellPixelSize(width: 10, height: 20)
      fill(s)
      _ = s.snapshot()
      return s
    }
    let ascii = session { s in
      for _ in 0 ..< 39 {
        s.feed(Array((String(repeating: "x", count: 80) + "\r\n").utf8))
      }
    }
    let rgb = Data(repeating: 128, count: 8 * 8 * 3).base64EncodedString()
    let placeholders = session { s in
      s.feed(
        Array(
          "\u{1B}_Ga=T,U=1,f=24,s=8,v=8,i=42,c=80,r=39,q=2;\(rgb)\u{1B}\\".utf8
        )
      )
      s.feed(Array("\u{1B}[H\u{1B}[38;5;42m".utf8))
      let d = KittyGraphics.diacritics
      for row in 0 ..< 39 {
        var line = ""
        for column in 0 ..< 80 {
          line.unicodeScalars.append(Unicode.Scalar(KittyGraphics.placeholder)!)
          line.unicodeScalars.append(Unicode.Scalar(d[row])!)
          line.unicodeScalars.append(Unicode.Scalar(d[column])!)
        }
        s.feed(Array((line + "\r\n").utf8))
      }
    }
    #expect(placeholders.snapshot().images.count == 39)
    let typed = (0 ..< 10).map { Array("\u{1B}[40;1H\($0)".utf8) }
    var samples: [[Double]] = [[], []]
    for _ in 0 ..< 30 {
      for (k, s) in [ascii, placeholders].enumerated() {
        var spent = 0.0
        for i in 0 ..< 500 {
          s.feed(typed[i % 10])
          let start = DispatchTime.now().uptimeNanoseconds
          _ = s.snapshot()
          spent += Self.ms(start)
        }
        samples[k].append(spent / 500)
      }
    }
    let a = Self.percentile(samples[0], 0.5)
    let p = Self.percentile(samples[1], 0.5)
    print(
      "kitty-device placeholders ascii_us=\(a * 1000) placeholder_us=\(p * 1000) ratio=\(p / a)"
    )
    #expect(p / a <= 1.10)
  }
}
