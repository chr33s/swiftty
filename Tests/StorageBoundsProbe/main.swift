import SwifttyCore

let operation = Int(CommandLine.arguments.last ?? "") ?? -1
var grid = Grid(columns: 4, rows: 2)
switch operation {
case 0: _ = grid.cells(row: -1)
case 1: _ = grid.cells(row: 2)
case 2: _ = grid[4, 0]
case 3: grid[-1, 0] = .blank
case 4: _ = grid.historyCells(at: 0)
case 5: grid.scrollUp(top: 0, bottom: 2, count: 1, fill: .blank)
case 6: grid.insertCells(row: 0, at: 0, count: -1, fill: .blank)
case 7: grid.fill(row: 0, from: 2, to: 5, with: .blank)
case 8: _ = Grid(columns: Int.max, rows: 1)
case 9: _ = Grid(columns: 1, rows: Int(Int32.max), historyLimitBytes: 16)
case 10:
  let snapshot = TerminalSession(columns: 4, rows: 1).snapshot()
  var attributes = CellAttributes.default
  attributes.flags.insert(.grapheme)
  _ = snapshot.graphemeScalars(
    Cell(glyph: UInt32.max, attributes: attributes, width: 1)
  )
case 11: _ = checkedAllocationCount(Int.max, 16)
default: fatalError("unknown storage probe")
}
