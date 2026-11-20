/// Package accessors for exporting the authoritative screen as an owned
/// presentation (spec.roaming.md §A.4.2). Read-only; callers copy
/// what they need while the state is borrowed.
extension TerminalState {
  /// Appends `cell`'s scalars (none for an empty cell); returns the count.
  @discardableResult
  package func appendScalars(of cell: Cell, to out: inout [UInt32]) -> Int {
    if cell.isGrapheme {
      let count = graphemes.scalarCount(cell.glyph)
      let scalars = graphemes.scalars(cell.glyph)
      for i in scalars.indices { out.append(scalars[i]) }
      return count
    }
    guard cell.glyph != 0 else { return 0 }
    out.append(cell.glyph)
    return 1
  }

  /// Number of scrollback rows currently retained (bounded-memory checks).
  package var retainedHistoryRows: Int { grid.historyCount }
}
