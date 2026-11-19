import RoamingTerminal
import SwifttyEngine
import TTYKit
import Testing

/// `swroam` keyed row diffing (spec.multiplexer.md §6): keyed and unkeyed
/// diffs write the same bytes, and a palette change redraws keyed rows.
struct RoamingKeyedDiffTests {
  static func frame(
    _ rows: [String],
    versions: [UInt64],
    foreground: UInt32 = 0x11_2233
  ) -> PresentationFrame {
    let columns = 6
    var cells: [PresentationFrame.Cell] = []
    for row in rows {
      let padded = row.padding(toLength: columns, withPad: " ", startingAt: 0)
      for ch in padded {
        cells.append(.init(text: ch == " " ? "" : String(ch), style: 1))
      }
    }
    var frame = PresentationFrame(
      columns: columns,
      rows: rows.count,
      cells: cells,
      wrapped: Array(repeating: false, count: rows.count),
      styles: [
        .init(foreground: nil, background: nil, underlineColor: nil, flags: []),
        .init(
          foreground: foreground,
          background: nil,
          underlineColor: nil,
          flags: []
        ),
      ],
      cursorX: 0,
      cursorY: 0
    )
    frame.rowKeys = versions.enumerated()
      .map { [7, 0, UInt64($0.offset), $0.element] }
    return frame
  }

  @Test
  func `keys skip unchanged rows and never change the bytes`() {
    var renderer = DiffRenderer()
    let first = ScreenBuffer(
      Self.frame(["one", "two", "three"], versions: [1, 2, 3]),
      columns: 6,
      rows: 3
    )
    _ = renderer.update(to: first)
    renderer.commit(first)
    let edited = ScreenBuffer(
      Self.frame(["one", "TWO", "three"], versions: [1, 4, 3]),
      columns: 6,
      rows: 3
    )
    #expect(renderer.keyedRows(of: edited) == [0, 2])
    #expect(
      renderer.update(to: edited) == renderer.update(to: edited, useKeys: false)
    )
    // Same identities, other palette: the resolved style is in the key.
    let recolored = ScreenBuffer(
      Self.frame(
        ["one", "two", "three"],
        versions: [1, 2, 3],
        foreground: 0xFF_0000
      ),
      columns: 6,
      rows: 3
    )
    #expect(renderer.keyedRows(of: recolored).isEmpty)
    #expect(
      renderer.update(to: recolored)
        == renderer.update(to: recolored, useKeys: false)
    )
    // Mutation: changed cells under an unchanged key are skipped.
    var mutated = first
    mutated[0, 0] = ScreenCell(text: "X")
    let keyed = String(decoding: renderer.update(to: mutated), as: UTF8.self)
    #expect(!keyed.contains("X"))
  }
}
