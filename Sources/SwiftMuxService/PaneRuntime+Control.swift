import Darwin
import Dispatch
import Foundation
import MuxAttention
import SwiftMuxExport
import SwiftMuxProtocol
import SwifttyEngine
import SwifttyJS
import Synchronization

/// Terminal control, clipboard replies, links and shell integration.
extension PaneRuntime {
  // MARK: Terminal control and shell integration

  /// Clears the screen, keeping the cursor's line, as the direct view's
  /// Clear Screen does.
  func clearScreen() {
    queue.async { [self] in
      guard !finished else { return }
      state.clearScreenKeepingCursorLine()
      advanceViewport()
      noteChange()
    }
  }

  /// The program's report of a native drag; nil without a registration.
  /// Dropped items that could not be served in one reply are left out.
  func dragReport(_ drag: MuxDrag) -> [UInt8]? {
    func position(_ p: MuxDragPosition) -> KittyDragAndDrop.MoveEvent {
      var operations: KittyDragAndDrop.Operations = []
      if p.allowsCopy { operations.insert(.copy) }
      if p.allowsMove { operations.insert(.move) }
      return KittyDragAndDrop.MoveEvent(
        column: UInt32(clamping: max(0, p.column)),
        row: UInt32(clamping: max(0, p.row)),
        pixelX: Int32(clamping: p.pixelX),
        pixelY: Int32(clamping: p.pixelY),
        operations: operations
      )
    }
    switch drag {
    case let .move(p, types): return state.dragMove(position(p), mimes: types)
    case let .drop(p, items):
      return state.dragDrop(
        position(p),
        items:
          items.filter { Self.replyFits([$0], reserve: writer.replyReserve) }
          .map { KittyDragAndDrop.Item(mime: $0.mime, data: Array($0.data)) }
      )
    case .leave: return state.dragLeave()
    }
  }

  /// Answers a deferred kitty clipboard read. Contents whose reply would
  /// not fit the pane's reply reserve answer EIO rather than being lost.
  func completeClipboardRead(_ token: UInt64, _ result: MuxClipboardReadResult)
  {
    queue.async { [self] in
      guard !finished else { return }
      let answer: KittyClipboard.ReadResult =
        switch result {
        case let .success(available, contents, remember):
          Self.replyFits(contents, reserve: writer.replyReserve)
            ? .success(
              available: available,
              contents: contents.map {
                KittyClipboard.Content(mime: $0.mime, data: Array($0.data))
              },
              remember: remember
            ) : .ioError
        case .denied: .denied
        case .unsupported: .unsupported
        case .busy: .busy
        case .ioError: .ioError
        }
      state.completeKittyClipboardRead(token, with: answer)
      _ = enqueueReplies()
    }
  }

  func completeClipboardWrite(
    _ token: UInt64,
    _ result: MuxClipboardWriteResult
  ) {
    queue.async { [self] in
      guard !finished else { return }
      let answer: KittyClipboard.WriteResult =
        switch result {
        case let .success(remember): .success(remember: remember)
        case .denied: .denied
        case .unsupported: .unsupported
        case .busy: .busy
        case .invalidData: .invalidData
        case .ioError: .ioError
        }
      state.completeKittyClipboardWrite(token, with: answer)
      _ = enqueueReplies()
    }
  }

  /// Whether `contents`, base64-encoded in DATA packets, fit one reply.
  static func replyFits(_ contents: [MuxClipboardContent], reserve: Int) -> Bool
  {
    let raw = contents.reduce(0) { $0 + $1.data.count + $1.mime.utf8.count }
    let packets = contents.reduce(0) { $0 + $1.data.count / 4096 + 1 }
    return (raw + 2) / 3 * 4 + packets * 96 + 1024 <= reserve
  }

  /// Full reset (RIS) of the emulator; the process keeps running.
  func resetTerminal() {
    queue.async { [self] in
      guard !finished else { return }
      parser = Parser()
      state.reset()
      publishStatus()
      advanceViewport()
      noteChange()
    }
  }

  private func point(_ address: HistoryAddress, column: Int) -> TerminalPoint? {
    guard address.generation == state.addressingGeneration,
      address.alternateScreen == state.isAlternateScreen,
      state.contains(absoluteRow: address.row)
    else { return nil }
    return TerminalPoint(row: address.row, column: column)
  }

  private func address(_ row: Int) -> HistoryAddress {
    HistoryAddress(
      generation: state.addressingGeneration,
      alternateScreen: state.isAlternateScreen,
      row: row
    )
  }

  func link(
    at address: HistoryAddress,
    column: Int,
    detectURLs: Bool,
    completion: @escaping @Sendable (MuxLink?) -> Void,
  ) {
    queue.async { [self] in
      guard let p = point(address, column: column),
        let link = state.link(at: p, detectURLs: detectURLs)
      else { return completion(nil) }
      completion(
        MuxLink(
          url: link.url,
          start: self.address(link.range.start.row),
          startColumn: link.range.start.column,
          end: self.address(link.range.end.row),
          endColumn: link.range.end.column
        )
      )
    }
  }

  /// The output around `address`, or the most recent command with
  /// output; scrolled into view as the direct view's selection is.
  func commandOutput(
    at address: HistoryAddress?,
    completion: @escaping @Sendable (CommandOutput?) -> Void,
  ) {
    queue.async { [self] in
      let click = address.flatMap { point($0, column: 0) }
      let prompts = state.promptRows()
      var output = state.commandOutputRange(
        at: click ?? TerminalPoint(row: prompts.last ?? 0, column: 0)
      )
      if output == nil, click == nil {
        // Fresh prompts and commands without output are skipped.
        for boundary in prompts.reversed() {
          output = state.commandOutputRange(
            at: TerminalPoint(row: boundary - 1, column: 0)
          )
          if output != nil { break }
        }
      }
      guard let range = output else { return completion(nil) }
      let before = state.viewportOffset
      state.scrollToShow(row: range.start.row)
      if state.viewportOffset != before {
        advanceViewport()
        noteChange()
      }
      completion(
        CommandOutput(
          start: self.address(range.start.row),
          end: self.address(range.end.row),
          text: state.text(from: range.start, to: range.end)
        )
      )
    }
  }

  /// Frontend theme: default colours and scheme, as a theme change does.
  func setTheme(_ theme: MuxTheme) {
    queue.async { [self] in
      var colors = InlineArray<256, UInt32>(repeating: 0)
      for i in 0 ..< 256 { colors[i] = theme.palette.colors[i] }
      let p = theme.palette
      state.setDefaultPalette(
        Palette(
          colors: colors,
          foreground: p.foreground,
          background: p.background,
          cursor: p.cursor,
          cursorText: p.cursorText,
          selectionForeground: p.selectionForeground,
          selectionBackground: p.selectionBackground,
        ),
      )
      state.setColorScheme(theme.dark ? .dark : .light)
      publish()
    }
  }

  func advanceViewport() {
    currentViewport.wrappingAdd(1, ordering: .releasing)
  }

  /// Returns the viewport to live output and clears search (detach).
  func resetViewport() {
    queue.async { [self] in
      state.endSearch()
      state.scrollViewportToBottom()
      advanceViewport()
      noteChange()
    }
  }
}
