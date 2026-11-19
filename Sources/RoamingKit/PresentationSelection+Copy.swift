import SwiftMuxProtocol
import SwifttyEngine

extension CopySelectionRequest {
  /// The request for a presentation selection: its host addresses and the
  /// versions of the screen rows it covered when seen (spec.roaming.md
  /// §7.5). Rectangular selections copy the rows they span.
  public init(_ selection: PresentationSelection) {
    func point(_ p: (row: Int, column: Int)) -> SelectionPoint {
      SelectionPoint(
        address: HistoryAddress(
          generation: selection.generation,
          alternateScreen: selection.alternateScreen,
          row: p.row
        ),
        column: max(p.column, 0)
      )
    }
    let screen = selection.seen.filter { $0.value.screen }
      .sorted { $0.key < $1.key }.prefix(CopySelectionRequest.maxScreenRows)
      .map {
        RowIdentity(
          address: HistoryAddress(
            generation: selection.generation,
            alternateScreen: selection.alternateScreen,
            row: $0.key
          ),
          version: $0.value.version
        )
      }
    self.init(
      pane: PaneID(),
      start: point(selection.anchor),
      end: point(selection.head),
      unit: .character,
      screenRowVersions: Array(screen)
    )
  }
}
