@testable import SwifttyCore
import Testing
import TestSupport

struct MouseEncoderTests {
  @Test(
    arguments: [MouseEvent.Action.press, .release, .motion],
    [Modes(), .mouseUTF8, .mouseSGR]
  )
  func `only ordinary button presses are reported in X10`(
    _ action: MouseEvent.Action,
    _ format: Modes
  ) {
    let buttons: [MouseEvent.Button] = [
      .left, .middle, .right, .none, .wheelUp, .wheelDown, .wheelLeft,
      .wheelRight,
    ]
    for (code, button) in buttons.enumerated() {
      var output: [UInt8] = [0x78]
      let event = MouseEvent(
        action,
        button,
        column: 4,
        row: 2,
        modifiers: [.shift, .alt, .control]
      )
      let sent = InputEncoder.encode(
        .mouse(event),
        modes: [.mouseX10, format],
        into: &output
      )
      let expected = action == .press && code < 3
      #expect(
        sent == expected,
        Comment(rawValue: escapedTestText("action=\(action) button=\(button)"))
      )
      if expected {
        let bytes =
          format == .mouseSGR
          ? Array("\u{1B}[<\(code);5;3M".utf8)
          : [0x1B, 0x5B, 0x4D, UInt8(code + 32), 37, 35]
        #expect(output == [0x78] + bytes)
      } else {
        #expect(output == [0x78])
      }
    }
  }

  @Test(
    arguments: [Modes.mouseNormal, .mouseButton, .mouseAny],
    [KeyModifiers(), [.shift, .alt, .control]]
  )
  func `SGR releases preserve every ordinary button identity`(
    _ tracking: Modes,
    _ modifiers: KeyModifiers
  ) {
    for (code, button) in [MouseEvent.Button.left, .middle, .right].enumerated()
    {
      var output: [UInt8] = []
      let event = MouseEvent(
        .release,
        button,
        column: 4,
        row: 2,
        modifiers: modifiers
      )
      #expect(
        TestFixture(
          InputEncoder.encode(
            .mouse(event),
            modes: [tracking, .mouseSGR],
            into: &output
          )
        ) == TestFixture(true)
      )
      let modifierCode = modifiers.isEmpty ? 0 : 28
      #expect(
        TestFixture(output)
          == TestFixture(Array("\u{1B}[<\(code + modifierCode);5;3m".utf8))
      )
    }
  }

  @Test(
    arguments: [Modes.mouseX10, .mouseNormal, .mouseButton, .mouseAny],
    [Modes(), .mouseUTF8, .mouseSGR]
  )
  func `unpressed motion requires any event tracking`(
    _ tracking: Modes,
    _ format: Modes
  ) {
    var output: [UInt8] = []
    let event = MouseEvent(
      .motion,
      .none,
      column: 4,
      row: 2,
      modifiers: [.shift, .alt, .control]
    )
    let sent = InputEncoder.encode(
      .mouse(event),
      modes: [tracking, format],
      into: &output
    )
    #expect(sent == (tracking == .mouseAny))
    if tracking == .mouseAny {
      let expected: [UInt8] =
        format == .mouseSGR
        ? Array("\u{1B}[<63;5;3M".utf8) : [0x1B, 0x5B, 0x4D, 95, 37, 35]
      #expect(output == expected)
    } else {
      #expect(output.isEmpty)
    }
  }

  @Test(
    arguments: [Modes.mouseNormal, .mouseButton, .mouseAny],
    [Modes(), .mouseUTF8, .mouseSGR]
  )
  func `wheel directions report presses without releases`(
    _ tracking: Modes,
    _ format: Modes
  ) {
    let buttons: [MouseEvent.Button] = [
      .wheelUp, .wheelDown, .wheelLeft, .wheelRight,
    ]
    for (offset, button) in buttons.enumerated() {
      var output: [UInt8] = []
      let event = MouseEvent(.press, button, column: 4, row: 2)
      #expect(
        TestFixture(
          InputEncoder.encode(
            .mouse(event),
            modes: [tracking, format],
            into: &output
          )
        ) == TestFixture(true)
      )
      let expected: [UInt8] =
        format == .mouseSGR
        ? Array("\u{1B}[<\(64 + offset);5;3M".utf8)
        : [0x1B, 0x5B, 0x4D, UInt8(96 + offset), 37, 35]
      #expect(output == expected)
      var release = event
      release.action = .release
      #expect(
        TestFixture(
          !InputEncoder.encode(
            .mouse(release),
            modes: [tracking, format],
            into: &output
          )
        ) == TestFixture(true)
      )
      #expect(output == expected)
    }
  }
}
