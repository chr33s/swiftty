import Darwin
import Dispatch
import Foundation
import MuxAttention
import SwiftMuxExport
import SwiftMuxProtocol
import SwifttyEngine
import SwifttyJS
import Synchronization

/// Resize, history scrolling, viewports and search.
extension PaneRuntime {
  // MARK: Geometry, history and search

  /// Engine resize, then `TIOCSWINSZ`, in this pane's order. Returns the
  /// geometry generation frames carry once this request is applied.
  @discardableResult
  func resize(columns: Int, rows: Int) -> UInt64 {
    let (generation, schedule) = resizes.withLock { requests in
      requests.requested &+= 1
      requests.pending = ResizeRequest(
        columns: columns,
        rows: rows,
        generation: requests.requested,
      )
      guard !requests.scheduled else { return (requests.requested, false) }
      requests.scheduled = true
      return (requests.requested, true)
    }
    if schedule { scheduleResize() }
    return generation
  }

  /// One running resize and one replaceable pending request. Queue the next
  /// turn at the tail so sustained geometry traffic cannot starve input.
  private func scheduleResize() {
    queue.async { [self] in
      let request = resizes.withLock { requests in
        let request = requests.pending!
        requests.pending = nil
        return request
      }
      applyResize(request)
      let again = resizes.withLock { requests in
        if requests.pending != nil { return true }
        requests.scheduled = false
        return false
      }
      if again { scheduleResize() }
    }
  }

  private func applyResize(_ request: ResizeRequest) {
    geometryGeneration = request.generation
    guard request.columns != state.columns || request.rows != state.rows else {
      noteChange()
      return
    }
    state.resize(columns: request.columns, rows: request.rows)
    if master >= 0 {
      var size = winsize(
        ws_row: UInt16(clamping: state.rows),
        ws_col: UInt16(clamping: state.columns),
        ws_xpixel: 0,
        ws_ypixel: 0,
      )
      _ = ioctl(master, TIOCSWINSZ, &size)
    }
    publish()
  }

  func scroll(
    _ request: ScrollRequest,
    completion: @escaping @Sendable (MuxError?) -> Void,
  ) {
    queue.async { [self] in
      switch request {
      case let .lines(n): state.scrollViewport(by: n)
      case let .pages(n):
        // The engine clamps to history; only the product can overflow.
        let (lines, overflow) = n.multipliedReportingOverflow(
          by: max(1, state.rows - 1),
        )
        state.scrollViewport(by: overflow ? (n < 0 ? .min : .max) : lines)
      case .bottom: state.scrollViewportToBottom()
      case .oldest: state.scrollViewport(by: .max)
      case let .prompt(n):
        guard state.jumpToPrompt(n) else {
          completion(MuxError(.notFound, "no such prompt"))
          return
        }
      case let .top(address):
        guard address.generation == state.addressingGeneration,
          address.alternateScreen == state.isAlternateScreen,
          state.contains(absoluteRow: address.row)
        else {
          completion(MuxError(.historyUnavailable, "history address is stale"))
          return
        }
        state.scrollViewport(by: -state.viewportRow(absoluteRow: address.row))
      }
      advanceViewport()
      noteChange()
      completion(nil)
    }
  }

  /// Moves the controller viewport to an anchor, addressed as a viewer's
  /// is (either screen); `followTail` returns it to live output.
  func setViewport(
    followTail: Bool,
    historyGeneration: UInt64,
    anchorRow: Int?,
    completion: @escaping @Sendable (MuxError?) -> Void,
  ) {
    queue.async { [self] in
      guard
        place(
          followTail: followTail,
          historyGeneration: historyGeneration,
          anchorRow: anchorRow,
        )
      else {
        completion(MuxError(.historyUnavailable, "history anchor is stale"))
        return
      }
      advanceViewport()
      noteChange()
      completion(nil)
    }
  }

  /// A step with nothing to select, or an end with no search, changes
  /// nothing.
  func search(
    _ query: String?,
    step forward: Bool?,
    completion: @escaping @Sendable (SearchResult) -> Void,
  ) {
    queue.async { [self] in
      let changes: Bool
      if let query {
        state.search(query)
        state.selectSearchMatch(forward: false)
        changes = true
      } else if let forward {
        // Nothing to step to: the window stays. (Matches are current:
        // the parser refreshes them after every read.)
        changes = state.selectSearchMatch(forward: forward) != nil
      } else {
        changes = state.isSearching
        state.endSearch()
      }
      if changes {
        advanceViewport()
        noteChange()
      }
      completion(
        SearchResult(
          matchCount: state.searchMatches.count,
          selected: state.searchSelected,
        ),
      )
    }
  }
}
