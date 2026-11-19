import Dispatch
import SwifttyCore
import Synchronization
import Testing

/// Live selection on presentation sessions (spec.roaming.md §7.5): a
/// selection follows its host rows across installed frames, ends on an
/// in-place edit or a new generation, and copies from the host when it
/// reaches beyond the shown rows.
struct PresentationSelectionTests {
  /// Rows `top ..< top + count` of a host whose row `n` reads "row n",
  /// with `versions` overriding a row's version (default 1).
  static func window(
    top: Int,
    count: Int = 4,
    generation: UInt64 = 3,
    versions: [Int: UInt64] = [:],
    text: [Int: String] = [:]
  ) -> PresentationFrame {
    let columns = 10
    var cells: [PresentationFrame.Cell] = []
    for row in top ..< top + count {
      let line = (text[row] ?? "row \(row)")
        .padding(toLength: columns, withPad: " ", startingAt: 0)
      for ch in line { cells.append(.init(text: ch == " " ? "" : String(ch))) }
    }
    var frame = PresentationFrame(
      columns: columns,
      rows: count,
      cells: cells,
      wrapped: Array(repeating: false, count: count),
      styles: [.init()],
      cursorX: 0,
      cursorY: 0
    )
    frame.rowKeys = (top ..< top + count)
      .map { [generation, 0, UInt64($0), versions[$0] ?? 1, 1] }
    return frame
  }

  static func select(_ s: TerminalSession, from a: Int, to b: Int) {
    s.mutate { state in
      state.setSelection(
        Selection(
          anchor: state.viewportPoint(row: a, column: 0),
          head: state.viewportPoint(row: b, column: 9)
        )
      )
    }
  }

  @Test
  func `a selection follows its rows as the window moves`() {
    let s = TerminalSession(presentationColumns: 10, rows: 4)
    #expect(s.installPresentation(Self.window(top: 10)))
    Self.select(s, from: 1, to: 2)  // rows 11 and 12
    #expect(s.withState { $0.selectionText } == "row 11\nrow 12")
    // The host window scrolls back one line: rows 9 to 12.
    #expect(s.installPresentation(Self.window(top: 9)))
    #expect(s.withState { $0.selectionText } == "row 11\nrow 12")
    #expect(s.withState { $0.presentationSelectionBeyondView } == nil)
    // Back three: rows 6 to 9; the selection is wholly below the window.
    #expect(s.installPresentation(Self.window(top: 6)))
    let beyond = s.withState { $0.presentationSelectionBeyondView }
    #expect(beyond?.anchor.row == 11)
    #expect(beyond?.head.row == 12)
    // Forward again: shown once more.
    #expect(s.installPresentation(Self.window(top: 10)))
    #expect(s.withState { $0.selectionText } == "row 11\nrow 12")
    // Cleared while off the frame, it does not come back.
    #expect(s.installPresentation(Self.window(top: 6)))
    s.mutate { $0.setSelection(nil) }
    #expect(s.installPresentation(Self.window(top: 10)))
    #expect(s.withState { $0.selection } == nil)
  }

  @Test
  func `an in-place edit or a new generation ends the selection`() {
    let s = TerminalSession(presentationColumns: 10, rows: 4)
    #expect(s.installPresentation(Self.window(top: 10)))
    Self.select(s, from: 1, to: 2)
    #expect(
      s.installPresentation(
        Self.window(top: 10, versions: [12: 2], text: [12: "EDITED"])
      )
    )
    #expect(s.withState { $0.selection } == nil)
    Self.select(s, from: 0, to: 1)
    #expect(s.installPresentation(Self.window(top: 10, generation: 4)))
    #expect(s.withState { $0.selection } == nil)
  }

  @Test
  func `a selection beyond the window is copied by the handler`() async {
    let s = TerminalSession(presentationColumns: 10, rows: 4)
    #expect(s.installPresentation(Self.window(top: 10)))
    Self.select(s, from: 0, to: 3)  // rows 10 to 13
    // Scroll back two: the selection's end lies below the window.
    #expect(s.installPresentation(Self.window(top: 8)))
    let requested = Mutex<PresentationSelection?>(nil)
    s.remoteCopyHandler = { selection, done in
      requested.withLock { $0 = selection }
      done("row 10\nrow 11\nrow 12\nrow 13")
    }
    let text: String? = await withCheckedContinuation { continuation in
      DispatchQueue.main.async {
        s.copySelectedText { continuation.resume(returning: $0) }
      }
    }
    #expect(text == "row 10\nrow 11\nrow 12\nrow 13")
    let selection = requested.withLock { $0 }
    #expect(selection?.anchor.row == 10)
    #expect(selection?.head.row == 13)
    // Every selected row seen so far carries its version for the host.
    #expect(Set(selection?.seen.keys.map { $0 } ?? []) == [10, 11, 12, 13])
  }

  @Test
  func `a shown selection copies locally`() async {
    let s = TerminalSession(presentationColumns: 10, rows: 4)
    #expect(s.installPresentation(Self.window(top: 10)))
    Self.select(s, from: 1, to: 1)
    s.remoteCopyHandler = { _, done in done("remote") }
    let text: String? = await withCheckedContinuation { continuation in
      DispatchQueue.main.async {
        s.copySelectedText { continuation.resume(returning: $0) }
      }
    }
    #expect(text == "row 11")
  }

  @Test
  func
    `changing a carried selection before the next frame still copies it all`()
  {
    let s = TerminalSession(presentationColumns: 10, rows: 4)
    #expect(s.installPresentation(Self.window(top: 10)))
    Self.select(s, from: 0, to: 2)  // rows 10 to 12
    // Scroll on: row 10 is above the window, the anchor shows clamped.
    #expect(s.installPresentation(Self.window(top: 12)))
    // The user moves the head to the last shown row; no frame follows.
    s.mutate { state in
      let anchor = state.selection!.anchor
      state.setSelection(
        Selection(anchor: anchor, head: state.viewportPoint(row: 3, column: 9))
      )
    }
    let beyond = s.withState { $0.presentationSelectionBeyondView }
    #expect(beyond?.anchor.row == 10)
    #expect(beyond?.head.row == 15)
  }

  @Test
  func `dragging extends from the anchor's host row across frames`() {
    let s = TerminalSession(presentationColumns: 10, rows: 4)
    #expect(s.installPresentation(Self.window(top: 10)))
    Self.select(s, from: 1, to: 1)  // row 11
    // The window moves back while dragging up, twice.
    #expect(s.installPresentation(Self.window(top: 8)))
    #expect(
      s.mutate {
        $0.extendPresentationSelection(
          toViewportRow: 0,
          column: 0,
          rectangle: false
        )
      }
    )
    #expect(s.installPresentation(Self.window(top: 5)))
    #expect(
      s.mutate {
        $0.extendPresentationSelection(
          toViewportRow: 0,
          column: 0,
          rectangle: false
        )
      }
    )
    #expect(s.installPresentation(Self.window(top: 10)))
    let beyond = s.withState { $0.presentationSelectionBeyondView }
    #expect(beyond?.anchor.row == 11)
    #expect(beyond?.head.row == 5)
  }

  @Test
  func `placement clamps off-frame ends and checks only selected rows`() {
    func keys(top: Int, versions: [Int: UInt64] = [:]) -> [[UInt64]] {
      (top ..< top + 4).map { [3, 0, UInt64($0), versions[$0] ?? 1, 1] }
    }
    var selection = PresentationSelection(
      generation: 3,
      alternateScreen: false,
      anchor: (row: 5, column: 7),
      head: (row: 11, column: 2),
      rectangle: false
    )
    // Anchor above the frame: the shown part starts at its first cell.
    #expect(
      selection.place(in: keys(top: 10), columns: 10)
        == .shown(
          anchor: .init(row: 0, column: 0),
          head: .init(row: 1, column: 2)
        )
    )
    // Wholly above the frame: hidden, never drawn on row 0.
    #expect(selection.place(in: keys(top: 20), columns: 10) == .hidden)
    // An edit to a row outside the selection does not end it.
    #expect(
      selection.place(in: keys(top: 20, versions: [20: 9]), columns: 10)
        == .hidden
    )
    // An edit to a selected row does.
    #expect(
      selection.place(in: keys(top: 10, versions: [11: 9]), columns: 10)
        == .ended
    )
  }
}
