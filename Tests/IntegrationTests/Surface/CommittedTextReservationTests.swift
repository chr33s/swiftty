import SessionCore
import SwifttyCore
import Testing

@testable import RoamingKit
@testable import TerminalSurface

struct CommittedTextReservationTests {
  @Test
  func reservationCoversEveryKeyboardFlagCombination() throws {
    for text in [
      "a", "漢", "e\u{301}", "👩‍💻", "\u{10FFFF}",
      String(repeating: "z", count: RSTLimits.maxPasteBytes),
      String(repeating: "漢", count: RSTLimits.maxPasteBytes / 3),
    ] {
      let reservation = try #require(inputReservation(for: .text(text)))
      for flags in UInt8(0) ... 31 {
        var output: [UInt8] = []
        #expect(
          InputEncoder.encode(
            .text(text),
            modes: .initial,
            keyboardFlags: flags,
            into: &output
          )
        )
        #expect(output.count <= reservation)
      }
    }
    #expect(inputReservation(for: .text("")) == nil)
    #expect(
      inputReservation(
        for: .text(String(repeating: "x", count: RSTLimits.maxPasteBytes + 1))
      ) == nil
    )
  }
}
