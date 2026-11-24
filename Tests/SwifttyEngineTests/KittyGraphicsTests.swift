// Kitty graphics protocol tests, ported from Ghostty's
// `src/terminal/kitty/graphics_command.zig`, `graphics_exec.zig`,
// `graphics_storage.zig`, `graphics_unicode.zig` and `render.zig` tests
// at 167acf0c, plus Swiftty's deviations (spec.graphics.md §19).
import Foundation
import Testing

@testable import SwifttyEngine
import ZlibCodec

private func apc(_ body: String) -> String { "\u{1B}_G\(body)\u{1B}\\" }

private func b64(_ bytes: [UInt8]) -> String {
  Data(bytes).base64EncodedString()
}

private func pixels(
  _ w: Int,
  _ h: Int,
  bpp: Int = 4,
  value: UInt8 = 0xFF
) -> [UInt8] { [UInt8](repeating: value, count: w * h * bpp) }

/// A terminal with 10×20 px cells.
private func terminal(_ columns: Int = 10, _ rows: Int = 5) -> VT {
  var vt = VT(columns, rows)
  vt.state.cellPixelSize = (10, 20)
  return vt
}

private func parse(_ body: String) -> KittyGraphics.Command? {
  var p = KittyGraphics.CommandParser()
  let bytes = Array(body.utf8)
  bytes.withUnsafeBufferPointer { p.feed($0) }
  return p.complete()
}

private func command(_ body: String) throws -> KittyGraphics.Command {
  try #require(parse(body))
}

struct KittyGraphicsCommandTests {
  @Test
  func `transmission command defaults and keys`() throws {
    let c = try #require(parse("f=24,s=10,v=20,i=7;AAAA"))
    #expect(c.action == 0x74)
    let t = try #require(KittyGraphics.Transmission(c))
    #expect(t.format == .rgb)
    #expect(t.width == 10)
    #expect(t.height == 20)
    #expect(t.imageID == 7)
    #expect(c.payload == [0, 0, 0])
  }

  @Test
  func `payload only command is valid`() throws {
    let c = try #require(parse(";AAAA"))
    #expect(c.present == 0)
    #expect(c.payload.count == 3)
  }

  @Test
  func `ending after a key is malformed`() {
    #expect(parse("a=t,b") == nil)
    #expect(parse("a=t,") == nil)
  }

  @Test
  func `unknown long and non-letter keys are ignored`() throws {
    let c = try #require(parse("f=24,s=10,v=20,hello=world"))
    #expect(c.value("s") == 10)
    #expect(c.value("v") == 20)
    let d = try #require(parse("f=24,s=10,v=20,1=2"))
    #expect(d.value("v") == 20)
    // As in Ghostty, keys after an ignored key or value are ignored too.
    let e = try #require(parse("hello=world,i=3"))
    #expect(e.get("i") == nil)
  }

  @Test
  func `very long values make the key absent`() throws {
    let c = try #require(
      parse("f=24,s=10,v=2000000000000000000000000000000000000000")
    )
    #expect(c.value("s") == 10)
    #expect(c.get("v") == nil)
  }

  @Test
  func `integer overflow empty and negative unsigned values fail`() {
    #expect(parse("i=10000000000") == nil)
    #expect(parse("z=-9999999999") == nil)
    #expect(parse("i=,s=1") == nil)
    #expect(parse("i=-1") == nil)
    #expect(parse("i=+1") == nil)  // D2
  }

  @Test
  func `all i32 values parse for signed keys`() throws {
    #expect(try #require(parse("z=-2147483648")).signed("z") == .min)
    #expect(try #require(parse("z=2147483647")).signed("z") == .max)
    #expect(try #require(parse("H=-5")).signed("H") == -5)
  }

  @Test
  func `single non-digit values are ASCII codes`() throws {
    #expect(try #require(parse("i=a")).value("i") == 97)
  }

  @Test
  func `m is honoured only for direct transmission`() throws {
    let file = try #require(KittyGraphics.Transmission(try command("t=f,m=1")))
    #expect(!file.moreChunks)
    let direct = try #require(KittyGraphics.Transmission(try command("m=1")))
    #expect(direct.moreChunks)
  }

  @Test
  func `unknown flag values fail`() throws {
    #expect(KittyGraphics.Transmission(try command("t=x")) == nil)
    #expect(KittyGraphics.Transmission(try command("o=y")) == nil)
    #expect(KittyGraphics.Delete(try command("a=d,d=b")) == nil)
  }

  @Test
  func `quiet above two suppresses all responses`() throws {
    #expect(try #require(parse("q=5")).quiet == .failures)
    #expect(try #require(parse("q=1")).quiet == .ok)
  }

  @Test
  func `delete range command`() throws {
    let d = try #require(KittyGraphics.Delete(try command("a=d,d=R,x=1,y=6")))
    #expect(d == .range(delete: true, first: 1, last: 6))
  }

  @Test
  func `base64 skips whitespace and accepts missing padding`() {
    #expect(KittyGraphics.decodeBase64(Array("AA\nAA".utf8)) == [0, 0, 0])
    #expect(KittyGraphics.decodeBase64(Array("AQ".utf8)) == [1])
    #expect(KittyGraphics.decodeBase64(Array("AQ==".utf8)) == [1])
    #expect(KittyGraphics.decodeBase64(Array("A".utf8)) == nil)
    #expect(KittyGraphics.decodeBase64(Array("A?AA".utf8)) == nil)
    #expect(KittyGraphics.decodeBase64(Array("AQ==AA".utf8)) == nil)
  }

  @Test
  func `response encoding`() {
    #expect(
      KittyGraphics.Response(id: 1).encoded()
        == Array("\u{1B}_Gi=1;OK\u{1B}\\".utf8)
    )
    #expect(
      KittyGraphics.Response(
        id: 2,
        imageNumber: 3,
        placementID: 4,
        message: "ENOENT: x"
      )
      .encoded() == Array("\u{1B}_Gi=2,I=3,p=4;ENOENT: x\u{1B}\\".utf8)
    )
    #expect(KittyGraphics.Response().encoded() == nil)
  }
}

struct KittyGraphicsExecTests {
  @Test
  func `transmit replies OK and stores the image`() {
    var vt = terminal()
    vt.feed(apc("a=t,f=24,s=2,v=1,i=1;" + b64(pixels(2, 1, bpp: 3))))
    #expect(vt.takeOutput() == apc("i=1;OK"))
    #expect(vt.state.kittyImages.image(id: 1)?.width == 2)
  }

  @Test
  func `query validates and does not store`() {
    var vt = terminal()
    vt.feed(apc("i=31,s=1,v=1,a=q,t=d,f=24;AAAA"))
    #expect(vt.takeOutput() == apc("i=31;OK"))
    #expect(vt.state.kittyImages.images.isEmpty)
    vt.feed(apc("i=32,s=2,v=1,a=q,f=24;AAAA"))
    #expect(vt.takeOutput() == apc("i=32;EINVAL: invalid data"))
  }

  @Test
  func `disabled graphics answer nothing`() {
    var vt = terminal()
    vt.state.kittyGraphicsEnabled = false
    vt.feed(apc("i=31,s=1,v=1,a=q,t=d,f=24;AAAA"))
    #expect(vt.takeOutput() == "")
    var zero = terminal()
    zero.state.imageStorageLimit = 0
    zero.feed(apc("i=31,s=1,v=1,a=q,t=d,f=24;AAAA"))
    #expect(zero.takeOutput() == "")
  }

  @Test
  func `image id and number are mutually exclusive for every action`() {
    for action in ["t", "T", "q", "p", "d", "f", "a", "c"] {
      var vt = terminal()
      vt.feed(apc("a=\(action),i=1,I=2;AAAA"))
      #expect(
        vt.takeOutput()
          == apc("i=1,I=2;EINVAL: image ID and number are mutually exclusive")
      )
    }
  }

  @Test
  func `malformed commands get no reply`() {
    var vt = terminal()
    vt.feed(apc("a=x,i=1"))
    vt.feed(apc("a=t,i=1,t=x"))
    vt.feed(apc("a=t,i=1;!!!!"))
    vt.feed(apc("a=t,i=1,b"))
    #expect(vt.takeOutput() == "")
  }

  @Test
  func `unknown format responds with EINVAL`() {
    var vt = terminal()
    vt.feed(apc("a=t,f=99,i=1,s=1,v=1;AAAA"))
    #expect(vt.takeOutput() == apc("i=1;EINVAL: unsupported format"))
  }

  @Test
  func `dimensions are validated`() {
    var vt = terminal()
    vt.feed(apc("a=t,f=24,i=1;AAAA"))
    #expect(vt.takeOutput() == apc("i=1;EINVAL: dimensions required"))
    vt.feed(apc("a=t,f=24,i=1,s=10001,v=1;AAAA"))
    #expect(vt.takeOutput() == apc("i=1;EINVAL: dimensions too large"))
  }

  @Test
  func `quiet levels`() {
    var vt = terminal()
    let data = b64(pixels(1, 1, bpp: 3))
    vt.feed(apc("a=t,f=24,s=1,v=1,i=1,q=1;" + data))
    #expect(vt.takeOutput() == "")
    vt.feed(apc("a=t,f=24,s=2,v=1,i=2,q=1;" + data))
    #expect(vt.takeOutput() == apc("i=2;EINVAL: invalid data"))
    vt.feed(apc("a=t,f=24,s=2,v=1,i=3,q=2;" + data))
    #expect(vt.takeOutput() == "")
  }

  @Test
  func `implicit ids never respond nor replace client images`() {
    var vt = terminal()
    let data = b64(pixels(1, 1, bpp: 3))
    vt.feed(apc("a=t,f=24,s=1,v=1;" + data))
    #expect(vt.takeOutput() == "")
    #expect(vt.state.kittyImages.images.keys.first == 2_147_483_647)
  }

  @Test
  func `number-based transmission assigns smallest free id`() {
    var vt = terminal()
    let data = b64(pixels(1, 1, bpp: 3))
    vt.feed(apc("a=t,f=24,s=1,v=1,i=1;" + data))
    _ = vt.takeOutput()
    vt.feed(apc("a=t,f=24,s=1,v=1,I=9;" + data))
    #expect(vt.takeOutput() == apc("i=2,I=9;OK"))
  }

  @Test
  func `chunked transmission replies once with initial identifiers`() {
    var vt = terminal()
    let data = b64(pixels(2, 1, bpp: 3))
    let a = String(data.prefix(4))
    let b = String(data.dropFirst(4))
    vt.feed(apc("a=t,f=24,s=2,v=1,i=5,m=1;" + a))
    #expect(vt.takeOutput() == "")
    vt.feed(apc("m=0;" + b))
    #expect(vt.takeOutput() == apc("i=5;OK"))
  }

  @Test
  func `chunked error uses initial identifiers`() {
    var vt = terminal()
    vt.feed(apc("a=t,f=24,s=3,v=1,i=5,m=1;AAAA"))
    vt.feed(apc("m=0;AAAA"))
    #expect(vt.takeOutput() == apc("i=5;EINVAL: invalid data"))
  }

  @Test
  func `more chunks with increasing q`() {
    var vt = terminal()
    vt.feed(apc("a=t,f=24,s=3,v=1,i=5,m=1;AAAA"))
    vt.feed(apc("m=0,q=2;AAAA"))
    #expect(vt.takeOutput() == "")
  }

  @Test
  func `delete aborts chunked image load`() {
    var vt = terminal()
    vt.feed(apc("a=t,f=24,s=2,v=1,i=5,m=1;AAAA"))
    vt.feed(apc("a=d"))
    #expect(vt.state.kittyImages.loading == nil)
  }

  @Test
  func `retransmit same id removes existing placements`() {
    var vt = terminal()
    let data = b64(pixels(1, 1, bpp: 3))
    vt.feed(apc("a=T,f=24,s=1,v=1,i=1,q=2;" + data))
    #expect(vt.state.kittyImages.placements.count == 1)
    vt.feed(apc("a=t,f=24,s=1,v=1,i=1,q=2;" + data))
    #expect(vt.state.kittyImages.placements.isEmpty)
    #expect(vt.state.kittyImages.images.count == 1)
  }

  @Test
  func `chunked retransmit keeps image until it ends`() {
    var vt = terminal()
    let data = b64(pixels(2, 1, bpp: 3))
    vt.feed(apc("a=t,f=24,s=2,v=1,i=1,q=2;" + data))
    let first = vt.state.kittyImages.image(id: 1)!.transmission
    vt.feed(apc("a=t,f=24,s=2,v=1,i=1,q=2,m=1;" + String(data.prefix(4))))
    #expect(vt.state.kittyImages.image(id: 1)?.transmission == first)
    vt.feed(apc("m=0;" + String(data.dropFirst(4))))
    #expect(vt.state.kittyImages.image(id: 1)?.transmission != first)
  }

  @Test
  func `display requires an existing image`() {
    var vt = terminal()
    vt.feed(apc("a=p,i=9"))
    #expect(vt.takeOutput() == apc("i=9;ENOENT: image not found"))
    vt.feed(apc("a=p"))
    #expect(vt.takeOutput() == "")
  }

  @Test
  func `virtual placement cannot refer to a parent`() {
    var vt = terminal()
    vt.feed(apc("a=p,i=9,U=1,P=2"))
    #expect(
      vt.takeOutput()
        == apc("i=9;EINVAL: virtual placement cannot refer to a parent")
    )
  }

  @Test
  func `placement moves cursor past the image`() {
    var vt = terminal(10, 5)
    // 20×40 px over 10×20 cells: 2 columns, 2 rows.
    vt.feed(apc("a=T,f=24,s=20,v=40,i=1,q=2;" + b64(pixels(20, 40, bpp: 3))))
    #expect(vt.cursor == (2, 1))
  }

  @Test
  func `C=1 keeps the cursor and other values move it`() {
    var vt = terminal(10, 5)
    let data = b64(pixels(20, 40, bpp: 3))
    vt.feed(apc("a=T,f=24,s=20,v=40,i=1,q=2,C=1;" + data))
    #expect(vt.cursor == (0, 0))
    vt.feed(apc("a=p,i=1,q=2,C=2"))
    #expect(vt.cursor == (2, 1))
  }

  @Test
  func `placement bounds cursor movement for untrusted dimensions`() {
    var vt = terminal(10, 5)
    vt.feed(apc("a=t,f=24,s=1,v=1,i=1,q=2;" + b64(pixels(1, 1, bpp: 3))))
    vt.feed(apc("a=p,i=1,q=2,c=1,r=4000000000"))
    #expect(vt.cursor == (1, 4))
  }

  @Test
  func `cursor wraps when the image reaches the right edge`() {
    var vt = terminal(4, 5)
    vt.feed(apc("a=t,f=24,s=1,v=1,i=1,q=2;" + b64(pixels(1, 1, bpp: 3))))
    vt.feed(apc("a=p,i=1,q=2,c=4,r=1"))
    #expect(vt.cursor == (0, 1))
  }

  @Test
  func `display clamps cell offsets`() {
    var vt = terminal()
    vt.feed(apc("a=t,f=24,s=1,v=1,i=1,q=2;" + b64(pixels(1, 1, bpp: 3))))
    vt.feed(apc("a=p,i=1,q=2,X=99,Y=99,C=1"))
    let p = vt.state.kittyImages.placements.values.first!
    #expect(p.xOffset == 9)
    #expect(p.yOffset == 19)
  }

  @Test
  func `zlib compressed RGBA`() throws {
    var vt = terminal()
    let raw = pixels(2, 2)
    let compressed = Zlib.compress(raw)
    vt.feed(apc("a=t,f=32,o=z,s=2,v=2,i=1;" + b64(compressed)))
    #expect(vt.takeOutput() == apc("i=1;OK"))
    vt.feed(apc("a=t,f=32,o=z,s=2,v=2,i=2;" + b64([1, 2, 3, 4, 5, 6])))
    #expect(vt.takeOutput() == apc("i=2;EINVAL: decompression failed"))
  }

  @Test
  func `PNG decodes to RGBA`() throws {
    var vt = terminal()
    vt.feed(apc("a=t,f=100,i=1;" + Self.png1x1))
    #expect(vt.takeOutput() == apc("i=1;OK"))
    let image = try #require(vt.state.kittyImages.image(id: 1))
    #expect(image.width == 1)
    #expect(image.format == .rgba)
    vt.feed(apc("a=t,f=100,i=2;" + b64([1, 2, 3, 4])))
    #expect(vt.takeOutput() == apc("i=2;EINVAL: invalid data"))
  }

  /// A 1×1 opaque red PNG.
  static let png1x1 =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="

  @Test
  func `APC aborted by CAN is discarded`() {
    var vt = terminal()
    vt.feed("\u{1B}_Ga=t,f=24,s=1,v=1,i=1;AAAA\u{18}")
    #expect(vt.takeOutput() == "")
    #expect(vt.state.kittyImages.images.isEmpty)
  }

  @Test
  func `non-G APC SOS and PM are ignored`() {
    var vt = terminal()
    vt.feed(
      "\u{1B}_xyz\u{1B}\\\u{1B}XGa=q,i=1\u{1B}\\\u{1B}^Ga=q,i=1\u{1B}\\ok"
    )
    #expect(vt.takeOutput() == "")
    #expect(vt.lines[0].hasPrefix("ok"))
  }

  @Test
  func `split at every byte boundary`() {
    let stream = Array(apc("a=t,f=24,s=1,v=1,i=1;AAAA").utf8)
    for split in 1 ..< stream.count {
      var vt = terminal()
      vt.feed(bytes: Array(stream[..<split]))
      vt.feed(bytes: Array(stream[split...]))
      #expect(vt.takeOutput() == apc("i=1;OK"))
    }
  }
}

struct KittyGraphicsMediaTests {
  private func tempFile(_ name: String, _ bytes: [UInt8]) throws -> String {
    let path = NSTemporaryDirectory() + name
    try Data(bytes).write(to: URL(fileURLWithPath: path))
    return path
  }

  @Test
  func `media are refused unless allowed`() throws {
    var vt = terminal()
    let path = try tempFile("swiftty-kitty-file", pixels(1, 1, bpp: 3))
    defer { unlink(path) }
    vt.feed(apc("a=t,t=f,f=24,s=1,v=1,i=1;" + b64(Array(path.utf8))))
    #expect(vt.takeOutput() == apc("i=1;EINVAL: unsupported medium"))
    vt.state.kittyGraphicsMedia = .all
    vt.feed(apc("a=t,t=f,f=24,s=1,v=1,i=1;" + b64(Array(path.utf8))))
    #expect(vt.takeOutput() == apc("i=1;OK"))
    #expect(FileManager.default.fileExists(atPath: path))
  }

  @Test
  func `temporary files must be named and are deleted`() throws {
    var vt = terminal()
    vt.state.kittyGraphicsMedia = .all
    let bad = try tempFile("swiftty-kitty-bad", pixels(1, 1, bpp: 3))
    defer { unlink(bad) }
    vt.feed(apc("a=t,t=t,f=24,s=1,v=1,i=1;" + b64(Array(bad.utf8))))
    #expect(
      vt.takeOutput() == apc("i=1;EINVAL: temporary file not named correctly")
    )
    let good = try tempFile("tty-graphics-protocol-1", pixels(1, 1, bpp: 3))
    vt.feed(apc("a=t,t=t,f=24,s=1,v=1,i=2;" + b64(Array(good.utf8))))
    #expect(vt.takeOutput() == apc("i=2;OK"))
    #expect(!FileManager.default.fileExists(atPath: good))
  }

  @Test
  func `temporary file outside the temp directories is rejected`() throws {
    var vt = terminal()
    vt.state.kittyGraphicsMedia = .all
    let dir = FileManager.default.homeDirectoryForCurrentUser.path
    let path = dir + "/.tty-graphics-protocol-swiftty-test"
    try Data(pixels(1, 1, bpp: 3)).write(to: URL(fileURLWithPath: path))
    defer { unlink(path) }
    vt.feed(apc("a=t,t=t,f=24,s=1,v=1,i=1;" + b64(Array(path.utf8))))
    #expect(
      vt.takeOutput() == apc("i=1;EINVAL: temporary file not in temp dir")
    )
    #expect(FileManager.default.fileExists(atPath: path))
  }

  @Test
  func `regular file size rejects short data and dev is refused`() throws {
    var vt = terminal()
    vt.state.kittyGraphicsMedia = .all
    let path = try tempFile("swiftty-kitty-short", [1, 2, 3])
    defer { unlink(path) }
    vt.feed(apc("a=t,t=f,f=24,s=1,v=1,S=6,i=1;" + b64(Array(path.utf8))))
    #expect(vt.takeOutput() == apc("i=1;EINVAL: invalid data"))
    vt.feed(apc("a=t,t=f,f=24,s=1,v=1,i=2;" + b64(Array("/dev/zero".utf8))))
    #expect(vt.takeOutput() == apc("i=2;EINVAL: invalid data"))
  }

  @Test
  func `isPath respects separator boundaries`() {
    #expect(KittyGraphics.LoadingImage.isPath("/tmp/a", inside: "/tmp"))
    #expect(!KittyGraphics.LoadingImage.isPath("/tmpfoo/a", inside: "/tmp"))
  }
}

struct KittyImageStorageTests {
  @Test
  func `evicts images in priority order`() {
    var vt = terminal()
    vt.state.imageStorageLimit = 3 * 4
    let one = b64(pixels(1, 1))
    vt.feed(apc("a=t,s=1,v=1,i=1,q=2;" + one))
    vt.feed(apc("a=T,s=1,v=1,i=2,q=2;" + one))
    vt.feed(apc("a=t,s=1,v=1,i=3,q=2,N=1;" + one))
    vt.feed(apc("a=t,s=1,v=1,i=4,q=2;" + one))
    // The transient unused image goes first.
    #expect(Set(vt.state.kittyImages.images.keys) == [1, 2, 4])
    vt.feed(apc("a=t,s=1,v=1,i=5,q=2;" + one))
    #expect(Set(vt.state.kittyImages.images.keys) == [2, 4, 5])
  }

  @Test
  func `image over the limit is ENOMEM`() {
    var vt = terminal()
    vt.state.imageStorageLimit = 3
    vt.feed(apc("a=t,s=1,v=1,i=1;" + b64(pixels(1, 1))))
    #expect(vt.takeOutput() == apc("i=1;ENOMEM: out of memory"))
  }

  @Test
  func `delete all visible placements preserves scrollback`() {
    var vt = terminal(10, 3)
    let data = b64(pixels(10, 20))
    vt.feed(apc("a=T,s=10,v=20,i=1,q=2;" + data))
    vt.feed("\n\n\n\n")
    vt.feed(apc("a=p,i=1,q=2"))
    #expect(vt.state.kittyImages.placements.count == 2)
    vt.feed(apc("a=d,d=a"))
    #expect(vt.state.kittyImages.placements.count == 1)
  }

  @Test
  func `uppercase id delete preserves image when placement does not match`() {
    var vt = terminal()
    vt.feed(apc("a=t,s=1,v=1,i=1,q=2;" + b64(pixels(1, 1))))
    vt.feed(apc("a=d,d=I,i=1,p=5"))
    #expect(vt.state.kittyImages.image(id: 1) != nil)
    vt.feed(apc("a=d,d=I,i=1"))
    #expect(vt.state.kittyImages.image(id: 1) == nil)
  }

  @Test
  func `uppercase range deletes unplaced image data`() {
    var vt = terminal()
    for i in 1 ... 6 {
      vt.feed(apc("a=t,s=1,v=1,i=\(i),q=2;" + b64(pixels(1, 1))))
    }
    vt.feed(apc("a=d,d=r,x=2,y=3"))
    #expect(vt.state.kittyImages.images.count == 6)
    vt.feed(apc("a=d,d=R,x=2,y=3"))
    #expect(Set(vt.state.kittyImages.images.keys) == [1, 4, 5, 6])
    vt.feed(apc("a=d,d=R,x=5,y=0"))
    #expect(vt.state.kittyImages.images.count == 4)
  }

  @Test
  func `cell row column and z deletes`() {
    var vt = terminal(10, 5)
    vt.feed(apc("a=t,s=20,v=40,i=1,q=2;" + b64(pixels(20, 40))))
    vt.feed(apc("a=p,i=1,p=1,q=2,C=1,z=3"))
    vt.feed("\u{1B}[4;5H")
    vt.feed(apc("a=p,i=1,p=2,q=2,C=1"))
    vt.feed(apc("a=d,d=p,x=2,y=2"))
    #expect(vt.state.kittyImages.placements.count == 1)
    vt.feed(apc("a=d,d=x,x=6"))
    #expect(vt.state.kittyImages.placements.isEmpty)
    vt.feed("\u{1B}[H")
    vt.feed(apc("a=p,i=1,p=1,q=2,C=1,z=3"))
    vt.feed(apc("a=d,d=q,x=1,y=1,z=2"))
    #expect(vt.state.kittyImages.placements.count == 1)
    vt.feed(apc("a=d,d=z,z=3"))
    #expect(vt.state.kittyImages.placements.isEmpty)
    vt.feed(apc("a=p,i=1,p=1,q=2,C=1"))
    vt.feed(apc("a=d,d=y,y=2"))
    #expect(vt.state.kittyImages.placements.isEmpty)
  }

  @Test
  func `erase display reclaims unplaced images and keeps scrollback`() {
    var vt = terminal(10, 3)
    let data = b64(pixels(10, 20))
    vt.feed(apc("a=T,s=10,v=20,i=1,q=2;" + data))
    vt.feed("\n\n\n\n")
    vt.feed(apc("a=T,s=10,v=20,i=2,q=2;" + data))
    vt.feed(apc("a=t,s=10,v=20,i=3,q=2;" + data))
    vt.feed("\u{1B}[2J")
    #expect(Set(vt.state.kittyImages.images.keys) == [1])
    #expect(vt.state.kittyImages.placements.count == 1)
    vt.feed("\u{1B}[3J")
    #expect(vt.state.kittyImages.placements.isEmpty)
  }

  @Test
  func `placements follow output into history`() {
    var vt = terminal(10, 3)
    vt.feed(apc("a=T,s=10,v=20,i=1,q=2,C=1;" + b64(pixels(10, 20))))
    #expect(vt.state.kittyPlacements().first?.row == 0)
    vt.feed("\n\n\n")
    #expect(vt.state.kittyPlacements().isEmpty)
    vt.state.scrollViewport(by: 1)
    #expect(vt.state.kittyPlacements().first?.row == 0)
  }

  @Test
  func `insert and delete lines do not move placements`() {
    var vt = terminal(10, 5)
    vt.feed("\u{1B}[2;1H")
    vt.feed(apc("a=T,s=10,v=20,i=1,q=2,C=1;" + b64(pixels(10, 20))))
    vt.feed("\u{1B}[1;1H\u{1B}[L")
    #expect(vt.state.kittyPlacements().first?.row == 1)
    vt.feed("\u{1B}[M")
    #expect(vt.state.kittyPlacements().first?.row == 1)
  }

  @Test
  func `scroll margins move contained placements and clip them`() {
    var vt = terminal(10, 6)
    vt.feed("\u{1B}[2;5r\u{1B}[3;1H")
    // Two rows tall.
    vt.feed(apc("a=T,s=10,v=40,i=1,q=2,C=1;" + b64(pixels(10, 40))))
    vt.feed("\u{1B}[1S")
    #expect(vt.state.kittyPlacements().first?.row == 1)
    vt.feed("\u{1B}[1S")
    let clipped = vt.state.kittyPlacements().first
    #expect(clipped?.row == 1)
    #expect(clipped?.sourceY == 20)
    #expect(clipped?.sourceHeight == 20)
    vt.feed("\u{1B}[1S")
    #expect(vt.state.kittyPlacements().isEmpty)
  }

  @Test
  func `a bottom margin scroll moves region placements and keeps the rest`() {
    var vt = terminal(10, 6)
    vt.feed("\u{1B}[3;1H")
    vt.feed(apc("a=T,s=10,v=20,i=1,p=1,q=2,C=1;" + b64(pixels(10, 20))))
    vt.feed("\u{1B}[6;1H")
    vt.feed(apc("a=p,i=1,p=2,q=2,C=1"))
    // Region rows 1–4 at the top of the primary screen: LF at its bottom
    // shifts the region into history.
    vt.feed("\u{1B}[1;4r\u{1B}[4;1H\n")
    let rows = Dictionary(
      uniqueKeysWithValues: vt.state.kittyImages.placements.map {
        ($0.key.id, $0.value.location)
      }
    )
    let top = vt.state.screenAbsoluteRow(0)
    #expect(rows[1] == .anchor(row: top + 1, column: 0))
    #expect(rows[2] == .anchor(row: top + 5, column: 0))
  }

  @Test
  func `alternate screen scrolls move and clip placements`() {
    var vt = terminal(10, 3)
    vt.feed("\u{1B}[?1049h\u{1B}[2;1H")
    vt.feed(apc("a=T,s=10,v=20,i=1,q=2,C=1;" + b64(pixels(10, 20))))
    vt.feed("\u{1B}[3;1H\n")
    #expect(vt.state.kittyPlacements().first?.row == 0)
    vt.feed("\n")
    #expect(vt.state.kittyPlacements().isEmpty)
  }

  @Test
  func `placements outside the region stay`() {
    var vt = terminal(10, 6)
    vt.feed("\u{1B}[3;5r\u{1B}[1;1H")
    vt.feed(apc("a=T,s=10,v=20,i=1,q=2,C=1;" + b64(pixels(10, 20))))
    vt.feed("\u{1B}[2S")
    #expect(vt.state.kittyPlacements().first?.row == 0)
  }

  @Test
  func `reflow keeps anchors on their content`() {
    var vt = terminal(10, 4)
    vt.feed("abcdefgh\r\n")
    vt.feed(apc("a=T,s=10,v=20,i=1,q=2,C=1;" + b64(pixels(10, 20))))
    vt.state.resize(columns: 4, rows: 4)
    // "abcdefgh" now wraps over two rows; the image row moves down.
    #expect(vt.state.kittyPlacements().first?.row == 2)
  }

  @Test
  func `alternate screen keeps its own storage and 1049 clears it`() {
    var vt = terminal()
    let data = b64(pixels(1, 1))
    vt.feed(apc("a=t,s=1,v=1,i=1,q=2;" + data))
    vt.feed("\u{1B}[?1049h")
    #expect(vt.state.kittyImages.images.isEmpty)
    vt.feed(apc("a=T,s=1,v=1,i=2,q=2;" + data))
    vt.feed("\u{1B}[?1049l")
    #expect(vt.state.kittyImages.image(id: 1) != nil)
    vt.feed("\u{1B}[?1049h")
    #expect(vt.state.kittyImages.placements.isEmpty)
  }

  @Test
  func `full reset keeps limits and drops images`() {
    var vt = terminal()
    vt.state.imageStorageLimit = 1000
    vt.feed(apc("a=t,s=1,v=1,i=1,q=2;" + b64(pixels(1, 1))))
    vt.feed("\u{1B}c")
    #expect(vt.state.kittyImages.images.isEmpty)
    #expect(vt.state.kittyImages.limit == 1000)
  }
}

struct KittyPlacementTests {
  private func geometry() -> KittyImageStorage.Geometry {
    .init(
      cellWidth: 10,
      cellHeight: 20,
      columns: 80,
      rows: 24,
      screenTop: 0,
      firstRow: 0
    )
  }

  private func image(_ w: UInt32, _ h: UInt32) -> KittyGraphics.Image {
    KittyGraphics.Image(id: 1, width: w, height: h)
  }

  @Test
  func `pixel and grid size for every c and r combination`() {
    let g = geometry()
    let img = image(30, 30)
    var p = KittyImageStorage.Placement(location: .anchor(row: 0, column: 0))
    #expect(KittyImageStorage.pixelSize(p, img, g) == (30, 30))
    #expect(KittyImageStorage.gridSize(p, img, g) == (3, 2))
    p.columns = 2
    #expect(KittyImageStorage.pixelSize(p, img, g) == (20, 20))
    p.columns = 0
    p.rows = 2
    #expect(KittyImageStorage.pixelSize(p, img, g) == (40, 40))
    p.columns = 3
    #expect(KittyImageStorage.pixelSize(p, img, g) == (30, 40))
    #expect(KittyImageStorage.gridSize(p, img, g) == (3, 2))
    p.xOffset = 5
    #expect(KittyImageStorage.pixelSize(p, img, g) == (25, 40))
  }

  @Test
  func `zero cell size gives zero grid`() {
    var g = geometry()
    g.cellWidth = 0
    let p = KittyImageStorage.Placement(location: .anchor(row: 0, column: 0))
    #expect(KittyImageStorage.gridSize(p, image(30, 30), g) == (0, 0))
  }

  @Test
  func `relative placement chain and errors`() {
    var vt = terminal()
    vt.feed(apc("a=t,s=10,v=20,i=1,q=2;" + b64(pixels(10, 20))))
    vt.feed(apc("a=p,i=1,p=1,q=2,C=1"))
    vt.feed(apc("a=p,i=1,p=2,P=1,Q=1,H=2,V=1"))
    #expect(vt.takeOutput() == apc("i=1,p=2;OK"))
    let placed = vt.state.kittyPlacements().map { ($0.row, $0.column) }
    #expect(placed.contains { $0 == (1, 2) })
    vt.feed(apc("a=p,i=1,p=3,P=9"))
    #expect(vt.takeOutput() == apc("i=1,p=3;ENOPARENT: parent image not found"))
    vt.feed(apc("a=p,i=1,p=3,P=1,Q=9"))
    #expect(
      vt.takeOutput() == apc("i=1,p=3;ENOPARENT: parent placement not found")
    )
    vt.feed(apc("a=p,i=1,p=2,P=1,Q=2"))
    #expect(
      vt.takeOutput()
        == apc("i=1,p=2;EINVAL: placement cannot be its own parent")
    )
    vt.feed(apc("a=p,i=1,p=1,P=1,Q=2"))
    #expect(
      vt.takeOutput() == apc("i=1,p=1;ECYCLE: parent chain creates a cycle")
    )
    // Deleting the parent deletes its children.
    vt.feed(apc("a=d,d=i,i=1,p=1"))
    #expect(vt.state.kittyImages.placements.isEmpty)
  }

  @Test
  func `relative placement depth limit`() {
    var vt = terminal()
    vt.feed(apc("a=t,s=10,v=20,i=1,q=2;" + b64(pixels(10, 20))))
    vt.feed(apc("a=p,i=1,p=1,q=2,C=1"))
    for p in 2 ... 9 { vt.feed(apc("a=p,i=1,p=\(p),P=1,Q=\(p - 1),q=2")) }
    vt.feed(apc("a=p,i=1,p=10,P=1,Q=9"))
    #expect(vt.takeOutput() == apc("i=1,p=10;ETOODEEP: parent chain too deep"))
  }

  @Test
  func `layers come from z`() {
    #expect(KittyGraphics.Layer.from(z: -1_073_741_825) == .belowBackground)
    #expect(KittyGraphics.Layer.from(z: -1_073_741_824) == .belowText)
    #expect(KittyGraphics.Layer.from(z: -1) == .belowText)
    #expect(KittyGraphics.Layer.from(z: 0) == .aboveText)
  }
}

struct KittyPlaceholderTests {
  private func placeholder(row: Int, column: Int) -> String {
    let d = KittyGraphics.diacritics
    return "\u{10EEEE}" + String(Character(Unicode.Scalar(d[row])!))
      + String(Character(Unicode.Scalar(d[column])!))
  }

  /// The SIMD base64 path agrees with Foundation on valid input of every
  /// length and alignment, and hands padding, whitespace and invalid bytes
  /// to the scalar path.
  @Test
  func `base64 decoding matches Foundation across lengths and blocks`() {
    var rng = SystemRandomNumberGenerator()
    for length in 0 ..< 200 {
      let bytes = (0 ..< length)
        .map { _ in UInt8.random(in: 0 ... 255, using: &rng) }
      let encoded = Array(Data(bytes).base64EncodedString().utf8)
      #expect(KittyGraphics.decodeBase64(encoded) == bytes, "length \(length)")
      // Unpadded, as kitty clients may send.
      let unpadded = Array(encoded.prefix { $0 != UInt8(ascii: "=") })
      #expect(
        KittyGraphics.decodeBase64(unpadded) == bytes,
        "unpadded \(length)"
      )
      guard encoded.count > 20 else { continue }
      // Whitespace inside a SIMD block is skipped.
      var spaced = encoded
      spaced.insert(UInt8(ascii: "\n"), at: 10)
      #expect(KittyGraphics.decodeBase64(spaced) == bytes, "spaced \(length)")
      // An invalid byte anywhere fails.
      var bad = encoded
      bad[Int.random(in: 0 ..< encoded.count - 3, using: &rng)] = UInt8(
        ascii: "*"
      )
      #expect(KittyGraphics.decodeBase64(bad) == nil, "invalid \(length)")
      // Bytes 0x80 and above, and padding, inside a block also fail.
      for invalid in [UInt8(0xC3), 0x80, 0xFF, UInt8(ascii: "=")] {
        var high = encoded
        high[Int.random(in: 0 ..< encoded.count - 3, using: &rng)] = invalid
        #expect(
          KittyGraphics.decodeBase64(high) == nil,
          "byte \(invalid) length \(length)"
        )
      }
    }
  }

  @Test
  func `payload high-bit checks find a byte at any offset`() {
    for n in 0 ..< 40 {
      var bytes = [UInt8](repeating: 0x41, count: n)
      bytes.withUnsafeBufferPointer { #expect(!TerminalState.hasHighBit($0)) }
      for i in 0 ..< n {
        bytes[i] = 0x80
        bytes.withUnsafeBufferPointer { #expect(TerminalState.hasHighBit($0)) }
        bytes[i] = 0x41
      }
    }
  }

  @Test
  func `the diacritic table maps every diacritic and nothing else`() {
    for (i, d) in KittyGraphics.diacritics.enumerated() {
      #expect(KittyGraphics.diacriticIndex(d) == UInt32(i))
    }
    let known = Set(KittyGraphics.diacritics)
    for scalar in UInt32(0) ..< 0x1E000 where !known.contains(scalar) {
      if KittyGraphics.diacriticIndex(scalar) != nil {
        Issue.record("\(scalar) is not a diacritic")
        break
      }
    }
    #expect(KittyGraphics.diacriticIndex(0x10FFFF) == nil)
  }

  @Test
  func `placeholders measure one column with zero-width diacritics`() {
    #expect(UnicodeWidth.width(0x10EEEE) == 1)
    for d in KittyGraphics.diacritics { #expect(UnicodeWidth.width(d) == 0) }
  }

  @Test
  func `dog 4x2 placeholder grid draws a slice per row`() {
    var vt = terminal(10, 5)
    // 40×40 image on a 4×2 virtual grid of 10×20 cells: fits exactly.
    vt.feed(apc("a=T,U=1,s=40,v=40,i=42,c=4,r=2,q=2;" + b64(pixels(40, 40))))
    #expect(vt.cursor == (0, 0))
    vt.feed("\u{1B}[38;5;42m")
    for row in 0 ..< 2 {
      vt.feed("\u{1B}[\(row + 1);1H")
      for column in 0 ..< 4 { vt.feed(placeholder(row: row, column: column)) }
    }
    let placed = vt.state.kittyPlacements()
    #expect(placed.count == 2)
    #expect(
      placed.allSatisfy {
        $0.isPlaceholder && $0.columns == 4 && $0.layer == .belowText
      }
    )
    let first = placed.first { $0.row == 0 }!
    #expect(first.sourceY == 0)
    #expect(first.sourceHeight == 20)
    #expect(first.width == 40)
    let second = placed.first { $0.row == 1 }!
    #expect(second.sourceY == 20)
  }

  @Test
  func `placeholders without diacritics continue the run`() {
    var vt = terminal(10, 5)
    vt.feed(apc("a=T,U=1,s=40,v=20,i=42,c=4,r=1,q=2;" + b64(pixels(40, 20))))
    vt.feed(
      "\u{1B}[38;5;42m" + placeholder(row: 0, column: 0)
        + "\u{10EEEE}\u{10EEEE}\u{10EEEE}"
    )
    let placed = vt.state.kittyPlacements()
    #expect(placed.count == 1)
    #expect(placed.first?.columns == 4)
  }

  @Test
  func
    `RGB foreground encodes 24-bit ids and the third diacritic the high byte`()
  {
    var vt = terminal(10, 5)
    let id: UInt32 = 0x0201_0203
    vt.feed(apc("a=T,U=1,s=10,v=20,i=\(id),q=2;" + b64(pixels(10, 20))))
    let d = KittyGraphics.diacritics
    vt.feed(
      "\u{1B}[38;2;1;2;3m\u{10EEEE}" + String(Character(Unicode.Scalar(d[0])!))
        + String(Character(Unicode.Scalar(d[0])!))
        + String(Character(Unicode.Scalar(d[2])!))
    )
    #expect(vt.state.kittyPlacements().first?.imageID == id)
  }

  @Test
  func `placeholders without a virtual placement draw nothing`() {
    var vt = terminal(10, 5)
    vt.feed(apc("a=t,s=10,v=20,i=42,q=2;" + b64(pixels(10, 20))))
    vt.feed("\u{1B}[38;5;42m\u{10EEEE}")
    #expect(vt.state.kittyPlacements().isEmpty)
  }

  /// Runs built cell by cell with `PlaceholderRun.append`, the general path
  /// of `kittyPlaceholderRow`, without its fast path.
  private func referenceRuns(
    _ state: borrowing TerminalState,
    absoluteRow row: Int
  ) -> KittyGraphics.PlaceholderRow {
    var out = KittyGraphics.PlaceholderRow()
    _ = state.withLine(absoluteRow: row) { cells, _ in
      var current: KittyGraphics.PlaceholderRun?
      for x in 0 ..< cells.count {
        let cell = cells[x]
        var scalars = [cell.glyph]
        if cell.isGrapheme {
          let span = state.graphemeScalars(cell.glyph)
          scalars = []
          for i in 0 ..< span.count { scalars.append(span[i]) }
        }
        guard scalars[0] == KittyGraphics.placeholder else {
          if let r = current { out.runs.append(r) }
          current = nil
          continue
        }
        let mark = { (i: Int) in i < scalars.count ? scalars[i] : nil }
        var run = KittyGraphics.PlaceholderRun(
          foreground: KittyGraphics.colorID(cell.attributes.foreground),
          underline: state.underlineColor(cell.attributes.underlineColor)
            .map(KittyGraphics.colorID) ?? 0,
          marks: (mark(1), mark(2), mark(3))
        )
        run.x = x
        if current != nil, current!.append(run) { continue }
        if let r = current { out.runs.append(r) }
        current = run.started()
      }
      if let r = current { out.runs.append(r) }
    }
    return out
  }

  /// The fast path for cells continuing a run (same color bits, row mark
  /// and next column mark) must agree with the general path on rows that
  /// break each of its conditions.
  @Test
  func `placeholder run fast path matches the general path`() {
    let d = KittyGraphics.diacritics
    let notDiacritic = (0x0300 ... 0x036F)
      .first { KittyGraphics.diacriticIndex(UInt32($0)) == nil }!
    func s(_ v: UInt32) -> String { String(Character(Unicode.Scalar(v)!)) }
    var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    func next(_ n: Int) -> Int {
      seed &+= 0x9E37_79B9_7F4A_7C15
      var z = seed
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return Int((z ^ (z >> 31)) % UInt64(n))
    }
    let columns = 40
    for trial in 0 ..< 300 {
      var vt = terminal(columns, 3)
      vt.feed(apc("a=T,U=1,s=10,v=20,i=42,c=40,r=2,q=2;" + b64(pixels(10, 20))))
      var text = "\u{1B}[H\u{1B}[38;5;42m"
      var column = next(3)
      var row = 0
      for _ in 0 ..< columns {
        // Mostly the common contiguous cell; otherwise break one condition.
        switch next(14) {
        case 0: text += "\u{1B}[38;5;\(42 + next(2))m"
        case 1: text += "\u{1B}[58;5;\(next(3))m"
        case 2: text += "\u{1B}[59m"
        case 3: text += "\u{1B}[38;2;0;0;\(42 + next(2))m"
        case 4: row = next(2)
        case 5: column += next(3) - 1
        default: break
        }
        column = max(0, min(column, d.count - 1))
        switch next(13) {
        case 0: text += "x"
        case 6: text += "x" + s(d[row]) + s(d[column])
        case 1: text += "\u{10EEEE}"
        case 2: text += "\u{10EEEE}" + s(d[row])
        case 3: text += "\u{10EEEE}" + s(d[row]) + s(d[column]) + s(d[next(3)])
        case 4: text += "\u{10EEEE}" + s(UInt32(notDiacritic)) + s(d[column])
        case 5: text += "\u{10EEEE}" + s(d[row]) + s(UInt32(notDiacritic))
        default: text += "\u{10EEEE}" + s(d[row]) + s(d[column])
        }
        column += 1
      }
      vt.feed(text)
      let top = vt.state.viewportTopAbsoluteRow
      let fast = vt.state.kittyPlaceholderRow(absoluteRow: top)
      let reference = referenceRuns(vt.state, absoluteRow: top)
      #expect(fast == reference, "trial \(trial): \(text.debugDescription)")
      if fast != reference { return }
    }
  }
}

struct KittyAnimationTests {
  @Test
  func `frames compose append and edit`() throws {
    var vt = terminal()
    vt.feed(apc("a=t,s=2,v=1,i=1,q=2;" + b64(pixels(2, 1, value: 0))))
    vt.feed(apc("a=f,i=1,s=1,v=1,x=1;" + b64([255, 0, 0, 255])))
    #expect(vt.takeOutput() == apc("i=1,r=2;OK"))
    var image = try #require(vt.state.kittyImages.image(id: 1))
    #expect(image.animation?.frameCount == 2)
    #expect(image.frame(2)?.bytes == [0, 0, 0, 0, 255, 0, 0, 255])
    vt.feed(apc("a=f,i=1,r=2,s=1,v=1;" + b64([0, 255, 0, 255])))
    #expect(vt.takeOutput() == apc("i=1,r=2;OK"))
    image = try #require(vt.state.kittyImages.image(id: 1))
    #expect(image.frame(2)?.bytes == [0, 255, 0, 255, 255, 0, 0, 255])
  }

  @Test
  func `frame errors`() {
    var vt = terminal()
    vt.feed(apc("a=f,i=1,s=1,v=1;" + b64(pixels(1, 1))))
    #expect(vt.takeOutput() == apc("i=1;ENOENT: image not found"))
    vt.feed(apc("a=t,s=1,v=1,i=1,q=2;" + b64(pixels(1, 1))))
    vt.feed(apc("a=f,i=1,s=2,v=1;" + b64(pixels(2, 1))))
    #expect(vt.takeOutput() == apc("i=1;EINVAL: frame dimensions exceed image"))
    vt.feed(apc("a=f,i=1,s=1,v=1,c=5;" + b64(pixels(1, 1))))
    #expect(vt.takeOutput() == apc("i=1,r=2;EINVAL: base frame not found"))
  }

  @Test
  func `compose errors and success`() {
    var vt = terminal()
    vt.feed(apc("a=t,s=2,v=2,i=1,q=2;" + b64(pixels(2, 2))))
    vt.feed(apc("a=f,i=1,s=2,v=2,q=2;" + b64(pixels(2, 2, value: 0))))
    vt.feed(apc("a=c,i=1,r=9,c=1"))
    #expect(vt.takeOutput() == apc("i=1;ENOENT: source frame not found"))
    vt.feed(apc("a=c,i=1,r=1,c=9"))
    #expect(vt.takeOutput() == apc("i=1;ENOENT: destination frame not found"))
    vt.feed(apc("a=c,i=1,r=1,c=2,x=1,w=2"))
    #expect(
      vt.takeOutput() == apc("i=1;EINVAL: destination rectangle out of bounds")
    )
    vt.feed(apc("a=c,i=1,r=1,c=1,w=1,h=1"))
    #expect(
      vt.takeOutput()
        == apc("i=1;EINVAL: source and destination rectangles overlap")
    )
    vt.feed(apc("a=c,i=1,r=1,c=2,w=1,h=1,C=1"))
    #expect(vt.takeOutput() == apc("i=1;OK"))
  }

  @Test
  func `playback advances only placed running animations`() throws {
    var vt = terminal()
    vt.feed(apc("a=t,s=1,v=1,i=1,q=2;" + b64(pixels(1, 1))))
    vt.feed(apc("a=f,i=1,s=1,v=1,z=100,q=2;" + b64(pixels(1, 1, value: 0))))
    vt.feed(apc("a=a,i=1,r=1,z=50,s=3"))
    #expect(vt.takeOutput() == "")
    #expect(vt.state.kittyAnimationTick(now: 0) == nil)
    vt.feed(apc("a=p,i=1,q=2,C=1"))
    #expect(vt.state.kittyAnimationTick(now: 0) == 50)
    #expect(vt.state.kittyAnimationTick(now: 50) == 100)
    #expect(vt.state.kittyImages.image(id: 1)?.animation?.currentIndex == 1)
    _ = vt.state.kittyAnimationTick(now: 150)
    #expect(vt.state.kittyImages.image(id: 1)?.animation?.currentIndex == 0)
  }

  @Test
  func `deleting the root frame promotes frame 2`() throws {
    var vt = terminal()
    vt.feed(apc("a=t,s=1,v=1,i=1,q=2;" + b64(pixels(1, 1))))
    vt.feed(apc("a=f,i=1,s=1,v=1,q=2,X=1;" + b64([1, 2, 3, 4])))
    vt.feed(apc("a=d,d=f,i=1,r=1"))
    let image = try #require(vt.state.kittyImages.image(id: 1))
    #expect(image.pixels?.bytes == [1, 2, 3, 4])
    #expect(image.animation?.frames.isEmpty == true)
    vt.feed(apc("a=d,d=F,i=1"))
    #expect(vt.state.kittyImages.image(id: 1) == nil)
  }
}

struct KittyGraphicsCheckpointTests {
  @Test
  func `checkpoints without images are unchanged by graphics`() throws {
    var a = terminal()
    a.feed("hello")
    let before = try a.state.checkpoint()
    a.feed(apc("a=t,s=1,v=1,i=1,q=2;" + b64(pixels(1, 1))))
    a.feed(apc("a=d,d=I,i=1"))
    #expect(try a.state.checkpoint() == before)
  }

  @Test
  func `images placements and animation survive a checkpoint`() throws {
    var vt = terminal()
    vt.feed(
      apc("a=T,f=24,s=10,v=20,i=4,p=2,q=2;" + b64(pixels(10, 20, bpp: 3)))
    )
    vt.feed(apc("a=p,i=4,p=3,P=4,Q=2,H=1,q=2"))
    vt.feed(apc("a=t,U=1,s=10,v=20,i=5,q=2;" + b64(pixels(10, 20))))
    vt.feed(apc("a=p,U=1,i=5,q=2"))
    vt.feed(apc("a=f,i=4,s=1,v=1,q=2;" + b64(pixels(1, 1))))
    vt.feed(apc("a=a,i=4,s=3,v=2"))
    vt.feed("\u{1B}[?1049h")
    vt.feed(apc("a=T,s=1,v=1,i=9,q=2;" + b64(pixels(1, 1))))
    let bytes = try vt.state.checkpoint()
    let restored = try TerminalState.restored(checkpoint: bytes)
    #expect(Set(restored.kittyAlternate.images.keys) == [9])
    let primary = restored.kittyPrimary
    #expect(Set(primary.images.keys) == [4, 5])
    #expect(primary.placements.count == 3)
    #expect(primary.image(id: 4)?.animation?.frameCount == 2)
    #expect(primary.image(id: 4)?.animation?.maxLoops == 1)
    #expect(
      primary.image(id: 4)?.pixels?.bytes
        == vt.state.kittyPrimary.image(id: 4)?.pixels?.bytes
    )
    #expect(primary.totalBytes == vt.state.kittyPrimary.totalBytes)
    // A second checkpoint of the restored state is identical.
    var again = restored
    #expect(try again.checkpoint() == bytes)
  }

  @Test
  func `a chunked load is abandoned at the cut`() throws {
    var vt = terminal()
    vt.feed(apc("a=t,s=1,v=1,i=1,q=2;" + b64(pixels(1, 1))))
    vt.feed(apc("a=t,f=24,s=2,v=1,i=2,m=1,q=2;AAAA"))
    let restored = try TerminalState.restored(
      checkpoint: try vt.state.checkpoint()
    )
    #expect(restored.kittyPrimary.loading == nil)
    #expect(restored.kittyPrimary.image(id: 1) != nil)
  }
}

/// Regressions found reviewing the kitty graphics change.
struct KittyGraphicsReviewTests {
  private func placeholder(row: Int, column: Int) -> String {
    let d = KittyGraphics.diacritics
    return "\u{10EEEE}" + String(Character(Unicode.Scalar(d[row])!))
      + String(Character(Unicode.Scalar(d[column])!))
  }

  @Test
  func `deleting at a cell left of a placement beyond the grid does not trap`()
  {
    var vt = terminal(20, 5)
    vt.feed("\u{1B}[?1049h\u{1B}[1;16H")
    vt.feed(apc("a=T,s=10,v=20,i=1,q=2,C=1;" + b64(pixels(10, 20))))
    vt.state.resize(columns: 10, rows: 5)
    vt.feed("\u{1B}[1;5H")
    vt.feed(apc("a=d,d=c"))
    vt.feed(apc("a=d,d=p,x=5,y=1"))
    vt.feed(apc("a=d,d=q,x=5,y=1,z=0"))
    #expect(vt.state.kittyImages.images.count == 1)
  }

  @Test
  func `placeholder source rects stay inside odd-sized images`() {
    var vt = terminal(10, 5)
    vt.feed(apc("a=T,U=1,s=10,v=101,i=42,c=1,r=2,q=2;" + b64(pixels(10, 101))))
    vt.feed("\u{1B}[38;5;42m")
    for row in 0 ..< 2 {
      vt.feed("\u{1B}[\(row + 1);1H" + placeholder(row: row, column: 0))
    }
    let placed = vt.state.kittyPlacements()
    #expect(placed.count == 2)
    for p in placed {
      #expect(p.sourceX >= 0 && p.sourceX + p.sourceWidth <= 10)
      #expect(p.sourceY >= 0 && p.sourceY + p.sourceHeight <= 101)
    }
  }

  @Test
  func `an animation control on an RGB image survives a checkpoint`() throws {
    var vt = terminal()
    vt.feed(apc("a=T,f=24,s=1,v=1,i=1,q=2;" + b64(pixels(1, 1, bpp: 3))))
    vt.feed(apc("a=a,i=1,s=1"))
    let restored = try TerminalState.restored(
      checkpoint: try vt.state.checkpoint()
    )
    #expect(restored.kittyPrimary.image(id: 1)?.format == .rgb)
  }

  @Test
  func `clearing the screen and scrollback drops every primary placement`() {
    var vt = terminal(10, 3)
    let data = b64(pixels(10, 20))
    vt.feed(apc("a=T,s=10,v=20,i=1,q=2;" + data))
    vt.feed("\r\n\r\n\r\n\r\n")
    vt.feed(apc("a=T,s=10,v=20,i=2,q=2;" + data))
    vt.feed("\r\n$ ")
    #expect(vt.state.kittyImages.placements.count == 2)
    vt.state.clearScreenKeepingCursorLine()
    #expect(vt.state.kittyImages.placements.isEmpty)
    #expect(vt.state.kittyImages.images.isEmpty)
    #expect(vt.state.kittyPlacements().isEmpty)
  }

  @Test
  func `scroll down on the full primary screen moves placements`() {
    var vt = terminal(10, 5)
    vt.feed(apc("a=T,s=10,v=20,i=1,q=2,C=1;" + b64(pixels(10, 20))))
    vt.feed("\u{1B}[2T")
    #expect(vt.state.kittyPlacements().first?.row == 2)
  }

  @Test
  func `deleting the displayed frame keeps the index on its successor`() throws
  {
    var vt = terminal()
    vt.feed(apc("a=t,s=1,v=1,i=1,q=2;" + b64(pixels(1, 1))))
    vt.feed(apc("a=f,i=1,s=1,v=1,q=2,X=1;" + b64([1, 2, 3, 4])))
    vt.feed(apc("a=f,i=1,s=1,v=1,q=2,X=1;" + b64([5, 6, 7, 8])))
    vt.feed(apc("a=a,i=1,c=2"))
    vt.feed(apc("a=d,d=f,i=1,r=2"))
    let animation = try #require(vt.state.kittyImages.image(id: 1)?.animation)
    #expect(animation.currentIndex == 1)
    #expect(animation.frames.map(\.pixels.bytes) == [[5, 6, 7, 8]])
    // Deleting the frame after the displayed one leaves it alone.
    vt.feed(apc("a=f,i=1,s=1,v=1,q=2,X=1;" + b64([9, 9, 9, 9])))
    vt.feed(apc("a=d,d=f,i=1,r=3"))
    #expect(vt.state.kittyImages.image(id: 1)?.animation?.currentIndex == 1)
  }

  #if canImport(ImageIO)
  @Test
  func `PNG decoding stops at the storage limit`() throws {
    let data = [UInt8](
      try #require(Data(base64Encoded: KittyGraphicsExecTests.png1x1))
    )
    guard case .overLimit = PNG.decode(data, limit: 3) else {
      Issue.record("decoded past the limit")
      return
    }
    guard case .pixels = PNG.decode(data, limit: 4) else {
      Issue.record("refused within the limit")
      return
    }
  }
  #endif
}
