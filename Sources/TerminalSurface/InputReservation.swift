import SessionCore
import SwifttyEngine

func inputReservation(for input: TerminalInput) -> Int? {
  input.encodedByteReservation(maxInputBytes: RSTLimits.maxPasteBytes)
}
