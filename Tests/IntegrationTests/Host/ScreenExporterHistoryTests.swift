#if os(macOS)
import SwiftMuxProtocol
@testable import TerminalHost
import Testing

/// History windows for one RST/1 attachment (`historyViewport`), moved
/// over a worker frame's history metadata.
struct ScreenExporterHistoryTests {
  /// Rows 0 ..< 47 are history; the live screen starts at row 47.
  let history = HistoryWindow(
    generation: 3,
    firstRow: 0,
    availableRows: 51,
    viewportTop: 47,
    viewportOffset: 0,
    scrollbackRows: 47
  )

  func top(
    from: Int?,
    generation: UInt64 = 3,
    moving lines: Int,
    alternate: Bool = false
  ) -> Int? {
    ScreenExporter.historyTop(
      history,
      alternateScreen: alternate,
      from: from,
      generation: generation,
      moving: lines
    )
    .top
  }

  @Test
  func `windows clamp to history and return to live output`() {
    #expect(top(from: nil, moving: 0) == nil)
    #expect(top(from: nil, moving: 5) == 42)
    #expect(top(from: 42, moving: -5) == nil)
    #expect(top(from: 42, moving: -99) == nil)
    #expect(top(from: nil, moving: 10_000) == 0)
    #expect(top(from: nil, moving: .max) == 0)
    #expect(top(from: nil, moving: .min) == nil)
  }

  @Test
  func `a window from other row numbering starts again from live output`() {
    #expect(top(from: 10, generation: 2, moving: 5) == 42)
    #expect(
      ScreenExporter.historyTop(
        history,
        alternateScreen: false,
        from: 10,
        generation: 2,
        moving: 5
      )
      .generation == 3
    )
  }

  @Test
  func `the alternate screen has no history window`() {
    #expect(top(from: nil, moving: 5, alternate: true) == nil)
    #expect(top(from: 10, moving: 5, alternate: true) == nil)
  }
}
#endif
