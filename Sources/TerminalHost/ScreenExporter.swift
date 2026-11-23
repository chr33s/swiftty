#if os(macOS)
import ScreenProtocol
import SessionCore
import SwiftMuxExport
import SwiftMuxProtocol
import SwifttyEngine

/// RST/1 screens (spec §6) from the frames a SwiftMux worker sends a
/// roaming session (`frame(from:stamp:)`), and the history window moves
/// over their metadata.
public enum ScreenExporter {
  /// Revision and identity metadata stamped on an exported snapshot.
  public struct Stamp: Sendable, Hashable {
    public var sessionID: SessionID
    public var attachmentEpoch: UInt64
    public var screenRevision: UInt64
    public var resizeRevision: UInt64
    public var lastFullyAppliedInputSequence: UInt64

    public init(
      sessionID: SessionID,
      attachmentEpoch: UInt64 = 0,
      screenRevision: UInt64 = 0,
      resizeRevision: UInt64 = 0,
      lastFullyAppliedInputSequence: UInt64 = 0
    ) {
      self.sessionID = sessionID
      self.attachmentEpoch = attachmentEpoch
      self.screenRevision = screenRevision
      self.resizeRevision = resizeRevision
      self.lastFullyAppliedInputSequence = lastFullyAppliedInputSequence
    }
  }

  /// The history window top after moving `lines` (positive reveals older
  /// lines) from `top` (nil: live output), given a frame's history window.
  /// A `top` from another addressing generation starts from live output.
  /// Nil again at the live screen; the alternate screen has no history
  /// window.
  package static func historyTop(
    _ history: HistoryWindow,
    alternateScreen: Bool,
    from top: Int?,
    generation: UInt64,
    moving lines: Int
  ) -> (top: Int?, generation: UInt64) {
    guard !alternateScreen else { return (nil, history.generation) }
    let first = history.firstRow
    let live = first + history.scrollbackRows
    let from = generation == history.generation ? top : nil
    let start = min(max(from ?? live, first), live)
    let (moved, overflow) = start.subtractingReportingOverflow(lines)
    let next =
      overflow ? (lines > 0 ? first : live) : min(max(moved, first), live)
    return (next >= live ? nil : next, history.generation)
  }

  static func text(_ scalars: [UInt32]) -> String {
    RSTPresentation.text(scalars)
  }

  static func boundedTitle(_ title: String) -> String {
    RSTPresentation.boundedTitle(title)
  }
}

#endif
