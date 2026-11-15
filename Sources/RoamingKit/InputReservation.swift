import SessionCore
import SwifttyEngine

package func inputReservation(for input: TerminalInput) -> Int? {
  input.encodedByteReservation(maxInputBytes: RSTLimits.maxPasteBytes)
}
