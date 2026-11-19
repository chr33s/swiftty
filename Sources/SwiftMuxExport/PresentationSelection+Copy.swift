import SwiftMuxProtocol
import SwifttyEngine

extension CopySelectionRequest {
  /// The request for an address-based selection: its host addresses, unit
  /// and the versions of the screen rows it covers as first seen
  /// (spec.multiplexer.md §4; spec.roaming.md §7.5). A rectangular
  /// selection copies the rows it spans.
  public init(_ selection: PresentationSelection, pane: PaneID = PaneID()) {
    func address(_ row: Int) -> HistoryAddress {
      HistoryAddress(
        generation: selection.generation,
        alternateScreen: selection.alternateScreen,
        row: row
      )
    }
    func point(_ p: (row: Int, column: Int)) -> SelectionPoint {
      SelectionPoint(address: address(p.row), column: max(p.column, 0))
    }
    let unit: Unit =
      switch selection.unit {
      case .character: .character
      case .word: .word
      case .line: .line
      }
    self.init(
      pane: pane,
      start: point(selection.anchor),
      end: point(selection.head),
      unit: unit,
      screenRowVersions: selection.screenRowVersions
        .prefix(CopySelectionRequest.maxScreenRows)
        .map { RowIdentity(address: address($0.row), version: $0.version) }
    )
  }
}
