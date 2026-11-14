@testable import SwifttyEngine
import Testing

/// Kitty drag-and-drop protocol (OSC 72), ported from Ghostty's
/// `dnd_command`, `dnd_response`, `dnd_test` and stream tests.
struct KittyDragAndDropTests {
  private typealias DnD = KittyDragAndDrop

  private static let ev0 = DnD.MoveEvent(
    column: 0,
    row: 0,
    pixelX: 0,
    pixelY: 0,
    operations: .copy
  )

  private func command(
    _ vt: inout VT,
    _ meta: String,
    _ payload: String? = nil,
    bel: Bool = false
  ) {
    vt.feed(
      "\u{1B}]72;\(meta)\(payload.map { ";\($0)" } ?? "")\(bel ? "\u{7}" : "\u{1B}\\")"
    )
  }

  private func events(_ vt: inout VT) -> [DnD.Event] {
    vt.state.takeEvents()
      .compactMap {
        if case let .dragAndDrop(event) = $0 { event } else { nil }
      }
  }

  private static func text(_ bytes: [UInt8]?) -> String? {
    bytes.map { String(decoding: $0, as: UTF8.self) }
  }

  // MARK: Metadata

  @Test
  func `metadata parses every key`() throws {
    let meta = try #require(
      DnD.Metadata.parse(
        Array("t=m:m=1:i=3:o=2:x=10:y=5:X=320:Y=200".utf8)[...]
      )
    )
    #expect(
      meta
        == DnD.Metadata(
          kind: .status,
          more: true,
          clientID: 3,
          operation: 2,
          x: 10,
          y: 5,
          pixelX: 320,
          pixelY: 200
        )
    )
    #expect(DnD.Metadata.parse([]) == DnD.Metadata())
    #expect(DnD.Metadata.parse(Array("t=a:".utf8)[...])?.kind == .register)
    #expect(DnD.Metadata.parse(Array("t=m:x=-1:y=-1".utf8)[...])?.x == -1)
    #expect(DnD.Metadata.parse(Array("x=4294967295".utf8)[...])?.x == -1)
    #expect(
      DnD.Metadata.parse(Array("i=4294967295".utf8)[...])?.clientID == .max
    )
    for (char, kind) in [
      ("a", DnD.Kind.register), ("A", .unregister), ("m", .status),
      ("M", .drop), ("r", .request), ("R", .requestError), ("o", .offer),
      ("p", .present), ("P", .startDrag), ("e", .dragEvent), ("E", .dragError),
      ("k", .remoteData), ("q", .query),
    ] {
      #expect(DnD.Metadata.parse(Array("t=\(char)".utf8)[...])?.kind == kind)
    }
  }

  @Test(arguments: [
    "t=z", "z=1", "x10", "x=notanumber", "x=-", "i=4294967296", "i=99999999999",
    "x=1z", "t=a: x=1", "t = a", "t", "t=", "x=", "t=r:x=", "x=1:t=", "t=ab",
    "i=-1",
  ])
  func `malformed metadata is rejected`(_ meta: String) {
    #expect(DnD.Metadata.parse(Array(meta.utf8)[...]) == nil)
  }

  // MARK: Responses

  @Test
  func `responses chunk payloads and repeat headers`() {
    #expect(
      Self.text(DnD.encode("t=q", 0, [], base64: false, "\u{1B}\\"))
        == "\u{1B}]72;t=q\u{1B}\\"
    )
    #expect(
      Self.text(DnD.encode("t=q", 7, [], base64: false, "\u{1B}\\"))
        == "\u{1B}]72;t=q:i=7\u{1B}\\"
    )
    #expect(
      Self.text(
        DnD.encode(
          "t=m:x=1:y=2",
          0,
          Array("text/plain ".utf8),
          base64: false,
          "\u{1B}\\"
        )
      ) == "\u{1B}]72;t=m:x=1:y=2:m=0;text/plain \u{1B}\\"
    )
    let data = [UInt8](repeating: 0x41, count: 3073)
    let out = Self.text(
      DnD.encode("t=r:x=1", 3, data, base64: true, "\u{1B}\\")
    )!
    let first = "\u{1B}]72;t=r:x=1:i=3:m=1;"
    #expect(out.hasPrefix(first))
    let rest = out.dropFirst(first.count + 4096)
    #expect(rest.hasPrefix("\u{1B}\\\u{1B}]72;t=r:x=1:i=3:m=0;QQ==\u{1B}\\"))
    #expect(
      Self.text(
        DnD.error(
          drag: false,
          keys: DnD.requestKeys(x: 2),
          clientID: 0,
          "ENOENT:drop data request index out of bounds",
          "\u{1B}\\"
        )
      )
        == "\u{1B}]72;t=R:x=2:m=0;ENOENT:drop data request index out of bounds\u{1B}\\"
    )
    #expect(
      Self.text(
        DnD.error(drag: true, keys: "", clientID: 5, "EPERM", "\u{1B}\\")
      ) == "\u{1B}]72;t=E:i=5:m=0;EPERM\u{1B}\\"
    )
    #expect(DnD.requestKeys() == "")
    #expect(DnD.requestKeys(x: 1, y: 2, pixelY: 3) == ":x=1:y=2:Y=3")
    #expect(DnD.requestKeys(pixelY: 4) == ":Y=4")
  }

  // MARK: Commands

  @Test
  func `queries echo their own id and terminator`() {
    var vt = VT()
    command(&vt, "t=q")
    #expect(vt.takeOutput() == "\u{1B}]72;t=q\u{1B}\\")
    command(&vt, "t=q:i=31")
    #expect(vt.takeOutput() == "\u{1B}]72;t=q:i=31\u{1B}\\")
    command(&vt, "t=q", bel: true)
    #expect(vt.takeOutput() == "\u{1B}]72;t=q\u{7}")
    #expect(vt.state.dragAndDrop == nil)
  }

  @Test
  func `register and unregister`() {
    var vt = VT()
    command(&vt, "t=a", "text/plain text/uri-list")
    #expect(events(&vt) == [.registration])
    #expect(vt.takeOutput() == "")
    #expect(
      vt.state.dragAndDrop?.registeredMimes == ["text/plain", "text/uri-list"]
    )
    command(&vt, "t=a:x=1", "1:deadbeef")
    #expect(events(&vt) == [])
    #expect(
      vt.state.dragAndDrop?.registeredMimes == ["text/plain", "text/uri-list"]
    )
    command(&vt, "t=a", "image/png")
    #expect(events(&vt) == [.registration])
    #expect(vt.state.dragAndDrop?.registeredMimes == ["image/png"])
    command(&vt, "t=a")
    #expect(events(&vt) == [.registration])
    #expect(vt.state.dragAndDrop?.registeredMimes == [])
    command(&vt, "t=A")
    #expect(events(&vt) == [.registration])
    #expect(vt.state.dragAndDrop == nil)
    command(&vt, "t=A")
    #expect(events(&vt) == [])
    #expect(vt.takeOutput() == "")
  }

  @Test
  func `commands before registration`() {
    var vt = VT()
    command(&vt, "t=m:o=1", "text/plain")
    command(&vt, "t=r")
    #expect(vt.takeOutput() == "")
    command(&vt, "t=r:x=1")
    #expect(
      vt.takeOutput()
        == "\u{1B}]72;t=R:x=1:m=0;ENOENT:no drop data available\u{1B}\\"
    )
    #expect(vt.state.dragAndDrop == nil)
    #expect(vt.state.dragMove(Self.ev0, mimes: ["text/plain"]) == nil)
    #expect(vt.state.dragLeave() == nil)
  }

  @Test
  func `moves echo the registration id and resend the types`() {
    var vt = VT()
    command(&vt, "t=a:i=7", "")
    let move = DnD.MoveEvent(
      column: 1,
      row: 2,
      pixelX: 8,
      pixelY: 16,
      operations: [.copy, .move]
    )
    #expect(
      Self.text(vt.state.dragMove(move, mimes: ["text/plain"]))
        == "\u{1B}]72;t=m:x=1:y=2:X=8:Y=16:o=3:i=7:m=0;text/plain \u{1B}\\"
    )
    command(&vt, "t=a:i=9")
    #expect(vt.state.dragAndDrop?.clientID == 9)
    command(&vt, "t=a")
    let first = vt.state.dragMove(
      DnD.MoveEvent(
        column: 5,
        row: 3,
        pixelX: 100,
        pixelY: 60,
        operations: .copy
      ),
      mimes: ["text/plain", "text/uri-list"]
    )
    #expect(
      Self.text(first)
        == "\u{1B}]72;t=m:x=5:y=3:X=100:Y=60:o=1:m=0;text/plain text/uri-list \u{1B}\\"
    )
    _ = vt.state.dragMove(Self.ev0, mimes: ["text/plain"])
    #expect(
      Self.text(vt.state.dragMove(Self.ev0, mimes: ["text/plain"]))
        == "\u{1B}]72;t=m:x=0:y=0:X=0:Y=0:o=1:m=0;text/plain \u{1B}\\"
    )
    #expect(
      Self.text(vt.state.dragLeave()) == "\u{1B}]72;t=m:x=-1:y=-1\u{1B}\\"
    )
    #expect(vt.state.dragLeave() == nil)
  }

  @Test
  func `client acceptance including chunks`() {
    var vt = VT()
    command(&vt, "t=a")
    _ = events(&vt)
    #expect(vt.state.dragAndDrop?.clientAccepted == nil)
    command(&vt, "t=m:o=1", "text/plain")
    #expect(events(&vt) == [.acceptance])
    #expect(vt.takeOutput() == "")
    #expect(vt.state.dragAndDrop?.clientAccepted == .copy)
    command(&vt, "t=m:o=0", "")
    #expect(events(&vt) == [.acceptance])
    #expect(vt.state.dragAndDrop?.clientAccepted == DnD.Operation.none)
    command(&vt, "t=m:o=2:m=1", "text/pl")
    #expect(events(&vt) == [])
    #expect(vt.state.dragAndDrop?.clientAccepted == nil)
    command(&vt, "t=m:m=1", "ain text")
    command(&vt, "t=m:m=0", "/html")
    #expect(events(&vt) == [.acceptance])
    #expect(vt.state.dragAndDrop?.clientAccepted == .move)
    #expect(
      vt.state.dragAndDrop?.acceptedMimes
        == Array("text/plain\0text/html\0".utf8)
    )
    #expect(vt.state.dragAndDrop?.acceptedTypes == ["text/plain", "text/html"])
  }

  @Test
  func `drops are served until concluded`() {
    var vt = VT()
    command(&vt, "t=a", "text/plain text/uri-list")
    _ = events(&vt)
    let drop = vt.state.dragDrop(
      DnD.MoveEvent(
        column: 4,
        row: 2,
        pixelX: 40,
        pixelY: 20,
        operations: .copy
      ),
      items: [
        .init(mime: "text/uri-list", data: Array("file:///tmp/a.txt\r\n".utf8)),
        .init(mime: "text/plain", data: Array("hello".utf8)),
      ]
    )
    #expect(
      Self.text(drop)
        == "\u{1B}]72;t=M:x=4:y=2:X=40:Y=20:o=1:m=0;text/uri-list text/plain \u{1B}\\"
    )
    command(&vt, "t=r:x=2")
    #expect(
      vt.takeOutput()
        == "\u{1B}]72;t=r:x=2:m=0;aGVsbG8=\u{1B}\\\u{1B}]72;t=r:x=2\u{1B}\\"
    )
    command(&vt, "t=r:x=2")
    #expect(vt.takeOutput().hasPrefix("\u{1B}]72;t=r:x=2:m=0;aGVsbG8="))
    command(&vt, "t=r:x=3")
    #expect(
      vt.takeOutput()
        == "\u{1B}]72;t=R:x=3:m=0;ENOENT:drop data request index out of bounds\u{1B}\\"
    )
    command(&vt, "t=r:o=1")
    #expect(events(&vt) == [.concluded(.copy)])
    #expect(vt.takeOutput() == "")
    command(&vt, "t=r:o=1")
    #expect(events(&vt) == [])
    command(&vt, "t=r:x=1")
    #expect(
      vt.takeOutput()
        == "\u{1B}]72;t=R:x=1:m=0;ENOENT:no drop data available\u{1B}\\"
    )
  }

  @Test
  func `empty and large items`() {
    var vt = VT()
    command(&vt, "t=a")
    _ = vt.state.dragDrop(
      Self.ev0,
      items: [.init(mime: "text/plain", data: [])]
    )
    command(&vt, "t=r:x=1")
    #expect(vt.takeOutput() == "\u{1B}]72;t=r:x=1\u{1B}\\")
    _ = vt.state.dragMove(Self.ev0, mimes: [])
    _ = vt.state.dragDrop(
      Self.ev0,
      items: [
        .init(
          mime: "application/octet-stream",
          data: .init(repeating: 0x5A, count: 3073)
        )
      ]
    )
    command(&vt, "t=r:x=1")
    let out = vt.takeOutput()
    #expect(out.hasPrefix("\u{1B}]72;t=r:x=1:m=1;"))
    #expect(out.contains("\u{1B}]72;t=r:x=1:m=0;"))
    #expect(out.hasSuffix("\u{1B}]72;t=r:x=1\u{1B}\\"))
  }

  @Test
  func `drops survive a leave but not a new drag`() {
    var vt = VT()
    command(&vt, "t=a")
    _ = vt.state.dragDrop(
      Self.ev0,
      items: [.init(mime: "text/plain", data: Array("x".utf8))]
    )
    #expect(vt.state.dragLeave() == nil)
    command(&vt, "t=r:x=1")
    #expect(
      vt.takeOutput()
        == "\u{1B}]72;t=r:x=1:m=0;eA==\u{1B}\\\u{1B}]72;t=r:x=1\u{1B}\\"
    )
    _ = vt.state.dragMove(Self.ev0, mimes: ["text/plain"])
    command(&vt, "t=r:x=1")
    #expect(
      vt.takeOutput()
        == "\u{1B}]72;t=R:x=1:m=0;ENOENT:no drop data available\u{1B}\\"
    )
  }

  @Test
  func `at most sixteen items are held`() {
    var vt = VT()
    command(&vt, "t=a")
    let items = (0 ..< 20).map { DnD.Item(mime: "a/\($0)", data: [0x61]) }
    _ = vt.state.dragDrop(Self.ev0, items: items)
    #expect(vt.state.dragAndDrop?.items?.count == 16)
  }

  @Test
  func `remote transfers and drag out are refused`() {
    var vt = VT()
    command(&vt, "t=a")
    command(&vt, "t=r:x=1:y=2")
    #expect(
      vt.takeOutput()
        == "\u{1B}]72;t=R:x=1:y=2:m=0;EINVAL:remote drop data is not supported\u{1B}\\"
    )
    command(&vt, "t=r:Y=2:x=1")
    #expect(
      vt.takeOutput()
        == "\u{1B}]72;t=R:x=1:Y=2:m=0;EINVAL:remote drop data is not supported\u{1B}\\"
    )
    var fresh = VT()
    command(&fresh, "t=o:x=1")
    command(&fresh, "t=o:x=2")
    #expect(fresh.takeOutput() == "")
    command(&fresh, "t=o:o=3", "text/plain")
    #expect(
      fresh.takeOutput()
        == "\u{1B}]72;t=E:m=0;EPERM:drag out is not supported by this terminal\u{1B}\\"
    )
    command(&fresh, "t=P:x=-1:i=9")
    #expect(
      fresh.takeOutput()
        == "\u{1B}]72;t=E:i=9:m=0;EPERM:drag out is not supported by this terminal\u{1B}\\"
    )
    #expect(fresh.state.dragAndDrop == nil)
  }

  @Test
  func `chunked registration keeps the first chunk's metadata`() {
    var vt = VT()
    command(&vt, "t=a:i=4:m=1", "text/pla")
    #expect(events(&vt) == [])
    #expect(vt.state.dragAndDrop != nil)
    command(&vt, "t=q:m=0", "in")
    #expect(events(&vt) == [.registration])
    #expect(vt.takeOutput() == "")
    #expect(vt.state.dragAndDrop?.clientID == 4)
    #expect(vt.state.dragAndDrop?.registeredMimes == ["text/plain"])
    command(&vt, "t=q")
    #expect(vt.takeOutput() == "\u{1B}]72;t=q\u{1B}\\")
  }

  @Test
  func `oversized registration never completes`() {
    var vt = VT()
    command(&vt, "t=a", String(repeating: "a", count: (1 << 20) + 1))
    #expect(events(&vt) == [])
    #expect(vt.state.dragAndDrop?.registeredMimes == [])
  }

  @Test
  func `malformed commands are ignored`() {
    var vt = VT()
    command(&vt, "t=a:zz=1", "")
    command(&vt, "x=1", "")
    vt.feed("\u{1B}]72\u{1B}\\ok")
    #expect(vt.takeOutput() == "")
    #expect(vt.state.dragAndDrop == nil)
    #expect(vt.lines[0] == "ok")
  }

  @Test
  func `registration survives reset but a split command ends`() {
    var vt = VT()
    command(&vt, "t=a:i=5")
    command(&vt, "t=m:o=1:m=1", "text/pl")
    vt.feed("\u{1B}c")
    #expect(vt.state.dragAndDrop != nil)
    #expect(vt.state.dragAndDrop?.chunking == false)
    command(&vt, "t=q")
    #expect(vt.takeOutput() == "\u{1B}]72;t=q\u{1B}\\")
  }

  @Test
  func `kitten replay`() {
    var vt = VT()
    let id =
      "1:5cff8247c477900a8727e2281fe890252f8848f87c224dd8dd7fb6303e94ddbd"
    command(&vt, "t=a:m=0", "text/uri-list text/plain")
    command(&vt, "t=a:x=1:m=0", id)
    command(&vt, "t=A")
    #expect(vt.state.dragAndDrop == nil)
    command(&vt, "t=o:x=2")
    command(&vt, "t=a:m=0", "text/uri-list text/plain")
    command(&vt, "t=a:x=1:m=0", id)
    #expect(vt.takeOutput() == "")
    let ev = DnD.MoveEvent(
      column: 2,
      row: 1,
      pixelX: 20,
      pixelY: 18,
      operations: .copy
    )
    #expect(
      Self.text(vt.state.dragMove(ev, mimes: ["text/plain"]))
        == "\u{1B}]72;t=m:x=2:y=1:X=20:Y=18:o=1:m=0;text/plain \u{1B}\\"
    )
    command(&vt, "t=m:o=1:m=0", "text/plain")
    #expect(vt.state.dragAndDrop?.clientAccepted == .copy)
    let drop = vt.state.dragDrop(
      ev,
      items: [
        .init(mime: "text/plain", data: Array("hello from ghostty\n".utf8))
      ]
    )
    #expect(
      Self.text(drop)
        == "\u{1B}]72;t=M:x=2:y=1:X=20:Y=18:o=1:m=0;text/plain \u{1B}\\"
    )
    command(&vt, "t=r:x=1")
    #expect(
      vt.takeOutput()
        == "\u{1B}]72;t=r:x=1:m=0;aGVsbG8gZnJvbSBnaG9zdHR5Cg==\u{1B}\\\u{1B}]72;t=r:x=1\u{1B}\\"
    )
    command(&vt, "t=r:o=1")
    #expect(vt.takeOutput() == "")
    #expect(vt.state.dragAndDrop?.items == nil)
  }

  @Test
  func `events report registration acceptance and conclusion`() {
    var vt = VT(80, 24)
    command(&vt, "t=a", "image/png text/plain")
    #expect(events(&vt) == [.registration])
    #expect(
      vt.state.dragAndDrop?.registeredMimes == ["image/png", "text/plain"]
    )
    _ = vt.state.dragDrop(
      Self.ev0,
      items: [.init(mime: "text/plain", data: [0x78])]
    )
    command(&vt, "t=m:o=2", "text/plain")
    #expect(events(&vt) == [.acceptance])
    command(&vt, "t=r:o=2")
    #expect(events(&vt) == [.concluded(.move)])
    command(&vt, "t=A")
    #expect(events(&vt) == [.registration])
    #expect(vt.state.dragAndDrop == nil)
  }
}
