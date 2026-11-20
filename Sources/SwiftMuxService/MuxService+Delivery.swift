import Dispatch
import Foundation
import SwiftMuxProtocol

extension MuxService {
  // MARK: Geometry and subscriptions

  func setSubscriptions(_ list: [PaneID], client: UUID) -> MuxError? {
    guard let wsID = clientLeases[client], let current = leases[wsID],
      let ws = workspaces.first(where: { $0.id == wsID })
    else { return MuxError(.notAttached) }
    let members = Set(ws.allPanes)
    guard clients[client]?.local == nil || list.isEmpty else {
      return MuxError(.invalidRequest, "in-process clients export screens")
    }
    guard list.count <= limits.maxPanes, Set(list).count == list.count,
      list.allSatisfy(members.contains)
    else { return MuxError(.invalidRequest, "subscription list") }
    var frames: [PaneID: FrameSlot] = [:]
    var activity: [PaneID] = []
    for pane in list {
      // Keep in-flight state; a new subscription forces a full frame.
      frames[pane] = current.frames[pane] ?? FrameSlot()
      frames[pane]?.hiddenActivity = false
    }
    for (pane, slot) in current.frames where frames[pane] == nil {
      releaseBudget(slot)
      if slot.hiddenActivity, let tab = ws.tabIndex(containing: pane),
        ws.tabs[tab].id != ws.activeTab,
        !current.reportedActivity.contains(pane)
      {
        activity.append(pane)
      }
    }
    leases[wsID]?.subscriptions = list
    leases[wsID]?.frames = frames
    leases[wsID]?.readiness.arm(list)
    publishControllerReady(wsID)
    leases[wsID]?.reportedActivity.subtract(list)
    for pane in activity {
      leases[wsID]?.reportedActivity.insert(pane)
      send(.event(.activity(pane)), to: current.client)
    }
    pump()
    return nil
  }

  // MARK: Frames

  func pump() {
    let now = DispatchTime.now().uptimeNanoseconds
    var wake: UInt64?
    // Rotate which workspace goes first so one cannot starve the others
    // of the shared frame budget: start after the last lease served.
    let n = leaseOrder.count
    let start = n == 0 ? 0 : workspaceCursor % n
    var served: Int?
    for k in 0 ..< n {
      let i = (start + k) % n
      let (due, started) = pump(leaseOrder[i], now: now)
      if started, served == nil { served = i }
      if let due { wake = min(wake ?? due, due) }
    }
    workspaceCursor = n == 0 ? 0 : ((served ?? start) + 1) % n
    if let viewerWake = pumpViewers(now: now) {
      wake = min(wake ?? viewerWake, viewerWake)
    }
    if let wake, !pumpScheduled {
      pumpScheduled = true
      queue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: wake)) {
        [weak self] in
        self?
          .assumeIsolated {
            $0.pumpScheduled = false
            $0.pump()
          }
      }
    }
  }

  /// Starts captures for one lease; returns when a throttled pane is due
  /// and whether any capture started.
  func pump(_ wsID: WorkspaceID, now: UInt64, ) -> (due: UInt64?, started: Bool)
  {
    guard let current = leases[wsID], !current.subscriptions.isEmpty else {
      return (nil, false)
    }
    let interval = limits.frameIntervalNanoseconds
    var wake: UInt64?
    var started = false
    let order = current.subscriptions
    let n = order.count
    let first = current.paneCursor % n
    leases[wsID]?.paneCursor = (first + 1) % n
    for k in 0 ..< n {
      let pane = order[(first + k) % n]
      guard let slot = current.frames[pane], slot.dirty, slot.capture == nil,
        slot.inflight == nil, let record = panes[pane]
      else { continue }
      let viewportMoved =
        record.runtime.currentViewport.load(ordering: .acquiring)
        != slot.lastViewport
      if now &- slot.lastSent < interval, slot.lastSent != 0, !viewportMoved {
        let due = slot.lastSent + interval
        wake = min(wake ?? due, due)
        continue
      }
      guard inflightFrameBytes + reservedFrameBytes < limits.pendingFrameBudget
      else { break }
      nextCapture &+= 1
      let token = nextCapture
      let estimate = captureEstimate(record)
      reservedFrameBytes += estimate
      leases[wsID]?.frames[pane]?.dirty = false
      leases[wsID]?.frames[pane]?.capture = token
      leases[wsID]?.frames[pane]?.reserved = estimate
      started = true
      let attachment = current.attachment
      let layoutRevision =
        workspaces.first { $0.id == wsID }?.layoutRevision ?? 0
      record.runtime.captureFrame(
        server: instance,
        attachment: attachment,
        layoutRevision: layoutRevision,
        encoding: clients[current.client]?.frameEncoding
          ?? PaneRuntime.FrameEncoding(),
        baseline: slot.baseline,
      ) { [weak self] result in
        self?
          .onQueue {
            $0.frameCaptured(pane, workspace: wsID, token: token, result)
          }
      }
    }
    return (wake, started)
  }

  func frameCaptured(
    _ pane: PaneID,
    workspace wsID: WorkspaceID,
    token: UInt64,
    _ result: Result<PaneRuntime.CapturedFrame, MuxError>,
  ) {
    // The token is unique to this slot's capture: a completion for a
    // pane since unsubscribed (or resubscribed), or for another lease,
    // never reaches the client or the frame budget.
    guard let current = leases[wsID], let slot = current.frames[pane],
      slot.capture == token
    else { return }
    leases[wsID]?.frames[pane]?.capture = nil
    leases[wsID]?.frames[pane]?.reserved = 0
    reservedFrameBytes -= slot.reserved
    switch result {
    case let .success(captured):
      guard let client = clients[current.client],
        case let .xpc(channel) = client.transport
      else { return }
      if let stale = slot.inflight { inflightFrameBytes -= stale.bytes }
      channel.send(captured.data)
      leases[wsID]?.frames[pane]?.sent(captured.sent)
      inflightFrameBytes += captured.data.count
    case .failure where token <= slot.supersededThrough:
      // Captured at a size since replaced: recapture, report nothing.
      leases[wsID]?.frames[pane]?.dirty = true
    case let .failure(error):
      // Preserve the session; report instead of omitting cells. Ready
      // does not wait for a pane that reported no frame.
      send(.event(.frameUnavailable(pane, error)), to: current.client)
      if leases[wsID]?.readiness.failed.insert(pane).inserted == true {
        publishControllerReady(wsID)
      }
    }
    pump()
  }

  /// Frame bytes a capture of `record` may produce, held from its start.
  func captureEstimate(_ record: PaneRecord) -> Int {
    let cells = max(1, record.columns) * max(1, record.rows)
    let (bytes, overflow) = cells.multipliedReportingOverflow(
      by: Self.frameBytesPerCell,
    )
    return overflow ? limits.maxFrameBytes : min(bytes, limits.maxFrameBytes)
  }

  /// Rough encoded size of one cell; frames carry per-cell attributes.
  static let frameBytesPerCell = 32

  /// Returns a dropped slot's budget: its unacknowledged frame and the
  /// estimate held by a capture still in progress (whose completion,
  /// carrying a token no slot holds, is then dropped).
  func releaseBudget(_ slot: FrameSlot) {
    if let inflight = slot.inflight { inflightFrameBytes -= inflight.bytes }
    if let queued = slot.queued { inflightFrameBytes -= queued.frame.bytes }
    reservedFrameBytes -= slot.reserved
  }

  func frameAck(
    _ pane: PaneID,
    _ revision: UInt64,
    attachment: AttachmentID,
    from id: UUID,
  ) {
    if let wsID = clientLeases[id], leases[wsID]?.attachment == attachment,
      let slot = leases[wsID]?.frames[pane], let inflight = slot.inflight,
      inflight.revision == revision
    {
      leases[wsID]?.frames[pane]?.inflight = nil
      leases[wsID]?.frames[pane]?.baseline = inflight.baseline
      inflightFrameBytes -= inflight.bytes
      let window =
        panes[pane]?.runtime.currentViewport.load(ordering: .acquiring) ?? 0
      if leases[wsID]?.readiness.install(pane, inflight, window: window) == true
      {
        publishControllerReady(wsID)
      }
      pump()
      return
    }
    acknowledgeViewer(pane, revision, attachment: attachment, from: id)
  }

  /// A delta could not be applied. Releases the refused frame's credit
  /// (`revision`, as an acknowledgement would) without adopting it as a
  /// base, and forgets the base, so the next frame of the pane is
  /// complete. A viewer's queued frame was encoded against the same
  /// unusable base and is dropped. Applies to the lease or the viewer
  /// `attachment` names; anything else is ignored.
  func requestFullFrame(
    _ pane: PaneID,
    _ revision: UInt64,
    attachment: AttachmentID,
    from id: UUID,
  ) {
    if let wsID = clientLeases[id], leases[wsID]?.attachment == attachment,
      let slot = leases[wsID]?.frames[pane]
    {
      if let inflight = slot.inflight, inflight.revision == revision {
        leases[wsID]?.frames[pane]?.inflight = nil
        inflightFrameBytes -= inflight.bytes
      }
      leases[wsID]?.frames[pane]?.baseline = nil
      leases[wsID]?.frames[pane]?.dirty = true
    } else if let wsID = clientViewers[id] {
      let released = withViewer(id, in: wsID) { viewer -> Int in
        guard viewer.attachment == attachment, let slot = viewer.frames[pane]
        else { return 0 }
        var bytes = 0
        if let inflight = slot.inflight, inflight.revision == revision {
          viewer.frames[pane]?.inflight = nil
          bytes += inflight.bytes
          if let queued = slot.queued {
            viewer.frames[pane]?.queued = nil
            bytes += queued.frame.bytes
          }
        }
        viewer.frames[pane]?.baseline = nil
        viewer.frames[pane]?.dirty = true
        return bytes
      }
      inflightFrameBytes -= released ?? 0
    }
    pump()
  }

  // MARK: Input

  func input(_ record: InputRecord, from id: UUID) {
    let ack = { (error: MuxError?) in
      self.send(.inputAck(sequence: record.sequence, error: error), to: id)
    }
    if clientViewers[id] != nil {
      return ack(MuxError(.unauthorized, "observers cannot write"))
    }
    guard let wsID = clientLeases[id], let current = leases[wsID] else {
      return ack(MuxError(.notAttached))
    }
    guard record.attachment == current.attachment else {
      return ack(MuxError(.staleAttachment, "attachment is no longer current"))
    }
    // Ledger (spec.inbox.md §1–2): each sequence is answered once and in
    // order. A duplicate was already answered and is never written
    // again; a gap is refused without consuming anything.
    guard record.sequence >= current.nextInput else { return ack(nil) }
    guard record.sequence == current.nextInput else {
      return ack(MuxError(.inputGap, "expected input \(current.nextInput)"))
    }
    leases[wsID]?.nextInput += 1
    guard let pane = panes[record.pane], pane.workspace == wsID,
      !pane.detachedFromLayout
    else { return ack(MuxError(.notFound, "pane")) }
    guard pane.exitStatus == nil else { return ack(MuxError(.paneExited)) }
    let runtime = pane.runtime
    switch record.payload {
    case let .input(input):
      if case let .text(s) = input, s.utf8.count > limits.maxPasteChunkBytes {
        return ack(MuxError(.resourceLimit, "text input record too large"))
      }
      if case let .paste(s) = input, s.utf8.count > limits.maxPasteChunkBytes {
        return ack(MuxError(.resourceLimit, "text input record too large"))
      }
      if !Self.clipboardInputIsBounded(input) {
        return ack(MuxError(.invalidRequest, "clipboard input out of bounds"))
      }
      let estimate = Self.estimate(input)
      guard runtime.reserve(estimate) else {
        return ack(MuxError(.resourceLimit, "pane input buffer is full"))
      }
      runtime.write(input, estimate: estimate)
      ack(nil)
    case let .pasteBegin(pasteID):
      guard current.pastes[pasteID] == nil,
        !current.pastes.values.contains(where: { $0.pane == record.pane })
      else { return ack(MuxError(.invalidRequest, "paste already active")) }
      let estimate = PaneWriter.pasteMarkerBytes
      guard runtime.reserve(estimate) else {
        return ack(MuxError(.resourceLimit, "pane input buffer is full"))
      }
      leases[wsID]?.pastes[pasteID] = ActivePaste(pane: record.pane)
      runtime.pasteBegin(id: pasteID, estimate: estimate)
      ack(nil)
    case let .pasteChunk(pasteID, text):
      guard let paste = current.pastes[pasteID], paste.pane == record.pane
      else { return ack(MuxError(.invalidRequest, "unknown paste")) }
      let n = text.utf8.count
      guard n <= limits.maxPasteChunkBytes,
        paste.bytes + n <= limits.maxPasteBytes
      else {
        cancelPaste(pasteID, in: wsID, notify: id)
        return ack(
          MuxError(
            .resourceLimit,
            "paste exceeds \(limits.maxPasteBytes) bytes",
          ),
        )
      }
      let estimate = n + text.utf8.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
      guard runtime.reserve(estimate) else {
        return ack(MuxError(.resourceLimit, "pane input buffer is full"))
      }
      leases[wsID]?.pastes[pasteID]?.bytes += n
      runtime.pasteChunk(id: pasteID, text: text, estimate: estimate)
      ack(nil)
    case let .pasteEnd(pasteID):
      // The paste stays open on a mismatch, so detach still cancels it.
      guard let paste = current.pastes[pasteID], paste.pane == record.pane
      else { return ack(MuxError(.invalidRequest, "unknown paste")) }
      leases[wsID]?.pastes.removeValue(forKey: pasteID)
      runtime.pasteEnd(id: pasteID)
      ack(nil)
      send(.event(.paste(id: pasteID, state: .completed)), to: id)
    case let .pasteCancel(pasteID):
      guard let paste = current.pastes[pasteID], paste.pane == record.pane
      else { return ack(MuxError(.invalidRequest, "unknown paste")) }
      cancelPaste(pasteID, in: wsID, notify: id)
      ack(nil)
    }
  }

  /// True when this text can never fit the peer's chunk or pane budget.
  /// A full pane buffer is a different, transient `resourceLimit`.
  package static func permanentlyExceedsText(
    utf8Count: Int,
    limits: MuxLimits
  ) -> Bool {
    utf8Count > limits.maxPasteChunkBytes
      || utf8Count > limits.inputBytesPerPane
  }

  /// True when this paste can never fit. `newlineCount` is the number of
  /// `0x0A` bytes, which the service expands while estimating the write.
  package static func permanentlyExceedsPaste(
    utf8Count: Int,
    newlineCount: Int,
    limits: MuxLimits
  ) -> Bool {
    let estimate = utf8Count + PaneWriter.pasteMarkerBytes + newlineCount
    return utf8Count > limits.maxPasteChunkBytes
      || estimate > limits.inputBytesPerPane
  }

  /// True when a key encoding cannot fit an empty pane budget.
  package static func permanentlyExceedsKey(limits: MuxLimits) -> Bool {
    32 > limits.inputBytesPerPane
  }

  /// Paste events and drags list at most 16 types (and items) of the
  /// sizes frames carry.
  static func clipboardInputIsBounded(_ input: MuxInput) -> Bool {
    func valid(_ types: [String]) -> Bool {
      types.count <= 16
        && types.allSatisfy {
          !$0.isEmpty && $0.utf8.count <= FrameDropTarget.maxTypeBytes
        }
    }
    return switch input {
    case let .clipboardPaste(types), let .drag(.move(_, types)): valid(types)
    case let .drag(.drop(_, items)): valid(items.map(\.mime))
    default: true
    }
  }

  static func estimate(_ input: MuxInput) -> Int {
    switch input {
    case let .text(s): s.utf8.count
    // Brackets plus a carriage return for every newline.
    case let .paste(s):
      s.utf8.count + PaneWriter.pasteMarkerBytes
        + s.utf8.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
    case .key: 32
    case .focus: 3
    // An SGR report with large coordinates.
    case .mouse: 32
    case .moveCursor: MuxInput.moveCursorBytes
    case let .clipboardPaste(types): MuxInput.clipboardBytes(types: types)
    case let .drag(.move(_, types)): MuxInput.clipboardBytes(types: types)
    case let .drag(.drop(_, items)):
      MuxInput.clipboardBytes(types: items.map(\.mime))
    case .drag(.leave): 64
    }
  }

  func cancelPaste(
    _ pasteID: UInt64,
    in wsID: WorkspaceID,
    notify client: UUID?,
    discardDeferredInput: Bool = false,
  ) {
    guard let paste = leases[wsID]?.pastes.removeValue(forKey: pasteID),
      let runtime = panes[paste.pane]?.runtime
    else { return }
    runtime.pasteCancel(id: pasteID, discardDeferredInput: discardDeferredInput)
    { [weak self] state in
      guard let client else { return }
      self?
        .onQueue {
          $0.send(.event(.paste(id: pasteID, state: state)), to: client)
        }
    }
  }

  func cancelPastes(_ wsID: WorkspaceID, discardDeferredInput: Bool = false, ) {
    for id in leases[wsID]?.pastes.keys.map(\.self) ?? [] {
      cancelPaste(
        id,
        in: wsID,
        notify: nil,
        discardDeferredInput: discardDeferredInput,
      )
    }
    if discardDeferredInput { discardQueuedInput(wsID) }
  }

  /// Drops unwritten user input on every pane of a workspace whose writer
  /// just lost the lease. Runs on each pane queue after paste cleanup.
  func discardQueuedInput(_ wsID: WorkspaceID) {
    guard let ws = workspaces.first(where: { $0.id == wsID }) else { return }
    for pane in ws.allPanes { panes[pane]?.runtime.discardUnwrittenInput() }
  }
}
