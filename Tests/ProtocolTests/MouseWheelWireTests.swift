import Foundation
@testable import ScreenProtocol
import SessionCore
import Testing

/// RST/1 `wheel` operations and the `mouseWheel` feature that gates them.
struct MouseWheelWireTests {
  @Test
  func `wheel input round-trips through a control record`() throws {
    for wheel in [
      SemanticWheel(.up, column: 0, row: 0),
      SemanticWheel(.right, column: 199, row: 79, modifiers: [.shift, .alt]),
    ] {
      let message = ControlMessage.input(
        .init(attachmentEpoch: 1, sequence: 2, operation: .wheel(wheel))
      )
      let record = try ControlRecord.encode(message)
      #expect(try ControlRecord.decodeBody(record.dropFirst(4)) == message)
    }
    let body = try JSONEncoder()
      .encode(InputOperation.wheel(SemanticWheel(.down, column: 3, row: 4)))
    let json = try #require(
      try JSONSerialization.jsonObject(with: body) as? [String: Any]
    )
    #expect(json["op"] as? String == "wheel")
    let wheel = try #require(json["wheel"] as? [String: Any])
    #expect(wheel["direction"] as? String == "down")
    #expect(wheel["modifiers"] == nil)
  }

  @Test
  func `wheel operations stay inside the grid limits`() throws {
    try InputOperation.wheel(SemanticWheel(.up, column: 199, row: 79))
      .validate()
    for wheel in [
      SemanticWheel(.up, column: -1, row: 0),
      SemanticWheel(.up, column: 0, row: -1),
      SemanticWheel(.up, column: RSTLimits.maxColumns, row: 0),
      SemanticWheel(.up, column: 0, row: RSTLimits.maxRows),
    ] {
      #expect(throws: InputOperation.ValidationError.invalidWheel) {
        try InputOperation.wheel(wheel).validate()
      }
    }
    #expect(
      InputOperation.wheel(SemanticWheel(.up, column: 0, row: 0)).expansionBound
        >= "\u{1B}[<64;200;80M".utf8.count
    )
  }

  @Test
  func `unknown wheel directions are rejected`() {
    let body = #"{"op":"wheel","wheel":{"direction":"in","column":0,"row":0}}"#
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(InputOperation.self, from: Data(body.utf8))
    }
  }

  @Test
  func `hosts advertise mouseWheel by name`() {
    #expect(RSTFeatures.supported.contains(.mouseWheel))
    #expect(RSTFeatures(names: ["mouseWheel"]) == .mouseWheel)
    #expect(RSTFeatures.mouseWheel.names == ["mouseWheel"])
    #expect(RSTFeatures.supported.agreed(with: .mouseWheel) == .mouseWheel)
  }
}
