import CoreGraphics
import Foundation
import ImageIO
@testable import SwifttyEngine
import Testing
import ZlibCodec

// Ports of Ghostty's kitty graphics tests at 167acf0c (spec.graphics.md
// KG19) with Ghostty's exact expected values:
// src/terminal/kitty/graphics_command.zig, graphics_exec.zig,
// graphics_storage.zig, graphics_image.zig, graphics_unicode.zig,
// graphics_pixel.zig and graphics_animation.zig.
// Commands go through the byte stream (`ESC _ G … ESC \`), so a Ghostty
// `execute` returning null is an empty reply and a response is its
// encoding. Page pins, tracked-pin counts, allocator injection and
// Windows path rules are omitted (listed at the end of this file);
// tests already in KittyGraphicsTests.swift with the same values are not
// repeated. Deviations are marked `// D<n>:` (spec.graphics.md §19).

private func apc(_ body: String) -> String { "\u{1B}_G\(body)\u{1B}\\" }

private func b64(_ bytes: [UInt8]) -> String {
  Data(bytes).base64EncodedString()
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

/// Ghostty's `Terminal.init(.{ .rows = rows, .cols = cols })`: no pixel
/// size unless a test sets one.
private func term(_ columns: Int = 5, _ rows: Int = 5) -> VT {
  VT(columns, rows)
}

extension VT {
  /// Feeds one command and returns its reply ("" for none).
  fileprivate mutating func exec(_ body: String) -> String {
    feed(apc(body))
    return takeOutput()
  }

  fileprivate var storage: KittyImageStorage { state.kittyImages }

  fileprivate func placement(
    _ image: UInt32,
    _ id: UInt32
  ) -> KittyImageStorage.Placement? {
    state.kittyImages.placements[.init(imageID: image, external: true, id: id)]
  }
}

private func ok(_ ids: String) -> String { apc("\(ids);OK") }

// MARK: graphics_command.zig

struct KittyGraphicsCommandOracleTests {
  @Test
  func `transmission command`() throws {
    let t = try #require(
      KittyGraphics.Transmission(try command("f=24,s=10,v=20"))
    )
    #expect(t.format == .rgb)
    #expect(t.width == 10)
    #expect(t.height == 20)
    #expect(!t.transient)
  }

  @Test
  func `transmission command with transient hint`() throws {
    let t = try #require(
      KittyGraphics.Transmission(try command("f=24,s=10,v=20,N=1"))
    )
    #expect(t.format == .rgb)
    #expect(t.width == 10)
    #expect(t.height == 20)
    #expect(t.transient)
  }

  @Test
  func `feedSlice matches per-byte feed`() throws {
    let input = Array("f=24,s=10,v=20;aGVsbG8gd29ybGQ=".utf8)
    var bytewise = KittyGraphics.CommandParser()
    for b in input { [b].withUnsafeBufferPointer { bytewise.feed($0) } }
    let done = bytewise.complete()
    let a = try #require(done)
    let b = try command("f=24,s=10,v=20;aGVsbG8gd29ybGQ=")
    #expect(a.payload == b.payload)
    #expect(a.action == 0x74)
  }

  @Test
  func `feedSlice across slice boundaries`() throws {
    var p = KittyGraphics.CommandParser()
    for part in ["f=24,s=10", ",v=20;aGVsbG8g", "d29ybGQ="] {
      Array(part.utf8).withUnsafeBufferPointer { p.feed($0) }
    }
    let done = p.complete()
    let c = try #require(done)
    #expect(c.action == 0x74)
    #expect(String(decoding: c.payload, as: UTF8.self) == "hello world")
  }

  @Test
  func `transmission ignores 'm' if medium is not direct`() throws {
    let t = try #require(KittyGraphics.Transmission(try command("a=t,t=t,m=1")))
    #expect(t.medium == .temporaryFile)
    #expect(!t.moreChunks)
  }

  @Test
  func `transmission respects 'm' if medium is direct`() throws {
    let t = try #require(KittyGraphics.Transmission(try command("a=t,t=d,m=1")))
    #expect(t.medium == .direct)
    #expect(t.moreChunks)
  }

  @Test
  func `query command`() throws {
    let c = try command("i=31,s=1,v=1,a=q,t=d,f=24;QUFBQQ")
    #expect(c.action == 0x71)
    let t = try #require(KittyGraphics.Transmission(c))
    #expect(t.medium == .direct)
    #expect(t.width == 1)
    #expect(t.height == 1)
    #expect(t.imageID == 31)
    #expect(c.payload == Array("AAAA".utf8))
  }

  @Test
  func `display command`() throws {
    let c = try command("a=p,U=1,i=31,c=80,r=120")
    #expect(c.action == 0x70)
    let d = KittyGraphics.Display(c)
    #expect(d.columns == 80)
    #expect(d.rows == 120)
    #expect(d.imageID == 31)
  }

  @Test
  func `delete command`() throws {
    let d = try #require(KittyGraphics.Delete(try command("a=d,d=p,x=3,y=4")))
    #expect(d == .cell(delete: false, x: 3, y: 4))
  }

  @Test
  func `no control data`() throws {
    let c = try command(";QUFBQQ")
    #expect(c.action == 0x74)
    #expect(c.payload == Array("AAAA".utf8))
  }

  @Test
  func `ignore unknown keys (non-letter)`() throws {
    let t = try #require(
      KittyGraphics.Transmission(try command("f=24,s=10,v=20,!=1"))
    )
    #expect(t.format == .rgb)
    #expect(t.width == 10)
    #expect(t.height == 20)
  }

  @Test
  func `ignore very long values`() throws {
    let t = try #require(
      KittyGraphics.Transmission(
        try command("f=24,s=10,v=2000000000000000000000000000000000000000")
      )
    )
    #expect(t.format == .rgb)
    #expect(t.width == 10)
    #expect(t.height == 0)
  }

  @Test
  func `ensure very large negative values don't get skipped`() throws {
    let d = KittyGraphics.Display(try command("a=p,i=1,z=-2000000000"))
    #expect(d.imageID == 1)
    #expect(d.z == -2_000_000_000)
  }

  @Test
  func `ensure proper overflow error for u32 and i32`() {
    #expect(parse("a=p,i=10000000000") == nil)
    #expect(parse("a=p,i=1,z=-9999999999") == nil)
  }

  @Test
  func `all i32 values`() throws {
    #expect(KittyGraphics.Display(try command("a=p,i=1,z=-1")).z == -1)
    #expect(
      KittyGraphics.Display(try command("a=p,i=1,H=-1")).horizontalOffset == -1
    )
    #expect(
      KittyGraphics.Display(try command("a=p,i=1,V=-1")).verticalOffset == -1
    )
  }

  @Test
  func `response encodings`() {
    #expect(KittyGraphics.Response().encoded() == nil)
    #expect(
      KittyGraphics.Response(id: 4).encoded()
        == Array("\u{1B}_Gi=4;OK\u{1B}\\".utf8)
    )
    #expect(
      KittyGraphics.Response(imageNumber: 4).encoded()
        == Array("\u{1B}_GI=4;OK\u{1B}\\".utf8)
    )
    #expect(
      KittyGraphics.Response(id: 12, imageNumber: 4).encoded()
        == Array("\u{1B}_Gi=12,I=4;OK\u{1B}\\".utf8)
    )
  }

  @Test(arguments: [
    (
      "a=d,d=r,x=3,y=4",
      KittyGraphics.Delete.range(delete: false, first: 3, last: 4)
    ), ("a=d,d=R,x=5,y=11", .range(delete: true, first: 5, last: 11)),
    // Inverted: accepted, matches nothing.
    ("a=d,d=R,x=5,y=4", .range(delete: true, first: 5, last: 4)),
    ("a=d,d=R,x=5", .range(delete: true, first: 5, last: 0)),
    ("a=d,d=R,y=5", .range(delete: true, first: 0, last: 5)),
    ("a=d,d=r", .range(delete: false, first: 0, last: 0)),
  ])
  func `delete range commands`(
    input: String,
    expected: KittyGraphics.Delete
  ) throws { #expect(KittyGraphics.Delete(try command(input)) == expected) }

  @Test
  func `unknown format value is deferred to execution`() throws {
    let t = try #require(
      KittyGraphics.Transmission(try command("a=t,f=42,i=31,s=1,v=1"))
    )
    #expect(t.formatUnknown)
    #expect(t.imageID == 31)
  }

  @Test
  func `zero and known format values`() throws {
    for (input, format) in [
      ("a=t,f=0,i=31,s=1,v=1", KittyGraphics.Format.rgba), ("f=24", .rgb),
      ("f=32", .rgba), ("f=100", .png),
    ] {
      let t = try #require(KittyGraphics.Transmission(try command(input)))
      #expect(!t.formatUnknown)
      #expect(t.format == format)
    }
  }

  @Test
  func `quiet value above two suppresses all responses`() throws {
    #expect(try command("a=t,q=3,i=31,s=1,v=1").quiet == .failures)
  }

  @Test
  func `cursor movement and virtual values above one`() throws {
    #expect(KittyGraphics.Display(try command("a=p,i=31,C=2")).movesCursor)
    #expect(KittyGraphics.Display(try command("a=p,i=31,U=2")).virtual)
  }

  @Test
  func `animation frame composition value above one alpha blends`() throws {
    let f = try #require(KittyGraphics.FrameLoad(try command("a=f,i=31,X=2")))
    #expect(!f.overwrite)
  }

  @Test
  func `unknown flag key values still fail parsing`() {
    // Rejected before execution: no reply even with an id.
    for input in ["a=z,i=31", "a=d,d=w,i=31", "a=t,t=q,i=31", "a=t,o=q,i=31"] {
      var vt = term()
      #expect(vt.exec(input) == "")
    }
  }
}

// MARK: graphics_exec.zig

struct KittyGraphicsExecOracleTests {
  @Test
  func `query validates image data`() {
    var vt = term()
    // A 1×1 RGB image needs three bytes.
    #expect(
      vt.exec("a=q,f=24,s=1,v=1,i=31;" + b64([0, 0]))
        == apc("i=31;EINVAL: invalid data")
    )
    #expect(vt.storage.images.isEmpty)
  }

  @Test
  func `valid query does not replace or store image`() {
    var vt = term()
    #expect(vt.exec("a=t,f=24,s=1,v=1,i=31;/wAA") == ok("i=31"))
    #expect(vt.exec("a=q,f=24,s=1,v=1,i=31;" + b64([0, 0, 0])) == ok("i=31"))
    #expect(vt.storage.images.count == 1)
    #expect(vt.storage.image(id: 31)?.pixels?.bytes == [255, 0, 0])
  }

  @Test
  func `image id and number are mutually exclusive for every action`() {
    var vt = term()
    for input in [
      "a=q,f=24,s=1,v=1,i=1,I=2,p=3;AAAA", "a=t,f=24,s=1,v=1,i=1,I=2,p=3;AAAA",
      "a=T,f=24,s=1,v=1,i=1,I=2,p=3;AAAA", "a=p,i=1,I=2,p=3",
      "a=d,d=a,i=1,I=2,p=3", "a=f,i=1,I=2,p=3;AAAA", "a=a,i=1,I=2,p=3",
      "a=c,i=1,I=2,p=3",
    ] {
      #expect(
        vt.exec(input)
          == apc(
            "i=1,I=2,p=3;EINVAL: image ID and number are mutually exclusive"
          )
      )
    }
    #expect(vt.storage.images.isEmpty)
    #expect(vt.storage.placements.isEmpty)
  }

  @Test
  func `conflicting identifiers are rejected before mutation`() {
    var vt = term()
    #expect(vt.exec("a=t,f=24,s=1,v=1,i=1;/wAA") == ok("i=1"))
    #expect(
      vt.exec("a=p,i=1,I=2,p=7,C=1").hasPrefix("\u{1B}_Gi=1,I=2,p=7;EINVAL")
    )
    #expect(vt.storage.placements.isEmpty)
    #expect(vt.exec("a=p,i=1,p=7,C=1") == ok("i=1,p=7"))
    #expect(
      vt.exec("a=d,d=i,i=1,I=2,p=7").hasPrefix("\u{1B}_Gi=1,I=2,p=7;EINVAL")
    )
    #expect(vt.storage.placements.count == 1)
    // q=2 suppresses the reply but not the validation.
    #expect(vt.exec("a=d,d=i,i=1,I=2,p=7,q=2") == "")
    #expect(vt.storage.placements.count == 1)
  }

  @Test
  func `chunked success response uses initial identifiers`() {
    var vt = term()
    #expect(vt.exec("a=t,f=24,s=1,v=2,I=93,p=7,m=1;AAAA") == "")
    #expect(vt.exec("m=0;AAAA") == ok("i=1,I=93,p=7"))
  }

  @Test
  func `chunked error response uses initial identifiers`() {
    var vt = term()
    #expect(vt.exec("a=t,f=24,s=1,v=1,i=41,p=7,m=1;AA==") == "")
    #expect(vt.exec("m=0;AA==") == apc("i=41,p=7;EINVAL: invalid data"))
  }

  @Test
  func `more chunks with q=1, q=0 and increasing q`() {
    var a = term()
    #expect(a.exec("a=T,f=24,t=d,i=1,s=1,v=2,c=10,r=1,m=1,q=1;////") == "")
    #expect(a.exec("m=0;////") == "")
    var b = term()
    #expect(b.exec("a=t,f=24,t=d,s=1,v=2,c=10,r=1,m=1,i=1,q=0;////") == "")
    #expect(b.exec("m=0;////") == ok("i=1"))
    var c = term()
    #expect(c.exec("a=t,f=24,t=d,s=1,v=2,c=10,r=1,m=1,i=1,q=0;////") == "")
    #expect(c.exec("m=0,q=1;////") == "")
  }

  @Test
  func `delete aborts chunked image load and a fresh load starts empty`() {
    var vt = term()
    #expect(vt.exec("a=t,f=24,s=1,v=2,i=1,m=1;AAAA") == "")
    #expect(vt.storage.loading != nil)
    #expect(vt.exec("a=d") == "")
    #expect(vt.storage.loading == nil)
    #expect(vt.exec("a=t,f=24,s=1,v=2,i=1,m=1;AAAA") == "")
    #expect(vt.exec("m=0;AAAA") == ok("i=1"))
    #expect(vt.storage.image(id: 1)?.pixels?.bytes.count == 6)
  }

  @Test
  func `non-direct transmission abandons chunked image load`() throws {
    var vt = term()
    vt.state.kittyGraphicsMedia = .all
    let path = try tempFile([1, 2, 3])
    defer { unlink(path) }
    #expect(vt.exec("a=t,f=24,s=1,v=2,i=1,m=1;AAAA") == "")
    #expect(vt.storage.loading != nil)
    #expect(
      vt.exec("a=t,t=f,f=24,s=1,v=1,i=2;" + b64(Array(path.utf8))) == ok("i=2")
    )
    #expect(vt.storage.loading == nil)
    #expect(vt.storage.image(id: 1) == nil)
    #expect(vt.storage.image(id: 2)?.pixels?.bytes == [1, 2, 3])
  }

  @Test
  func `default and zero format are rgba`() {
    for f in ["", "f=0,"] {
      var vt = term()
      #expect(
        vt.exec("a=t,\(f)t=d,i=1,s=1,v=2,c=10,r=1;///////////") == ok("i=1")
      )
      #expect(vt.storage.image(id: 1)?.format == .rgba)
    }
  }

  @Test
  func `valid u32 and i32 extremes reach the image lookup`() {
    var vt = term()
    #expect(
      vt.exec("a=p,i=4294967295") == apc("i=4294967295;ENOENT: image not found")
    )
    #expect(
      vt.exec("a=p,i=1,z=-2147483648") == apc("i=1;ENOENT: image not found")
    )
  }

  @Test
  func `no response with no image ID or number`() {
    var vt = term()
    #expect(vt.exec("a=t,f=24,t=d,s=1,v=2,c=10,r=1,i=0,I=0;////////") == "")
    #expect(vt.exec("a=T,f=24,t=d,s=1,v=2,c=10,r=1,i=0,I=0;////////") == "")
  }

  @Test
  func `retransmit same id gets fresh image generation`() throws {
    var vt = term()
    #expect(vt.exec("a=t,t=d,f=24,i=1,s=1,v=2;////////") == ok("i=1"))
    let gen1 = try #require(vt.storage.image(id: 1)?.generation)
    #expect(gen1 > 0)
    #expect(gen1 == vt.storage.generation)
    #expect(vt.exec("a=t,t=d,f=24,i=1,s=1,v=2;AAAAAAAA") == ok("i=1"))
    let gen2 = try #require(vt.storage.image(id: 1)?.generation)
    #expect(gen2 > gen1)
    #expect(gen2 == vt.storage.generation)
  }

  @Test
  func `retransmit same id removes existing placements`() {
    var vt = term()
    #expect(vt.exec("a=T,t=d,f=24,i=1,s=1,v=2,C=1;////////") == ok("i=1"))
    #expect(vt.exec("a=p,i=1,C=1") == ok("i=1"))
    #expect(vt.exec("a=p,i=1,p=7,C=1") == ok("i=1,p=7"))
    #expect(vt.storage.placements.count == 3)
    #expect(vt.exec("a=t,t=d,f=24,i=1,s=1,v=2;AAAAAAAA") == ok("i=1"))
    #expect(vt.storage.placements.isEmpty)
    #expect(vt.exec("a=T,t=d,f=24,i=1,s=1,v=2,C=1;////////") == ok("i=1"))
    #expect(vt.exec("a=T,t=d,f=24,i=1,s=1,v=2,C=1;AAAAAAAA") == ok("i=1"))
    #expect(vt.storage.placements.count == 1)
  }

  @Test(arguments: [
    ("m=0;AAAAAAAAAAAA", 12), ("m=0;AA==", nil), ("a=d,d=I,i=2", nil),
  ])
  func `chunked retransmit same id keeps image until it ends`(
    end: String,
    length: Int?
  ) {
    var vt = term()
    #expect(vt.exec("a=T,t=d,f=24,i=1,s=1,v=2,C=1;////////") == ok("i=1"))
    let generation = vt.storage.generation
    #expect(vt.exec("a=t,t=d,f=24,i=1,s=1,v=4,m=1;AAAA") == "")
    #expect(vt.storage.loading != nil)
    #expect(vt.storage.image(id: 1)?.pixels?.bytes.count == 6)
    #expect(vt.storage.placements.count == 1)
    #expect(vt.storage.generation == generation)
    _ = vt.exec(end)
    #expect(vt.storage.loading == nil)
    #expect(vt.storage.placements.isEmpty)
    #expect(vt.storage.image(id: 1)?.pixels?.bytes.count == length)
  }

  @Test
  func `delete then retransmit same id gets fresh generation`() throws {
    var vt = term()
    #expect(vt.exec("a=T,t=d,f=24,i=1,s=1,v=2,c=1,r=1;////////") == ok("i=1"))
    let gen1 = try #require(vt.storage.image(id: 1)?.generation)
    #expect(vt.exec("a=d,d=A") == "")
    #expect(vt.storage.image(id: 1) == nil)
    let deleted = vt.storage.generation
    #expect(deleted > gen1)
    #expect(vt.exec("a=t,t=d,f=24,i=1,s=1,v=2;////////") == ok("i=1"))
    let gen2 = try #require(vt.storage.image(id: 1)?.generation)
    #expect(gen2 > gen1)
    #expect(gen2 > deleted)
  }

  @Test
  func `display clamps cell offsets and sizes the placement`() throws {
    var vt = term()
    vt.state.cellPixelSize = (10, 20)
    #expect(
      vt.exec("a=T,t=d,f=24,i=1,s=1,v=1,c=2,r=1,X=99,Y=99,C=1;AAAA")
        == ok("i=1")
    )
    let p = try #require(vt.storage.placements.values.first)
    #expect(p.xOffset == 9)
    #expect(p.yOffset == 19)
    let size = KittyImageStorage.pixelSize(
      p,
      try #require(vt.storage.image(id: 1)),
      vt.state.kittyGeometry
    )
    #expect(size.width == 11)
    #expect(size.height == 1)
  }

  @Test
  func `placement bounds cursor movement for untrusted dimensions`() {
    var vt = term()
    #expect(
      vt.exec("a=T,t=d,f=24,i=1,s=1,v=1,c=4294967295,r=4294967295;////")
        == ok("i=1")
    )
    #expect(vt.storage.placements.count == 1)
    // Ghostty: scrollbar total 10 (5 rows plus 5 scrolled into history).
    #expect(vt.state.grid.historyCount + 5 == 10)
  }

  @Test
  func `placement moves cursor past a tall image`() throws {
    var vt = term()
    #expect(vt.exec("a=t,t=d,f=24,i=1,s=1,v=1;////") == ok("i=1"))
    #expect(vt.exec("a=p,i=1,p=1,c=5,r=8") == ok("i=1,p=1"))
    #expect(vt.exec("a=p,i=1,p=2,C=1") == ok("i=1,p=2"))
    guard
      case let .anchor(first, _) = try #require(
        vt.storage.placements[.init(imageID: 1, external: true, id: 1)]
      )
      .location,
      case let .anchor(second, _) = try #require(
        vt.storage.placements[.init(imageID: 1, external: true, id: 2)]
      )
      .location
    else {
      Issue.record("not anchored")
      return
    }
    #expect(first + 8 == second)
  }

  @Test
  func `unknown format responds with EINVAL`() {
    var vt = term()
    #expect(
      vt.exec("a=t,f=42,t=d,i=31,s=1,v=1;AAAA")
        == apc("i=31;EINVAL: unsupported format")
    )
    #expect(vt.storage.images.isEmpty)
    #expect(
      vt.exec("a=q,f=42,t=d,i=31,s=1,v=1;AAAA")
        == apc("i=31;EINVAL: unsupported format")
    )
    #expect(vt.exec("a=t,f=42,t=d,i=31,q=3,s=1,v=1;AAAA") == "")
  }

  @Test
  func `out of range display keys are tolerated`() throws {
    var vt = term()
    #expect(vt.exec("a=T,f=24,t=d,i=31,s=1,v=1,C=2,U=2;AAAA") == ok("i=31"))
    #expect(
      try #require(vt.storage.placements.values.first).location == .virtual
    )
  }

  @Test
  func `number-based transmission assigns smallest free id`() {
    var vt = term()
    #expect(vt.exec("a=t,f=24,s=1,v=1,I=42;/wAA") == ok("i=1,I=42"))
    #expect(vt.exec("a=t,f=24,s=1,v=1,i=2;/wAA") == ok("i=2"))
    #expect(vt.exec("a=t,f=24,s=1,v=1,I=43;/wAA") == ok("i=3,I=43"))
    #expect(vt.exec("a=d,d=I,i=1") == "")
    #expect(vt.exec("a=t,f=24,s=1,v=1,I=44;/wAA") == ok("i=1,I=44"))
    #expect(vt.storage.images.count == 3)
    #expect(vt.storage.image(id: 1)?.number == 44)
    #expect(vt.storage.image(id: 2)?.number == 0)
    #expect(vt.storage.image(id: 3)?.number == 43)
  }

  @Test
  func `number-based id assignment does not replace client image`() {
    var vt = term()
    #expect(vt.exec("a=t,f=24,s=1,v=1,i=2147483647;/wAA") == ok("i=2147483647"))
    #expect(vt.exec("a=p,i=2147483647,C=1") == ok("i=2147483647"))
    #expect(vt.exec("a=t,f=24,s=1,v=1,I=42;AAD/") == ok("i=1,I=42"))
    #expect(vt.storage.images.count == 2)
    #expect(vt.storage.placements.count == 1)
    #expect(vt.storage.image(id: 2_147_483_647)?.pixels?.bytes == [255, 0, 0])
  }

  @Test
  func `implicit id assignment does not replace client image`() throws {
    var vt = term()
    #expect(vt.exec("a=t,f=24,s=1,v=1,i=2147483647;/wAA") == ok("i=2147483647"))
    #expect(vt.exec("a=p,i=2147483647,C=1") == ok("i=2147483647"))
    #expect(vt.exec("a=t,f=24,s=1,v=1;AAD/") == "")
    #expect(vt.storage.images.count == 2)
    #expect(vt.storage.placements.count == 1)
    #expect(vt.storage.image(id: 2_147_483_647)?.pixels?.bytes == [255, 0, 0])
    let implicit = try #require(vt.storage.image(id: 2_147_483_648))
    #expect(implicit.implicitID)
    #expect(implicit.pixels?.bytes == [0, 0, 255])
  }

  @Test
  func `relative placement with missing parent image`() {
    var vt = term()
    #expect(vt.exec("a=t,f=24,s=1,v=1,i=1;AAAA") == ok("i=1"))
    #expect(
      vt.exec("a=p,i=1,p=1,P=42,Q=1,H=2,V=2")
        == apc("i=1,p=1;ENOPARENT: parent image not found")
    )
    #expect(vt.storage.placements.isEmpty)
    #expect(vt.cursor == (0, 0))
  }

  @Test
  func `relative placement with missing parent placement`() {
    var vt = term()
    #expect(vt.exec("a=t,f=24,s=1,v=1,i=1;AAAA") == ok("i=1"))
    #expect(vt.exec("a=t,f=24,s=1,v=1,i=2;AAAA") == ok("i=2"))
    #expect(
      vt.exec("a=p,i=1,P=2") == apc("i=1;ENOPARENT: parent placement not found")
    )
    #expect(vt.exec("a=p,i=2,p=1,C=1") == ok("i=2,p=1"))
    #expect(
      vt.exec("a=p,i=1,P=2,Q=9")
        == apc("i=1;ENOPARENT: parent placement not found")
    )
    #expect(vt.storage.placements.count == 1)
  }

  @Test
  func `relative placement cannot parent itself`() throws {
    var vt = term()
    #expect(vt.exec("a=t,f=24,s=1,v=1,i=1;AAAA") == ok("i=1"))
    #expect(vt.exec("a=p,i=1,p=1,C=1") == ok("i=1,p=1"))
    for input in ["a=p,i=1,p=1,P=1,Q=1", "a=p,i=1,p=1,P=1"] {
      #expect(
        vt.exec(input)
          == apc("i=1,p=1;EINVAL: placement cannot be its own parent")
      )
    }
    guard
      case .anchor = try #require(
        vt.storage.placements[.init(imageID: 1, external: true, id: 1)]
      )
      .location
    else {
      Issue.record("parent moved")
      return
    }
  }

  @Test
  func `relative placement cycle`() throws {
    var vt = term()
    #expect(vt.exec("a=t,f=24,s=1,v=1,i=1;AAAA") == ok("i=1"))
    #expect(vt.exec("a=p,i=1,p=1,C=1") == ok("i=1,p=1"))
    #expect(vt.exec("a=p,i=1,p=2,P=1,Q=1") == ok("i=1,p=2"))
    #expect(
      vt.exec("a=p,i=1,p=1,P=1,Q=2")
        == apc("i=1,p=1;ECYCLE: parent chain creates a cycle")
    )
    guard
      case .anchor = try #require(
        vt.storage.placements[.init(imageID: 1, external: true, id: 1)]
      )
      .location
    else {
      Issue.record("parent replaced")
      return
    }
  }

  @Test
  func `relative placement chain depth limit`() {
    var vt = term()
    #expect(vt.exec("a=t,f=24,s=1,v=1,i=1;AAAA") == ok("i=1"))
    #expect(vt.exec("a=p,i=1,p=1,C=1") == ok("i=1,p=1"))
    for id in 2 ..< 10 {
      #expect(vt.exec("a=p,i=1,p=\(id),P=1,Q=\(id - 1)") == ok("i=1,p=\(id)"))
    }
    #expect(
      vt.exec("a=p,i=1,p=10,P=1,Q=9")
        == apc("i=1,p=10;ETOODEEP: parent chain too deep")
    )
    #expect(vt.storage.placements.count == 9)
  }

  @Test
  func `relative placement does not move cursor`() throws {
    var vt = term()
    #expect(vt.exec("a=t,f=24,s=1,v=1,i=1;AAAA") == ok("i=1"))
    #expect(vt.exec("a=p,i=1,p=1,C=1") == ok("i=1,p=1"))
    #expect(vt.exec("a=p,i=1,p=2,P=1,Q=1,H=3,V=2,c=2,r=2") == ok("i=1,p=2"))
    #expect(vt.cursor == (0, 0))
    #expect(
      try #require(
        vt.storage.placements[.init(imageID: 1, external: true, id: 2)]
      )
      .location
        == .relative(
          parent: .init(imageID: 1, external: true, id: 1),
          horizontal: 3,
          vertical: 2
        )
    )
  }

  @Test
  func `virtual placement with parent rejected before image lookup`() {
    var vt = term()
    #expect(
      vt.exec("a=p,i=42,U=1,P=1")
        == apc("i=42;EINVAL: virtual placement cannot refer to a parent")
    )
  }

  @Test
  func `deleting a parent deletes relative placements transitively`() {
    var vt = term()
    for input in [
      "a=t,f=24,s=1,v=1,i=1;AAAA", "a=p,i=1,p=1,C=1", "a=p,i=1,p=2,P=1,Q=1",
      "a=p,i=1,p=3,P=1,Q=2",
    ] { #expect(vt.exec(input).hasSuffix(";OK\u{1B}\\")) }
    #expect(vt.storage.placements.count == 3)
    #expect(vt.exec("a=d,d=i,i=1,p=2") == "")
    #expect(vt.storage.placements.count == 1)
    #expect(vt.placement(1, 1) != nil)
    #expect(vt.exec("a=d,d=i,i=1,p=1") == "")
    #expect(vt.storage.placements.isEmpty)
    #expect(vt.storage.image(id: 1) != nil)
  }

  @Test
  func `retransmitting parent image deletes relative placements`() {
    var vt = term()
    for input in [
      "a=t,f=24,s=1,v=1,i=1;AAAA", "a=t,f=24,s=1,v=1,i=2;AAAA",
      "a=p,i=1,p=1,C=1", "a=p,i=2,p=1,P=1,Q=1",
    ] { #expect(vt.exec(input).hasSuffix(";OK\u{1B}\\")) }
    #expect(vt.storage.placements.count == 2)
    #expect(vt.exec("a=t,f=24,s=1,v=1,i=1;AAAA") == ok("i=1"))
    #expect(vt.storage.placements.isEmpty)
    #expect(vt.storage.image(id: 2) == nil)
  }

  @Test
  func `relative placement parent fallback picks lowest external id`() throws {
    var vt = term()
    for input in [
      "a=t,f=24,s=1,v=1,i=1;AAAA", "a=t,f=24,s=1,v=1,i=2;AAAA",
      "a=p,i=1,p=7,C=1", "a=p,i=1,p=3,C=1", "a=p,i=2,P=1",
    ] { #expect(vt.exec(input).hasSuffix(";OK\u{1B}\\")) }
    let child = try #require(
      vt.storage.placements.first { $0.key.imageID == 2 }
    )
    guard case let .relative(parent, _, _) = child.value.location else {
      Issue.record("not relative")
      return
    }
    #expect(parent == .init(imageID: 1, external: true, id: 3))
  }

  @Test
  func `placements created after a full reset are retained`() {
    var vt = term(80, 24)
    vt.feed("\u{1B}c")
    for input in [
      "a=t,f=24,s=1,v=1,i=1;AAAA", "a=p,i=1,p=1,C=1", "a=p,i=1,p=2,C=1",
      "a=p,i=1,p=3,P=1,Q=2",
    ] { #expect(vt.exec(input).hasSuffix(";OK\u{1B}\\")) }
    #expect(vt.storage.placements.count == 3)
  }

  @Test
  func `relative placement with pruned parent is ENOPARENT`() {
    var vt = term()
    #expect(vt.exec("a=t,f=24,s=1,v=1,i=1;AAAA") == ok("i=1"))
    #expect(vt.exec("a=p,i=1,p=1,C=1") == ok("i=1,p=1"))
    // Ghostty marks the pin garbage; here the anchor row leaves history.
    vt.storage.placements[.init(imageID: 1, external: true, id: 1)]?.location =
      .anchor(row: vt.state.kittyGeometry.firstRow - 1, column: 0)
    #expect(
      vt.exec("a=p,i=1,p=2,P=1,Q=1")
        == apc("i=1,p=2;ENOPARENT: parent placement not found")
    )
    #expect(vt.storage.placements.isEmpty)
  }

  @Test
  func `uppercase delete frees image of cascaded placements`() {
    var vt = term()
    for input in [
      "a=t,f=24,s=1,v=1,i=1;AAAA", "a=p,i=1,p=1,C=1", "a=p,i=1,p=2,P=1,Q=1",
    ] { #expect(vt.exec(input).hasSuffix(";OK\u{1B}\\")) }
    #expect(vt.exec("a=d,d=I,i=1,p=1") == "")
    #expect(vt.storage.placements.isEmpty)
    #expect(vt.storage.image(id: 1) == nil)
  }

  private func tempFile(_ bytes: [UInt8]) throws -> String {
    let path = NSTemporaryDirectory() + "swiftty-oracle-\(UUID().uuidString)"
    try Data(bytes).write(to: URL(fileURLWithPath: path))
    return path
  }
}

// MARK: graphics_exec.zig, animation

struct KittyAnimationExecOracleTests {
  private func animated() -> VT {
    var vt = term()
    _ = vt.exec("a=t,f=24,s=1,v=1,i=1;/wAA")
    return vt
  }

  @Test
  func `new frame with default gap responds with frame number`() throws {
    var vt = animated()
    #expect(vt.exec("a=f,i=1,f=24,s=1,v=1;AAD/") == apc("i=1,r=2;OK"))
    let img = try #require(vt.storage.image(id: 1))
    #expect(img.format == .rgba)
    #expect(img.pixels?.bytes == [255, 0, 0, 255])
    let anim = try #require(img.animation)
    #expect(anim.frameCount == 2)
    #expect(anim.rootGap == 0)
    #expect(anim.frames[0].gap == 40)
    #expect(anim.frames[0].pixels.bytes == [0, 0, 255, 255])
    #expect(img.displayedPixels?.bytes == [255, 0, 0, 255])
    #expect(vt.storage.totalBytes == 8)
  }

  @Test
  func `frame gap normalization on create`() throws {
    var vt = animated()
    #expect(vt.exec("a=f,i=1,f=24,s=1,v=1,z=100;AAD/") == apc("i=1,r=2;OK"))
    #expect(vt.exec("a=f,i=1,f=24,s=1,v=1,z=-5;AAD/") == apc("i=1,r=3;OK"))
    let anim = try #require(vt.storage.image(id: 1)?.animation)
    #expect(anim.frames[0].gap == 100)
    #expect(anim.frames[1].gap == 0)
  }

  @Test
  func `background fill and offset composition`() throws {
    var vt = term()
    _ = vt.exec("a=t,f=24,s=2,v=1,i=1;////////")
    #expect(
      vt.exec("a=f,i=1,f=24,s=1,v=1,x=1,Y=4278190335;////") == apc("i=1,r=2;OK")
    )
    let anim = try #require(vt.storage.image(id: 1)?.animation)
    #expect(
      anim.frames[0].pixels.bytes == [255, 0, 0, 255, 255, 255, 255, 255]
    )
  }

  @Test
  func `create from base frame with overwrite`() throws {
    var vt = animated()
    #expect(
      vt.exec("a=f,i=1,f=32,s=1,v=1,c=1,X=1;AAD/gA==") == apc("i=1,r=2;OK")
    )
    #expect(
      vt.storage.image(id: 1)?.animation?.frames[0].pixels.bytes == [
        0, 0, 255, 128,
      ]
    )
  }

  @Test
  func `alpha blend composes over base frame`() throws {
    var vt = animated()
    #expect(vt.exec("a=f,i=1,f=32,s=1,v=1,c=1;AAD//w==") == apc("i=1,r=2;OK"))
    #expect(vt.exec("a=f,i=1,f=32,s=1,v=1,c=1;AAD/AA==") == apc("i=1,r=3;OK"))
    let anim = try #require(vt.storage.image(id: 1)?.animation)
    #expect(anim.frames[0].pixels.bytes == [0, 0, 255, 255])
    #expect(anim.frames[1].pixels.bytes == [255, 0, 0, 255])
  }

  @Test
  func `edit root frame bumps generation`() throws {
    var vt = animated()
    let gen1 = try #require(vt.storage.image(id: 1)?.generation)
    #expect(vt.exec("a=f,i=1,f=24,s=1,v=1,r=1;AAD/") == apc("i=1,r=1;OK"))
    let img = try #require(vt.storage.image(id: 1))
    #expect(img.pixels?.bytes == [0, 0, 255, 255])
    #expect(img.generation > gen1)
  }

  @Test
  func `edit frame gap without data change`() throws {
    var vt = animated()
    _ = vt.exec("a=f,i=1,f=24,s=1,v=1,z=77;AAD/")
    #expect(vt.exec("a=f,i=1,f=24,s=1,v=1,r=2;/wAA") == apc("i=1,r=2;OK"))
    #expect(vt.storage.image(id: 1)?.animation?.frames[0].gap == 77)
    #expect(vt.exec("a=f,i=1,f=24,s=1,v=1,r=2,z=-1;/wAA") == apc("i=1,r=2;OK"))
    #expect(vt.storage.image(id: 1)?.animation?.frames[0].gap == 0)
  }

  @Test
  func `frame errors`() {
    var vt = animated()
    for (input, message) in [
      ("a=f,i=9,f=24,s=1,v=1;AAD/", "ENOENT: image not found"),
      (
        "a=f,i=1,f=24,s=2,v=1;////////", "EINVAL: frame dimensions exceed image"
      ), ("a=f,i=1,f=24,s=1,v=1,c=5;AAD/", "EINVAL: base frame not found"),
      ("a=f,i=1,f=24,s=1,v=1;AA==", "ENODATA: insufficient data"),
    ] {
      let reply = vt.exec(input)
      #expect(reply.hasSuffix(";\(message)\u{1B}\\"), "\(input): \(reply)")
    }
    #expect((vt.storage.image(id: 1)?.animation?.frames.count ?? 0) == 0)
  }

  @Test
  func `excess frame data is truncated`() {
    var vt = animated()
    #expect(vt.exec("a=f,i=1,f=24,s=1,v=1;AAD/////") == apc("i=1,r=2;OK"))
    #expect(
      vt.storage.image(id: 1)?.animation?.frames[0].pixels.bytes == [
        0, 0, 255, 255,
      ]
    )
  }

  @Test
  func `chunked frame transmission`() throws {
    var vt = term()
    _ = vt.exec("a=t,f=24,s=2,v=1,i=1;////////")
    #expect(vt.exec("a=f,i=1,f=24,s=2,v=1,z=60,m=1;/wAA") == "")
    #expect(vt.storage.loading != nil)
    #expect(vt.exec("a=f,m=0;AAD/") == apc("i=1,r=2;OK"))
    #expect(vt.storage.loading == nil)
    let anim = try #require(vt.storage.image(id: 1)?.animation)
    #expect(anim.frames[0].gap == 60)
    #expect(anim.frames[0].pixels.bytes == [255, 0, 0, 255, 0, 0, 255, 255])
  }

  @Test
  func `chunked frame continuation without a=f`() {
    var vt = term()
    _ = vt.exec("a=t,f=24,s=2,v=1,i=1;////////")
    #expect(vt.exec("a=f,i=1,f=24,s=2,v=1,m=1;/wAA") == "")
    #expect(vt.exec("m=0;AAD/") == apc("i=1,r=2;OK"))
    #expect(vt.storage.image(id: 1)?.animation?.frames.count == 1)
  }

  @Test
  func `non-direct transmission abandons chunked frame load`() throws {
    var vt = term()
    vt.state.kittyGraphicsMedia = .all
    let path = NSTemporaryDirectory() + "swiftty-oracle-\(UUID().uuidString)"
    try Data([0, 255, 0, 0, 255, 0]).write(to: URL(fileURLWithPath: path))
    defer { unlink(path) }
    _ = vt.exec("a=t,f=24,s=2,v=1,i=1;////////")
    #expect(vt.exec("a=f,i=1,f=24,s=2,v=1,m=1;/wAA") == "")
    #expect(vt.storage.loading != nil)
    #expect(
      vt.exec("a=f,t=f,i=1,f=24,s=2,v=1;" + b64(Array(path.utf8)))
        == apc("i=1,r=2;OK")
    )
    #expect(vt.storage.loading == nil)
    let anim = try #require(vt.storage.image(id: 1)?.animation)
    #expect(anim.frames.count == 1)
    #expect(anim.frames[0].pixels.bytes == [0, 255, 0, 255, 0, 255, 0, 255])
  }

  @Test
  func `control command sets gap current state and loops`() throws {
    var vt = animated()
    _ = vt.exec("a=f,i=1,f=24,s=1,v=1;AAD/")
    let gen1 = try #require(vt.storage.image(id: 1)?.generation)
    #expect(vt.exec("a=a,i=1,r=1,z=50,c=2,s=3,v=3") == "")
    let img = try #require(vt.storage.image(id: 1))
    let anim = try #require(img.animation)
    #expect(anim.rootGap == 50)
    #expect(anim.currentIndex == 1)
    #expect(anim.state == .running)
    #expect(anim.maxLoops == 2)
    #expect(img.generation > gen1)
    #expect(img.displayedPixels?.bytes == [0, 0, 255, 255])
  }

  @Test
  func `control command ignores invalid values`() throws {
    var vt = animated()
    #expect(vt.exec("a=a,i=1,r=9,z=50,c=9,s=7") == "")
    let anim = try #require(vt.storage.image(id: 1)?.animation)
    #expect(anim.rootGap == 0)
    #expect(anim.currentIndex == 0)
    #expect(anim.state == .stopped)
  }

  @Test
  func `control command missing image responds ENOENT`() {
    var vt = term()
    #expect(vt.exec("a=a,i=9,s=3") == apc("i=9;ENOENT: image not found"))
  }

  @Test
  func `compose frames`() {
    var vt = term()
    _ = vt.exec("a=t,f=24,s=2,v=1,i=1;/wAAAAD/")
    _ = vt.exec("a=f,i=1,f=24,s=1,v=1;////")
    // Ghostty's response has frame 0: no r= key.
    #expect(vt.exec("a=c,i=1,r=1,c=2,w=1,h=1,X=1,x=0") == ok("i=1"))
    #expect(
      vt.storage.image(id: 1)?.animation?.frames[0].pixels.bytes == [
        0, 0, 255, 255, 0, 0, 0, 0,
      ]
    )
  }

  @Test
  func `compose current frame bumps generation`() throws {
    var vt = term()
    _ = vt.exec("a=t,f=24,s=2,v=1,i=1;////////")
    let gen1 = try #require(vt.storage.image(id: 1)?.generation)
    #expect(vt.exec("a=c,i=1,r=1,c=1,w=1,h=1,x=1") == ok("i=1"))
    #expect(try #require(vt.storage.image(id: 1)?.generation) > gen1)
  }

  @Test
  func `compose errors`() {
    var vt = animated()
    for (input, message) in [
      ("a=c,i=9,r=1,c=1", "ENOENT: image not found"),
      ("a=c,i=1,r=2,c=1", "ENOENT: source frame not found"),
      ("a=c,i=1,r=1,c=2", "ENOENT: destination frame not found"),
      ("a=c,i=1,r=1,c=1,x=1", "EINVAL: destination rectangle out of bounds"),
      ("a=c,i=1,r=1,c=1,X=1", "EINVAL: source rectangle out of bounds"),
      ("a=c,i=1,r=1,c=1", "EINVAL: source and destination rectangles overlap"),
    ] {
      let reply = vt.exec(input)
      #expect(reply.hasSuffix(";\(message)\u{1B}\\"), "\(input): \(reply)")
    }
  }

  @Test
  func `delete frame promotes root and fixes current`() throws {
    var vt = animated()
    _ = vt.exec("a=f,i=1,f=24,s=1,v=1,z=10;AAD/")
    _ = vt.exec("a=f,i=1,f=24,s=1,v=1,z=20;////")
    let before = vt.storage.totalBytes
    #expect(vt.exec("a=d,d=f,i=1") == "")
    var img = try #require(vt.storage.image(id: 1))
    #expect(img.animation?.frameCount == 2)
    #expect(img.animation?.rootGap == 10)
    #expect(img.pixels?.bytes == [0, 0, 255, 255])
    #expect(vt.storage.totalBytes == before - 4)
    #expect(vt.exec("a=d,d=f,i=1,r=9") == "")
    img = try #require(vt.storage.image(id: 1))
    #expect(img.animation?.frameCount == 1)
    #expect(vt.storage.totalBytes == before - 8)
    #expect(vt.exec("a=d,d=f,i=1") == "")
    #expect(vt.storage.image(id: 1) != nil)
  }

  @Test
  func `uppercase frame delete removes non-animated image`() {
    var vt = term()
    #expect(vt.exec("a=T,f=24,s=1,v=1,i=1,C=1;/wAA") == ok("i=1"))
    #expect(vt.storage.placements.count == 1)
    #expect(vt.exec("a=d,d=F,i=1") == "")
    #expect(vt.storage.image(id: 1) == nil)
    #expect(vt.storage.placements.isEmpty)
    #expect(vt.storage.totalBytes == 0)
  }

  @Test
  func `deleting current frame refreshes display`() throws {
    var vt = animated()
    for input in [
      "a=f,i=1,f=24,s=1,v=1;AAD/", "a=f,i=1,f=24,s=1,v=1;////", "a=a,i=1,c=3",
    ] { _ = vt.exec(input) }
    var img = try #require(vt.storage.image(id: 1))
    #expect(img.animation?.currentIndex == 2)
    let gen1 = img.generation
    #expect(vt.exec("a=d,d=f,i=1,r=3") == "")
    img = try #require(vt.storage.image(id: 1))
    #expect(img.animation?.currentIndex == 1)
    #expect(img.generation > gen1)
    #expect(img.displayedPixels?.bytes == [0, 0, 255, 255])
  }

  @Test
  func `retransmitting base image resets animation`() throws {
    var vt = animated()
    _ = vt.exec("a=f,i=1,f=24,s=1,v=1;AAD/")
    #expect(vt.storage.totalBytes == 8)
    #expect(vt.exec("a=t,f=24,s=1,v=1,i=1;/wAA") == ok("i=1"))
    #expect(try #require(vt.storage.image(id: 1)).animation == nil)
    #expect(vt.storage.totalBytes == 3)
  }

  @Test
  func `control negative gap makes frame gapless`() {
    var vt = animated()
    _ = vt.exec("a=f,i=1,f=24,s=1,v=1;AAD/")
    #expect(vt.exec("a=a,i=1,r=2,z=-1") == "")
    #expect(vt.storage.image(id: 1)?.animation?.frames[0].gap == 0)
  }
}

// MARK: graphics_storage.zig

/// Ghostty's storage tests call `ImageStorage` directly with images that
/// carry metadata only; `pixels` stays nil unless a test gives data.
private func image(
  _ id: UInt32,
  _ width: UInt32 = 0,
  _ height: UInt32 = 0,
  number: UInt32 = 0,
  data: [UInt8]? = nil,
  transient: Bool = false
) -> KittyGraphics.Image {
  var i = KittyGraphics.Image(
    id: id,
    number: number,
    width: width,
    height: height
  )
  i.transient = transient
  if let data {
    i.pixels = KittyImagePixels(
      width: data.count,
      height: 1,
      bytesPerPixel: 1,
      bytes: data
    )
  }
  return i
}

/// Ghostty's `stars()`: 64 bytes.
private let stars = [UInt8](repeating: 0x2A, count: 64)

extension VT {
  /// Ghostty's `t.width_px` / `t.height_px` over the grid.
  fileprivate mutating func pixels(_ width: Int, _ height: Int) {
    state.cellPixelSize = (width / state.columns, height / state.rows)
  }

  fileprivate var geometry: KittyImageStorage.Geometry { state.kittyGeometry }

  fileprivate func add(_ i: KittyGraphics.Image) throws { try storage.add(i) }

  fileprivate func pin(_ x: Int, _ y: Int) -> KittyImageStorage.Location {
    .anchor(row: state.screenAbsoluteRow(y), column: x)
  }

  fileprivate func place(
    _ imageID: UInt32,
    _ placementID: UInt32,
    _ placement: KittyImageStorage.Placement
  ) throws {
    try storage.addPlacement(
      imageID: imageID,
      placementID: placementID,
      placement,
      state.kittyGeometry
    )
  }

  fileprivate func place(
    _ imageID: UInt32,
    _ placementID: UInt32,
    x: Int,
    y: Int
  ) throws { try place(imageID, placementID, .init(location: pin(x, y))) }

  fileprivate func delete(_ action: KittyGraphics.Delete) {
    storage.delete(
      action,
      cursor: (state.cursor.x, state.cursor.y),
      state.kittyGeometry
    )
  }

  fileprivate func has(
    _ imageID: UInt32,
    _ id: UInt32,
    external: Bool = true
  ) -> Bool {
    storage.placements[.init(imageID: imageID, external: external, id: id)]
      != nil
  }

  /// Active-area coordinate of an anchored placement; nil in history.
  fileprivate func point(_ imageID: UInt32, _ id: UInt32) -> (x: Int, y: Int)? {
    guard
      case let .anchor(row, column) = storage.placements[
        .init(imageID: imageID, external: true, id: id)
      ]?
      .location
    else { return nil }
    let y = row - state.screenAbsoluteRow(0)
    return y >= 0 && y < state.rows ? (column, y) : nil
  }
}

private func key(
  _ imageID: UInt32,
  _ id: UInt32
) -> KittyImageStorage.PlacementKey {
  .init(imageID: imageID, external: true, id: id)
}

struct KittyImageStorageOracleTests {
  @Test
  func `add placement with zero placement id`() throws {
    var vt = term(100, 100)
    vt.pixels(100, 100)
    try vt.add(image(1, 50, 50))
    try vt.add(image(2, 25, 25))
    try vt.place(1, 0, x: 25, y: 25)
    try vt.place(1, 0, x: 25, y: 25)
    #expect(vt.storage.placements.count == 2)
    #expect(vt.storage.images.count == 2)
    #expect(true == (vt.has(1, 0, external: false)))
    #expect(true == (vt.has(1, 1, external: false)))
  }

  @Test
  func `replacing placement keeps one entry at the new location`() throws {
    let vt = term(3, 3)
    try vt.add(image(1))
    try vt.place(1, 1, x: 1, y: 1)
    try vt.place(1, 1, x: 2, y: 2)
    #expect(vt.storage.placements.count == 1)
    #expect(vt.storage.placements[key(1, 1)]?.location == vt.pin(2, 2))
  }

  @Test
  func `adding placement reclaims garbage placements`() throws {
    let vt = term(3, 3)
    try vt.add(image(1))
    try vt.place(
      1,
      0,
      .init(location: .anchor(row: vt.geometry.firstRow - 1, column: 0))
    )
    try vt.place(1, 0, x: 1, y: 1)
    #expect(vt.storage.placements.count == 1)
    #expect(
      vt.storage.placements[.init(imageID: 1, external: false, id: 1)]?.location
        == vt.pin(1, 1)
    )
  }

  @Test
  func `placement count limit permits replacement`() throws {
    let vt = term(3, 3)
    try vt.add(image(1))
    try vt.place(1, 1, .init(location: .virtual))
    vt.storage.images[1]!.placementCount = 1 << 30
    try vt.place(1, 1, .init(location: .virtual))
    #expect(throws: KittyGraphics.LoadError.outOfMemory) {
      try vt.place(1, 2, .init(location: .virtual))
    }
    #expect(vt.storage.placements.count == 1)
  }

  private func threeImagesTwoPlaced() throws -> VT {
    let vt = term(3, 3)
    for id in UInt32(1) ... 3 { try vt.add(image(id)) }
    try vt.place(1, 1, x: 1, y: 1)
    try vt.place(2, 1, x: 1, y: 1)
    return vt
  }

  @Test
  func `delete all visible placements and matching images`() throws {
    let vt = try threeImagesTwoPlaced()
    vt.storage.limit = 5000
    let dirty = vt.storage.dirty
    vt.delete(.all(delete: true))
    #expect(vt.storage.dirty != dirty)
    #expect(Set(vt.storage.images.keys) == [3])
    #expect(vt.storage.placements.isEmpty)
    #expect(vt.storage.limit == 5000)
  }

  @Test
  func `delete all includes placements spanning into active area`() throws {
    var vt = VT(2, 2, scrollback: 4096)
    vt.pixels(2, 2)
    try vt.add(image(1, 1, 2))
    try vt.place(1, 1, x: 0, y: 0)
    vt.feed("\u{1B}[2;1H\n")
    #expect(vt.point(1, 1) == nil)
    vt.delete(.all(delete: true))
    #expect(vt.storage.placements.isEmpty)
    #expect(vt.storage.images.isEmpty)
  }

  @Test
  func `delete all placements`() throws {
    let vt = try threeImagesTwoPlaced()
    let dirty = vt.storage.dirty
    vt.delete(.all(delete: false))
    #expect(vt.storage.dirty != dirty)
    #expect(vt.storage.placements.isEmpty)
    #expect(vt.storage.images.count == 3)
  }

  @Test
  func `delete all placements by image id, with and without unused images`()
    throws
  {
    var vt = try threeImagesTwoPlaced()
    var dirty = vt.storage.dirty
    vt.delete(.id(delete: false, imageID: 2, placementID: 0))
    #expect(vt.storage.dirty != dirty)
    #expect(vt.storage.placements.count == 1)
    #expect(vt.storage.images.count == 3)
    vt = try threeImagesTwoPlaced()
    dirty = vt.storage.dirty
    vt.delete(.id(delete: true, imageID: 2, placementID: 0))
    #expect(vt.storage.dirty != dirty)
    #expect(vt.storage.placements.count == 1)
    #expect(vt.storage.images.count == 2)
  }

  @Test
  func `delete placement by specific id`() throws {
    let vt = term(3, 3)
    for id in UInt32(1) ... 3 { try vt.add(image(id)) }
    try vt.place(1, 1, x: 1, y: 1)
    try vt.place(1, 2, x: 1, y: 1)
    try vt.place(2, 1, x: 1, y: 1)
    let dirty = vt.storage.dirty
    vt.delete(.id(delete: true, imageID: 1, placementID: 2))
    #expect(vt.storage.dirty != dirty)
    #expect(vt.storage.placements.count == 2)
    #expect(vt.storage.images.count == 3)
  }

  @Test
  func `uppercase id delete without a matching placement changes nothing`()
    throws
  {
    let vt = term(3, 3)
    try vt.add(image(1))
    let (dirty, generation) = (vt.storage.dirty, vt.storage.generation)
    vt.delete(.id(delete: true, imageID: 1, placementID: 7))
    #expect(vt.storage.image(id: 1) != nil)
    #expect(vt.storage.dirty == dirty)
    #expect(vt.storage.generation == generation)
  }

  @Test
  func `uppercase id delete frees image after placement matches`() throws {
    let vt = term(3, 3)
    try vt.add(image(1))
    try vt.place(1, 9, x: 1, y: 1)
    let dirty = vt.storage.dirty
    vt.delete(.id(delete: true, imageID: 1, placementID: 9))
    #expect(vt.storage.placements.isEmpty)
    #expect(vt.storage.images.isEmpty)
    #expect(vt.storage.dirty != dirty)
  }

  @Test
  func `uppercase id delete without placement frees unplaced image`() throws {
    let vt = term(3, 3)
    try vt.add(image(1))
    let dirty = vt.storage.dirty
    vt.delete(.id(delete: true, imageID: 1, placementID: 0))
    #expect(vt.storage.images.isEmpty)
    #expect(vt.storage.dirty != dirty)
  }

  /// Ghostty's 100×100 terminal with 1 px cells, a 50×50 image at (0,0)
  /// and a 25×25 one at (25,25), both placements of image 1.
  private func twoSquares() throws -> VT {
    var vt = term(100, 100)
    vt.pixels(100, 100)
    try vt.add(image(1, 50, 50))
    try vt.add(image(2, 25, 25))
    try vt.place(1, 1, x: 0, y: 0)
    try vt.place(1, 2, x: 25, y: 25)
    return vt
  }

  @Test(arguments: [false, true])
  func `delete intersecting cursor`(unused: Bool) throws {
    var vt = try twoSquares()
    vt.feed("\u{1B}[13;13H")
    let dirty = vt.storage.dirty
    vt.delete(.cursor(delete: unused))
    #expect(vt.storage.dirty != dirty)
    #expect(vt.storage.placements.count == 1)
    #expect(vt.storage.images.count == 2)
    #expect(true == (vt.has(1, 2)))
  }

  @Test
  func `delete intersecting cursor hits multiple`() throws {
    var vt = try twoSquares()
    vt.feed("\u{1B}[27;27H")
    let dirty = vt.storage.dirty
    vt.delete(.cursor(delete: true))
    #expect(vt.storage.dirty != dirty)
    #expect(vt.storage.placements.isEmpty)
    #expect(vt.storage.images.count == 1)
  }

  private func twoTens() throws -> VT {
    var vt = term(100, 100)
    vt.pixels(100, 100)
    try vt.add(image(1, 10, 10))
    try vt.place(1, 1, x: 0, y: 0)
    try vt.place(1, 2, x: 20, y: 0)
    return vt
  }

  @Test
  func `delete intersecting cursor checks interior row column`() throws {
    var vt = try twoTens()
    vt.feed("\u{1B}[6;22H")
    vt.delete(.cursor(delete: false))
    #expect(vt.storage.placements.count == 1)
    #expect(true == (vt.has(1, 1)))
  }

  @Test
  func `delete intersecting cell checks interior row column`() throws {
    let vt = try twoTens()
    vt.delete(.cell(delete: false, x: 22, y: 6))
    #expect(vt.storage.placements.count == 1)
    #expect(true == (vt.has(1, 1)))
  }

  @Test
  func `delete by column and row`() throws {
    var vt = try twoSquares()
    var dirty = vt.storage.dirty
    vt.delete(.column(delete: false, x: 60))
    #expect(vt.storage.dirty != dirty)
    #expect(vt.storage.placements.count == 1)
    #expect(vt.storage.images.count == 2)
    #expect(true == (vt.has(1, 1)))
    vt = try twoSquares()
    dirty = vt.storage.dirty
    vt.delete(.row(delete: false, y: 60))
    #expect(vt.storage.dirty != dirty)
    #expect(vt.storage.placements.count == 1)
    #expect(true == (vt.has(1, 1)))
  }

  @Test
  func `delete by column and row 1x1`() throws {
    var vt = term(100, 100)
    vt.pixels(100, 100)
    try vt.add(image(1, 1, 1))
    for (p, x) in [(UInt32(1), 0), (2, 1), (3, 2)] {
      try vt.place(1, p, x: x, y: 0)
    }
    vt.delete(.column(delete: false, x: 2))
    #expect(vt.storage.placements.count == 2)
    #expect(vt.storage.images.count == 1)
    #expect(true == (vt.has(1, 1) && vt.has(1, 3)))
    var rows = term(100, 100)
    rows.pixels(100, 100)
    try rows.add(image(1, 1, 1))
    for (p, y) in [(UInt32(1), 0), (2, 1), (3, 2)] {
      try rows.place(1, p, x: 0, y: y)
    }
    rows.delete(.row(delete: false, y: 2))
    #expect(rows.storage.placements.count == 2)
    #expect(true == (rows.has(1, 1) && rows.has(1, 3)))
  }

  @Test
  func `delete images by range`() throws {
    var vt = try threeImagesTwoPlaced()
    var dirty = vt.storage.dirty
    vt.delete(.range(delete: false, first: 1, last: 2))
    #expect(vt.storage.dirty != dirty)
    #expect(vt.storage.images.count == 3)
    #expect(vt.storage.placements.isEmpty)

    vt = try threeImagesTwoPlaced()
    dirty = vt.storage.dirty
    vt.delete(.range(delete: true, first: 1, last: 2))
    #expect(vt.storage.dirty != dirty)
    #expect(vt.storage.images.count == 1)
    #expect(vt.storage.placements.isEmpty)

    for unused in [false, true] {
      vt = try threeImagesTwoPlaced()
      try vt.place(3, 1, x: 1, y: 1)
      dirty = vt.storage.dirty
      vt.delete(.range(delete: unused, first: 2, last: 2))
      #expect(vt.storage.dirty != dirty)
      #expect(vt.storage.images.count == (unused ? 2 : 3))
      #expect(vt.storage.placements.count == 2)
      #expect(true == (vt.has(1, 1) && vt.has(3, 1)))
    }
  }

  @Test
  func `uppercase range from zero deletes unplaced image data`() throws {
    let vt = term(3, 3)
    for id in UInt32(1) ... 3 { try vt.add(image(id)) }
    vt.delete(.range(delete: true, first: 0, last: 2))
    #expect(Set(vt.storage.images.keys) == [3])
  }

  @Test
  func `delete images by empty range`() throws {
    let vt = term(3, 3)
    try vt.add(image(1))
    try vt.add(image(2))
    try vt.place(1, 1, x: 1, y: 1)
    try vt.place(2, 1, x: 1, y: 1)
    for (first, last) in [(UInt32(5), UInt32(4)), (5, 0), (0, 0)] {
      vt.delete(.range(delete: true, first: first, last: last))
      #expect(vt.storage.images.count == 2)
      #expect(vt.storage.placements.count == 2)
    }
  }

  @Test
  func `erase display preserves scrollback and reclaims unplaced images`()
    throws
  {
    var vt = VT(2, 2, scrollback: 4096)
    vt.pixels(2, 2)
    try vt.add(image(1, 1, 1))
    try vt.place(1, 1, x: 0, y: 0)
    vt.feed("\u{1B}[2;1H\n")
    #expect(vt.point(1, 1) == nil)
    try vt.add(image(2, 1, 1))
    try vt.place(2, 1, x: 0, y: 0)
    try vt.add(image(3, 1, 1))
    vt.feed("\u{1B}[2J")
    #expect(vt.storage.placements.count == 1)
    #expect(true == (vt.has(1, 1)))
    #expect(Set(vt.storage.images.keys) == [1])
  }

  @Test
  func `erase scrollback removes placements in history`() throws {
    var vt = VT(2, 2, scrollback: 4096)
    vt.pixels(2, 2)
    try vt.add(image(1, 1, 1))
    try vt.place(1, 1, x: 0, y: 0)
    vt.feed("\u{1B}[2;1H\n")
    try vt.add(image(2, 1, 1))
    try vt.place(2, 1, x: 0, y: 0)
    vt.feed("\u{1B}[3J")
    #expect(vt.storage.placements.count == 1)
    #expect(true == (vt.has(2, 1)))
  }

  @Test
  func `cell offsets stay within explicit destination rectangle`() {
    var vt = term(5, 5)
    vt.pixels(50, 100)
    let p = KittyImageStorage.Placement(
      location: .virtual,
      xOffset: 3,
      yOffset: 4,
      columns: 2,
      rows: 1
    )
    let i = image(1, 4, 3)
    #expect(KittyImageStorage.pixelSize(p, i, vt.geometry) == (17, 16))
    #expect(KittyImageStorage.gridSize(p, i, vt.geometry) == (2, 1))
  }

  @Test
  func `cell offsets clamp to cell bounds`() {
    var vt = term(5, 5)
    vt.pixels(50, 100)
    let p = KittyImageStorage.Placement(
      location: .virtual,
      xOffset: .max,
      yOffset: .max,
      columns: 1,
      rows: 1
    )
    #expect(KittyImageStorage.cellOffset(p, vt.geometry) == (9, 19))
    #expect(
      KittyImageStorage.pixelSize(p, image(1, 1, 1), vt.geometry) == (1, 1)
    )
  }

  @Test
  func `aspect ratio calculation when only columns or rows specified`() {
    var vt = term(100, 100)
    vt.pixels(1000, 2000)
    let i = image(1, 16, 9)
    #expect(
      KittyImageStorage.pixelSize(
        .init(location: .virtual, columns: 10),
        i,
        vt.geometry
      ) == (100, 56)
    )
    #expect(
      KittyImageStorage.pixelSize(
        .init(location: .virtual, rows: 5),
        i,
        vt.geometry
      ) == (178, 100)
    )
  }

  @Test
  func `source rectangles are intersected before sizing`() {
    let none = term(5, 5)
    #expect(
      KittyImageStorage.pixelSize(
        .init(location: .virtual, sourceX: 3, sourceY: 1),
        image(1, 4, 3),
        none.geometry
      ) == (1, 2)
    )
    var vt = term(10, 10)
    vt.pixels(100, 100)
    let p = KittyImageStorage.Placement(
      location: .virtual,
      sourceX: 8,
      sourceY: 7,
      sourceWidth: 8,
      sourceHeight: 8,
      columns: 2
    )
    #expect(
      KittyImageStorage.pixelSize(p, image(1, 10, 10), vt.geometry) == (20, 30)
    )
  }

  @Test
  func `placement geometry handles untrusted dimensions`() {
    let max = UInt32.max
    var g = KittyImageStorage.Geometry(
      cellWidth: max / 2,
      cellHeight: max / 2,
      columns: 2,
      rows: 2,
      screenTop: 0,
      firstRow: 0
    )
    let one = image(1, 1, 1)
    #expect(
      KittyImageStorage.pixelSize(
        .init(location: .virtual, columns: 3, rows: 3),
        one,
        g
      ) == (max, max)
    )
    #expect(
      KittyImageStorage.pixelSize(
        .init(location: .virtual, sourceHeight: max, columns: 3),
        one,
        g
      ) == (max, max)
    )
    #expect(
      KittyImageStorage.pixelSize(
        .init(location: .virtual, sourceWidth: max, rows: 3),
        one,
        g
      ) == (max, max)
    )
    g.cellWidth = 1
    g.cellHeight = 1
    #expect(
      KittyImageStorage.gridSize(
        .init(location: .virtual, xOffset: max, yOffset: max),
        one,
        g
      ) == (1, 1)
    )
    let wide = KittyImageStorage.Placement(
      location: .anchor(row: 0, column: 0),
      columns: max,
      rows: 1
    )
    #expect(KittyImageStorage.cells(wide, one, g)?.right == 1)
    g.firstRow = 1  // Ghostty: the pin is garbage.
    #expect(
      KittyImageStorage.cells(
        .init(location: .anchor(row: 0, column: 0), columns: 1, rows: 1),
        one,
        g
      ) == nil
    )
    g.firstRow = 0
    g.cellWidth = 0
    g.cellHeight = 0
    let unsized = KittyImageStorage.Placement(
      location: .anchor(row: 0, column: 0),
      columns: 1
    )
    #expect(KittyImageStorage.gridSize(unsized, one, g) == (0, 0))
    #expect(KittyImageStorage.cells(unsized, one, g) == nil)
  }

  @Test
  func `generation stamps on image add and replace`() throws {
    let vt = term(3, 3)
    #expect(vt.storage.generation == 0)
    try vt.add(image(1, 1, 1))
    let gen1 = vt.storage.generation
    #expect(gen1 > 0)
    #expect(vt.storage.image(id: 1)?.generation == gen1)
    try vt.add(image(2, 1, 1))
    let gen2 = vt.storage.generation
    #expect(gen2 > gen1)
    #expect(vt.storage.image(id: 2)?.generation == gen2)
    try vt.add(image(1, 1, 1))
    let gen3 = vt.storage.generation
    #expect(gen3 > gen2)
    #expect(vt.storage.image(id: 1)?.generation == gen3)
    #expect(vt.storage.image(id: 2)?.generation == gen2)
  }

  @Test
  func `generation bumps on placement and delete`() throws {
    let vt = term(3, 3)
    try vt.add(image(1))
    let added = vt.storage.generation
    try vt.place(1, 1, x: 1, y: 1)
    let placed = vt.storage.generation
    #expect(placed > added)
    _ = vt.storage.image(id: 1)
    _ = vt.storage.image(number: 1)
    #expect(vt.storage.generation == placed)
    vt.delete(.all(delete: true))
    #expect(vt.storage.generation > placed)
  }

  @Test
  func `generation bumps when setLimit evicts or disables`() throws {
    let vt = term(3, 3)
    try vt.add(image(1, 1, 1, data: Array("1234".utf8)))
    let (gen, dirty) = (vt.storage.generation, vt.storage.dirty)
    vt.storage.setLimit(1)
    #expect(vt.storage.dirty != dirty)
    #expect(vt.storage.generation > gen)
    #expect(vt.storage.images.isEmpty)
    let (gen2, dirty2) = (vt.storage.generation, vt.storage.dirty)
    vt.storage.setLimit(0)
    #expect(vt.storage.dirty != dirty2)
    #expect(vt.storage.generation > gen2)
  }

  @Test
  func `image by number returns most recently transmitted`() throws {
    let vt = term(3, 3)
    try vt.add(image(1, number: 7))
    try vt.add(image(2, number: 7))
    #expect(vt.storage.image(number: 7)?.id == 2)
    try vt.add(image(1, number: 7))
    #expect(vt.storage.image(number: 7)?.id == 1)
    vt.storage.markContentChanged(2)
    #expect(vt.storage.image(number: 7)?.id == 1)
    #expect(vt.storage.imageID(id: 0, number: 7) == 1)
  }

  @Test
  func `next generation is unique and monotonic`() {
    let a = KittyImageStorage.nextGeneration()
    let b = KittyImageStorage.nextGeneration()
    #expect(b > a)
    #expect(a > 0)
  }

  @Test
  func `no-op delete does not mark a mutation`() throws {
    let vt = term(3, 3)
    vt.delete(.all(delete: true))
    #expect(vt.storage.dirty == 0)
    #expect(vt.storage.generation == 0)
    try vt.add(image(1))
    try vt.place(1, 1, x: 1, y: 1)
    let (gen, dirty) = (vt.storage.generation, vt.storage.dirty)
    vt.delete(.id(delete: false, imageID: 42, placementID: 0))
    #expect(vt.storage.dirty == dirty)
    #expect(vt.storage.generation == gen)
    vt.delete(.id(delete: false, imageID: 1, placementID: 0))
    #expect(vt.storage.dirty != dirty)
    #expect(vt.storage.generation > gen)
  }

  @Test
  func `evicts images in priority order`() throws {
    let vt = term(3, 3)
    vt.storage.limit = 192
    try vt.add(image(1, data: stars))
    try vt.add(image(2, data: stars, transient: true))
    try vt.add(image(3, data: stars, transient: true))
    try vt.place(2, 1, x: 1, y: 1)
    let (gen, dirty) = (vt.storage.generation, vt.storage.dirty)
    #expect(vt.storage.evict(96, except: nil))
    #expect(vt.storage.dirty != dirty)
    #expect(vt.storage.generation > gen)
    #expect(Set(vt.storage.images.keys) == [2])
  }

  @Test
  func `eviction releases placements of the oldest transmission`() throws {
    let vt = term(3, 3)
    vt.storage.limit = 128
    try vt.add(image(1, data: stars))
    try vt.place(1, 1, x: 0, y: 0)
    try vt.add(image(2, data: stars))
    try vt.place(2, 1, x: 1, y: 1)
    // A content change is not a newer transmission.
    vt.storage.markContentChanged(1)
    try vt.add(image(3, data: stars))
    #expect(Set(vt.storage.images.keys) == [2, 3])
    #expect(vt.storage.placements.count == 1)
    #expect(true == (vt.has(2, 1)))
  }

  @Test
  func `images awaiting pixels share exact eviction ordering`() throws {
    // Ghostty's pending images: here, images whose pixels are not loaded
    // are sized by their metadata (16×1 RGBA = 64 bytes).
    let vt = term(3, 3)
    vt.storage.limit = 192
    try vt.add(image(1, 16, 1))
    try vt.add(image(2, 16, 1, transient: true))
    try vt.add(image(3, data: stars, transient: true))
    try vt.place(2, 1, x: 1, y: 1)
    #expect(vt.storage.evict(64, except: nil))
    #expect(Set(vt.storage.images.keys) == [1, 2])
    #expect(vt.storage.totalBytes == 128)
  }

  @Test
  func `next explicit image id matches kitty get_free_client_id`() throws {
    let vt = term(3, 3)
    #expect(vt.storage.nextImageID(.explicit) == 1)
    for id in UInt32(1) ... 3 { try vt.add(image(id)) }
    #expect(vt.storage.nextImageID(.explicit) == 4)
    try vt.add(image(100))
    vt.delete(.id(delete: true, imageID: 2, placementID: 0))
    #expect(vt.storage.nextImageID(.explicit) == 2)
    vt.delete(.id(delete: true, imageID: 1, placementID: 0))
    #expect(vt.storage.nextImageID(.explicit) == 1)
  }

  @Test
  func `next implicit image id skips in-use ids`() throws {
    // The wrap past UInt32.max needs Ghostty's writable `next_image_id`.
    let vt = term(3, 3)
    try vt.add(image(2_147_483_647))
    try vt.add(image(2_147_483_648))
    #expect(vt.storage.nextImageID(.implicit) == 2_147_483_649)
    #expect(vt.storage.nextImageID(.implicit) == 2_147_483_650)
  }

  // MARK: Scroll margins (10×6 cells of 10×10 px)

  private func scrollTerminal() -> VT {
    var vt = term(10, 6)
    vt.pixels(100, 60)
    return vt
  }

  @Test
  func `scroll margins placement inside region scrolls and clips at top`()
    throws
  {
    var vt = scrollTerminal()
    try vt.add(image(1, 10, 20))
    try vt.place(1, 1, x: 0, y: 2)
    vt.feed("\u{1B}[2;5r\u{1B}[5;1H\u{1B}D")
    #expect(vt.point(1, 1)! == (0, 1))
    vt.feed("\u{1B}D")
    #expect(vt.point(1, 1)! == (0, 1))
    #expect(vt.storage.placements[key(1, 1)]?.sourceY == 10)
    #expect(vt.storage.placements[key(1, 1)]?.sourceHeight == 10)
    vt.feed("\u{1B}D")
    #expect(vt.storage.placements.isEmpty)
    #expect(vt.storage.images.count == 1)
  }

  @Test
  func `scroll margins placement straddling region does not move`() throws {
    var vt = scrollTerminal()
    try vt.add(image(1, 10, 30))
    try vt.place(1, 1, x: 0, y: 0)
    vt.feed("\u{1B}[1;2r\u{1B}[2;1H\u{1B}D")
    #expect(vt.point(1, 1)! == (0, 0))
    #expect(vt.storage.placements[key(1, 1)]?.sourceY == 0)
    #expect(vt.storage.placements[key(1, 1)]?.sourceHeight == 0)
  }

  @Test
  func `scroll margins placement below region does not move`() throws {
    var vt = scrollTerminal()
    try vt.add(image(1, 10, 10))
    try vt.place(1, 1, x: 0, y: 5)
    vt.feed("\u{1B}[1;4r\u{1B}[4;1H\u{1B}D\u{1B}D")
    #expect(vt.point(1, 1)! == (0, 5))
  }

  @Test
  func `scroll margins reverse index clips at bottom`() throws {
    var vt = scrollTerminal()
    try vt.add(image(1, 10, 20))
    try vt.place(1, 1, x: 0, y: 3)
    vt.feed("\u{1B}[2;5r\u{1B}[2;1H\u{1B}M")
    #expect(vt.point(1, 1)! == (0, 4))
    #expect(vt.storage.placements[key(1, 1)]?.sourceY == 0)
    #expect(vt.storage.placements[key(1, 1)]?.sourceHeight == 10)
    vt.feed("\u{1B}M")
    #expect(vt.storage.placements.isEmpty)
  }

  @Test
  func `scroll margins scaled placement clips proportionally`() throws {
    var vt = scrollTerminal()
    try vt.add(image(1, 10, 40))
    try vt.place(1, 1, .init(location: vt.pin(0, 1), columns: 1, rows: 2))
    vt.feed("\u{1B}[2;3r\u{1B}[3;1H\u{1B}D")
    let p = try #require(vt.storage.placements[key(1, 1)])
    #expect(vt.point(1, 1)! == (0, 1))
    #expect(p.sourceY == 20)
    #expect(p.sourceHeight == 20)
    #expect(p.rows == 1)
    #expect(p.columns == 1)
  }

  @Test
  func `scroll margins left and right margins respect columns`() throws {
    var vt = scrollTerminal()
    try vt.add(image(1, 10, 10))
    try vt.place(1, 1, x: 0, y: 2)
    try vt.place(1, 2, x: 2, y: 2)
    vt.feed("\u{1B}[?69h\u{1B}[2;8s\u{1B}[1S")
    #expect(vt.point(1, 1)! == (0, 2))
    #expect(vt.point(1, 2)! == (2, 1))
  }

  @Test
  func `scroll margins insert and delete lines do not move placements`() throws
  {
    var vt = scrollTerminal()
    try vt.add(image(1, 10, 10))
    try vt.place(1, 1, x: 0, y: 2)
    vt.feed("\u{1B}[2;5r\u{1B}[2;1H\u{1B}[M")
    #expect(vt.point(1, 1)! == (0, 2))
    vt.feed("\u{1B}[L")
    #expect(vt.point(1, 1)! == (0, 2))
  }

  @Test
  func `scroll without margins moves placement into scrollback`() throws {
    var vt = scrollTerminal()
    try vt.add(image(1, 10, 20))
    try vt.place(1, 1, x: 0, y: 0)
    let row = vt.state.screenAbsoluteRow(0)
    vt.feed("\u{1B}[6;1H\u{1B}D")
    #expect(vt.point(1, 1) == nil)
    #expect(
      vt.storage.placements[key(1, 1)]?.location == .anchor(row: row, column: 0)
    )
  }

  @Test
  func `scroll margins large scroll deletes inside placement`() throws {
    var vt = scrollTerminal()
    try vt.add(image(1, 10, 10))
    try vt.place(1, 1, x: 0, y: 2)
    vt.feed("\u{1B}[2;5r\u{1B}[10S")
    #expect(vt.storage.placements.isEmpty)
  }

  @Test
  func `scroll margins straddling placement inside region is restored`() throws
  {
    var vt = scrollTerminal()
    try vt.add(image(1, 10, 20))
    try vt.place(1, 1, x: 0, y: 4)
    vt.feed("\u{1B}[2;5r\u{1B}[5;1H\u{1B}D")
    #expect(vt.point(1, 1)! == (0, 4))
    #expect(vt.storage.placements[key(1, 1)]?.sourceY == 0)
    #expect(vt.storage.placements[key(1, 1)]?.sourceHeight == 0)
  }

  @Test
  func `scroll margins multi-line scroll up with scrollback`() throws {
    var vt = scrollTerminal()
    try vt.add(image(1, 10, 10))
    try vt.place(1, 1, x: 0, y: 2)
    vt.feed("\u{1B}[1;4r\u{1B}[2S")
    #expect(vt.point(1, 1)! == (0, 0))
    vt.feed("\u{1B}[2S")
    #expect(vt.storage.placements.isEmpty)
  }

  // MARK: Relative placements and placeholders

  @Test
  func `resolveChain accumulates offsets to the pin root`() throws {
    let vt = term()
    try vt.add(image(1))
    try vt.place(1, 1, x: 1, y: 1)
    try vt.place(
      1,
      2,
      .init(location: .relative(parent: key(1, 1), horizontal: 2, vertical: 1))
    )
    try vt.place(
      1,
      3,
      .init(location: .relative(parent: key(1, 2), horizontal: -1, vertical: 4))
    )
    guard
      case let .relative(parent, h, v) = vt.storage.placements[key(1, 3)]?
        .location
    else {
      Issue.record("not relative")
      return
    }
    let chain = try #require(
      vt.storage.resolveChain(parent: parent, horizontal: h, vertical: v)
    )
    #expect(chain.rootKey == key(1, 1))
    #expect(chain.root.location == vt.pin(1, 1))
    #expect(chain.horizontal == 1)
    #expect(chain.vertical == 5)
  }

  @Test
  func `resolveChain finds virtual roots`() throws {
    let vt = term()
    try vt.add(image(1))
    try vt.place(1, 1, .init(location: .virtual))
    try vt.place(
      1,
      2,
      .init(location: .relative(parent: key(1, 1), horizontal: 1, vertical: 0))
    )
    let chain = try #require(
      vt.storage.resolveChain(parent: key(1, 1), horizontal: 1, vertical: 0)
    )
    #expect(chain.root.location == .virtual)
    #expect(chain.rootKey == key(1, 1))
    #expect(chain.horizontal == 1)
    #expect(chain.vertical == 0)
  }

  @Test
  func `eviction removes orphaned relative placements`() throws {
    let vt = term()
    vt.storage.limit = 8
    try vt.add(image(1, 2, 1, data: [0, 0, 0, 0, 0, 0]))
    try vt.place(1, 1, x: 1, y: 1)
    try vt.add(image(2))
    try vt.place(
      2,
      1,
      .init(location: .relative(parent: key(1, 1), horizontal: 0, vertical: 0))
    )
    try vt.add(image(3, 2, 1, data: [0, 0, 0, 0, 0, 0]))
    #expect(vt.storage.image(id: 1) == nil)
    #expect(vt.storage.placements.isEmpty)
    #expect(vt.storage.image(id: 2) != nil)
  }

  @Test
  func `placeholderTarget lookup`() throws {
    let vt = term()
    try vt.add(image(1))
    try vt.place(1, 5, .init(location: .virtual))
    #expect(
      vt.storage.placeholderTarget(imageID: 1, placementID: 5)?.0 == key(1, 5)
    )
    #expect(
      vt.storage.placeholderTarget(imageID: 1, placementID: 5)?.1.location
        == .virtual
    )
    #expect(
      vt.storage.placeholderTarget(imageID: 1, placementID: 0)?.0 == key(1, 5)
    )
    #expect(vt.storage.placeholderTarget(imageID: 1, placementID: 9) == nil)
    #expect(vt.storage.placeholderTarget(imageID: 2, placementID: 0) == nil)
    try vt.place(1, 7, x: 0, y: 0)
    #expect(vt.storage.placeholderTarget(imageID: 1, placementID: 7) == nil)
    try vt.place(1, 3, .init(location: .virtual))
    #expect(
      vt.storage.placeholderTarget(imageID: 1, placementID: 0)?.0 == key(1, 3)
    )
  }

  // MARK: Animation ticks

  private func animatedStorage(
    _ configure: (inout KittyGraphics.Animation) -> Void,
    place: Bool = true
  ) throws -> VT {
    var vt = term(10, 10)
    vt.pixels(100, 100)
    var i = KittyGraphics.Image(id: 1, width: 1, height: 1)
    i.pixels = KittyImagePixels(
      width: 1,
      height: 1,
      bytesPerPixel: 4,
      bytes: [255, 0, 0, 255]
    )
    try vt.add(i)
    var anim = KittyGraphics.Animation()
    anim.frames.append(
      .init(
        pixels: KittyImagePixels(
          width: 1,
          height: 1,
          bytesPerPixel: 4,
          bytes: [0, 0, 255, 255]
        ),
        gap: 40
      )
    )
    configure(&anim)
    vt.storage.images[1]!.animation = anim
    if place { try vt.place(1, 0, x: 0, y: 0) }
    return vt
  }

  private func anim(_ vt: borrowing VT) -> KittyGraphics.Animation {
    vt.storage.images[1]!.animation!
  }

  @Test
  func `animation tick advances and schedules`() throws {
    let vt = try animatedStorage({ $0.state = .running }, place: false)
    #expect(vt.storage.animationTick(now: 0) == nil)
    #expect(anim(vt).currentIndex == 0)
    try vt.place(1, 0, x: 0, y: 0)
    let (gen1, dirty) = (vt.storage.images[1]!.generation, vt.storage.dirty)
    #expect(vt.storage.animationTick(now: 0) == 40)
    #expect(anim(vt).currentIndex == 1)
    #expect(vt.storage.images[1]!.generation > gen1)
    #expect(vt.storage.dirty != dirty)
    let gen2 = vt.storage.images[1]!.generation
    #expect(vt.storage.animationTick(now: 10) == 30)
    #expect(vt.storage.images[1]!.generation == gen2)
    #expect(vt.storage.animationTick(now: 40) == 40)
    #expect(anim(vt).currentIndex == 1)
    #expect(anim(vt).currentLoop == 1)
  }

  @Test
  func `animation tick loading state parks on last frame`() throws {
    let vt = try animatedStorage { $0.state = .loading }
    #expect(vt.storage.animationTick(now: 0) == 40)
    #expect(anim(vt).currentIndex == 1)
    #expect(vt.storage.animationTick(now: 100) == nil)
    #expect(anim(vt).currentIndex == 1)
    #expect(anim(vt).currentLoop == 0)
    vt.storage.images[1]!.animation!.frames
      .append(
        .init(
          pixels: KittyImagePixels(
            width: 1,
            height: 1,
            bytesPerPixel: 4,
            bytes: [0, 255, 0, 255]
          ),
          gap: 25
        )
      )
    vt.storage.markMutated()
    #expect(vt.storage.animationTick(now: 150) == 25)
    #expect(anim(vt).currentIndex == 2)
  }

  @Test
  func `animation tick exhausts loop budget`() throws {
    let vt = try animatedStorage {
      $0.state = .running
      $0.rootGap = 10
      $0.maxLoops = 1
    }
    #expect(vt.storage.animationTick(now: 0) == 10)
    #expect(anim(vt).currentIndex == 0)
    #expect(vt.storage.animationTick(now: 10) == 40)
    #expect(anim(vt).currentIndex == 1)
    #expect(vt.storage.animationTick(now: 50) == nil)
    #expect(anim(vt).currentIndex == 1)
    #expect(vt.storage.animationTick(now: 500) == nil)
  }

  @Test
  func `animation tick ignores ineligible animations`() throws {
    let vt = try animatedStorage { _ in }
    #expect(vt.storage.animationTick(now: 0) == nil)
    vt.storage.images[1]!.animation!.state = .running
    vt.storage.images[1]!.animation!.frames[0].gap = 0
    vt.storage.markMutated()
    #expect(vt.storage.animationTick(now: 0) == nil)
    #expect(anim(vt).currentIndex == 0)
  }

  @Test
  func `animation tick skips the walk while idle`() throws {
    let vt = try animatedStorage { _ in }
    #expect(vt.storage.animationTick(now: 0) == nil)
    // Unchanged generation: the idle walk is skipped.
    vt.storage.images[1]!.animation!.state = .running
    #expect(vt.storage.animationTick(now: 10) == nil)
    #expect(anim(vt).currentIndex == 0)
    vt.storage.markMutated()
    #expect(vt.storage.animationTick(now: 20) == 40)
    #expect(anim(vt).currentIndex == 1)
  }

  @Test
  func `animation tick re-anchors a restarted clock`() throws {
    let vt = try animatedStorage {
      $0.state = .running
      $0.currentIndex = 1
      $0.frameShownAt = 1000
    }
    #expect(vt.storage.animationTick(now: 5) == 40)
    #expect(anim(vt).frameShownAt == 5)
  }
}

// MARK: graphics_image.zig

/// A `width`×`height` RGB gradient (Ghostty's testdata images are raw
/// captures; the loaders only check sizes and formats).
private func rgbData(_ width: Int, _ height: Int) -> [UInt8] {
  (0 ..< width * height * 3).map { UInt8(truncatingIfNeeded: $0 * 7) }
}

private func pngData(_ width: Int, _ height: Int) -> [UInt8] {
  let rgba = (0 ..< width * height * 4)
    .map { UInt8(truncatingIfNeeded: $0 | 3) }
  let image = CGImage(
    width: width,
    height: height,
    bitsPerComponent: 8,
    bitsPerPixel: 32,
    bytesPerRow: width * 4,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
    provider: CGDataProvider(data: Data(rgba) as CFData)!,
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

private func crc32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
  var c: UInt32 = 0xFFFF_FFFF
  for b in bytes {
    c ^= UInt32(b)
    for _ in 0 ..< 8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
  }
  return ~c
}

private func writeTemp(_ name: String, _ bytes: [UInt8]) throws -> String {
  let dir = NSTemporaryDirectory() + "swiftty-oracle-\(UUID().uuidString)"
  try FileManager.default.createDirectory(
    atPath: dir,
    withIntermediateDirectories: true
  )
  let path = dir + "/" + name
  try Data(bytes).write(to: URL(fileURLWithPath: path))
  return path
}

struct KittyImageLoadOracleTests {
  private func media(_ media: KittyGraphics.Media = .all) -> VT {
    var vt = term()
    vt.state.kittyGraphicsMedia = media
    return vt
  }

  @Test
  func `temporary file path must be inside directory`() {
    let isPath = KittyGraphics.LoadingImage.isPath
    #expect(isPath("/tmp/tty-graphics-protocol-image.data", "/tmp"))
    #expect(isPath("/tmp/tty-graphics-protocol-image.data", "/tmp/"))
    #expect(isPath("/tmp", "/tmp"))
    #expect(!isPath("/tmp/tty-graphics-protocol-image.data", ""))
    #expect(!isPath("/tmpX/tty-graphics-protocol-image.data", "/tmp"))
    #expect(
      !isPath("/dev/shm-evil/tty-graphics-protocol-image.data", "/dev/shm")
    )
    #expect(
      !isPath(
        "/custom/tmp-suffix/tty-graphics-protocol-image.data",
        "/custom/tmp"
      )
    )
  }

  @Test
  func `shared memory names that cannot exist are invalid data`() {
    // Ghostty's `validSharedMemoryName` with Darwin's 31-byte limit.
    var vt = media()
    for name in [
      "", "/", "/kitty\u{0}image", "kitty\u{0}image",
      "/" + String(repeating: "k", count: 31),
    ] {
      #expect(
        vt.exec("a=t,t=s,f=24,s=1,v=1,i=31;" + b64(Array(name.utf8)))
          == apc("i=31;EINVAL: invalid data"),
        "\(name.debugDescription)"
      )
    }
  }

  @Test
  func `image load with invalid RGB data`() {
    var vt = term()
    // Ghostty passes the raw bytes "AAAA": four bytes for a 3-byte image.
    #expect(
      vt.exec("a=t,f=24,s=1,v=1,i=31;" + b64(Array("AAAA".utf8)))
        == apc("i=31;EINVAL: invalid data")
    )
  }

  @Test
  func `image load with image too wide or too tall`() {
    var vt = term()
    #expect(
      vt.exec("a=t,f=24,s=10001,v=1,i=31;QUFBQQ")
        == apc("i=31;EINVAL: dimensions too large")
    )
    #expect(
      vt.exec("a=t,f=24,s=1,v=10001,i=31;QUFBQQ")
        == apc("i=31;EINVAL: dimensions too large")
    )
  }

  @Test
  func `image load rgb zlib compressed direct, whole and chunked`() throws {
    let raw = rgbData(128, 96)
    let z = b64(Zlib.compress(raw))
    var whole = term()
    #expect(whole.exec("a=t,f=24,o=z,s=128,v=96,i=31;" + z) == ok("i=31"))
    let stored = try #require(whole.storage.image(id: 31))
    #expect(!stored.compressed)
    #expect(stored.pixels?.bytes == raw)
    // 1024-byte chunks of base64, then with an empty first chunk.
    for empty in [false, true] {
      var vt = term()
      var chunks = stride(from: 0, to: z.count, by: 1024)
        .map { String(Array(z)[$0 ..< min($0 + 1024, z.count)]) }
      if empty { chunks.insert("", at: 0) }
      for (i, chunk) in chunks.enumerated() {
        let more = i < chunks.count - 1 ? 1 : 0
        let keys =
          i == 0 ? "a=t,f=24,o=z,s=128,v=96,i=31,m=\(more)" : "m=\(more)"
        let reply = vt.exec("\(keys);\(chunk)")
        #expect(reply == (more == 1 ? "" : ok("i=31")))
      }
      #expect(vt.storage.image(id: 31)?.pixels?.bytes == raw)
    }
  }

  @Test
  func `image load rgb not compressed direct`() {
    var vt = term()
    #expect(
      vt.exec("a=t,f=24,s=20,v=15,i=31;" + b64(rgbData(20, 15))) == ok("i=31")
    )
    #expect(vt.storage.image(id: 31)?.compressed == false)
  }

  @Test
  func `temporary file without correct path is rejected and kept`() throws {
    var vt = media()
    let path = try writeTemp("image.data", rgbData(20, 15))
    defer { unlink(path) }
    #expect(
      vt.exec("a=t,t=t,f=24,s=20,v=15,i=31;" + b64(Array(path.utf8)))
        == apc("i=31;EINVAL: temporary file not named correctly")
    )
    #expect(FileManager.default.fileExists(atPath: path))
  }

  @Test
  func `temporary file in tmp is read and deleted`() throws {
    var vt = media()
    let path =
      "/tmp/swiftty-oracle-\(UUID().uuidString)-tty-graphics-protocol-image.data"
    try Data(rgbData(20, 15)).write(to: URL(fileURLWithPath: path))
    defer { unlink(path) }
    #expect(
      vt.exec("a=t,t=t,f=24,s=20,v=15,i=31;" + b64(Array(path.utf8)))
        == ok("i=31")
    )
    #expect(!FileManager.default.fileExists(atPath: path))
  }

  @Test
  func `rgb not compressed temporary file is deleted`() throws {
    var vt = media()
    let path = try writeTemp(
      "tty-graphics-protocol-image.data",
      rgbData(20, 15)
    )
    #expect(
      vt.exec("a=t,t=t,f=24,s=20,v=15,i=31;" + b64(Array(path.utf8)))
        == ok("i=31")
    )
    #expect(!FileManager.default.fileExists(atPath: path))
  }

  @Test
  func `rgb not compressed regular file is kept`() throws {
    var vt = media()
    let path = try writeTemp("image.data", rgbData(20, 15))
    defer { unlink(path) }
    #expect(
      vt.exec("a=t,t=f,f=24,s=20,v=15,i=31;" + b64(Array(path.utf8)))
        == ok("i=31")
    )
    #expect(FileManager.default.fileExists(atPath: path))
  }

  @Test
  func `regular file size reads exactly requested bytes`() throws {
    let path = try writeTemp("image.data", [1, 2, 3, 4, 5, 6])
    defer { unlink(path) }
    for (offset, expected) in [(0, [UInt8]([1, 2, 3])), (3, [4, 5, 6])] {
      var vt = media(.file)
      #expect(
        vt.exec(
          "a=t,t=f,f=24,s=1,v=1,S=3,O=\(offset),i=31;" + b64(Array(path.utf8))
        ) == ok("i=31")
      )
      #expect(vt.storage.image(id: 31)?.pixels?.bytes == expected)
    }
  }

  @Test
  func `regular file size rejects short data`() throws {
    var vt = media(.file)
    let path = try writeTemp("image.data", [1, 2])
    defer { unlink(path) }
    #expect(
      vt.exec("a=t,t=f,f=24,s=1,v=1,S=3,i=31;" + b64(Array(path.utf8)))
        == apc("i=31;EINVAL: invalid data")
    )
  }

  @Test
  func `rgb not compressed relative regular file`() throws {
    var vt = media(.file)
    let name = "swiftty-oracle-\(UUID().uuidString).data"
    let cwd = FileManager.default.currentDirectoryPath
    let path = cwd + "/" + name
    try Data(rgbData(20, 15)).write(to: URL(fileURLWithPath: path))
    defer { unlink(path) }
    #expect(
      vt.exec("a=t,t=f,f=24,s=20,v=15,i=31;" + b64(Array(name.utf8)))
        == ok("i=31")
    )
  }

  @Test
  func `blocklist applies to the opened file, not the link`() throws {
    // Ghostty swaps the link between open and validation; here the link
    // itself names the blocked device: the opened file is checked.
    var vt = media(.file)
    let link = NSTemporaryDirectory() + "swiftty-oracle-\(UUID().uuidString)"
    try FileManager.default.createSymbolicLink(
      atPath: link,
      withDestinationPath: "/dev/null"
    )
    defer { unlink(link) }
    #expect(
      vt.exec("a=t,t=f,f=24,s=1,v=1,i=31;" + b64(Array(link.utf8)))
        == apc("i=31;EINVAL: invalid data")
    )
  }

  @Test
  func `png not compressed regular file`() throws {
    var vt = media()
    let path = try writeTemp(
      "tty-graphics-protocol-image.data",
      pngData(50, 76)
    )
    defer { unlink(path) }
    #expect(
      vt.exec("a=t,t=f,f=100,i=31;" + b64(Array(path.utf8))) == ok("i=31")
    )
    let image = try #require(vt.storage.image(id: 31))
    #expect(image.format == .rgba)
    #expect(!image.compressed)
    #expect(FileManager.default.fileExists(atPath: path))
  }

  @Test
  func `png zlib compressed direct`() throws {
    var vt = term()
    #expect(
      vt.exec("a=t,f=100,o=z,i=31;" + b64(Zlib.compress(pngData(50, 76))))
        == ok("i=31")
    )
    let image = try #require(vt.storage.image(id: 31))
    #expect(!image.compressed)
    #expect(image.format == .rgba)
    #expect(image.width == 50)
    #expect(image.height == 76)
  }

  @Test
  func `png rejects oversized image before allocation`() {
    var data = pngData(50, 76)
    // IHDR width and height, then its CRC over type and data.
    for (i, v) in [(16, UInt32(32768)), (20, 32767)] {
      withUnsafeBytes(of: v.bigEndian) {
        for j in 0 ..< 4 { data[i + j] = $0[j] }
      }
    }
    withUnsafeBytes(of: crc32(data[12 ..< 29]).bigEndian) {
      for j in 0 ..< 4 { data[29 + j] = $0[j] }
    }
    var vt = term()
    #expect(
      vt.exec("a=t,f=100,i=31;" + b64(data)) == apc("i=31;EINVAL: invalid data")
    )
  }

  @Test
  func `limits gate the file and temporary file media`() throws {
    let file = try writeTemp("image.data", rgbData(20, 15))
    defer { unlink(file) }
    var direct = media(.direct)
    #expect(
      direct.exec("a=t,f=24,s=1,v=1,i=31;" + b64([1, 2, 3])) == ok("i=31")
    )
    #expect(
      direct.exec("a=t,t=f,f=24,s=20,v=15,i=31;" + b64(Array(file.utf8)))
        == apc("i=31;EINVAL: unsupported medium")
    )
    var files = media(.file)
    #expect(
      files.exec("a=t,t=f,f=24,s=20,v=15,i=31;" + b64(Array(file.utf8)))
        == ok("i=31")
    )
    let temp = try writeTemp(
      "tty-graphics-protocol-image.data",
      rgbData(20, 15)
    )
    defer { unlink(temp) }
    var noTemp = media([.file, .sharedMemory])
    #expect(
      noTemp.exec("a=t,t=t,f=24,s=20,v=15,i=31;" + b64(Array(temp.utf8)))
        == apc("i=31;EINVAL: unsupported medium")
    )
    #expect(FileManager.default.fileExists(atPath: temp))
    var temps = media(.temporaryFile)
    #expect(
      temps.exec("a=t,t=t,f=24,s=20,v=15,i=31;" + b64(Array(temp.utf8)))
        == ok("i=31")
    )
  }
}

// MARK: graphics_unicode.zig

struct KittyPlaceholderOracleTests {
  @Test
  func `diacritics are sorted and every one maps to its index`() {
    let d = KittyGraphics.diacritics
    #expect(d == d.sorted())
    #expect(KittyGraphics.diacriticIndex(0x483) == 30)
    #expect(KittyGraphics.diacriticIndex(0x1D242) == 294)
    for (i, cp) in d.enumerated() {
      #expect(KittyGraphics.diacriticIndex(cp) == UInt32(i))
    }
    let set = Set(d)
    var stray = 0
    for cp in UInt32(0) ..< 0x1E000 where !set.contains(cp) {
      if KittyGraphics.diacriticIndex(cp) != nil { stray += 1 }
    }
    #expect(stray == 0)
  }

  /// Ghostty's `renderPlacement` for a run on the dog image (500×306) in
  /// 36×80 px cells.
  private func render(
    columns: UInt32,
    rows: UInt32,
    row: UInt32,
    width: UInt32 = 4
  ) -> [Int]? {
    var run = KittyGraphics.PlaceholderRun(
      foreground: 1,
      underline: 0,
      marks: (nil, nil, nil)
    )
    run.row = row
    run.column = 0
    run.width = width
    guard
      let g = KittyGraphics.placeholderGeometry(
        run: run,
        target: .init(location: .virtual, columns: columns, rows: rows),
        image: .init(id: 1, width: 500, height: 306),
        cellWidth: 36,
        cellHeight: 80
      )
    else { return nil }
    return [g.offsetX, g.offsetY, g.sx, g.sy, g.sw, g.sh, g.width, g.height]
  }

  @Test
  func `unicode render placement dog 4x2`() throws {
    // (offset_x, offset_y, source_x, source_y, source_w, source_h, dest_w, dest_h)
    #expect(
      try #require(render(columns: 4, rows: 2, row: 0)) == [
        0, 36, 0, 0, 500, 153, 144, 44,
      ]
    )
    #expect(
      try #require(render(columns: 4, rows: 2, row: 1)) == [
        0, 0, 0, 153, 500, 153, 144, 44,
      ]
    )
  }

  @Test
  func `unicode render placement dog 2x2 with blank cells`() throws {
    #expect(
      try #require(render(columns: 2, rows: 2, row: 0)) == [
        0, 58, 0, 0, 500, 153, 72, 22,
      ]
    )
    #expect(
      try #require(render(columns: 2, rows: 2, row: 1)) == [
        0, 0, 0, 153, 500, 153, 72, 22,
      ]
    )
  }

  @Test
  func `unicode render placement dog 1x1`() throws {
    #expect(
      try #require(render(columns: 1, rows: 1, row: 0)) == [
        0, 29, 0, 0, 500, 306, 36, 22,
      ]
    )
  }
}

// MARK: graphics_pixel.zig, graphics_animation.zig

struct KittyPixelOracleTests {
  @Test
  func `rgba conversion`() {
    func rgba(_ bpp: Int, _ bytes: [UInt8]) -> [UInt8] {
      KittyImagePixels(
        width: bytes.count / bpp,
        height: 1,
        bytesPerPixel: bpp,
        bytes: bytes
      )
      .rgba()
    }
    #expect(rgba(3, [1, 2, 3, 4, 5, 6]) == [1, 2, 3, 255, 4, 5, 6, 255])
    #expect(rgba(1, [7, 8]) == [7, 7, 7, 255, 8, 8, 8, 255])
    #expect(rgba(2, [7, 100, 8, 200]) == [7, 7, 7, 100, 8, 8, 8, 200])
    #expect(rgba(4, [1, 2, 3, 4]) == [1, 2, 3, 4])
  }

  @Test
  func `fill background`() {
    var buf = [UInt8](repeating: 9, count: 8)
    KittyGraphics.fillBackground(&buf, 0x0102_0304)
    #expect(buf == [1, 2, 3, 4, 1, 2, 3, 4])
    KittyGraphics.fillBackground(&buf, 0)
    #expect(buf == [UInt8](repeating: 0, count: 8))
  }

  @Test
  func `compose rect overwrite with clipping`() {
    var dst = [UInt8](repeating: 0, count: 16)
    KittyGraphics.composeRect(
      &dst,
      width: 2,
      height: 2,
      [1, 2, 3, 4, 5, 6, 7, 8],
      width: 2,
      height: 1,
      x: 1,
      y: 1,
      overwrite: true
    )
    var expected = [UInt8](repeating: 0, count: 16)
    expected[12 ..< 16] = [1, 2, 3, 4]
    #expect(dst == expected)
  }

  @Test
  func `compose rect entirely out of bounds`() {
    var dst = [UInt8](repeating: 9, count: 16)
    let src = [UInt8](repeating: 1, count: 4)
    KittyGraphics.composeRect(
      &dst,
      width: 2,
      height: 2,
      src,
      width: 1,
      height: 1,
      x: 2,
      y: 0,
      overwrite: true
    )
    KittyGraphics.composeRect(
      &dst,
      width: 2,
      height: 2,
      src,
      width: 1,
      height: 1,
      x: 0,
      y: 2,
      overwrite: true
    )
    #expect(dst == [UInt8](repeating: 9, count: 16))
  }

  @Test
  func `alpha blend source-over semantics`() {
    func blend(_ dst: [UInt8], _ src: [UInt8]) -> [UInt8] {
      var d = dst
      KittyGraphics.composeRect(
        &d,
        width: 1,
        height: 1,
        src,
        width: 1,
        height: 1,
        x: 0,
        y: 0,
        overwrite: false
      )
      return d
    }
    #expect(
      blend([10, 20, 30, 40], [100, 110, 120, 255]) == [100, 110, 120, 255]
    )
    #expect(blend([10, 20, 30, 40], [100, 110, 120, 0]) == [10, 20, 30, 40])
    let half = blend([0, 0, 0, 255], [255, 255, 255, 128])
    #expect(half[3] == 255)
    #expect(half[0] == 128)
    #expect(blend([0, 0, 0, 0], [200, 100, 50, 128]) == [200, 100, 50, 128])
  }

  @Test
  func `compose canvas rect`() {
    var canvas: [UInt8] = [1, 2, 3, 4, 0, 0, 0, 0, 9, 9, 9, 9]
    let src = canvas
    KittyGraphics.composeCanvasRect(
      &canvas,
      src,
      canvasWidth: 3,
      width: 1,
      height: 1,
      srcX: 0,
      srcY: 0,
      dstX: 2,
      dstY: 0,
      overwrite: true
    )
    #expect(canvas == [1, 2, 3, 4, 0, 0, 0, 0, 1, 2, 3, 4])
  }

  @Test
  func `animation gap helpers`() {
    var anim = KittyGraphics.Animation()
    anim.frames.append(
      .init(
        pixels: KittyImagePixels(
          width: 1,
          height: 1,
          bytesPerPixel: 4,
          bytes: [0, 0, 0, 0]
        ),
        gap: 100
      )
    )
    #expect(anim.frameCount == 2)
    #expect(anim.gap(at: 0) == 0)
    #expect(anim.gap(at: 1) == 100)
    #expect(anim.duration == 100)
    #expect(anim.byteCount == 4)
    anim.setGap(at: 0, 40)
    anim.setGap(at: 1, 60)
    #expect(anim.duration == 100)
    #expect(anim.rootGap == 40)
  }
}

// MARK: Not ported
//
// graphics_command.zig
// - feedSlice respects max_bytes: Limit (Swiftty's cap is the fixed
//   64 MiB `maxAPCBytes`; Ghostty's parser takes a per-test cap)
// - animation compose value above one overwrites: Internal (compose keys
//   are read at execution; covered by the compose tests above)
// - animation control action above three is ignored: Duplicate (covered
//   by `control command ignores invalid values`)
// graphics_exec.zig: none.
// Already in KittyGraphicsTests.swift with Ghostty's values: ignore unknown
// keys (long); kittygfx uppercase id delete preserves image when placement
// does not match; storage: delete all visible placements preserves
// scrollback.
// graphics_storage.zig
// - replacing placement releases tracked pin: Pins (ported as the
//   location check only)
// - pending image completes once and preserves age: Pending
// - stale pending completion loses to delete replacement and eviction:
//   Pending
// - replacement reuses pending reservation and removes placements: Pending
// - pending completion survives a change of displayed frame: Pending
// - pending animation frames: Pending
//   (Swiftty restores checkpoint pixels synchronously; there is no
//   deferred completion API)
// - partial history erase keeps later history placements: Internal
//   (Ghostty calls `Screen.eraseHistory` with a partial range; Swiftty
//   trims history only through the scrollback limit)
// graphics_image.zig
// - image load accepts shared memory names without a leading slash:
//   Platform (creating a segment needs variadic `shm_open(O_CREAT)`,
//   unavailable from Swift)
// - shared memory range with offset and size / rejects out of bounds
//   offset / validates dimensions before multiplication: Internal
// - image load: temporary file outside directory prefix is rejected:
//   Platform (Ghostty injects a trusted directory; Swiftty's set is fixed,
//   D8; covered by KittyGraphicsTests)
// - image load: png rejects oversized decoder allocation: Internal
//   (decoder injection)
// - image load: windows UNC path / device namespace / reserved device
//   names / local file spellings / temporary file spelling / canonical
//   path checks (7 tests): Windows
