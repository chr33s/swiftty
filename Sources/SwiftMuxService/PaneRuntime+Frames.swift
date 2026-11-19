import Darwin
import Dispatch
import Foundation
import MuxAttention
import SwiftMuxExport
import SwiftMuxProtocol
import SwifttyEngine
import SwifttyJS
import Synchronization

/// Frame capture, observer viewports and inspection.
extension PaneRuntime {
  // MARK: Frames

  struct CapturedFrame: Sendable {
    var data: Data
    var revision: UInt64
    var geometry: UInt64
    /// The viewport (a viewer's window) the frame shows.
    var viewportRevision: UInt64
    /// What the client holds once it acknowledges this frame.
    var baseline: FrameBaseline?

    var sent: SentFrame {
      SentFrame(
        revision: revision,
        bytes: data.count,
        geometry: geometry,
        viewport: viewportRevision,
        baseline: baseline,
      )
    }
  }

  /// How one client receives frames (negotiated at hello).
  struct FrameEncoding: Sendable {
    var binary = false
    var deltas = false
  }

  /// Result of applying a viewer's anchor without touching the engine
  /// viewport that the controller is using.
  struct ResolvedViewport: Sendable {
    var followTail: Bool
    var historyGeneration: UInt64
    var anchorRow: Int?
    var search: SearchResult?
    var selectedMatch: SelectedMatch?
  }

  /// Captures cells and metadata in one operation and encodes the frame
  /// message, off the service queue. `viewport` nil uses the controller's
  /// engine viewport. A viewer viewport is applied only for the capture
  /// and then restored, so it cannot move the controller or the PTY.
  func captureFrame(
    server: ServerInstanceID,
    attachment: AttachmentID,
    layoutRevision: UInt64,
    viewport: ViewerViewport? = nil,
    encoding: FrameEncoding = FrameEncoding(),
    baseline: FrameBaseline? = nil,
    completion: @escaping @Sendable (Result<CapturedFrame, MuxError>) -> Void,
  ) {
    queue.async { [self] in
      // The controller's capture uses the engine state as it is; only a
      // viewer window needs saving and restoring around the capture.
      var saved: (offset: Int, search: TerminalState.TerminalSearchSnapshot)?
      if let viewport {
        saved = (state.viewportOffset, state.snapshotSearch())
        if let failure = apply(viewport) {
          restore(offset: saved!.offset, search: saved!.search)
          completion(.failure(failure))
          return
        }
      } else {
        state.refreshSearchIfNeeded()
      }
      var screen = state.captureOwnedScreen()
      let selected = state.searchSelected
      let geometry = geometryGeneration
      // A viewer capture does not share the controller's revision: each
      // exported frame for this pane stays strictly newer than the last.
      if viewport != nil { revision &+= 1 }
      let shownRevision =
        viewport?.revision ?? currentViewport.load(ordering: .relaxed)
      if let saved { restore(offset: saved.offset, search: saved.search) }
      rearmScrollbackMaintenanceIfNeeded()
      if let viewport {
        screen = screen.cropped(
          columns: viewport.columns ?? screen.columns,
          rows: viewport.rows ?? screen.rows
        )
      }
      let identity = FrameIdentity(
        server: server,
        attachment: attachment,
        pane: id,
        revision: revision,
        layoutRevision: layoutRevision,
        geometryGeneration: geometry,
        viewportRevision: shownRevision,
      )
      do {
        var frame = try FrameExporter.frame(
          from: screen,
          identity: identity,
          limits: limits,
        )
        frame.search?.selected = selected
        // Detach forgets a tracker; this bound only evicts the attachment
        // least recently captured, never every live one.
        rowTrackerOrder.removeAll { $0 == attachment }
        rowTrackerOrder.append(attachment)
        while rowTrackerOrder.count > Self.maxRowTrackers {
          rowTrackers.removeValue(forKey: rowTrackerOrder.removeFirst())
        }
        frame.rowVersions = rowTrackers[
          attachment,
          default: RowVersionTracker()
        ]
        .stamp(screen)
        let delta =
          encoding.deltas
          ? baseline.flatMap { FrameDeltaBuilder.delta(from: frame, base: $0) }
          : nil
        let data: Data
        switch (encoding.binary, delta) {
        case (true, let delta?): data = SMXB.encode(delta)
        case (true, nil): data = SMXB.encode(frame)
        case (false, let delta?):
          data = try SMXCodec.encode(
            ServerMessage.event(.frameDelta(delta)),
            limit: limits.maxFrameBytes,
          )
        case (false, nil):
          data = try SMXCodec.encode(
            ServerMessage.event(.frame(frame)),
            limit: limits.maxFrameBytes,
          )
        }
        guard data.count <= limits.maxFrameBytes else {
          throw MuxError(.resourceLimit, "frame of \(data.count) bytes")
        }
        completion(
          .success(
            CapturedFrame(
              data: data,
              revision: revision,
              geometry: geometry,
              viewportRevision: shownRevision,
              baseline: FrameBaseline(frame),
            )
          )
        )
      } catch let error as MuxError { completion(.failure(error)) } catch {
        completion(.failure(MuxError(.resourceLimit, "\(error)")))
      }
    }
  }

  /// Checks an anchor and, for a search, the match list. A relative
  /// `scroll` moves from the viewer's anchor and stops at the history
  /// edges. Searches and scrolls start from the viewer's own window (the
  /// tail when its anchor is stale), never from the controller's.
  /// Restores the controller viewport and search before returning.
  func resolveViewer(
    _ request: ViewportRequest,
    searchQuery: String?,
    searchStep: Bool?,
    searchSelected: SelectedMatch? = nil,
    scroll: ScrollRequest? = nil,
    completion: @escaping @Sendable (Result<ResolvedViewport, MuxError>) -> Void,
  ) {
    queue.async { [self] in
      let savedOffset = state.viewportOffset
      let savedSearch = state.snapshotSearch()
      defer { restore(offset: savedOffset, search: savedSearch) }
      let anchored = place(
        followTail: request.followTail,
        historyGeneration: request.historyGeneration,
        anchorRow: request.anchorRow,
      )
      let searching = searchQuery != nil || searchStep != nil
      // A stale anchor leaves the controller's viewport in place; a search
      // or scroll must start from the tail instead.
      if !anchored, searching || scroll != nil {
        state.scrollViewportToBottom()
      }
      if let searchStep {
        if let searchQuery, !searchQuery.isEmpty { viewerSearch(searchQuery) }
        // `search` clears the selection. Continue from the viewer's match
        // so a step does not jump back to the last occurrence.
        reselect(searchSelected)
        _ = state.selectSearchMatch(forward: searchStep)
      } else if let searchQuery {
        viewerSearch(searchQuery)
        _ = state.selectSearchMatch(forward: false)
      } else if let scroll {
        switch scroll {
        case let .lines(n): state.scrollViewport(by: n)
        case let .pages(n):
          // A page is the viewer's display height, not the PTY's.
          let page = max(1, (request.rows ?? state.rows) - 1)
          let (lines, overflow) = n.multipliedReportingOverflow(by: page)
          state.scrollViewport(by: overflow ? (n < 0 ? .min : .max) : lines)
        case .bottom: state.scrollViewportToBottom()
        case .oldest: state.scrollViewport(by: .max)
        case let .prompt(n): state.jumpToPrompt(n)
        case .top: break
        }
      } else if !anchored {
        completion(
          .failure(MuxError(.historyUnavailable, "history anchor is stale"))
        )
        return
      }
      let searchResult: SearchResult? =
        searching
        ? SearchResult(
          matchCount: state.searchMatches.count,
          selected: state.searchSelected,
        ) : nil
      let follow =
        request.followTail && !searching && scroll == nil
        ? true : state.viewportOffset == 0
      completion(
        .success(
          ResolvedViewport(
            followTail: follow,
            historyGeneration: state.addressingGeneration,
            anchorRow: state.absoluteRow(viewportRow: 0),
            search: searchResult,
            selectedMatch: state.searchSelected.map {
              SelectedMatch(
                range: state.searchMatches[$0],
                index: $0,
                historyGeneration: state.addressingGeneration,
              )
            },
          )
        )
      )
    }
  }

  /// Moves the engine viewport to a viewer window. False when the anchor
  /// is stale; the viewport is then unchanged.
  func place(
    followTail: Bool,
    historyGeneration: UInt64,
    anchorRow: Int?,
  ) -> Bool {
    if followTail {
      state.scrollViewportToBottom()
    } else if let row = anchorRow {
      guard historyGeneration == state.addressingGeneration,
        state.contains(absoluteRow: row)
      else { return false }
      state.scrollViewport(by: -state.viewportRow(absoluteRow: row))
    }
    return true
  }

  /// Runs a viewer search, reusing the matches of an identical search
  /// while the pane has not changed (several observers, one scan).
  private func viewerSearch(_ query: String) {
    if let cache = viewerSearchCache, cache.query == query,
      cache.change == changeCount
    {
      state.restoreSearch(cache.search)
      return
    }
    state.search(query)
    viewerSearchCache = ViewerSearchCache(
      query: query,
      change: changeCount,
      search: state.snapshotSearch(),
    )
  }

  /// Applies a viewer window for the duration of one capture. A viewer
  /// without a search of its own shows none, whatever the controller's.
  private func apply(_ viewport: ViewerViewport) -> MuxError? {
    let placed = place(
      followTail: viewport.followTail,
      historyGeneration: viewport.historyGeneration,
      anchorRow: viewport.anchorRow,
    )
    guard placed else {
      return MuxError(.historyUnavailable, "history anchor is stale")
    }
    if let query = viewport.searchQuery, !query.isEmpty {
      viewerSearch(query)
      reselect(viewport.searchSelected)
    } else {
      state.endSearch()
    }
    return nil
  }

  /// Reselects a viewer's match: by position within its history
  /// generation, else (rows renumbered by a clear, reflow or screen switch)
  /// by its place in the match list, as near as the new list allows.
  private func reselect(_ match: SelectedMatch?) {
    guard let match else { return }
    if match.historyGeneration == state.addressingGeneration {
      state.reselectSearchMatch(match.range)
    } else if !state.searchMatches.isEmpty {
      let index = min(match.index, state.searchMatches.count - 1)
      state.reselectSearchMatch(state.searchMatches[index])
    }
  }

  private func restore(
    offset: Int,
    search: TerminalState.TerminalSearchSnapshot
  ) {
    state.restoreSearch(search)
    let delta = offset - state.viewportOffset
    if delta != 0 { state.scrollViewport(by: delta) }
  }

  /// Plain text of the visible screen (tests, diagnostics).
  func screenLines() -> [String] { queue.sync { state.screenLines } }

  /// Metadata-only history storage accounting (tests, diagnostics).
  var scrollbackStatistics: ScrollbackStatistics {
    queue.sync { state.scrollbackStatistics }
  }

  /// Runs idle maintenance to completion now, as the coordinator would
  /// after a quiet period (tests). Publishes nothing.
  func compressScrollbackForTesting() -> ScrollbackStatistics {
    queue.sync {
      var budget = ScrollbackMaintenanceBudget()
      budget.maximumCandidates = 1 << 20
      budget.maximumUnits = 1 << 20
      while state.maintainScrollback(budget: budget) == .pending {}
      return state.scrollbackStatistics
    }
  }

  /// Captures teardown progress in pane order without signaling or reaping.
  func terminationStateForTesting() -> String {
    queue.sync {
      let now = DispatchTime.now().uptimeNanoseconds
      let remaining = terminationDeadline.map {
        $0.uptimeNanoseconds > now ? $0.uptimeNanoseconds - now : 0
      }
      return
        "pid=\(pid) terminating=\(terminating) exit=\(String(describing: exitStatus)) "
        + "finished=\(finished) forced=\(forcedTermination) groupKill=\(groupKillSent) "
        + "graceRemainingNs=\(String(describing: remaining)) drainPending=\(drainTimer != nil)"
    }
  }

  /// Runs `body` in this pane's order with the authoritative state, for
  /// exports other than `PaneFrame` (the roaming bridge's screens).
  func inspect<T: Sendable>(
    _ body: @escaping @Sendable (borrowing TerminalState) -> T,
    completion: @escaping @Sendable (T) -> Void,
  ) {
    queue.async { [self] in
      let value = body(state)
      rearmScrollbackMaintenanceIfNeeded()
      completion(value)
    }
  }

  var size: (columns: Int, rows: Int) {
    queue.sync { (state.columns, state.rows) }
  }
}
