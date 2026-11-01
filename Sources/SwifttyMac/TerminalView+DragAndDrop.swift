import AppKit
import SwifttyCore
import UniformTypeIdentifiers

/// Drops for programs registered through the kitty drag-and-drop
/// protocol (OSC 72). Without a registration the view takes no drops.
extension TerminalView {
  func dragAndDropRegistrationChanged() {
    let mimes = session.withState { $0.dragAndDrop?.registeredMimes }
    guard let mimes else {
      unregisterDraggedTypes()
      return
    }
    var types: [NSPasteboard.PasteboardType] = [.string, .fileURL, .URL]
    for mime in mimes {
      if let type = UTType(mimeType: mime) {
        types.append(NSPasteboard.PasteboardType(type.identifier))
      }
    }
    registerForDraggedTypes(types)
  }

  public override func draggingEntered(
    _ sender: any NSDraggingInfo
  ) -> NSDragOperation { dragMoved(sender) }

  public override func draggingUpdated(
    _ sender: any NSDraggingInfo
  ) -> NSDragOperation { dragMoved(sender) }

  public override func draggingExited(_ sender: (any NSDraggingInfo)?) {
    if let bytes = session.mutate({ $0.dragLeave() }) {
      submitInput(.bytes(bytes))
    }
  }

  public override func performDragOperation(
    _ sender: any NSDraggingInfo
  ) -> Bool {
    let pasteboard = sender.draggingPasteboard
    let items = Self.dragMimeTypes(on: pasteboard)
      .compactMap { Self.dragContent($0, on: pasteboard) }
    let event = moveEvent(sender)
    guard let bytes = session.mutate({ $0.dragDrop(event, items: items) })
    else { return false }
    return submitInput(.bytes(bytes))
  }

  private func dragMoved(_ sender: any NSDraggingInfo) -> NSDragOperation {
    let event = moveEvent(sender)
    let mimes = Self.dragMimeTypes(on: sender.draggingPasteboard)
    let result = session.mutate { state in
      state.dragMove(event, mimes: mimes)
        .map { ($0, state.dragAndDrop?.clientAccepted) }
    }
    guard let (bytes, accepted) = result else { return [] }
    guard submitInput(.bytes(bytes)) else { return [] }
    // Until the program answers, offer a copy.
    switch accepted {
    case .none?: return []
    case .move?: return .move
    case .copy?, nil: return .copy
    }
  }

  private func moveEvent(
    _ sender: any NSDraggingInfo
  ) -> KittyDragAndDrop.MoveEvent {
    let p = convert(sender.draggingLocation, from: nil)
    let cell = unclampedCell(at: p)
    let scale = window?.backingScaleFactor ?? 2
    let mask = sender.draggingSourceOperationMask
    var operations: KittyDragAndDrop.Operations = []
    if mask.contains(.copy) { operations.insert(.copy) }
    if mask.contains(.move) { operations.insert(.move) }
    return KittyDragAndDrop.MoveEvent(
      column: UInt32(max(0, cell.column)),
      row: UInt32(max(0, cell.row)),
      pixelX: Int32(
        clamping: Int((p.x * scale - renderer.options.paddingX).rounded())
      ),
      pixelY: Int32(
        clamping: Int(
          ((bounds.height - p.y) * scale - renderer.options.paddingY).rounded()
        )
      ),
      operations: operations
    )
  }

  /// Dragged files are offered as `text/uri-list` first.
  package static func dragMimeTypes(on pasteboard: NSPasteboard) -> [String] {
    var mimes = mimeTypes(on: pasteboard)
    if pasteboard.canReadObject(forClasses: [NSURL.self], options: nil) {
      mimes.removeAll { $0 == "text/uri-list" }
      mimes.insert("text/uri-list", at: 0)
    }
    return mimes
  }

  package static func dragContent(
    _ mime: String,
    on pasteboard: NSPasteboard
  ) -> KittyDragAndDrop.Item? {
    if mime == "text/uri-list" {
      let urls =
        pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        ?? []
      guard !urls.isEmpty else { return nil }
      let list = urls.map { $0.absoluteString + "\r\n" }.joined()
      return KittyDragAndDrop.Item(mime: mime, data: Array(list.utf8))
    }
    return content(mime, on: pasteboard)
      .map { KittyDragAndDrop.Item(mime: $0.mime, data: $0.data) }
  }
}
