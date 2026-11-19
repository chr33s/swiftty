import Foundation
import SwiftMuxProtocol
import SwiftMuxTerminal
import TTYKit
import Testing

/// Keyed row diffing (spec.multiplexer.md §6): keys skip work, never
/// change the bytes written.
struct KeyedDiffTests {
  struct Panes {
    var left = FrameDeltaTests.Exporter(columns: 19, rows: 7)
    var right = FrameDeltaTests.Exporter(columns: 20, rows: 7)
    let leftID = PaneID()
    let rightID = PaneID()
    let tab = TabID()

    func workspace(
      revision: UInt64 = 1,
      exited: Bool = false
    ) -> WorkspaceSnapshot {
      WorkspaceSnapshot(
        id: WorkspaceID(),
        name: "w",
        tabs: [
          TabSnapshot(
            id: tab,
            name: "t",
            layout: .split(
              axis: .leftRight,
              ratio: 0.5,
              first: .pane(leftID),
              second: .pane(rightID)
            ),
            activePane: leftID
          )
        ],
        activeTab: tab,
        panes: [
          PaneSummary(id: leftID, columns: 19, rows: 7),
          PaneSummary(
            id: rightID,
            columns: 20,
            rows: 7,
            exitStatus: exited ? 1 : nil
          ),
        ],
        layoutRevision: revision
      )
    }
  }

  /// Runs `steps`, composing after each, and checks keyed and unkeyed
  /// diffs write the same bytes. Returns rows skipped per step.
  static func run(
    _ steps: [(inout Panes) -> Void],
    overlay: PaneOverlay? = nil,
    exited: Bool = false
  ) throws -> [Int] {
    var panes = Panes()
    var renderer = DiffRenderer()
    let compositor = Compositor(columns: 40, rows: 8)
    var tokens: [PaneID: UInt64] = [:]
    var palettes: [PaneID: FramePalette] = [:]
    var skipped: [Int] = []
    for step in steps {
      step(&panes)
      let frames = [
        panes.leftID: try panes.left.frame(),
        panes.rightID: try panes.right.frame(),
      ]
      for (pane, frame) in frames where palettes[pane] != frame.palette {
        palettes[pane] = frame.palette
        tokens[pane, default: 0] += 1
      }
      let screen = compositor.compose(
        workspace: panes.workspace(exited: exited),
        frames: frames,
        overlays: overlay.map { [panes.leftID: $0] } ?? [:],
        status: StatusLine(),
        showCursor: true,
        paletteTokens: tokens
      )
      #expect(
        renderer.update(to: screen)
          == renderer.update(to: screen, useKeys: false)
      )
      skipped.append(renderer.keyedRows(of: screen).count)
      renderer.commit(screen)
    }
    return skipped
  }

  @Test
  func typingInOnePaneSkipsTheRestAndWritesTheSameBytes() throws {
    var steps: [(inout Panes) -> Void] = [{ $0.left.feed("$ ") }]
    for c in "echo hi" { steps.append { $0.left.feed(String(c)) } }
    steps.append { $0.right.feed("other pane\r\n") }
    let skipped = try Self.run(steps)
    // Typing changes one row; the other six pane rows are skipped.
    #expect(skipped.dropFirst().dropLast().allSatisfy { $0 == 6 })
  }

  @Test
  func scrollingCROverwriteAndOverlaysStayExact() throws {
    var steps: [(inout Panes) -> Void] = []
    for n in 1 ... 20 { steps.append { $0.left.feed("line \(n)\r\n") } }
    for n in 0 ... 8 {
      steps.append {
        $0.right.feed("\r[" + String(repeating: "#", count: n) + "]")
      }
    }
    steps.append { $0.left.feed("\u{1B}]4;1;rgb:12/34/56\u{07}") }  // palette
    _ = try Self.run(steps)
    let overlay = PaneOverlay(
      selection: ((1, 2), (3, 4), false),
      cursor: (3, 4)
    )
    _ = try Self.run(steps, overlay: overlay)
    _ = try Self.run(steps, exited: true)
  }

  /// Mutation check: a row whose cells change under an unchanged key is
  /// not rewritten, so the key alone is what skips the work.
  @Test
  func theKeyIsWhatSkipsTheRow() throws {
    var panes = Panes()
    panes.left.feed("same\r\n")
    let compositor = Compositor(columns: 40, rows: 8)
    let frames = [
      panes.leftID: try panes.left.frame(),
      panes.rightID: try panes.right.frame(),
    ]
    let tokens = [panes.leftID: UInt64(1), panes.rightID: 1]
    let screen = compositor.compose(
      workspace: panes.workspace(),
      frames: frames,
      status: StatusLine(),
      showCursor: false,
      paletteTokens: tokens
    )
    var renderer = DiffRenderer()
    _ = renderer.update(to: screen)
    renderer.commit(screen)
    var mutated = screen
    mutated[0, 0] = ScreenCell(text: "X")
    #expect(renderer.keyedRows(of: mutated).contains(0))
    let keyed = String(decoding: renderer.update(to: mutated), as: UTF8.self)
    let unkeyed = String(
      decoding: renderer.update(to: mutated, useKeys: false),
      as: UTF8.self
    )
    #expect(!keyed.contains("X"))
    #expect(unkeyed.contains("X"))
    // Without a palette token, rows are compared cell by cell.
    let unkeyedScreen = compositor.compose(
      workspace: panes.workspace(),
      frames: frames,
      status: StatusLine(),
      showCursor: false
    )
    #expect(unkeyedScreen.rowKeys.allSatisfy { $0 == nil })
  }
}
