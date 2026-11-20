import Foundation

// Kitty clipboard (OSC 5522) and drag-and-drop (OSC 72) for panes. The
// service owns each pane's emulator, so it forwards clipboard reads and
// writes to the controlling app (`ClientCapabilities.clipboardRequests`)
// and takes drags as input (`ServiceFeatures.dropTargets`).

public struct MuxClipboardContent: Codable, Sendable, Hashable {
  public var mime: String
  public var data: Data

  public init(mime: String, data: Data) {
    self.mime = mime
    self.data = data
  }
}

/// A program's clipboard read, answered with `clipboardReadResult`.
public struct MuxClipboardRead: Codable, Sendable, Equatable {
  public var pane: PaneID
  public var token: UInt64
  /// Data types requested, in request order (at most four).
  public var mimes: [String]
  /// Whether the program also asked for the available types.
  public var list: Bool
  /// The program's name, for permission prompts.
  public var name: String
  /// A remembered password grants the read; the app may still refuse.
  public var granted: Bool
  public var canRemember: Bool

  public init(
    pane: PaneID,
    token: UInt64,
    mimes: [String],
    list: Bool,
    name: String,
    granted: Bool,
    canRemember: Bool
  ) {
    self.pane = pane
    self.token = token
    self.mimes = mimes
    self.list = list
    self.name = name
    self.granted = granted
    self.canRemember = canRemember
  }
}

public enum MuxClipboardReadResult: Codable, Sendable, Equatable {
  case success(
    available: [String],
    contents: [MuxClipboardContent],
    remember: Bool
  )
  case denied, unsupported, busy, ioError
}

/// A program's committed clipboard write, answered with
/// `clipboardWriteResult`.
public struct MuxClipboardWrite: Codable, Sendable, Equatable {
  public var pane: PaneID
  public var token: UInt64
  public var contents: [MuxClipboardContent]
  public var name: String
  public var granted: Bool
  public var canRemember: Bool

  public init(
    pane: PaneID,
    token: UInt64,
    contents: [MuxClipboardContent],
    name: String,
    granted: Bool,
    canRemember: Bool
  ) {
    self.pane = pane
    self.token = token
    self.contents = contents
    self.name = name
    self.granted = granted
    self.canRemember = canRemember
  }
}

public enum MuxClipboardWriteResult: Codable, Sendable, Equatable {
  case success(remember: Bool)
  case denied, unsupported, busy, invalidData, ioError
}

/// A native drag over a pane, in viewport cells and content pixels.
public struct MuxDragPosition: Codable, Sendable, Hashable {
  public var column: Int
  public var row: Int
  public var pixelX: Int
  public var pixelY: Int
  public var allowsCopy: Bool
  public var allowsMove: Bool

  public init(
    column: Int,
    row: Int,
    pixelX: Int,
    pixelY: Int,
    allowsCopy: Bool,
    allowsMove: Bool
  ) {
    self.column = column
    self.row = row
    self.pixelX = pixelX
    self.pixelY = pixelY
    self.allowsCopy = allowsCopy
    self.allowsMove = allowsMove
  }
}

public enum MuxDrag: Codable, Sendable, Hashable {
  /// The types the drag offers, in the order data requests index them.
  case move(MuxDragPosition, types: [String])
  /// The dropped data, held for the program's requests (at most 16).
  case drop(MuxDragPosition, items: [MuxClipboardContent])
  case leave
}

extension MuxInput {
  /// Largest pane write a clipboard paste event or drag report needs:
  /// three packets with a one-time password, or a move or drop report,
  /// plus the types they list.
  public static func clipboardBytes(types: [String]) -> Int {
    let listed = types.reduce(types.count) { $0 + $1.utf8.count }
    return (listed + 2) / 3 * 4 + 512
  }
}

public enum MuxDropOperation: String, Codable, Sendable, Equatable {
  case none, copy, move
}

/// A pane's drop registration (OSC 72), carried in its frames.
public struct FrameDropTarget: Codable, Sendable, Equatable {
  /// Bounds on what a frame carries; the service drops the excess.
  public static let maxTypes = 64
  public static let maxTypeBytes = 256

  /// The types the program accepts drops of.
  public var types: [String]
  /// The program's answer for the current drag; nil until it answers.
  public var accepted: MuxDropOperation?

  public init(types: [String], accepted: MuxDropOperation?) {
    self.types = types
    self.accepted = accepted
  }
}
