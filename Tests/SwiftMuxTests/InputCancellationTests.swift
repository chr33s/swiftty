import Dispatch
import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
import SwiftMuxXPC
import Synchronization
import Testing

struct InputCancellationTests {
  @Test(arguments: [false, true])
  func largeAwaitedTextUsesBoundedRecords(_ escaped: Bool) async throws {
    let peer = InputAckPeer()
    defer { peer.close() }
    peer.acknowledgeFutureInputs()
    let connection = try await attached(to: peer)
    let text =
      escaped
      ? String(repeating: "x\u{1}", count: 40_000)
      : String(repeating: "👩‍💻界", count: 30_000)
    do {
      try await connection.send(.text(text), to: PaneID())
      let records = peer.records.withLock { $0 }
      let chunks = records.compactMap { record -> String? in
        if case let .input(.text(chunk)) = record.payload { return chunk }
        return nil
      }
      #expect(chunks.count > 1)
      #expect(
        chunks.allSatisfy {
          $0.utf8.count <= MuxLimits.standard.maxPasteChunkBytes
        }
      )
      #expect(chunks.joined() == text)
      #expect(records.map(\.sequence) == Array(1 ... UInt64(records.count)))
      #expect(try await connection.execute(.listWorkspaces) == .ok)
      await connection.close()
    } catch {
      await connection.close()
      throw error
    }
  }

  @Test(arguments: [false, true])
  func directReattachmentRetiresOldInput(_ paste: Bool) async throws {
    var limits = MuxLimits.standard
    limits.maxPasteChunkBytes = 2
    let peer = InputAckPeer(limits: limits)
    defer { peer.close() }
    let connection = try await attached(to: peer)
    let pane = PaneID()
    let finished = Mutex(false)
    let caller = Task {
      defer { finished.withLock { $0 = true } }
      if paste {
        _ = try await connection.paste("ABCD", to: pane)
      } else {
        try await connection.send(.text("ABCD"), to: pane)
      }
    }
    do {
      try #require(
        await waitUntil {
          peer.records.withLock { $0.count == (paste ? 2 : 1) }
        }
      )
      let original = peer.records.withLock { $0 }
      _ = try await connection.execute(
        .attach(AttachRequest(.id(peer.workspace.id)))
      )
      #expect(await waitUntil { finished.withLock { $0 } })
      peer.acknowledge()
      await #expect { try await caller.value } throws: {
        ($0 as? MuxError)?.code == .notAttached
      }
      #expect(peer.records.withLock { $0.count } == original.count)
      // The late acknowledgments carry only sequence numbers, which restart
      // with the new attachment. Drain them with an ordered round trip so a
      // stale ack cannot complete the next send before the peer records it.
      #expect(try await connection.execute(.listWorkspaces) == .ok)
      try await connection.send(.text("Z"), to: pane)
      #expect(
        peer.records.withLock { $0.last?.attachment }
          != original.first?.attachment
      )
      #expect(try await connection.execute(.listWorkspaces) == .ok)
      await connection.close()
    } catch {
      await connection.close()
      _ = try? await caller.value
      throw error
    }
  }

  @Test(arguments: [false, true])
  func negotiatedChunksRespectTheEncodedRecordLimit(
    _ smallRecord: Bool
  ) async throws {
    var limits = MuxLimits.standard
    if smallRecord {
      limits.maxControlRecordBytes = 4096
    } else {
      limits.maxPasteChunkBytes = 1 << 20
    }
    let peer = InputAckPeer(limits: limits)
    defer { peer.close() }
    peer.acknowledgeFutureInputs()
    let connection = try await attached(to: peer)
    let text =
      smallRecord
      ? String(repeating: "\u{1}", count: 4000)
      : String(repeating: "x", count: 300_000)
    do {
      try await connection.send(.text(text), to: PaneID())
      #expect(try await connection.paste(text, to: PaneID()) == .completed)
      await connection.post(.text(text), to: PaneID())
      #expect(try await connection.execute(.listWorkspaces) == .ok)
      let records = peer.records.withLock { $0 }
      let typed = records.compactMap { record -> String? in
        if case let .input(.text(chunk)) = record.payload { return chunk }
        return nil
      }
      let pasted = records.compactMap { record -> String? in
        if case let .pasteChunk(_, chunk) = record.payload { return chunk }
        return nil
      }
      #expect(typed.count > 1)
      #expect(pasted.count > 1)
      #expect(typed.joined() == text + text)
      #expect(pasted.joined() == text)
      for record in records {
        #expect(
          try SMXCodec
            .encode(
              ClientMessage.input(record),
              limit: limits.maxControlRecordBytes
            )
            .count <= limits.maxControlRecordBytes
        )
      }
      #expect(try await connection.execute(.listWorkspaces) == .ok)
      await connection.close()
    } catch {
      await connection.close()
      throw error
    }
  }

  @Test
  func acknowledgmentsForOtherRecordsDoNotExtendTheOldestDeadline() async throws
  {
    let peer = InputAckPeer()
    defer { peer.close() }
    let connection = try await attached(to: peer)
    await connection.setInputAcknowledgmentTimeout(.milliseconds(100))
    let finished = Mutex(false)
    let first = Task {
      defer { finished.withLock { $0 = true } }
      try await connection.send(.text("held"), to: PaneID())
    }
    do {
      try #require(await waitUntil { peer.records.withLock { $0.count == 1 } })
      peer.acknowledgeFutureInputs()
      for _ in 0 ..< 20 {
        if finished.withLock({ $0 }) { break }
        await connection.post(.text("progress"), to: PaneID())
        try await Task.sleep(for: .milliseconds(20))
      }
      #expect(peer.records.withLock { $0.count } < 11)
      await #expect { try await first.value } throws: {
        ($0 as? MuxError)
          == MuxError(.connectionLost, "input acknowledgment timed out")
      }
      await connection.close()
    } catch {
      await connection.close()
      _ = try? await first.value
      throw error
    }
  }

  @Test(arguments: [UInt64(1), 2])
  func lateAcknowledgmentCannotBypassAnExpiredInputDeadline(
    _ acknowledged: UInt64
  ) async throws {
    let peer = InputAckPeer()
    defer { peer.close() }
    let connection = try await attached(to: peer)
    await connection.setInputAcknowledgmentTimeout(.milliseconds(350))
    let firstFinished = Mutex(false)
    let secondFinished = Mutex(false)
    let first = Task {
      defer { firstFinished.withLock { $0 = true } }
      try await connection.send(.text("expired"), to: PaneID())
    }
    var second: Task<Void, any Error>?
    do {
      try #require(await waitUntil { peer.records.withLock { $0.count == 1 } })
      await connection.delayInputAcknowledgmentDeliveryForTesting()
      await connection.setInputAcknowledgmentTimeout(.seconds(2))
      let later = Task {
        defer { secondFinished.withLock { $0 = true } }
        try await connection.send(.text("later"), to: PaneID())
      }
      second = later
      try #require(await waitUntil { peer.records.withLock { $0.count == 2 } })
      try await Task.sleep(for: .milliseconds(500))
      peer.sendAcknowledgment(acknowledged)
      let retired = await waitUntil {
        firstFinished.withLock { $0 } && secondFinished.withLock { $0 }
          && peer.closed.withLock { $0 }
      }
      #expect(
        retired,
        "ACK processing must enforce the oldest absolute deadline and fail the channel"
      )
      // Collect delayed baseline waiters without leaving timers or tasks alive.
      if !retired { await connection.close() }
      await #expect { try await first.value } throws: {
        ($0 as? MuxError)
          == MuxError(.connectionLost, "input acknowledgment timed out")
      }
      await #expect { try await later.value } throws: {
        ($0 as? MuxError)
          == MuxError(.connectionLost, "input acknowledgment timed out")
      }
      #expect(await connection.attachment == nil)
      await connection.close()
    } catch {
      await connection.close()
      _ = try? await first.value
      _ = try? await second?.value
      throw error
    }
  }

  @Test
  func endAcknowledgmentsCannotRefundMissingBeginAcknowledgments() async throws
  {
    let peer = InputAckPeer(holdBegin: true)
    defer { peer.close() }
    peer.acknowledgeFutureInputs()
    let connection = try await attached(to: peer)
    await connection.setInputAcknowledgmentTimeout(.seconds(2))
    let pane = PaneID()
    do {
      for _ in 0 ..< 4 {
        #expect(
          try await connection.paste(
            String(repeating: "x", count: 1 << 20),
            to: pane
          ) == .completed
        )
      }
      let refused = Mutex<MuxError?>(nil)
      connection.enqueuePaste("overflow", to: pane) { result in
        if case let .failure(error) = result { refused.withLock { $0 = error } }
      }
      #expect(
        await waitUntil { refused.withLock { $0?.code == .resourceLimit } }
      )
      let begins = peer.records.withLock {
        $0.filter { if case .pasteBegin = $0.payload { true } else { false } }
      }
      #expect(begins.count == 4)
      for begin in begins { peer.sendAcknowledgment(begin.sequence) }
      _ = try await connection.execute(.listWorkspaces)
      #expect(try await connection.paste("fresh", to: pane) == .completed)
      await connection.close()
    } catch {
      await connection.close()
      throw error
    }
  }

  @Test
  func retiredDeadlineCannotFailAReattachedWaiterWithTheSameSequence()
    async throws
  {
    let peer = InputAckPeer()
    defer { peer.close() }
    let connection = try await attached(to: peer)
    await connection.setInputAcknowledgmentTimeout(.milliseconds(100))
    let first = Task { try await connection.send(.text("old"), to: PaneID()) }
    var fresh: Task<Void, any Error>?
    do {
      try #require(await waitUntil { peer.records.withLock { $0.count == 1 } })
      peer.detach()
      await #expect { try await first.value } throws: {
        ($0 as? MuxError)?.code == .notAttached
      }
      _ = try await connection.execute(
        .attach(AttachRequest(.id(peer.workspace.id)))
      )
      await connection.setInputAcknowledgmentTimeout(.seconds(2))
      let finished = Mutex(false)
      let next = Task {
        defer { finished.withLock { $0 = true } }
        try await connection.send(.text("fresh"), to: PaneID())
      }
      fresh = next
      try #require(await waitUntil { peer.records.withLock { $0.count == 2 } })
      #expect(peer.records.withLock { $0.map(\.sequence) } == [1, 1])
      try await Task.sleep(for: .milliseconds(150))
      #expect(!finished.withLock { $0 })
      #expect(try await connection.execute(.listWorkspaces) == .ok)
      peer.sendAcknowledgment(1)
      try await next.value
      await connection.close()
    } catch {
      await connection.close()
      _ = try? await first.value
      _ = try? await fresh?.value
      throw error
    }
  }

  enum SilentInput: CaseIterable, Sendable { case send, paste, post, canceled }

  @Test(arguments: SilentInput.allCases)
  func missingAcknowledgmentFailsTheChannelAndEveryWaiter(
    _ mode: SilentInput
  ) async throws {
    let peer = InputAckPeer()
    defer { peer.close() }
    let connection = try await attached(to: peer)
    await connection.setInputAcknowledgmentTimeout(.milliseconds(100))
    let finished = Mutex(false)
    let consumer = Task {
      defer { finished.withLock { $0 = true } }
      return try await connection.nextEvent()
    }
    let pane = PaneID()
    let caller = Task {
      switch mode {
      case .send, .canceled: try await connection.send(.text("held"), to: pane)
      case .paste: _ = try await connection.paste("held", to: pane)
      case .post: await connection.post(.text("held"), to: pane)
      }
    }
    do {
      try #require(await waitUntil { peer.records.withLock { !$0.isEmpty } })
      if mode == .canceled {
        caller.cancel()
        await #expect(throws: CancellationError.self) { try await caller.value }
      }
      #expect(await waitUntil { finished.withLock { $0 } })
      #expect(await waitUntil { peer.closed.withLock { $0 } })
      // Closing only after observation also releases the old implementation.
      await connection.close()
      let timedOut = MuxError(.connectionLost, "input acknowledgment timed out")
      await #expect { try await consumer.value } throws: {
        ($0 as? MuxError) == timedOut
      }
      if mode == .send || mode == .paste {
        await #expect { try await caller.value } throws: {
          ($0 as? MuxError) == timedOut
        }
      } else {
        _ = try? await caller.value
      }
      await #expect { try await connection.execute(.listWorkspaces) } throws: {
        ($0 as? MuxError) == timedOut
      }
    } catch {
      await connection.close()
      _ = try? await caller.value
      _ = try? await consumer.value
      throw error
    }
  }

  @Test
  func exhaustedAcknowledgmentCreditStillCancelsTheOpenedEnvelope() async throws
  {
    var limits = MuxLimits.standard
    limits.maxPasteChunkBytes = 1
    let peer = InputAckPeer(limits: limits)
    defer { peer.close() }
    let connection = try await attached(to: peer)
    let pane = PaneID()
    let result = Mutex<Result<PasteState, MuxError>?>(nil)
    do {
      await connection.setPasteRetry(attempts: 0, delay: .milliseconds(1))
      connection.enqueue(.text(String(repeating: "a", count: 2048)), to: pane)
      try #require(
        await waitUntil { peer.records.withLock { $0.count == 2048 } }
      )
      connection.enqueuePaste("blocked", to: pane) { state in
        result.withLock { $0 = state }
      }
      try #require(await waitUntil { result.withLock { $0 != nil } })
      #expect(result.withLock { $0 } == .success(.aborted))
      #expect(
        await waitUntil {
          peer.records.withLock {
            $0.contains { $0.payload == .pasteCancel(id: 1) }
          }
        }
      )
      peer.acknowledge()
      _ = try await connection.execute(.listWorkspaces)
      #expect(try await connection.paste("fresh", to: pane) == .completed)
      await connection.close()
    } catch {
      await connection.close()
      throw error
    }
  }

  @Test
  func canceledWaitersKeepAdmissionUntilTheirWireAcknowledgmentsArrive()
    async throws
  {
    let peer = InputAckPeer()
    defer { peer.close() }
    let connection = try await attached(to: peer)
    let pane = PaneID()
    var pending: [Task<Void, any Error>] = []
    do {
      for _ in 0 ..< 256 {
        pending.append(
          Task { try await connection.send(.text("held"), to: pane) }
        )
      }
      try #require(
        await waitUntil { peer.records.withLock { $0.count == 256 } }
      )
      for task in pending { task.cancel() }
      for task in pending {
        await #expect(throws: CancellationError.self) { try await task.value }
      }
      let finished = Mutex(false)
      let extra = Task {
        defer { finished.withLock { $0 = true } }
        try await connection.send(.text("overflow"), to: pane)
      }
      pending.append(extra)
      #expect(await waitUntil { finished.withLock { $0 } })
      #expect(peer.records.withLock { $0.count } == 256)
      peer.acknowledge()
      await #expect { try await extra.value } throws: {
        ($0 as? MuxError)?.code == .resourceLimit
      }
      _ = try await connection.execute(.listWorkspaces)
      try await connection.send(.text("fresh"), to: pane)
      await connection.close()
    } catch {
      await connection.close()
      for task in pending { _ = try? await task.value }
      throw error
    }
  }

  @Test
  func tinyNegotiatedChunksCannotGrowTheAcknowledgmentTableWithoutBound()
    async throws
  {
    var limits = MuxLimits.standard
    limits.maxPasteChunkBytes = 1
    let peer = InputAckPeer(limits: limits)
    defer { peer.close() }
    let connection = try await attached(to: peer)
    let pane = PaneID()
    connection.enqueue(.text(String(repeating: "a", count: 2048)), to: pane)
    let finished = Mutex(false)
    let extra = Task {
      try #require(
        await waitUntil { peer.records.withLock { $0.count == 2048 } }
      )
      defer { finished.withLock { $0 = true } }
      try await connection.send(.text("overflow"), to: pane)
    }
    do {
      #expect(await waitUntil { finished.withLock { $0 } })
      peer.acknowledge()
      await #expect { try await extra.value } throws: {
        ($0 as? MuxError)?.code == .resourceLimit
      }
      _ = try await connection.execute(.listWorkspaces)
      try await connection.send(.text("Z"), to: pane)
      #expect(peer.records.withLock { $0.last?.sequence } == 2049)
      await connection.close()
    } catch {
      await connection.close()
      _ = try? await extra.value
      throw error
    }
  }

  @Test(arguments: [false, true])
  func leaseLossRefundsAFullAdmissionBudget(bytes: Bool) async throws {
    let peer = InputAckPeer()
    defer { peer.close() }
    let connection = try await attached(to: peer)
    let pane = PaneID()
    let retired = Mutex(0)
    do {
      if bytes {
        for _ in 0 ..< 4 {
          connection.enqueuePaste(
            String(repeating: "x", count: 1 << 20),
            to: pane
          ) { result in
            if case let .failure(error) = result, error.code == .notAttached {
              retired.withLock { $0 += 1 }
            }
          }
        }
      } else {
        for _ in 0 ..< 256 {
          connection.enqueue(.text("held"), to: pane) { error in
            if error.code == .notAttached { retired.withLock { $0 += 1 } }
          }
        }
      }
      try #require(await waitUntil { peer.records.withLock { !$0.isEmpty } })
      peer.detach()
      try #require(
        await waitUntil { retired.withLock { $0 == (bytes ? 4 : 256) } }
      )
      _ = try await connection.execute(
        .attach(AttachRequest(.id(peer.workspace.id)))
      )
      // Do not send withheld ACKs from the old attachment into the new one.
      peer.acknowledgeFutureInputs()
      #expect(try await connection.paste("fresh", to: pane) == .completed)
      await connection.close()
    } catch {
      await connection.close()
      throw error
    }
  }

  @Test(arguments: [false, true])
  func admissionRefusesOverflowBeforeDispatch(bytes: Bool) async throws {
    let peer = InputAckPeer()
    defer { peer.close() }
    let connection = try await attached(to: peer)
    let pane = PaneID()
    let entered = Mutex(false)
    let release = DispatchSemaphore(value: 0)
    connection.queue.async {
      entered.withLock { $0 = true }
      _ = release.wait(timeout: .now() + .seconds(3))
    }
    defer {
      release.signal();
      peer.acknowledge()
    }
    let overflow = Mutex<Result<PasteState, MuxError>?>(nil)
    let completed = Mutex(0)
    var pasteOverflow: Task<PasteState, any Error>?
    do {
      try #require(await waitUntil { entered.withLock { $0 } })
      if bytes {
        for _ in 0 ..< 4 {
          connection.enqueuePaste(
            String(repeating: "x", count: 1 << 20),
            to: pane
          ) { result in
            if case .success(.completed) = result {
              completed.withLock { $0 += 1 }
            }
          }
        }
        connection.enqueuePaste("overflow", to: pane) { result in
          overflow.withLock { $0 = result }
        }
      } else {
        for index in 0 ..< 256 {
          connection.enqueue(.text("accepted-\(index)"), to: pane)
        }
        connection.enqueue(.text("overflow"), to: pane) { error in
          overflow.withLock { $0 = .failure(error) }
        }
      }
      // Admission must refuse before the blocked actor can drain captures.
      #expect(await waitUntil { overflow.withLock { $0 != nil } })
      #expect(peer.records.withLock { $0.isEmpty })
      release.signal()
      try #require(await waitUntil { peer.records.withLock { !$0.isEmpty } })
      if !bytes {
        await withCheckedContinuation { continuation in
          connection.queue.async { continuation.resume() }
        }
      }
      let pasteFinished = Mutex(false)
      let extraPaste = Task {
        defer { pasteFinished.withLock { $0 = true } }
        return try await connection.paste("async overflow", to: pane)
      }
      pasteOverflow = extraPaste
      #expect(await waitUntil { pasteFinished.withLock { $0 } })
      peer.acknowledge()
      await #expect { try await extraPaste.value } throws: {
        ($0 as? MuxError)?.code == .resourceLimit
      }
      if bytes { #expect(await waitUntil { completed.withLock { $0 == 4 } }) }
      _ = try await connection.execute(.listWorkspaces)
      let rejected = overflow.withLock { $0 }
      guard case let .failure(error)? = rejected else {
        Issue.record("Overflow was not refused")
        await connection.close()
        return
      }
      #expect(error.code == .resourceLimit)
      let records = peer.records.withLock { $0 }
      #expect(!records.contains { $0.payload == .input(.text("overflow")) })
      #expect(
        !records.contains { $0.payload == .pasteChunk(id: 5, text: "overflow") }
      )
      if !bytes {
        #expect(
          records.map(\.payload)
            == (0 ..< 256).map { .input(.text("accepted-\($0)")) }
        )
      }
      try await connection.send(.text("recovered"), to: pane)
      await connection.close()
    } catch {
      await connection.close()
      _ = try? await pasteOverflow?.value
      throw error
    }
  }

  @Test(arguments: [false, true])
  func inputAcknowledgmentAdmissionIsBounded(post: Bool) async throws {
    let peer = InputAckPeer()
    defer { peer.close() }
    let connection = try await attached(to: peer)
    let pane = PaneID()
    var pending: [Task<Void, any Error>] = []
    let finished = Mutex(false)
    do {
      for index in 0 ..< 256 {
        if post {
          await connection.post(.text("accepted-\(index)"), to: pane)
        } else {
          pending.append(
            Task {
              try await connection.send(.text("accepted-\(index)"), to: pane)
            }
          )
        }
      }
      try #require(
        await waitUntil { peer.records.withLock { $0.count >= 256 } }
      )
      let overflow = Task {
        defer { finished.withLock { $0 = true } }
        if post {
          await connection.post(.text("overflow"), to: pane)
        } else {
          try await connection.send(.text("overflow"), to: pane)
        }
      }
      pending.append(overflow)
      #expect(await waitUntil { finished.withLock { $0 } })
      _ = try await connection.execute(.listWorkspaces)
      #expect(
        !peer.records.withLock {
          $0.contains { $0.payload == .input(.text("overflow")) }
        }
      )
      peer.acknowledge()
      for task in pending.dropLast() { try await task.value }
      if post {
        try await overflow.value
      } else {
        await #expect { try await overflow.value } throws: {
          ($0 as? MuxError)?.code == .resourceLimit
        }
      }
      _ = try await connection.execute(.listWorkspaces)
      try await connection.send(.text("recovered"), to: pane)
      await connection.close()
    } catch {
      await connection.close()
      for task in pending { _ = try? await task.value }
      throw error
    }
  }

  @Test
  func queuedEncodingFailureRetiresEveryRemainingCallback() async throws {
    let peer = InputAckPeer()
    defer { peer.close() }
    let connection = try await attached(to: peer)
    let pane = PaneID()
    let results = Mutex<[Int: Result<PasteState, MuxError>]>([:])
    let refusals = Mutex<[Int: MuxError]>([:])
    connection.enqueuePaste("first", to: pane) { result in
      results.withLock { $0[0] = result }
    }
    do {
      try #require(await waitUntil { peer.records.withLock { $0.count == 2 } })
      connection.enqueuePaste("second", to: pane) { result in
        results.withLock { $0[1] = result }
      }
      // Wait behind the second paste, then fail encoding during its drain.
      connection.enqueue(
        .paste(String(repeating: "x", count: 300_000)),
        to: pane
      ) { error in refusals.withLock { $0[0] = error } }
      for index in 2 ... 3 {
        connection.enqueuePaste("later-\(index)", to: pane) { result in
          results.withLock { $0[index] = result }
        }
      }
      connection.enqueue(.text("last"), to: pane) { error in
        refusals.withLock { $0[1] = error }
      }
      await withCheckedContinuation { continuation in
        connection.queue.async { continuation.resume() }
      }
      try #require(await connection.pendingPasteCountForTesting == 4)
      peer.acknowledge()
      #expect(await waitUntil { results.withLock { $0.count == 4 } })
      #expect(await waitUntil { refusals.withLock { $0.count == 2 } })
      let completed = results.withLock { $0 }
      #expect(completed[0] == .success(.completed))
      #expect(completed[1] == .success(.completed))
      let failure = try #require(refusals.withLock { $0[0] })
      #expect(failure.code == .resourceLimit)
      #expect(completed[2] == .failure(failure))
      #expect(completed[3] == .failure(failure))
      #expect(refusals.withLock { $0[1] } == failure)
      #expect(await connection.pendingPasteCountForTesting == 0)
      await connection.close()
    } catch {
      await connection.close()
      throw error
    }
  }

  @Test
  func canceledInputWaitFinishesBeforeAcknowledgmentAndConnectionRecovers()
    async throws
  {
    let peer = InputAckPeer()
    defer { peer.close() }
    let connection = try await attached(to: peer)
    let finished = Mutex(false)
    let pane = PaneID()
    let pending = Task {
      defer { finished.withLock { $0 = true } }
      try await connection.send(.text("first"), to: pane)
    }
    defer {
      pending.cancel();
      peer.acknowledge()
    }
    do {
      try #require(await waitUntil { peer.records.withLock { $0.count == 1 } })
      pending.cancel()
      #expect(await waitUntil { finished.withLock { $0 } })
      // Release the old acknowledgment only after observing cancellation.
      peer.acknowledge()
      await #expect(throws: CancellationError.self) { try await pending.value }
      #expect(try await connection.execute(.listWorkspaces) == .ok)
      try await connection.send(.text("second"), to: pane)
      #expect(peer.records.withLock { $0.count } == 2)
      await connection.close()
    } catch {
      await connection.close()
      _ = try? await pending.value
      throw error
    }
  }

  @Test(arguments: [false, true])
  func alreadyCanceledInputSendsNoRecord(paste: Bool) async throws {
    let peer = InputAckPeer()
    defer { peer.close() }
    peer.acknowledge()
    let connection = try await attached(to: peer)
    let pending = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      if paste {
        _ = try await connection.paste("canceled", to: PaneID())
      } else {
        try await connection.send(.text("canceled"), to: PaneID())
      }
    }
    await #expect(throws: CancellationError.self) { try await pending.value }
    #expect(peer.records.withLock { $0.isEmpty })
    try await connection.send(.text("fresh"), to: PaneID())
    #expect(peer.records.withLock { $0.map(\.sequence) } == [1])
    await connection.close()
  }

  @Test(arguments: [false, true])
  func cancellationWithdrawsActiveOrQueuedPaste(queued: Bool) async throws {
    let peer = InputAckPeer()
    defer { peer.close() }
    let connection = try await attached(to: peer)
    let pane = PaneID()
    let blocker: Task<PasteState, any Error>? =
      queued ? Task { try await connection.paste("blocker", to: pane) } : nil
    let finished = Mutex(false)
    var pending: Task<PasteState, any Error>?
    var successor: Task<PasteState, any Error>?
    defer {
      pending?.cancel();
      blocker?.cancel();
      successor?.cancel()
      peer.acknowledge()
    }
    do {
      if queued {
        try #require(
          await waitUntil { peer.records.withLock { $0.count == 2 } }
        )
      }
      let paste = Task {
        defer { finished.withLock { $0 = true } }
        return try await connection.paste("canceled", to: pane)
      }
      pending = paste
      let deadline = ContinuousClock.now + .seconds(1)
      while await connection.pendingPasteCountForTesting < (queued ? 2 : 1),
        ContinuousClock.now < deadline
      { try await Task.sleep(for: .milliseconds(1)) }
      try #require(
        await connection.pendingPasteCountForTesting == (queued ? 2 : 1)
      )
      if !queued {
        try #require(
          await waitUntil { peer.records.withLock { $0.count == 2 } }
        )
      }
      paste.cancel()
      #expect(await waitUntil { finished.withLock { $0 } })
      if !queued {
        #expect(
          await waitUntil {
            peer.records.withLock {
              $0.contains { $0.payload == .pasteCancel(id: 1) }
            }
          }
        )
      }
      let next = Task { try await connection.paste("successor", to: pane) }
      successor = next
      if !queued {
        try #require(
          await waitUntil { peer.records.withLock { $0.count == 5 } }
        )
      }
      peer.acknowledge()
      await #expect(throws: CancellationError.self) { try await paste.value }
      if let blocker { #expect(try await blocker.value == .completed) }
      #expect(try await next.value == .completed)
      let records = peer.records.withLock { $0 }
      if queued {
        #expect(
          !records.contains {
            $0.payload == .pasteChunk(id: 2, text: "canceled")
          }
        )
      } else {
        #expect(!records.contains { $0.payload == .pasteEnd(id: 1) })
        let canceled = try #require(
          records.firstIndex { $0.payload == .pasteCancel(id: 1) }
        )
        let began = try #require(
          records.firstIndex { $0.payload == .pasteBegin(id: 2) }
        )
        #expect(canceled < began)
      }
      #expect(try await connection.paste("fresh", to: pane) == .completed)
      #expect(try await connection.execute(.listWorkspaces) == .ok)
      await connection.close()
    } catch {
      await connection.close()
      _ = try? await pending?.value
      _ = try? await blocker?.value
      _ = try? await successor?.value
      throw error
    }
  }

  @Test
  func delayedCancellationDoesNotRetireReusedSequenceAfterReattachment()
    async throws
  {
    let peer = InputAckPeer()
    defer { peer.close() }
    let connection = try await attached(to: peer)
    let attachment = try #require(await connection.attachment)
    let delayed = Mutex<(@Sendable () -> Void)?>(nil)
    let pane = PaneID()
    let first = Task {
      try await connection.submit(
        raw: InputRecord(
          sequence: 1,
          attachment: attachment,
          pane: pane,
          payload: .input(.text("first")),
        ),
        scheduleCancellation: { cleanup in delayed.withLock { $0 = cleanup } }
      )
    }
    defer { first.cancel() }
    do {
      try #require(await waitUntil { peer.records.withLock { $0.count == 1 } })
      first.cancel()
      let cleanup = try #require(delayed.withLock { $0 })
      peer.sendAcknowledgment(1)
      try await first.value
      _ = try await connection.execute(
        .attach(AttachRequest(.id(peer.workspace.id)))
      )
      let second = Task { try await connection.send(.text("second"), to: pane) }
      defer { second.cancel() }
      do {
        try #require(
          await waitUntil { peer.records.withLock { $0.count == 2 } }
        )
        #expect(peer.records.withLock { $0.map(\.sequence) } == [1, 1])
        connection.queue.async(execute: cleanup)
        await withCheckedContinuation { continuation in
          connection.queue.async { continuation.resume() }
        }
        peer.sendAcknowledgment(1)
        try await second.value
      } catch {
        await connection.close()
        _ = try? await second.value
        throw error
      }
      await connection.close()
    } catch {
      await connection.close()
      _ = try? await first.value
      throw error
    }
  }

  private func attached(to peer: InputAckPeer) async throws -> MuxConnection {
    let connection = try await MuxConnection.connect(
      endpoint: peer.listener.endpoint,
      frontend: .native,
    )
    do {
      _ = try await connection.execute(
        .attach(AttachRequest(.id(peer.workspace.id)))
      )
      return connection
    } catch {
      await connection.close()
      throw error
    }
  }

  private func waitUntil(_ predicate: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(1)
    while !predicate(), ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(1))
    }
    return predicate()
  }
}

private final class InputAckPeer: Sendable {
  let listener: SMXListener
  let records = Mutex<[InputRecord]>([])
  let closed = Mutex(false)
  let workspace = WorkspaceSnapshot(
    id: WorkspaceID(),
    name: "Input",
    tabs: [],
    activeTab: TabID(),
    panes: [],
    layoutRevision: 1,
  )
  private let channels = Mutex<[SMXChannel]>([])
  private let acknowledges = Mutex(false)
  private let limits: MuxLimits
  private let holdBegin: Bool

  init(limits: MuxLimits = .standard, holdBegin: Bool = false) {
    self.limits = limits
    self.holdBegin = holdBegin
    let queue = DispatchQueue(label: "input-ack-peer")
    listener = SMXListener(anonymousOn: queue)
    listener.activate(connectionQueue: queue) { [weak self] channel in
      guard let self else {
        channel.cancel();
        return
      }
      channels.withLock { $0.append(channel) }
      channel.activate { [weak self] event in
        guard let self else { return }
        if case .closed = event {
          closed.withLock { $0 = true };
          return
        }
        guard case let .message(data) = event,
          let message = try? SMXCodec.decode(
            ClientMessage.self,
            from: data,
            limit: 1 << 20,
          )
        else { return }
        switch message {
        case .hello:
          send(
            .welcome(
              .init(
                protocolVersion: SMX.protocolVersion,
                build: SMX.build,
                server: ServerInstanceID(),
                acceptedProfile: nil,
                limits: limits,
                innerTerm: "xterm-256color",
              )
            ),
            on: channel
          )
        case let .request(id, command):
          let reply: MuxReply =
            if case .attach = command {
              .attached(attachment: AttachmentID(), workspace: workspace)
            } else { .ok }
          send(.reply(id: id, result: .success(reply)), on: channel)
        case let .input(record):
          records.withLock { $0.append(record) }
          let withheld =
            holdBegin
            && {
              if case .pasteBegin = record.payload { true } else { false }
            }()
          if acknowledges.withLock({ $0 }), !withheld {
            send(.inputAck(sequence: record.sequence, error: nil), on: channel)
          }
        default: break
        }
      }
    }
  }

  func acknowledge() {
    acknowledges.withLock { $0 = true }
    for record in records.withLock({ $0 }) {
      for channel in channels.withLock({ $0 }) {
        send(.inputAck(sequence: record.sequence, error: nil), on: channel)
      }
    }
  }

  func acknowledgeFutureInputs() { acknowledges.withLock { $0 = true } }

  func detach() {
    for channel in channels.withLock({ $0 }) {
      send(.event(.detached(reason: "taken over")), on: channel)
    }
  }

  func sendAcknowledgment(_ sequence: UInt64) {
    for channel in channels.withLock({ $0 }) {
      send(.inputAck(sequence: sequence, error: nil), on: channel)
    }
  }

  private func send(_ message: ServerMessage, on channel: SMXChannel) {
    do { try channel.send(SMXCodec.encode(message, limit: 1 << 20)) } catch {
      Issue.record("Peer encode failed: \(error)")
    }
  }

  func close() {
    channels.withLock { $0 }.forEach { $0.cancel() }
    listener.cancel()
  }
}
