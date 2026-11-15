import Foundation
import SessionCore
import SwiftMuxProtocol
@testable import SwiftMuxService
import SwifttyCore
@testable import TerminalHost
import Testing

@testable import RoamingKit
@testable import TerminalSurface

/// Keypad keys across SMX/2 and RST/1, with main-keyboard fallbacks for
/// peers that do not advertise `keypadKeys`.
struct KeypadProtocolTests {
  @Test
  func `frontend keypad keys become semantic keypad keys`() {
    for key in KeypadKey.allCases {
      #expect(
        SemanticKey(KeyEvent(.keypad(key)))
          == SemanticKey(.keypad(SemanticKeypadKey(rawValue: key.rawValue)!))
      )
    }
  }

  @Test
  func `roaming clients downgrade keypad keys for hosts without the feature`() {
    let one = InputOperation.key(
      SemanticKey(.keypad(.one), modifiers: .control)
    )
    #expect(RoamingClient.operation(one, for: .keypadKeys) == one)
    #expect(
      RoamingClient.operation(one, for: [])
        == .key(SemanticKey(.character("1"), modifiers: .control))
    )
    #expect(
      RoamingClient.operation(.key(SemanticKey(.keypad(.enter))), for: [])
        == .key(SemanticKey(.enter))
    )
    #expect(
      RoamingClient.operation(.key(SemanticKey(.keypad(.end))), for: [])
        == .key(SemanticKey(.end))
    )
    #expect(
      RoamingClient.operation(.key(SemanticKey(.keypad(.begin))), for: [])
        == nil
    )
    #expect(RoamingClient.operation(.paste("x"), for: []) == .paste("x"))
  }

  @Test
  func `the roaming host forwards keypad keys only to services that take them`()
  {
    let key = SemanticKey(.keypad(.one), modifiers: [.shift])
    #expect(RoamingSession.muxKey(key, keypadKeys: true)?.0 == .keypad(.one))
    #expect(RoamingSession.muxKey(key, keypadKeys: true)?.1 == .shift)
    #expect(
      RoamingSession.muxKey(key, keypadKeys: false)?.0
        == .character(UInt32(("1" as Unicode.Scalar).value))
    )
    #expect(
      RoamingSession.muxKey(SemanticKey(.keypad(.pageUp)), keypadKeys: false)?.0
        == .pageUp
    )
    #expect(
      RoamingSession.muxKey(SemanticKey(.keypad(.begin)), keypadKeys: false)
        == nil
    )
  }

  @Test
  func `services advertise and encode keypad keys`() throws {
    #expect(ServiceFeatures.supported.contains(.keypadKeys))
    for key in MuxKeypadKey.allCases {
      #expect(
        PaneRuntime.key(.keypad(key))
          == .keypad(KeypadKey(rawValue: key.rawValue)!)
      )
      let encoded = try JSONEncoder().encode(MuxKey.keypad(key))
      #expect(
        try JSONDecoder().decode(MuxKey.self, from: encoded) == .keypad(key)
      )
    }
  }
}
