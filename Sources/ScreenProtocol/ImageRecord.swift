import CryptoKit
import Foundation
import SessionCore

#if canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

/// Kitty graphics pixels over RST/1 (spec.graphics.md §16.3): one image per
/// server-initiated stream, `KGIB/1` with encoding 4, never inside a
/// snapshot. Frames reference images by key; the digest of the full-size
/// RGBA pixels lets clients keep images across attachment epochs.
public enum ImageVariant: String, Sendable, Hashable, Codable {
  /// Lossless, downsampled only to fit `ImageBlob.maxSide` and the
  /// record limit.
  case full
  /// At most 1024 px per side and 1 MiB: PNG when it fits, else HEIC.
  case reduced
  /// The client draws no images and asks for none.
  case off
}

public struct ImageBlob: Sendable, Equatable {
  public static let encoding: UInt8 = 4
  /// Encoded image bytes: a record stays within the screen record limit.
  public static let maxEncodedBytes = RSTLimits.maxSnapshotEncodedBytes - 58
  public static let maxSide = 4096
  public static let reducedSide = 1024
  public static let reducedBytes = 1 << 20

  public enum Codec: UInt8, Sendable {
    case png = 1
    case heic = 2
  }

  public var key: UInt64
  /// SHA-256 of the full-size straight-alpha RGBA pixels.
  public var digest: [UInt8]
  /// The image's own size, which placement source rects use.
  public var sourceWidth: UInt32
  public var sourceHeight: UInt32
  /// This variant's size.
  public var width: UInt32
  public var height: UInt32
  public var variant: ImageVariant
  public var codec: Codec
  public var data: [UInt8]

  public init(
    key: UInt64,
    digest: [UInt8],
    sourceWidth: UInt32,
    sourceHeight: UInt32,
    width: UInt32,
    height: UInt32,
    variant: ImageVariant,
    codec: Codec,
    data: [UInt8]
  ) {
    self.key = key
    self.digest = digest
    self.sourceWidth = sourceWidth
    self.sourceHeight = sourceHeight
    self.width = width
    self.height = height
    self.variant = variant
    self.codec = codec
    self.data = data
  }

  public var digestHex: String {
    digest.map { String(format: "%02x", $0) }.joined()
  }

  /// A snapshot-stream record: `UInt8(4) UInt32BE length UInt32BE length`
  /// then the 58-byte image header and the encoded image, so transports
  /// bound it like any screen record.
  public func encoded() -> [UInt8] {
    var body: [UInt8] = []
    for i in 0 ..< 8 { body.append(UInt8(key >> (56 - 8 * UInt64(i)) & 0xFF)) }
    body += digest
    for v in [sourceWidth, sourceHeight, width, height] {
      appendUInt32(v, to: &body)
    }
    body.append(variant == .reduced ? 1 : 0)
    body.append(codec.rawValue)
    body += data
    var out: [UInt8] = [Self.encoding]
    appendUInt32(UInt32(body.count), to: &out)
    appendUInt32(UInt32(body.count), to: &out)
    return out + body
  }

  public static func isRecord(_ bytes: [UInt8]) -> Bool {
    bytes.first == encoding
  }

  static let headerBytes = 58

  public static func decode(_ bytes: [UInt8]) throws(FramingError) -> ImageBlob
  {
    guard let header = try SnapshotFrame.header(bytes),
      header.encoding == .imageBlob
    else { throw .invalidFrame("image encoding") }
    guard bytes.count == SnapshotFrame.headerLength + header.encodedLength
    else {
      throw bytes.count < SnapshotFrame.headerLength + header.encodedLength
        ? .truncated : .trailingData
    }
    let b = Array(bytes[SnapshotFrame.headerLength...])
    guard b.count >= headerBytes else { throw .truncated }
    let key = b[0 ..< 8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    let digest = Array(b[8 ..< 40])
    let sw = readUInt32(b, at: 40)
    let sh = readUInt32(b, at: 44)
    let w = readUInt32(b, at: 48)
    let h = readUInt32(b, at: 52)
    guard b[56] <= 1, let codec = Codec(rawValue: b[57]) else {
      throw .invalidFrame("image codec")
    }
    guard (1 ... 10_000).contains(sw), (1 ... 10_000).contains(sh),
      (1 ... UInt32(maxSide)).contains(w), (1 ... UInt32(maxSide)).contains(h),
      w <= sw, h <= sh
    else { throw .invalidFrame("image size") }
    return ImageBlob(
      key: key,
      digest: digest,
      sourceWidth: sw,
      sourceHeight: sh,
      width: w,
      height: h,
      variant: b[56] == 1 ? .reduced : .full,
      codec: codec,
      data: Array(b[headerBytes...])
    )
  }
}

#if canImport(ImageIO)
/// Host-side variant encoding and client-side bounded decoding, with
/// ImageIO pinned to the declared container type.
public enum ImageBlobCodec {
  public static func digest(rgba: [UInt8]) -> [UInt8] {
    Array(SHA256.hash(data: rgba))
  }

  /// Encodes straight-alpha RGBA as `variant` (the user's decision in
  /// spec.graphics.md §24): lossless PNG for `full`, shrinking only to fit;
  /// for `reduced`, PNG when it fits 1 MiB, else HEIC from quality 0.75
  /// down to 0.5, then halved dimensions.
  public static func encode(
    key: UInt64,
    rgba: [UInt8],
    width: Int,
    height: Int,
    variant: ImageVariant
  ) -> ImageBlob? {
    guard variant != .off, width > 0, height > 0,
      rgba.count == width * height * 4
    else { return nil }
    let digest = digest(rgba: rgba)
    let limitSide = variant == .full ? ImageBlob.maxSide : ImageBlob.reducedSide
    let limitBytes =
      variant == .full ? ImageBlob.maxEncodedBytes : ImageBlob.reducedBytes
    var scale = min(1, Double(limitSide) / Double(max(width, height)))
    for _ in 0 ..< 8 {
      let w = max(1, Int((Double(width) * scale).rounded()))
      let h = max(1, Int((Double(height) * scale).rounded()))
      guard let image = cgImage(rgba: rgba, width: width, height: height),
        let scaled = resize(image, width: w, height: h)
      else { return nil }
      func blob(_ codec: ImageBlob.Codec, _ data: [UInt8]) -> ImageBlob {
        ImageBlob(
          key: key,
          digest: digest,
          sourceWidth: UInt32(width),
          sourceHeight: UInt32(height),
          width: UInt32(w),
          height: UInt32(h),
          variant: variant,
          codec: codec,
          data: data
        )
      }
      if let png = write(scaled, type: "public.png", quality: nil),
        png.count <= limitBytes
      {
        return blob(.png, png)
      }
      if variant == .reduced {
        for quality in [0.75, 0.65, 0.55, 0.5] {
          if let heic = write(scaled, type: "public.heic", quality: quality),
            heic.count <= limitBytes
          {
            return blob(.heic, heic)
          }
        }
      }
      scale /= 2
    }
    return nil
  }

  /// Straight-alpha RGBA, or nil unless the data is the declared
  /// container with the blob's dimensions.
  public static func decode(_ blob: ImageBlob) -> [UInt8]? {
    let type = blob.codec == .png ? "public.png" : "public.heic"
    let options =
      [
        kCGImageSourceTypeIdentifierHint: type,
        kCGImageSourceShouldCache: false,
      ] as CFDictionary
    guard
      let source = CGImageSourceCreateWithData(
        Data(blob.data) as CFData,
        options
      ), let actual = CGImageSourceGetType(source), (actual as String) == type,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options)
        as? [CFString: Any],
      (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        == Int(blob.width),
      (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        == Int(blob.height),
      let image = CGImageSourceCreateImageAtIndex(source, 0, options),
      let space = CGColorSpace(name: CGColorSpace.sRGB)
    else { return nil }
    let (w, h) = (Int(blob.width), Int(blob.height))
    var out = [UInt8](repeating: 0, count: w * h * 4)
    let drawn = out.withUnsafeMutableBytes { raw -> Bool in
      guard
        let context = CGContext(
          data: raw.baseAddress,
          width: w,
          height: h,
          bitsPerComponent: 8,
          bytesPerRow: w * 4,
          space: space,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
      else { return false }
      context.setBlendMode(.copy)
      context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
      return true
    }
    guard drawn else { return nil }
    unpremultiply(&out)
    return out
  }

  static func unpremultiply(_ out: inout [UInt8]) {
    out.withUnsafeMutableBufferPointer { p in
      var i = 0
      while i < p.count {
        let a = UInt32(p[i + 3])
        if a != 0, a != 255 {
          for c in 0 ..< 3 {
            p[i + c] = UInt8(min(255, (UInt32(p[i + c]) * 255 + a / 2) / a))
          }
        }
        i += 4
      }
    }
  }

  static func cgImage(rgba: [UInt8], width: Int, height: Int) -> CGImage? {
    guard let provider = CGDataProvider(data: Data(rgba) as CFData),
      let space = CGColorSpace(name: CGColorSpace.sRGB)
    else { return nil }
    return CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: width * 4,
      space: space,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: true,
      intent: .defaultIntent
    )
  }

  static func resize(_ image: CGImage, width: Int, height: Int) -> CGImage? {
    guard width != image.width || height != image.height else { return image }
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { return nil }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
  }

  static func write(
    _ image: CGImage,
    type: String,
    quality: Double?
  ) -> [UInt8]? {
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data as CFMutableData,
        type as CFString,
        1,
        nil
      )
    else { return nil }
    let options: [CFString: Any] =
      quality.map { [kCGImageDestinationLossyCompressionQuality: $0] } ?? [:]
    CGImageDestinationAddImage(destination, image, options as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return [UInt8](data as Data)
  }
}
#endif
