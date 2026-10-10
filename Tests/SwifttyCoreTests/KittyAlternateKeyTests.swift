@testable import SwifttyCore
import Testing
import TestSupport

struct KittyAlternateKeyTests {
  @Test(arguments: [UInt8(0), 1, 5, 8, 13])
  func `modified backspace retains legacy and kitty encodings`(_ flags: UInt8) {
    #expect(
      TestFixture(encode(KeyEvent(.backspace, modifiers: .shift), flags: flags))
        == TestFixture(flags == 0 ? "\u{7F}" : "\u{1B}[127;2u")
    )
    #expect(
      TestFixture(encode(KeyEvent(.backspace, modifiers: .alt), flags: flags))
        == TestFixture(flags == 0 ? "\u{1B}\u{7F}" : "\u{1B}[127;3u")
    )
  }

  private func encode(_ event: KeyEvent, flags: UInt8 = 15) -> String {
    var output: [UInt8] = []
    InputEncoder.encode(
      .key(event),
      modes: .initial,
      keyboardFlags: flags,
      into: &output
    )
    return String(decoding: output, as: UTF8.self)
  }

  @Test(
    arguments: (0 ... 31).map(UInt32.init) + (127 ... 159).map(UInt32.init),
    [KeyEvent.Action.press, .repeat, .release]
  )
  func `control scalars are excluded from alternate identities`(
    _ value: UInt32,
    _ action: KeyEvent.Action
  ) throws {
    let control = try #require(Unicode.Scalar(value))
    let suffix = action == .repeat ? ":2" : action == .release ? ":3" : ""
    let shifted = KeyEvent(
      .character("ч"),
      modifiers: [.control, .shift],
      action: action,
      shiftedKey: control,
      baseLayoutKey: ";",
    )
    #expect(
      TestFixture(encode(shifted)) == TestFixture("\u{1B}[1095::59;6\(suffix)u")
    )
    let base = KeyEvent(
      .character("ч"),
      modifiers: [.control, .shift],
      action: action,
      shiftedKey: "Ч",
      baseLayoutKey: control,
    )
    #expect(
      TestFixture(encode(base)) == TestFixture("\u{1B}[1095:1063;6\(suffix)u")
    )
  }

  @Test(arguments: [KeyEvent.Action.press, .repeat, .release])
  func `control keys do not report alternate identities`(
    _ action: KeyEvent.Action
  ) throws {
    let suffix = action == .repeat ? ":2" : action == .release ? ":3" : ""
    var keys: [(Key, UInt32)] = [
      (.enter, 13), (.tab, 9), (.backspace, 127), (.escape, 27),
    ]
    for value in (0 ... 31).map(UInt32.init) + (127 ... 159).map(UInt32.init) {
      try keys.append((.character(#require(Unicode.Scalar(value))), value))
    }
    for (key, code) in keys {
      let event = KeyEvent(
        key,
        modifiers: [.control, .shift],
        action: action,
        shiftedKey: "X",
        baseLayoutKey: "a"
      )
      #expect(
        TestFixture(encode(event)) == TestFixture("\u{1B}[\(code);6\(suffix)u")
      )
    }
  }

  @Test(arguments: [false, true], [KeyEvent.Action.press, .repeat, .release])
  func
    `event reporting preserves Russian layout identities and associated text`(
      _ shifted: Bool,
      _ action: KeyEvent.Action
    )
  {
    let text = shifted ? "Ч" : "ч"
    let event = KeyEvent(
      .character("ч"),
      modifiers: shifted ? .shift : [],
      action: action,
      text: text,
      shiftedKey: "Ч",
      baseLayoutKey: ";",
    )
    let identity = shifted ? "1095:1063:59" : "1095::59"
    let modifier = shifted ? 2 : 1
    let suffix = action == .repeat ? ":2" : action == .release ? ":3" : ""
    let associated = action == .release ? "" : ";\(shifted ? 1063 : 1095)"
    #expect(
      TestFixture(encode(event, flags: 31))
        == TestFixture("\u{1B}[\(identity);\(modifier)\(suffix)\(associated)u")
    )
  }

  @Test(arguments: [KeyEvent.Action.press, .repeat, .release])
  func `every Hungarian layout event reports its physical base key`(
    _ action: KeyEvent.Action
  ) {
    let event = KeyEvent(
      .character("ő"),
      modifiers: .control,
      action: action,
      baseLayoutKey: "["
    )
    let suffix = action == .repeat ? ":2" : action == .release ? ":3" : ""
    #expect(
      TestFixture(encode(event)) == TestFixture("\u{1B}[337::91;5\(suffix)u")
    )
  }
}
