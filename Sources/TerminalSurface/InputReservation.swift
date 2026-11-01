import SessionCore
import SwifttyCore

func inputReservation(for input: TerminalInput) -> Int? {
  input.encodedByteReservation(maxInputBytes: RSTLimits.maxPasteBytes)
}
