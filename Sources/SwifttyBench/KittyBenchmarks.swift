// Kitty graphics gates (spec.graphics.md §21.3):
//   kitty-transmit      3840×2160 RGBA, direct, 4096-byte chunks
//   kitty-png           2000×2000 PNG decode
//   kitty-placeholders  snapshot of an 80×40 placeholder screen vs ASCII
//   kitty-render        33 MB texture upload frame and steady frames
//   kitty-file          400 MB-class file medium read (the 250 ms bound)
import CoreGraphics
import Foundation
import ImageIO
import Metal
import SwifttyCore

private func apc(_ body: String) -> [UInt8] {
  Array("\u{1B}_G\(body)\u{1B}\\".utf8)
}

/// Chunked direct transmission of `rgba`, as kitty's clients send it.
private func transmission(
  id: Int,
  width: Int,
  height: Int,
  rgba: [UInt8],
  format: Int = 32
) -> [UInt8] {
  let encoded = Array(Data(rgba).base64EncodedString().utf8)
  var out: [UInt8] = []
  out.reserveCapacity(encoded.count + encoded.count / 4096 * 16 + 64)
  var i = 0
  var first = true
  while i < encoded.count {
    let end = min(encoded.count, i + 4096)
    let more = end < encoded.count ? 1 : 0
    let keys =
      first
      ? "a=t,f=\(format),s=\(width),v=\(height),i=\(id),q=2,m=\(more)"
      : "m=\(more)"
    out +=
      Array("\u{1B}_G\(keys);".utf8) + encoded[i ..< end]
      + Array("\u{1B}\\".utf8)
    first = false
    i = end
  }
  return out
}

private func median(_ samples: [Double]) -> Double {
  let s = samples.sorted()
  return s.isEmpty ? 0 : s[s.count / 2]
}

private func kittyPercentile(_ samples: [Double], _ p: Double) -> Double {
  let s = samples.sorted()
  guard !s.isEmpty else { return 0 }
  return s[min(s.count - 1, Int(Double(s.count - 1) * p))]
}

private func now() -> Double {
  Double(DispatchTime.now().uptimeNanoseconds) / 1e6
}

private func gradient(_ w: Int, _ h: Int) -> [UInt8] {
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

private func pngData(_ w: Int, _ h: Int) -> [UInt8] {
  let rgba = gradient(w, h)
  let space = CGColorSpace(name: CGColorSpace.sRGB)!
  let provider = CGDataProvider(data: Data(rgba) as CFData)!
  let image = CGImage(
    width: w,
    height: h,
    bitsPerComponent: 8,
    bitsPerPixel: 32,
    bytesPerRow: w * 4,
    space: space,
    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
    provider: provider,
    decode: nil,
    shouldInterpolate: false,
    intent: .defaultIntent
  )!
  let data = NSMutableData()
  let dest = CGImageDestinationCreateWithData(
    data as CFMutableData,
    "public.png" as CFString,
    1,
    nil
  )!
  CGImageDestinationAddImage(dest, image, nil)
  CGImageDestinationFinalize(dest)
  return [UInt8](data as Data)
}

func runKittyBenchmarks() {
  let repeats = max(options.repeats, 5)

  if selected("kitty-transmit") {
    let (w, h) = (3840, 2160)
    let bytes = transmission(id: 1, width: w, height: h, rgba: gradient(w, h))
    var samples: [Double] = []
    for _ in 0 ..< repeats {
      var state = TerminalState(columns: 120, rows: 40)
      var parser = Parser()
      let start = now()
      parser.consume(bytes.span, into: &state)
      samples.append(now() - start)
    }
    row(
      "kitty-transmit",
      [
        ("image", "\(w)x\(h)"), ("MB", fmt(Double(bytes.count) / 1_048_576)),
        ("median_ms", fmt(median(samples), 2)),
        (
          "MB/s",
          fmt(Double(bytes.count) / 1_048_576 / (median(samples) / 1000))
        ),
      ]
    )
  }

  if selected("kitty-png") {
    let png = pngData(2000, 2000)
    let body =
      Array("a=t,f=100,i=1,q=2;".utf8)
      + Array(Data(png).base64EncodedString().utf8)
    let bytes = Array("\u{1B}_G".utf8) + body + Array("\u{1B}\\".utf8)
    var samples: [Double] = []
    for _ in 0 ..< repeats {
      var state = TerminalState(columns: 120, rows: 40)
      var parser = Parser()
      let start = now()
      parser.consume(bytes.span, into: &state)
      samples.append(now() - start)
    }
    row(
      "kitty-png",
      [
        ("image", "2000x2000"), ("png_KB", fmt(Double(png.count) / 1024, 0)),
        ("p50_ms", fmt(median(samples), 2)),
        ("p95_ms", fmt(kittyPercentile(samples, 0.95), 2)),
      ]
    )
  }

  if selected("kitty-placeholders") {
    // Damage one row per frame, as typing elsewhere does; or repaint the
    // whole screen (`full`), as a full-screen program redraw does.
    func snapshotTimes(
      full: Bool = true,
      _ fill: (TerminalSession) -> Void
    ) -> Double {
      let session = TerminalSession(columns: 80, rows: 40)
      session.setCellPixelSize(width: 10, height: 20)
      fill(session)
      _ = session.snapshot()
      var samples: [Double] = []
      if full {
        for i in 0 ..< max(repeats * 20, 500) {
          fill(session)
          session.feed(Array("\u{1B}[40;1H\(i % 10)".utf8))
          let start = now()
          _ = session.snapshot()
          samples.append(now() - start)
        }
        return median(samples)
      }
      fatalError("one-row frames are timed by typingTimes")
    }
    // One damaged row costs about a microsecond, near the clock's
    // resolution: time batches of 500 frames and take the median batch
    // mean. The sessions alternate batches so warm-up and frequency drift
    // affect them alike.
    func typingTimes(_ fills: [(TerminalSession) -> Void]) -> [Double] {
      let sessions = fills.map { fill in
        let session = TerminalSession(columns: 80, rows: 40)
        session.setCellPixelSize(width: 10, height: 20)
        fill(session)
        _ = session.snapshot()
        return session
      }
      let typed = (0 ..< 10).map { Array("\u{1B}[40;1H\($0)".utf8) }
      var samples = [[Double]](repeating: [], count: sessions.count)
      for _ in 0 ..< max(repeats * 6, 30) {
        for (k, session) in sessions.enumerated() {
          var spent = 0.0
          for i in 0 ..< 500 {
            session.feed(typed[i % 10])
            let start = now()
            _ = session.snapshot()
            spent += now() - start
          }
          samples[k].append(spent / 500)
        }
      }
      return samples.map(median)
    }
    func asciiText(_ s: TerminalSession) {
      s.feed(Array("\u{1B}[H".utf8))
      for _ in 0 ..< 39 {
        s.feed(Array((String(repeating: "x", count: 80) + "\r\n").utf8))
      }
    }
    let placeholderLines: [[UInt8]] = (0 ..< 39)
      .map { row in
        let d = KittyGraphics.diacritics
        var line = ""
        for column in 0 ..< 80 {
          line.unicodeScalars.append(Unicode.Scalar(KittyGraphics.placeholder)!)
          line.unicodeScalars.append(Unicode.Scalar(d[row])!)
          line.unicodeScalars.append(Unicode.Scalar(d[column])!)
        }
        return Array((line + "\r\n").utf8)
      }
    func placeholderText(_ s: TerminalSession) {
      s.feed(Array("\u{1B}[H\u{1B}[38;5;42m".utf8))
      for line in placeholderLines { s.feed(line) }
    }
    let rgb = Data(
      gradient(8, 8).enumerated()
        .compactMap { $0.offset % 4 == 3 ? nil : $0.element }
    )
    func withImage(_ s: TerminalSession) {
      s.feed(
        apc(
          "a=T,U=1,f=24,s=8,v=8,i=42,c=80,r=39,q=2;" + rgb.base64EncodedString()
        )
      )
      placeholderText(s)
    }
    // The same text without an image: the cost of grapheme cells alone.
    let typing = typingTimes([asciiText, placeholderText, withImage])
    let (ascii, text, placeholders) = (typing[0], typing[1], typing[2])
    let asciiFull = snapshotTimes(full: true, asciiText)
    let textFull = snapshotTimes(full: true, placeholderText)
    let placeholdersFull = snapshotTimes(full: true, withImage)
    row(
      "kitty-placeholders",
      [
        ("ascii_us", fmt(ascii * 1000, 2)),
        ("text_only_us", fmt(text * 1000, 2)),
        ("placeholder_us", fmt(placeholders * 1000, 2)),
        ("ratio", fmt(placeholders / max(ascii, 1e-9), 2)),
        ("full_ascii_us", fmt(asciiFull * 1000, 1)),
        ("full_text_us", fmt(textFull * 1000, 1)),
        ("full_placeholder_us", fmt(placeholdersFull * 1000, 1)),
        ("full_vs_text", fmt(placeholdersFull / max(textFull, 1e-9), 2)),
      ]
    )
  }

  if selected("kitty-render"), let device {
    guard
      let renderer = try? MetalRenderer(
        device: device,
        fontManager: CoreTextFontManager(),
        font: FontDescriptor(size: 13)
      )
    else { return }
    let session = TerminalSession(columns: 120, rows: 40)
    session.setCellPixelSize(
      width: Int(renderer.cellSize.width),
      height: Int(renderer.cellSize.height)
    )
    let (w, h) = (3840, 2160)
    guard let target = offscreenTarget(renderer, columns: 120, rows: 40) else {
      return
    }
    var uploads: [Double] = []
    var steady: [Double] = []
    for i in 0 ..< repeats {
      session.feed(
        transmission(id: i + 1, width: w, height: h, rgba: gradient(w, h))
      )
      session.feed(
        Array("\u{1B}[H".utf8) + apc("a=p,i=\(i + 1),c=120,r=40,C=1,q=2")
      )
      let snapshot = session.snapshot()
      var start = now()
      waitForFrame(
        renderer,
        try renderer.render(snapshot, to: target),
        benchmark: "kitty-render"
      )
      uploads.append(now() - start)
      start = now()
      waitForFrame(
        renderer,
        try renderer.render(snapshot, to: target),
        benchmark: "kitty-render"
      )
      steady.append(now() - start)
    }
    row(
      "kitty-render",
      [
        ("image", "\(w)x\(h)"), ("upload_frame_ms", fmt(median(uploads), 2)),
        ("steady_frame_ms", fmt(median(steady), 2)),
        ("120Hz_budget_ms", "8.33"),
      ]
    )
  }

  if selected("kitty-file") {
    let path = NSTemporaryDirectory() + "swiftty-bench-tty-graphics-protocol"
    let (w, h) = (10_000, 10_000)
    let raw = [UInt8](repeating: 7, count: w * h * 4)
    FileManager.default.createFile(atPath: path, contents: Data(raw))
    defer { unlink(path) }
    var samples: [Double] = []
    for _ in 0 ..< repeats {
      var state = TerminalState(columns: 120, rows: 40)
      state.imageStorageLimit = 400_000_000
      state.kittyGraphicsMedia = .all
      var parser = Parser()
      let start = now()
      parser.consume(
        apc(
          "a=t,t=f,f=32,s=\(w),v=\(h),i=1,q=1;"
            + Data(path.utf8).base64EncodedString()
        )
        .span,
        into: &state
      )
      samples.append(now() - start)
      if !state.output.isEmpty {
        row(
          "kitty-file",
          [("error", String(decoding: state.output, as: UTF8.self))]
        )
        return
      }
    }
    row(
      "kitty-file",
      [
        ("MB", fmt(Double(raw.count) / 1_048_576, 0)),
        ("median_ms", fmt(median(samples), 1)), ("bound_ms", "250"),
      ]
    )
  }
}
