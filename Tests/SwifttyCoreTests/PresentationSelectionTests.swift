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
}
