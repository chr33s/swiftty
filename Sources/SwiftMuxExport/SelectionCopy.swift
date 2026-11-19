import Synchronization
import SwiftMuxProtocol
import SwifttyEngine

/// A row-version tracker shared between captures and copies that run on
/// the pane's queue but are owned elsewhere (the roaming host).
package final class RowVersionBox: Sendable {
  private let tracker = Mutex(RowVersionTracker())

  package init() {}

  package func stamp(_ owned: OwnedScreen) -> [UInt64] {
    tracker.withLock { $0.stamp(owned) }
  }

  package func matches(
    _ identity: RowIdentity,
    in state: borrowing TerminalState
  ) -> Bool { tracker.withLock { $0.matches(identity, in: state) } }
}

/// Copies a client-local selection from the authoritative grid
/// (spec.multiplexer.md §4, "Live selection across pages"), for SwiftMux
/// and RST/1 alike. Fails rather than copying text the client did not see:
/// a changed generation or evicted row is `historyUnavailable`, a changed
/// screen row `selectionChanged`, more than `maxTextBytes` `resourceLimit`.
package enum SelectionCopy {
  package static func text(
    _ request: CopySelectionRequest,
    in state: borrowing TerminalState,
    matches: (RowIdentity) -> Bool
  ) -> Result<String, MuxError> {
    let generation = state.addressingGeneration
    for end in [request.start, request.end] {
      guard end.address.generation == generation,
        end.address.alternateScreen == state.isAlternateScreen,
        state.contains(absoluteRow: end.address.row)
      else {
        return .failure(MuxError(.historyUnavailable, "selection left history"))
      }
    }
    for identity in request.screenRowVersions where !matches(identity) {
      return .failure(MuxError(.selectionChanged, "a selected row changed"))
    }
    let a = TerminalPoint(
      row: request.start.address.row,
      column: request.start.column
    )
    let b = TerminalPoint(
      row: request.end.address.row,
      column: request.end.column
    )
    var start = min(a, b)
    var end = max(a, b)
    switch request.unit {
    case .character: break
    case .word:
      start = state.wordRange(at: start).start
      end = state.wordRange(at: end).end
    case .line:
      start = state.lineRange(at: start).start
      end = state.lineRange(at: end).end
    }
    let text = state.text(from: start, to: end)
    guard text.utf8.count <= CopySelectionRequest.maxTextBytes else {
      return .failure(
        MuxError(.resourceLimit, "selection exceeds the copy limit")
      )
    }
    return .success(text)
  }
}
