import SwiftMuxProtocol
import SwifttyEngine
import Synchronization

/// Assigns row edit versions at export time (spec.multiplexer.md §4, "Row
/// identity and versions"), one tracker per attachment.
///
/// Versions come from comparing each exported row's content with the
/// content last exported at the same address, so the engine's write paths
/// stay untouched. Screen rows can change in place and keep their content;
/// history rows are immutable within a generation and keep only their
/// version. Versions come from one process-wide sequence and are never
/// reused, even by a new tracker for the same rows.
package struct RowVersionTracker: Sendable {
  struct ScreenRow: Sendable {
    var version: UInt64
    /// The exported width; a later comparison reads the same columns.
    var columns: Int
    var content: [UInt32]
  }

  private var generation: UInt64?
  private var screen: [HistoryAddress: ScreenRow] = [:]
  private var history: [HistoryAddress: UInt64] = [:]
  /// One sequence for every tracker in the process: a replaced tracker
  /// (a reconnect, a new attachment) never reissues an identity that a
  /// client may still hold for other content.
  private static let sequence = Atomic<UInt64>(1)
  private var scratch: [UInt32] = []

  package init() {}

  /// Rows held with their content, and with a version only (tests).
  package var trackedRows: (content: Int, versions: Int) {
    (screen.count, history.count)
  }

  /// Versions for every row of `owned`, the screen a frame was exported
  /// from (after any viewer crop).
  package mutating func stamp(_ owned: OwnedScreen) -> [UInt64] {
    if generation != owned.addressingGeneration {
      generation = owned.addressingGeneration
      screen.removeAll(keepingCapacity: true)
      history.removeAll(keepingCapacity: true)
    }
    let screenTop = owned.viewportTopRow + owned.viewportOffset
    var versions: [UInt64] = []
    versions.reserveCapacity(owned.rows)
    for y in 0 ..< owned.rows {
      let address = HistoryAddress(
        generation: owned.addressingGeneration,
        alternateScreen: owned.isAlternateScreen,
        row: owned.viewportTopRow + y
      )
      let isScreen = owned.isAlternateScreen || address.row >= screenTop
      if !isScreen, let known = history[address] {
        versions.append(known)
        continue
      }
      scratch.removeAll(keepingCapacity: true)
      let start = y * owned.columns
      RowContent.append(
        owned.cells[start ..< start + owned.columns],
        wrapped: owned.wrapped[y],
        underlineColors: owned.underlineColors,
        graphemes: { owned.graphemes[Int($0.glyph)] },
        to: &scratch
      )
      let version: UInt64
      if let known = screen[address], known.content == scratch {
        version = known.version
      } else {
        version = Self.sequence.wrappingAdd(1, ordering: .relaxed).oldValue
      }
      if isScreen {
        screen[address] = ScreenRow(
          version: version,
          columns: owned.columns,
          content: scratch
        )
      } else {
        screen.removeValue(forKey: address)
        history[address] = version
      }
      versions.append(version)
    }
    prune(firstRow: owned.firstAbsoluteRow, screenTop: screenTop, owned)
    return versions
  }

  /// Bounds what the tracker keeps, amortized over the rows that scroll.
  /// Screen rows that scrolled into history unseen keep their content (a
  /// copy may still list them) until they are two screens above the
  /// screen; older ones are dropped, and a later export gives them a new
  /// version. Versions of rows that left history are forgotten.
  private mutating func prune(
    firstRow: Int,
    screenTop: Int,
    _ owned: OwnedScreen
  ) {
    let rows = max(owned.rows, 1)
    if screen.count > 4 * rows {
      let oldest = screenTop - 2 * rows
      screen = screen.filter { $0.key.row >= oldest && $0.key.row >= firstRow }
    }
    let available = owned.scrollbackCount + rows
    if history.count > 2 * available {
      history = history.filter { $0.key.row >= firstRow }
    }
  }

  /// Whether the client's `identity` still describes the row at its
  /// address: a screen row is compared with its current content, a
  /// history row by the version recorded when it left the screen.
  package func matches(
    _ identity: RowIdentity,
    in state: borrowing TerminalState
  ) -> Bool {
    guard identity.address.generation == generation else { return false }
    if let row = screen[identity.address] {
      guard row.version == identity.version else { return false }
      var current: [UInt32] = []
      let found: Bool? = state.withLine(absoluteRow: identity.address.row) {
        cells,
        wrapped in
        var padded: [Cell] = []
        padded.reserveCapacity(row.columns)
        for x in 0 ..< row.columns {
          padded.append(x < cells.count ? cells[x] : .blank)
        }
        RowContent.append(
          padded[...],
          wrapped: wrapped,
          underlineColors: state.underlineColors,
          graphemes: { cell in
            var scalars: [UInt32] = []
            state.appendScalars(of: cell, to: &scalars)
            return scalars
          },
          to: &current
        )
        return true
      }
      return found == true && current == row.content
    }
    return history[identity.address] == identity.version
  }
}

/// Canonical words of a row's visible content: what a frame exports for
/// it, independent of frame-local table order and of hyperlink ids.
enum RowContent {
  static func append<C: Collection<Cell>>(
    _ cells: C,
    wrapped: Bool,
    underlineColors: [TerminalColor],
    graphemes: (Cell) -> [UInt32],
    to out: inout [UInt32]
  ) {
    out.reserveCapacity(out.count + 1 + cells.count * 5)
    out.append(wrapped ? 1 : 0)
    for cell in cells {
      let a = cell.attributes
      put(a.foreground.rawValue, &out)
      put(a.background.rawValue, &out)
      put(UInt32(a.flags.rawValue) | UInt32(cell.width) << 16, &out)
      let u = Int(a.underlineColor)
      put(
        u > 0 && u <= underlineColors.count
          ? underlineColors[u - 1].rawValue : 0,
        &out
      )
      if cell.isGrapheme {
        let scalars = graphemes(cell)
        put(UInt32(scalars.count) | 0x8000_0000, &out)
        for s in scalars { put(s, &out) }
      } else {
        put(cell.glyph, &out)
      }
    }
  }

  @inline(__always)
  private static func put(_ v: UInt32, _ out: inout [UInt32]) { out.append(v) }
}
