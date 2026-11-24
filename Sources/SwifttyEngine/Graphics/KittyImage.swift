import Darwin
import Foundation
import Synchronization
import ZlibCodec

#if canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

/// Kitty graphics images, chunked loads, transmission media and decoding.
///
/// Ported from Ghostty's `src/terminal/kitty/graphics_image.zig` at
/// 167acf0c. Deviations (spec.graphics.md §19):
/// - D3: a file read is abandoned after 250 ms.
/// - D4: in-flight chunk data is also capped by the storage limit.
/// - D6: file, temporary-file and shared-memory media are refused unless
///   the embedder allows them (`TerminalState.kittyGraphicsMedia`).
/// - D8: Darwin temporary directories and `F_GETPATH` canonicalisation.
/// PNG is decoded with ImageIO, pinned to `public.png`.

/// Immutable pixels of a completed image, shared without copying by
/// snapshots, frames and caches.
public final class KittyImagePixels: Sendable {
  public let width: Int
  public let height: Int
  /// 1 (gray), 2 (gray+alpha), 3 (RGB) or 4 (RGBA), straight alpha.
  public let bytesPerPixel: Int
  public let bytes: [UInt8]
  /// Unique within the process: frames reference pixels by it. Client
  /// caches can outlive the process that issued a serial (worker
  /// replacement, session switch), so each process counts from a random
  /// base and its serials do not repeat an earlier process's.
  public let serial: UInt64

  private static let serials = Atomic<UInt64>(
    UInt64.random(in: 0 ..< 1 << 31) << 32
  )

  init(width: Int, height: Int, bytesPerPixel: Int, bytes: [UInt8]) {
    precondition(bytes.count == width * height * bytesPerPixel)
    self.width = width
    self.height = height
    self.bytesPerPixel = bytesPerPixel
    self.bytes = bytes
    serial = Self.serials.add(1, ordering: .relaxed).newValue
  }

  /// Pixels received from a host (frames, roaming); nil unless the
  /// sizes are within the protocol limits and agree with `bytes`.
  public convenience init?(
    receivedWidth width: Int,
    height: Int,
    bytesPerPixel: Int,
    bytes: [UInt8]
  ) {
    guard width > 0, height > 0, width <= Int(KittyGraphics.maxDimension),
      height <= Int(KittyGraphics.maxDimension),
      (1 ... 4).contains(bytesPerPixel),
      bytes.count == width * height * bytesPerPixel
    else { return nil }
    self.init(
      width: width,
      height: height,
      bytesPerPixel: bytesPerPixel,
      bytes: bytes
    )
  }

  /// RGBA expansion of these pixels.
  public func rgba() -> [UInt8] {
    if bytesPerPixel == 4 { return bytes }
    var out = [UInt8](repeating: 255, count: width * height * 4)
    let n = width * height
    bytes.withUnsafeBufferPointer { src in
      out.withUnsafeMutableBufferPointer { dst in
        for i in 0 ..< n {
          switch bytesPerPixel {
          case 3:
            dst[i * 4] = src[i * 3]
            dst[i * 4 + 1] = src[i * 3 + 1]
            dst[i * 4 + 2] = src[i * 3 + 2]
          case 2:
            let g = src[i * 2]
            (dst[i * 4], dst[i * 4 + 1], dst[i * 4 + 2]) = (g, g, g)
            dst[i * 4 + 3] = src[i * 2 + 1]
          default:
            let g = src[i]
            (dst[i * 4], dst[i * 4 + 1], dst[i * 4 + 2]) = (g, g, g)
          }
        }
      }
    }
    return out
  }
}

extension KittyGraphics {
  /// Transmission media a terminal may read in addition to `direct`.
  public struct Media: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let file = Media(rawValue: 1 << 0)
    public static let temporaryFile = Media(rawValue: 1 << 1)
    public static let sharedMemory = Media(rawValue: 1 << 2)
    /// Direct transmission only: the default, and the only safe choice
    /// when the program runs on another machine.
    public static let direct: Media = []
    /// Every medium: programs on this Mac.
    public static let all: Media = [.file, .temporaryFile, .sharedMemory]
  }

  enum LoadError: Error, Equatable {
    case outOfMemory, insufficientData, invalidData, decompressionFailed
    case temporaryFileNotInTempDir, temporaryFileNotNamedCorrectly
    case unsupportedFormat, unsupportedMedium
    case dimensionsRequired, dimensionsTooLarge

    var message: String {
      switch self {
      case .outOfMemory: "ENOMEM: out of memory"
      case .insufficientData: "ENODATA: insufficient data"
      case .invalidData: "EINVAL: invalid data"
      case .decompressionFailed: "EINVAL: decompression failed"
      case .temporaryFileNotInTempDir: "EINVAL: temporary file not in temp dir"
      case .temporaryFileNotNamedCorrectly:
        "EINVAL: temporary file not named correctly"
      case .unsupportedFormat: "EINVAL: unsupported format"
      case .unsupportedMedium: "EINVAL: unsupported medium"
      case .dimensionsRequired: "EINVAL: dimensions required"
      case .dimensionsTooLarge: "EINVAL: dimensions too large"
      }
    }
  }

  /// A stored image. `pixels` is nil while restored pixels are pending.
  struct Image {
    var id: UInt32 = 0
    var number: UInt32 = 0
    var width: UInt32 = 0
    var height: UInt32 = 0
    var format = Format.rgba
    var compressed = false
    var transient = false
    var implicitID = false
    var pixels: KittyImagePixels?
    var placementCount = 0
    /// Displayed pixels changed: texture and blob cache key.
    var generation: UInt64 = 0
    /// Identity of this transmission.
    var transmission: UInt64 = 0
    var animation: Animation?

    var storageSize: Int {
      (pixels?.bytes.count ?? Int(width) * Int(height)
        * max(format.bytesPerPixel, 1)) + (animation?.byteCount ?? 0)
    }
  }

  /// An image being received, possibly over several chunks.
  struct LoadingImage {
    var image: Image
    var data: [UInt8] = []
    var display: Display?
    var frame: FrameContext?
    var quiet: Command.Quiet
    var response: Response
    /// Accumulated-data cap: `min(maxSize, storage limit)` (D4).
    var dataLimit: Int

    struct FrameContext {
      var command: FrameLoad
      var imageGeneration: UInt64
    }

    init(
      command: Command,
      transmission t: Transmission,
      media: Media,
      storageLimit: Int,
      display: Display?
    ) throws(LoadError) {
      if t.formatUnknown { throw .unsupportedFormat }
      image = Image(
        id: t.imageID,
        number: t.imageNumber,
        width: t.width,
        height: t.height,
        format: t.format,
        compressed: t.compressed,
        transient: t.transient
      )
      self.display = display
      quiet = command.quiet
      response = Response(
        id: t.imageID,
        imageNumber: t.imageNumber,
        placementID: t.placementID
      )
      dataLimit = min(KittyGraphics.maxSize, max(0, storageLimit))
      if t.medium == .direct {
        // Reserve the raw size of a chunked transmission once.
        if t.moreChunks, !t.compressed, t.format != .png, t.width > 0,
          t.height > 0, t.width <= KittyGraphics.maxDimension,
          t.height <= KittyGraphics.maxDimension
        {
          let raw = Int(t.width) * Int(t.height) * t.format.bytesPerPixel
          if raw <= dataLimit { data.reserveCapacity(raw) }
        }
        try addData(command.payload)
        return
      }
      #if !canImport(ImageIO)
      if t.format == .png { throw .unsupportedMedium }
      #endif
      switch t.medium {
      case .direct: break
      case .file: guard media.contains(.file) else { throw .unsupportedMedium }
      case .temporaryFile:
        guard media.contains(.temporaryFile) else { throw .unsupportedMedium }
      case .sharedMemory:
        guard media.contains(.sharedMemory) else { throw .unsupportedMedium }
      }
      guard !command.payload.contains(0) else { throw .invalidData }
      let path = String(decoding: command.payload, as: UTF8.self)
      switch t.medium {
      case .direct: break
      case .file, .temporaryFile:
        data = try Self.readFile(
          path,
          temporary: t.medium == .temporaryFile,
          t,
          limit: dataLimit
        )
      case .sharedMemory:
        data = try Self.readSharedMemory(path, t, limit: dataLimit)
      }
    }

    mutating func addData(_ bytes: [UInt8]) throws(LoadError) {
      guard !bytes.isEmpty else { return }
      guard bytes.count <= KittyGraphics.maxSize - data.count else {
        throw .invalidData
      }
      guard bytes.count <= dataLimit - data.count else { throw .outOfMemory }
      data.append(contentsOf: bytes)
    }

    /// Decompresses, decodes and validates the data into an image.
    mutating func complete() throws(LoadError) -> Image {
      if image.compressed {
        do {
          data = try Zlib.decompress(data, limit: dataLimit)
        } catch .outputLimit {
          // Past the storage budget the image could never be stored.
          throw dataLimit < KittyGraphics.maxSize
            ? .outOfMemory : .decompressionFailed
        } catch { throw .decompressionFailed }
        image.compressed = false
      }
      if image.format == .png { try decodePNG() }
      if image.width == 0 || image.height == 0 { throw .dimensionsRequired }
      if image.width > KittyGraphics.maxDimension
        || image.height > KittyGraphics.maxDimension
      {
        throw .dimensionsTooLarge
      }
      let expected =
        Int(image.width) * Int(image.height) * image.format.bytesPerPixel
      if frame != nil {
        if data.count < expected { throw .insufficientData }
        data.removeLast(data.count - expected)
      } else if data.count != expected {
        throw .invalidData
      }
      var result = image
      result.pixels = KittyImagePixels(
        width: Int(image.width),
        height: Int(image.height),
        bytesPerPixel: image.format.bytesPerPixel,
        bytes: data
      )
      data = []
      return result
    }

    private mutating func decodePNG() throws(LoadError) {
      #if canImport(ImageIO)
      guard let decoded = PNG.decode(data, limit: dataLimit) else {
        throw .invalidData
      }
      switch decoded {
      case .overLimit: throw .outOfMemory
      case let .tooLarge(w, h):
        image.width = w
        image.height = h
        throw .dimensionsTooLarge
      case let .pixels(w, h, rgba):
        data = rgba
        image.width = w
        image.height = h
        image.format = .rgba
      }
      #else
      throw .unsupportedFormat
      #endif
    }

    // MARK: Media

    /// Darwin temporary directories a `t=t` file may live in.
    static let temporaryDirectories: [String] = {
      var dirs = ["/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp"]
      var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
      let n = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
      if n > 0, n <= buffer.count {
        let dir = string(nulTerminated: buffer)
        dirs.append(dir)
        if let real = realpath(dir, nil) {
          dirs.append(String(cString: real))
          free(real)
        }
      }
      return dirs.map {
        $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0
      }
    }()

    /// The string before the first NUL in `buffer`, as `String(cString:)`
    /// read it (invalid UTF-8 is repaired).
    static func string(nulTerminated buffer: [CChar]) -> String {
      String(
        decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
        as: UTF8.self
      )
    }

    /// Ghostty's `isPathInDir`: an empty directory contains nothing and a
    /// trailing separator is ignored.
    static func isPath(_ path: String, inside dir: String) -> Bool {
      guard !dir.isEmpty else { return false }
      let d = dir.count > 1 && dir.hasSuffix("/") ? String(dir.dropLast()) : dir
      return path == d || path.hasPrefix(d == "/" ? "/" : d + "/")
    }

    static func readFile(
      _ path: String,
      temporary: Bool,
      _ t: Transmission,
      limit: Int
    ) throws(LoadError) -> [UInt8] {
      let fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
      guard fd >= 0 else { throw .invalidData }
      defer { close(fd) }
      // Canonicalise the opened file, not the name: a swapped symlink
      // cannot redirect the checks below.
      var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
      guard fcntl(fd, F_GETPATH, &buffer) == 0 else { throw .invalidData }
      let canonical = string(nulTerminated: buffer)
      guard !isPath(canonical, inside: "/dev") else { throw .invalidData }
      if temporary {
        guard
          temporaryDirectories.contains(where: { isPath(canonical, inside: $0) }
          )
        else { throw .temporaryFileNotInTempDir }
        guard canonical.contains("tty-graphics-protocol") else {
          throw .temporaryFileNotNamedCorrectly
        }
      }
      defer { if temporary { unlink(canonical) } }
      var info = stat()
      guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
        throw .invalidData
      }
      let available = Int(info.st_size)
      let offset = Int(t.offset)
      guard offset <= available else { throw .invalidData }
      let wanted = t.size > 0 ? Int(t.size) : available - offset
      guard wanted <= min(limit, KittyGraphics.maxSize) else {
        throw .invalidData
      }
      guard t.size == 0 || offset + wanted <= available else {
        throw .invalidData
      }
      var out = [UInt8](repeating: 0, count: wanted)
      let deadline = DispatchTime.now().uptimeNanoseconds + 250_000_000
      var done = 0
      while done < wanted {
        let n = out.withUnsafeMutableBytes { raw in
          pread(
            fd,
            raw.baseAddress! + done,
            min(64 << 10, wanted - done),
            off_t(offset + done)
          )
        }
        if n < 0, errno == EINTR || errno == EAGAIN {
          guard DispatchTime.now().uptimeNanoseconds < deadline else {
            throw .invalidData
          }
          continue
        }
        guard n > 0 else { throw .invalidData }
        done += n
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
          throw .invalidData
        }
      }
      return out
    }

    /// `shm_open` is variadic and unavailable in Swift; the read-only
    /// open passes no variadic argument, so the plain C signature is ABI
    /// compatible.
    private typealias ShmOpen =
      @convention(c) (UnsafePointer<CChar>, Int32) -> Int32
    private static let shmOpen: ShmOpen? = {
      guard
        let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "shm_open")
      else { return nil }
      return unsafeBitCast(symbol, to: ShmOpen.self)
    }()

    static func readSharedMemory(
      _ name: String,
      _ t: Transmission,
      limit: Int
    ) throws(LoadError) -> [UInt8] {
      let bytes = name.utf8.count
      guard bytes > 0, bytes <= 31, name != "/", let shmOpen else {
        throw .invalidData
      }
      let fd = name.withCString { shmOpen($0, O_RDONLY) }
      guard fd >= 0 else { throw .invalidData }
      defer {
        close(fd)
        shm_unlink(name)
      }
      var info = stat()
      guard fstat(fd, &info) == 0, info.st_size > 0 else { throw .invalidData }
      let available = Int(info.st_size)
      let start = Int(t.offset)
      guard start <= available else { throw .invalidData }
      let length: Int
      if t.size > 0 {
        length = Int(t.size)
      } else if !t.compressed, t.format != .png, t.width > 0, t.height > 0 {
        guard t.width <= KittyGraphics.maxDimension,
          t.height <= KittyGraphics.maxDimension
        else { throw .dimensionsTooLarge }
        length = Int(t.width) * Int(t.height) * t.format.bytesPerPixel
      } else {
        length = available - start
      }
      guard length <= min(KittyGraphics.maxSize, limit),
        length <= available - start
      else { throw .invalidData }
      guard let map = mmap(nil, available, PROT_READ, MAP_SHARED, fd, 0),
        map != MAP_FAILED
      else { throw .invalidData }
      defer { munmap(map, available) }
      return Array(UnsafeRawBufferPointer(start: map + start, count: length))
    }
  }
}

#if canImport(ImageIO)
enum PNG {
  enum Decoded {
    case pixels(width: UInt32, height: UInt32, rgba: [UInt8])
    case tooLarge(width: UInt32, height: UInt32)
    /// Decoded pixels would exceed the caller's storage budget.
    case overLimit
  }

  /// Decodes only `public.png` containers into straight-alpha sRGB RGBA.
  /// `limit` bounds the decoded bytes before anything is allocated.
  static func decode(
    _ data: [UInt8],
    limit: Int = KittyGraphics.maxSize
  ) -> Decoded? {
    let options =
      [
        kCGImageSourceTypeIdentifierHint: "public.png",
        kCGImageSourceShouldCache: false,
      ] as CFDictionary
    guard
      let source = CGImageSourceCreateWithData(Data(data) as CFData, options),
      let type = CGImageSourceGetType(source), (type as String) == "public.png",
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options)
        as? [CFString: Any],
      let w = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
      let h = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
      w > 0, h > 0,
      // Ghostty: decoded pixels past `maxSize` are invalid data; only
      // decodable images report their dimensions as too large.
      Double(w) * Double(h) * 4 <= Double(KittyGraphics.maxSize)
    else { return nil }
    guard w <= Int(KittyGraphics.maxDimension),
      h <= Int(KittyGraphics.maxDimension)
    else {
      return .tooLarge(width: UInt32(clamping: w), height: UInt32(clamping: h))
    }
    guard w * h * 4 <= limit else { return .overLimit }
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, options),
      image.width == w, image.height == h,
      let space = CGColorSpace(name: CGColorSpace.sRGB)
    else { return nil }
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
    // Kitty RGBA is straight alpha.
    out.withUnsafeMutableBufferPointer { p in
      var i = 0
      while i < p.count {
        let a = UInt32(p[i + 3])
        if a != 0, a != 255 {
          p[i] = UInt8(min(255, (UInt32(p[i]) * 255 + a / 2) / a))
          p[i + 1] = UInt8(min(255, (UInt32(p[i + 1]) * 255 + a / 2) / a))
          p[i + 2] = UInt8(min(255, (UInt32(p[i + 2]) * 255 + a / 2) / a))
        }
        i += 4
      }
    }
    return .pixels(width: UInt32(w), height: UInt32(h), rgba: out)
  }
}
#endif

/// Pixel buffers are immutable, so identity is equality.
extension KittyImagePixels: Equatable {
  public static func == (a: KittyImagePixels, b: KittyImagePixels) -> Bool {
    a === b
  }
}
