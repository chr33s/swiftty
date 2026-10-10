@testable import SwifttyCore
import Testing
import TestSupport

struct InputEncoderTests {
  func encode(_ input: TerminalInput, _ modes: Modes = .initial) -> String? {
    var out: [UInt8] = []
    guard InputEncoder.encode(input, modes: modes, into: &out) else {
      return nil
    }
    return String(decoding: out, as: UTF8.self)
  }

  @Test
  func `text and control keys`() {
    #expect(TestFixture(encode(.text("héllo"))) == TestFixture("héllo"))
    #expect(
      TestFixture(encode(.key(KeyEvent(.character("c"), modifiers: .control))))
        == TestFixture("\u{03}")
    )
    #expect(
      TestFixture(encode(.key(KeyEvent(.character("["), modifiers: .control))))
        == TestFixture("\u{1B}")
    )
    #expect(
      TestFixture(encode(.key(KeyEvent(.character(" "), modifiers: .control))))
        == TestFixture("\u{00}")
    )
    #expect(
      TestFixture(encode(.key(KeyEvent(.character("x"), modifiers: .alt))))
        == TestFixture("\u{1B}x")
    )
    #expect(TestFixture(encode(.key(KeyEvent(.enter)))) == TestFixture("\r"))
    #expect(
      TestFixture(encode(.key(KeyEvent(.backspace)))) == TestFixture("\u{7F}")
    )
    #expect(
      TestFixture(encode(.key(KeyEvent(.tab, modifiers: .shift))))
        == TestFixture("\u{1B}[Z")
    )
  }

  @Test
  func `cursor keys respect DECCKM`() {
    #expect(TestFixture(encode(.key(KeyEvent(.up)))) == TestFixture("\u{1B}[A"))
    #expect(
      TestFixture(encode(.key(KeyEvent(.up)), [.cursorKeys]))
        == TestFixture("\u{1B}OA")
    )
    #expect(
      TestFixture(encode(.key(KeyEvent(.left, modifiers: [.control, .shift]))))
        == TestFixture("\u{1B}[1;6D")
    )
    #expect(
      TestFixture(encode(.key(KeyEvent(.home)), [.cursorKeys]))
        == TestFixture("\u{1B}OH")
    )
  }

  @Test
  func `function and editing keys`() {
    #expect(
      TestFixture(encode(.key(KeyEvent(.function(1)))))
        == TestFixture("\u{1B}OP")
    )
    #expect(
      TestFixture(encode(.key(KeyEvent(.function(5)))))
        == TestFixture("\u{1B}[15~")
    )
    #expect(
      TestFixture(encode(.key(KeyEvent(.function(12), modifiers: .shift))))
        == TestFixture("\u{1B}[24;2~")
    )
    #expect(
      TestFixture(encode(.key(KeyEvent(.delete)))) == TestFixture("\u{1B}[3~")
    )
    #expect(
      TestFixture(encode(.key(KeyEvent(.pageUp, modifiers: .alt))))
        == TestFixture("\u{1B}[5;3~")
    )
  }

  @Test
  func paste() {
    #expect(TestFixture(encode(.paste("a\nb"))) == TestFixture("a\rb"))
    #expect(
      TestFixture(encode(.paste("a\u{1B}b"), [.bracketedPaste]))
        == TestFixture("\u{1B}[200~a b\u{1B}[201~")
    )
  }

  @Test(
    arguments: [("", ""), ("a\0\u{8}\u{1B}\u{7F}b", "a    b")]
      .map(TestFixture.init),
    [false, true]
  )
  func `empty and combined control pastes retain their framing`(
    _ fixture: TestFixture<(String, String)>,
    _ bracketed: Bool
  ) {
    let fixture = fixture.value
    let expected = bracketed ? "\u{1B}[200~\(fixture.1)\u{1B}[201~" : fixture.1
    #expect(
      TestFixture(
        encode(.paste(fixture.0), bracketed ? [.bracketedPaste] : .initial)
      ) == TestFixture(expected)
    )
  }

  @Test(
    arguments: [
      UInt32(0), 3, 4, 5, 8, 15, 17, 18, 19, 21, 22, 23, 26, 27, 28, 127,
    ],
    [false, true]
  )
  func `paste replaces editing and signal controls with spaces`(
    _ value: UInt32,
    _ bracketed: Bool
  ) throws {
    let scalar = try #require(Unicode.Scalar(value))
    let input = "漢a" + String(scalar) + "b👩‍💻"
    let modes: Modes = bracketed ? [.bracketedPaste] : .initial
    let expected = bracketed ? "\u{1B}[200~漢a b👩‍💻\u{1B}[201~" : "漢a b👩‍💻"
    #expect(TestFixture(encode(.paste(input), modes)) == TestFixture(expected))
    // Explicit key events and raw writes remain available for controls.
    #expect(
      TestFixture(encode(.bytes(Array(input.utf8)))) == TestFixture(input)
    )
  }

  @Test(arguments: [false, true])
  func `paste preserves ordinary text tabs and mode specific line endings`(
    _ bracketed: Bool
  ) {
    let input = "a\t漢\r\nb\nc\rd👩‍💻\u{9B}"
    let expected =
      bracketed ? "\u{1B}[200~\(input)\u{1B}[201~" : "a\t漢\rb\rc\rd👩‍💻\u{9B}"
    #expect(
      TestFixture(
        encode(.paste(input), bracketed ? [.bracketedPaste] : .initial)
      ) == TestFixture(expected)
    )
  }

  @Test
  func mouse() {
    #expect(
      TestFixture(encode(.mouse(MouseEvent(.press, .left, column: 0, row: 0))))
        == TestFixture(nil)
    )
    #expect(
      TestFixture(
        encode(
          .mouse(MouseEvent(.press, .left, column: 4, row: 2)),
          [.mouseNormal, .mouseSGR]
        )
      ) == TestFixture("\u{1B}[<0;5;3M")
    )
    #expect(
      TestFixture(
        encode(
          .mouse(MouseEvent(.release, .left, column: 4, row: 2)),
          [.mouseNormal, .mouseSGR]
        )
      ) == TestFixture("\u{1B}[<0;5;3m")
    )
    #expect(
      TestFixture(
        encode(
          .mouse(
            MouseEvent(.press, .wheelUp, column: 0, row: 0, modifiers: .control)
          ),
          [.mouseNormal, .mouseSGR],
        )
      ) == TestFixture("\u{1B}[<80;1;1M")
    )
    #expect(
      TestFixture(
        encode(
          .mouse(MouseEvent(.motion, .none, column: 0, row: 0)),
          [.mouseNormal]
        )
      ) == TestFixture(nil)
    )
    #expect(
      TestFixture(
        encode(
          .mouse(MouseEvent(.motion, .left, column: 1, row: 1)),
          [.mouseButton, .mouseSGR]
        )
      ) == TestFixture("\u{1B}[<32;2;2M")
    )
    let legacy = encode(
      .mouse(MouseEvent(.press, .right, column: 1, row: 2)),
      [.mouseNormal]
    )
    #expect(TestFixture(legacy) == TestFixture("\u{1B}[M\u{22}\u{22}\u{23}"))
  }

  @Test(arguments: [Int.max, Int.max - 1, Int.max - 32])
  func `mouse encoding handles extreme coordinates`(_ coordinate: Int) {
    let event = MouseEvent(.press, .left, column: coordinate, row: coordinate)
    let oneBased = coordinate == Int.max ? Int.max : coordinate + 1
    #expect(
      TestFixture(encode(.mouse(event), [.mouseNormal, .mouseSGR]))
        == TestFixture("\u{1B}[<0;\(oneBased);\(oneBased)M")
    )
    #expect(
      TestFixture(encode(.mouse(event), [.mouseNormal, .mouseUTF8]))
        == TestFixture("\u{1B}[M \u{7FF}\u{7FF}")
    )
    var output: [UInt8] = [42]
    #expect(
      TestFixture(
        !InputEncoder.encode(
          .mouse(event),
          modes: [.mouseNormal],
          into: &output
        )
      ) == TestFixture(true)
    )
    #expect(output == [42])
    #expect(
      TestFixture(
        encode(
          .mouse(MouseEvent(.press, .left, column: Int.min, row: Int.min)),
          [.mouseNormal, .mouseSGR]
        )
      ) == TestFixture("\u{1B}[<0;1;1M")
    )
  }

  @Test
  func `mouse coordinate limits retain their last encodable values`() {
    var output: [UInt8] = []
    #expect(
      TestFixture(
        InputEncoder.encode(
          .mouse(MouseEvent(.press, .left, column: 222, row: 222)),
          modes: [.mouseNormal],
          into: &output,
        )
      ) == TestFixture(true)
    )
    #expect(output == [0x1B, 0x5B, 0x4D, 32, 255, 255])
    output.removeAll()
    #expect(
      TestFixture(
        !InputEncoder.encode(
          .mouse(MouseEvent(.press, .left, column: 223, row: 223)),
          modes: [.mouseNormal],
          into: &output,
        )
      ) == TestFixture(true)
    )
    #expect(output.isEmpty)
    for coordinate in [2014, 2015] {
      #expect(
        TestFixture(
          encode(
            .mouse(
              MouseEvent(.press, .left, column: coordinate, row: coordinate)
            ),
            [.mouseNormal, .mouseUTF8]
          )
        ) == TestFixture("\u{1B}[M \u{7FF}\u{7FF}"),
      )
    }
  }

  @Test
  func focus() {
    #expect(TestFixture(encode(.focus(true))) == TestFixture(nil))
    #expect(
      TestFixture(encode(.focus(false), [.focusEvents]))
        == TestFixture("\u{1B}[O")
    )
  }
}

struct KittyKeyboardTests {
  @Test
  func `push query and disambiguate`() {
    var vt = VT()
    vt.feed("\(CSI)?u")
    #expect(TestFixture(vt.takeOutput()) == TestFixture("\(CSI)?0u"))
    vt.feed("\(CSI)>1u\(CSI)?u")
    #expect(TestFixture(vt.takeOutput()) == TestFixture("\(CSI)?1u"))
    let flags = vt.state.keyboardFlags
    func enc(_ e: KeyEvent) -> String {
      var out: [UInt8] = []
      InputEncoder.encode(
        .key(e),
        modes: .initial,
        keyboardFlags: flags,
        into: &out
      )
      return String(decoding: out, as: UTF8.self)
    }
    #expect(
      TestFixture(enc(KeyEvent(.enter, modifiers: .shift)))
        == TestFixture("\(CSI)13;2u")
    )
    #expect(TestFixture(enc(KeyEvent(.enter))) == TestFixture("\r"))
    #expect(TestFixture(enc(KeyEvent(.escape))) == TestFixture("\(CSI)27u"))
    #expect(
      TestFixture(enc(KeyEvent(.character("c"), modifiers: .control)))
        == TestFixture("\(CSI)99;5u")
    )
    #expect(TestFixture(enc(KeyEvent(.up))) == TestFixture("\(CSI)A"))
    vt.feed("\(CSI)<u\(CSI)?u")
    #expect(TestFixture(vt.takeOutput()) == TestFixture("\(CSI)?0u"))
  }
}

struct KittyKeyboardLevelsTests {
  @Test(
    arguments: [Unicode.Scalar("Ꭰ"), "İ", "É", "Я"],
    [KeyEvent.Action.press, .repeat, .release]
  )
  func `kitty preserves non ASCII layout key identities`(
    _ scalar: Unicode.Scalar,
    _ action: KeyEvent.Action
  ) {
    let event = KeyEvent(
      .character(scalar),
      modifiers: [.control, .shift],
      action: action,
      shiftedKey: "X",
      baseLayoutKey: "a"
    )
    let suffix = action == .repeat ? ":2" : action == .release ? ":3" : ""
    #expect(
      TestFixture(enc(event, 15))
        == TestFixture("\(CSI)\(scalar.value):88:97;6\(suffix)u")
    )
  }

  @Test(arguments: (0 ... 31).map(UInt8.init))
  func `enter tab and backspace releases require event types and all keys`(
    _ flags: UInt8
  ) {
    let keys: [(Key, Int)] = [(.enter, 13), (.tab, 9), (.backspace, 127)]
    for (key, code) in keys {
      for rawModifiers in UInt8(0) ... 15 {
        let modifiers = KeyModifiers(rawValue: rawModifiers)
        var output: [UInt8] = [0xAA]
        let sent = InputEncoder.encode(
          .key(KeyEvent(key, modifiers: modifiers, action: .release)),
          modes: .initial,
          keyboardFlags: flags,
          into: &output,
        )
        let reportsRelease = flags & 10 == 10
        let expected =
          reportsRelease
          ? Array("\(CSI)\(code);\(1 + Int(rawModifiers)):3u".utf8) : []
        #expect(sent == reportsRelease)
        #expect(output == [0xAA] + expected)
      }
    }
  }

  @Test(
    arguments: (0 ... 31).map(UInt32.init) + (127 ... 159).map(UInt32.init),
    [UInt8(1), 3, 24, 26]
  )
  func `control characters are never treated as kitty key text`(
    _ value: UInt32,
    _ flags: UInt8
  ) throws {
    let text = try "a" + String(#require(Unicode.Scalar(value)))
    #expect(
      TestFixture(enc(KeyEvent(.character("a"), text: text), flags))
        == TestFixture("\(CSI)97u")
    )
  }

  @Test(arguments: [UInt32(0), 27, 127, 128, 159], [UInt8(1), 3])
  func `control character keys are disambiguated`(
    _ value: UInt32,
    _ flags: UInt8
  ) throws {
    #expect(
      try TestFixture(
        enc(KeyEvent(.character(#require(Unicode.Scalar(value)))), flags)
      ) == TestFixture("\(CSI)\(value)u")
    )
  }

  func enc(_ e: KeyEvent, _ flags: UInt8) -> String {
    var out: [UInt8] = []
    InputEncoder.encode(
      .key(e),
      modes: .initial,
      keyboardFlags: flags,
      into: &out
    )
    return String(decoding: out, as: UTF8.self)
  }

  @Test
  func `event types`() {
    #expect(
      TestFixture(
        enc(KeyEvent(.character("a"), modifiers: .control, action: .repeat), 3)
      ) == TestFixture("\(CSI)97;5:2u")
    )
    #expect(
      TestFixture(
        enc(KeyEvent(.character("a"), modifiers: .control, action: .release), 3)
      ) == TestFixture("\(CSI)97;5:3u")
    )
    #expect(
      TestFixture(
        enc(KeyEvent(.character("a"), action: .release, text: "a"), 3)
      ) == TestFixture("")
    )
    #expect(
      TestFixture(enc(KeyEvent(.up, action: .release), 3))
        == TestFixture("\(CSI)1;1:3A")
    )
    #expect(
      TestFixture(enc(KeyEvent(.up, action: .release), 1)) == TestFixture("")
    )
    #expect(
      TestFixture(enc(KeyEvent(.character("a"), action: .release), 0))
        == TestFixture("")
    )
  }

  @Test
  func `all keys and text`() {
    #expect(
      TestFixture(enc(KeyEvent(.character("a"), text: "a"), 8))
        == TestFixture("\(CSI)97u")
    )
    #expect(
      TestFixture(
        enc(KeyEvent(.character("a"), modifiers: .shift, text: "A"), 8)
      ) == TestFixture("\(CSI)97;2u")
    )
    #expect(TestFixture(enc(KeyEvent(.enter), 8)) == TestFixture("\(CSI)13u"))
    #expect(
      TestFixture(enc(KeyEvent(.character("a"), text: "a"), 24))
        == TestFixture("\(CSI)97;1;97u")
    )
    #expect(
      TestFixture(
        enc(KeyEvent(.character("a"), modifiers: .shift, text: "A"), 24)
      ) == TestFixture("\(CSI)97;2;65u")
    )
    #expect(
      TestFixture(
        enc(KeyEvent(.character("a"), modifiers: .shift, text: "A"), 1)
      ) == TestFixture("A")
    )
    #expect(
      TestFixture(enc(KeyEvent(.function(5), modifiers: .alt), 1))
        == TestFixture("\(CSI)15;3~")
    )
  }
}

struct KittyFlagGatingTests {
  @Test(arguments: [UInt8(1), 3, 8, 9, 10, 24], [false, true])
  func `kitty functional keys use canonical CSI forms in both cursor modes`(
    _ flags: UInt8,
    _ applicationCursor: Bool
  ) {
    let keys: [(Key, String)] = [
      (.up, "A"), (.down, "B"), (.right, "C"), (.left, "D"), (.home, "H"),
      (.end, "F"), (.function(1), "P"), (.function(2), "Q"),
      (.function(3), "13~"), (.function(4), "S"), (.insert, "2~"),
      (.delete, "3~"), (.pageUp, "5~"), (.pageDown, "6~"),
      (.function(5), "15~"),
    ]
    for (key, code) in keys {
      var output: [UInt8] = []
      let modes: Modes = applicationCursor ? [.cursorKeys] : .initial
      #expect(
        TestFixture(
          InputEncoder.encode(
            .key(KeyEvent(key)),
            modes: modes,
            keyboardFlags: flags,
            into: &output
          )
        ) == TestFixture(true)
      )
      #expect(
        TestFixture(String(decoding: output, as: UTF8.self))
          == TestFixture("\(CSI)\(code)")
      )
    }
  }

  func enc(_ e: KeyEvent, _ flags: UInt8) -> String {
    var out: [UInt8] = []
    InputEncoder.encode(
      .key(e),
      modes: .initial,
      keyboardFlags: flags,
      into: &out
    )
    return String(decoding: out, as: UTF8.self)
  }

  @Test
  func `repeats carry no event field without flag 2`() {
    #expect(
      TestFixture(enc(KeyEvent(.up, action: .repeat), 1))
        == TestFixture("\(CSI)A")
    )
    #expect(
      TestFixture(
        enc(KeyEvent(.character("a"), modifiers: .control, action: .repeat), 1)
      ) == TestFixture("\(CSI)97;5u")
    )
  }

  @Test
  func `flags without disambiguate stay legacy`() {
    #expect(
      TestFixture(enc(KeyEvent(.character("c"), modifiers: .control), 2))
        == TestFixture("\u{03}")
    )
    #expect(TestFixture(enc(KeyEvent(.escape), 16)) == TestFixture("\u{1B}"))
    #expect(
      TestFixture(enc(KeyEvent(.escape, action: .release), 2))
        == TestFixture("")
    )
  }
}
