import Foundation
import SwiftMuxProtocol

extension GuardianServer {
  func perform(
    _ command: GuardianCommand,
    workspace: Workspace
  ) throws -> GuardianResult {
    switch command {
    case .spawn: preconditionFailure("spawn must use asynchronous admission")
    case let .input(id, writer, bytes):
      try requireWriter(writer, workspace)
      let pane = try livePane(id, workspace)
      try reserveInput(bytes.count, pane)
      pane.runtime.appendInput(Array(bytes))
      pane.runtime.flush()
      return .admitted(bytes: bytes.count)
    case let .reply(id, bytes):
      let pane = try livePane(id, workspace)
      guard bytes.count <= GuardianWire.inputChunkLimit,
        pane.runtime.appendReply(Array(bytes))
      else { throw MuxError(.resourceLimit, "reply reserve exhausted") }
      pane.runtime.flush()
    case let .beginPaste(id, writer, paste, bracketed):
      try requireWriter(writer, workspace)
      let pane = try livePane(id, workspace)
      guard !pane.runtime.hasOpenPaste else {
        throw MuxError(.invalidRequest, "paste already open")
      }
      try reserveInput(bracketed ? PaneWriter.pasteMarkerBytes : 0, pane)
      pane.runtime.beginPaste(id: paste, bracketed: bracketed)
      pane.runtime.flush()
      return .admitted(bytes: bracketed ? PaneWriter.pasteMarkerBytes : 0)
    case let .appendPaste(id, writer, paste, text):
      try requireWriter(writer, workspace)
      let pane = try livePane(id, workspace)
      guard pane.runtime.pasteID == paste else {
        throw MuxError(.invalidRequest, "unknown paste")
      }
      let bytes = text.utf8.count
      guard bytes <= GuardianWire.inputChunkLimit else {
        throw MuxError(.resourceLimit, "paste chunk too large")
      }
      // Sanitization can expand a newline; reserve conservatively before
      // handing the text to the one authoritative writer.
      let estimate = bytes + text.utf8.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
      try reserveInput(
        estimate,
        pane,
        chunkLimit: GuardianWire.inputChunkLimit * 2
      )
      let before = pane.runtime.pendingInputBytes
      pane.runtime.appendPaste(id: paste, text: text)
      let admitted = pane.runtime.pendingInputBytes - before
      pane.runtime.flush()
      return .admitted(bytes: admitted)
    case let .endPaste(id, writer, paste):
      try requireWriter(writer, workspace)
      // Cleanup of a pane that has exited has nothing left to do.
      guard let pane = try cleanupPane(id, workspace) else { break }
      guard pane.runtime.pasteID == paste else {
        throw MuxError(.invalidRequest, "unknown paste")
      }
      pane.runtime.endPaste(id: paste)
      pane.runtime.flush()
    case let .cancelInput(id):
      guard let pane = try cleanupPane(id, workspace) else { break }
      let count = pane.runtime.discardUnwrittenInput()
      if count > 0 {
        send(.inputReleased(pane: id, bytes: count), to: workspace)
      }
      pane.runtime.flush()
    case let .resize(id, columns, rows, pixelWidth, pixelHeight):
      try validateSize(columns, rows)
      let pane = try livePane(id, workspace)
      let cut = pane.nextOutput - 1
      let error = pane.runtime.resize(
        columns: columns,
        rows: rows,
        pixelWidth: pixelWidth ?? 0,
        pixelHeight: pixelHeight ?? 0
      )
      guard error == 0 else {
        throw MuxError(.invalidRequest, "PTY resize failed (errno \(error))")
      }
      return .resized(outputThrough: cut)
    case let .end(id):
      guard let pane = workspace.panes[id.pane], pane.process == id.process
      else { throw MuxError(.notFound, "unknown pane") }
      pane.runtime.terminate()
    case let .cancelPaste(id, writer, paste, discardDeferredInput):
      try requireWriter(writer, workspace)
      guard let pane = try cleanupPane(id, workspace) else {
        return .pasteCancelled(wrote: false)
      }
      guard pane.runtime.pasteID == paste else {
        throw MuxError(.invalidRequest, "unknown paste")
      }
      let (discarded, wrote) = pane.runtime.cancelPaste(
        id: paste,
        discardDeferredInput: discardDeferredInput
      )
      if discarded > 0 {
        send(.inputReleased(pane: id, bytes: discarded), to: workspace)
      }
      pane.runtime.flush()
      return .pasteCancelled(wrote: wrote)
    case let .forget(id):
      guard let pane = workspace.panes[id.pane], pane.process == id.process,
        pane.runtime.finished, pane.outstanding.isEmpty
      else {
        throw MuxError(.invalidRequest, "pane has not finished and drained")
      }
      workspace.panes.removeValue(forKey: id.pane)
    }
    return .ok
  }

  private func requireWriter(_ token: UUID, _ workspace: Workspace) throws {
    guard workspace.writer == token else {
      throw MuxError(.staleAttachment, "writer capability revoked")
    }
  }

  /// A cleanup command's pane: nil when it has already exited (nothing to
  /// cancel), an error only for a pane this workspace never had.
  private func cleanupPane(
    _ id: GuardianPaneHandle,
    _ workspace: Workspace
  ) throws -> Pane? {
    guard let pane = workspace.panes[id.pane], pane.process == id.process else {
      throw MuxError(.notFound, "unknown pane")
    }
    return pane.runtime.isOpen && !pane.runtime.finished ? pane : nil
  }

  private func livePane(
    _ id: GuardianPaneHandle,
    _ workspace: Workspace
  ) throws -> Pane {
    guard let pane = workspace.panes[id.pane], pane.process == id.process,
      pane.runtime.isOpen, !pane.runtime.finished
    else { throw MuxError(.notFound, "pane is not running") }
    return pane
  }

  func validateSize(_ columns: Int, _ rows: Int) throws {
    guard columns >= limits.minPaneColumns, rows >= limits.minPaneRows,
      columns <= limits.maxColumns, rows <= limits.maxRows
    else { throw MuxError(.invalidRequest, "invalid PTY size") }
  }

  private func reserveInput(
    _ count: Int,
    _ pane: Pane,
    chunkLimit: Int = GuardianWire.inputChunkLimit
  ) throws {
    guard count >= 0, count <= chunkLimit,
      count <= limits.inputBytesPerPane - pane.runtime.pendingInputBytes
    else { throw MuxError(.resourceLimit, "input capacity exhausted") }
  }

  func installConsumer(_ pane: Pane, id: PaneID, workspace: Workspace) {
    let runtime = pane.runtime
    let handle = GuardianPaneHandle(pane: id, process: pane.process)
    runtime.canConsume = { [weak self, weak pane, weak workspace] in
      guard let self, let pane, let workspace, !workspace.unavailable,
        workspace.connection != nil, !workspace.migrationFrozen
      else { return false }
      return pane.outstanding.count < GuardianWire.outputRecordLimit
        && pane.nextOutput < UInt64.max
        && pane.outputBytes <= (1 << 20) - self.limits.readTurnBytes
        && workspace.outputBytes <= (16 << 20) - self.limits.readTurnBytes
        && self.outputBytes <= (64 << 20) - self.limits.readTurnBytes
    }
    runtime.consume = { [weak self, weak pane, weak workspace] bytes in
      guard let self, let pane, let workspace, !workspace.unavailable else {
        return 0
      }
      let sequence = pane.nextOutput
      pane.nextOutput += 1
      pane.outstanding[sequence] = bytes.count
      pane.outputBytes += bytes.count
      workspace.outputBytes += bytes.count
      self.outputBytes += bytes.count
      self.send(
        .output(pane: handle, sequence: sequence, bytes: Data(bytes)),
        to: workspace
      )
      return bytes.count
    }
    runtime.onInputReleased = { [weak self, weak workspace] bytes in
      guard bytes > 0, let workspace else { return }
      self?.send(.inputReleased(pane: handle, bytes: bytes), to: workspace)
    }
    runtime.onFinished = { [weak self, weak workspace] status, forced in
      guard let self, let workspace else { return }
      self.send(
        .exited(pane: handle, status: status, forced: forced),
        to: workspace
      )
      self.checkStopped()
    }
    runtime.onReplyReleased = { [weak self, weak workspace] bytes in
      guard bytes > 0, let workspace else { return }
      self?.send(.replyReleased(pane: handle, bytes: bytes), to: workspace)
    }
    runtime.onExiting = { [weak self, weak workspace] in
      guard let workspace else { return }
      self?.send(.exiting(pane: handle), to: workspace)
    }
  }
}
