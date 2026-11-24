/// Kitty graphics animation: frames, composition and playback.
///
/// Ported from Ghostty's `graphics_animation.zig`, `graphics_pixel.zig`
/// and the animation parts of `graphics_exec.zig`/`graphics_storage.zig`
/// at 167acf0c. Frames are composed eagerly into full RGBA canvases;
/// frame 1 is the image's own pixels.
extension KittyGraphics {
  static let defaultGapMilliseconds: UInt32 = 40

  struct Animation {
    struct Frame {
      var pixels: KittyImagePixels
      var gap: UInt32
    }

    enum State { case stopped, loading, running }

    var frames: [Frame] = []
    var rootGap: UInt32 = 0
    var currentIndex: UInt32 = 0
    var state = State.stopped
    var maxLoops: UInt32 = 0
    var currentLoop: UInt32 = 0
    var frameShownAt: UInt64?

    var frameCount: UInt32 { UInt32(frames.count + 1) }
    var byteCount: Int { frames.reduce(0) { $0 + $1.pixels.bytes.count } }

    func gap(at index: UInt32) -> UInt32 {
      index == 0 ? rootGap : frames[Int(index) - 1].gap
    }

    mutating func setGap(at index: UInt32, _ gap: UInt32) {
      if index == 0 { rootGap = gap } else { frames[Int(index) - 1].gap = gap }
    }

    var duration: UInt64 {
      frames.reduce(UInt64(rootGap)) { $0 + UInt64($1.gap) }
    }
  }

  /// `a=f` keys.
  struct FrameLoad {
    var transmission: Transmission
    var x: UInt32
    var y: UInt32
    var baseFrame: UInt32
    var editFrame: UInt32
    var gap: Int32
    var overwrite: Bool
    var background: UInt32

    init?(_ c: Command) {
      guard let t = Transmission(c) else { return nil }
      transmission = t
      x = c.value("x")
      y = c.value("y")
      baseFrame = c.value("c")
      editFrame = c.value("r")
      gap = c.signed("z")
      overwrite = c.value("X") == 1
      background = c.value("Y")
    }
  }

  // MARK: Pixels

  static func fillBackground(_ data: inout [UInt8], _ background: UInt32) {
    if background == 0 {
      for i in data.indices { data[i] = 0 }
      return
    }
    let r = UInt8(background >> 24)
    let g = UInt8(background >> 16 & 0xFF)
    let b = UInt8(background >> 8 & 0xFF)
    let a = UInt8(background & 0xFF)
    var i = 0
    while i + 4 <= data.count {
      data[i] = r
      data[i + 1] = g
      data[i + 2] = b
      data[i + 3] = a
      i += 4
    }
  }

  /// Straight-alpha source-over of one RGBA pixel run.
  @inline(__always)
  static func blend(
    _ dst: UnsafeMutablePointer<UInt8>,
    _ src: UnsafePointer<UInt8>,
    count: Int,
    overwrite: Bool
  ) {
    if overwrite {
      dst.update(from: src, count: count * 4)
      return
    }
    for p in 0 ..< count {
      let s = src + p * 4
      let d = dst + p * 4
      let sa = UInt32(s[3])
      if sa == 255 {
        d.update(from: s, count: 4)
        continue
      }
      if sa == 0 { continue }
      let da = UInt32(d[3])
      // outA = sa + da (1 - sa), in units of 255².
      let outA = sa * 255 + da * (255 - sa)
      guard outA > 0 else { continue }
      for c in 0 ..< 3 {
        let v =
          (UInt32(s[c]) * sa * 255 + UInt32(d[c]) * da * (255 - sa) + outA / 2)
          / outA
        d[c] = UInt8(min(v, 255))
      }
      d[3] = UInt8((outA + 127) / 255)
    }
  }

  static func composeRect(
    _ dst: inout [UInt8],
    width dw: UInt32,
    height dh: UInt32,
    _ src: [UInt8],
    width sw: UInt32,
    height sh: UInt32,
    x: UInt32,
    y: UInt32,
    overwrite: Bool
  ) {
    guard x < dw, y < dh else { return }
    let w = Int(min(sw, dw - x))
    let h = Int(min(sh, dh - y))
    dst.withUnsafeMutableBufferPointer { d in
      src.withUnsafeBufferPointer { s in
        for row in 0 ..< h {
          let dOff = ((Int(y) + row) * Int(dw) + Int(x)) * 4
          let sOff = row * Int(sw) * 4
          blend(
            d.baseAddress! + dOff,
            s.baseAddress! + sOff,
            count: w,
            overwrite: overwrite
          )
        }
      }
    }
  }

  static func composeCanvasRect(
    _ dst: inout [UInt8],
    _ src: [UInt8],
    canvasWidth: UInt32,
    width: Int,
    height: Int,
    srcX: UInt32,
    srcY: UInt32,
    dstX: UInt32,
    dstY: UInt32,
    overwrite: Bool
  ) {
    dst.withUnsafeMutableBufferPointer { d in
      src.withUnsafeBufferPointer { s in
        for row in 0 ..< height {
          let dOff = ((Int(dstY) + row) * Int(canvasWidth) + Int(dstX)) * 4
          let sOff = ((Int(srcY) + row) * Int(canvasWidth) + Int(srcX)) * 4
          blend(
            d.baseAddress! + dOff,
            s.baseAddress! + sOff,
            count: width,
            overwrite: overwrite
          )
        }
      }
    }
  }
}

extension KittyGraphics.Image {
  /// Pixels of 1-based frame `number`; nil when it does not exist or is
  /// still pending.
  func frame(_ number: UInt32) -> KittyImagePixels? {
    switch number {
    case 0: return nil
    case 1: return pixels
    default:
      guard let animation, Int(number) - 2 < animation.frames.count else {
        return nil
      }
      return animation.frames[Int(number) - 2].pixels
    }
  }

  /// The pixels currently displayed: the animation's current frame.
  public var displayedPixels: KittyImagePixels? {
    guard let animation, animation.currentIndex > 0 else { return pixels }
    return frame(animation.currentIndex + 1)
  }

  mutating func setFrame(_ number: UInt32, _ pixels: KittyImagePixels) {
    if number == 1 {
      self.pixels = pixels
    } else {
      animation?.frames[Int(number) - 2].pixels = pixels
    }
  }
}
