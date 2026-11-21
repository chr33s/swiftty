import Darwin
import Dispatch
import Foundation
import SwiftMuxGuardian
import SwiftMuxProtocol
import SwifttyEngine
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct GuardianTerminalOutputTests {
  @Test
  func realPTYResizeCutKeepsBufferedOutputOnTheCorrectGeometry() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString
    )
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let before = root.appendingPathComponent("before")
    let after = root.appendingPathComponent("after")
    let size = root.appendingPathComponent("size")
    let program = """
      import os,tty,time,sys
      tty.setraw(0)
      os.write(1,b'READY')
      while not os.path.exists(sys.argv[1]): time.sleep(0.005)
      os.write(1,b'BEFORE')
      while not os.path.exists(sys.argv[2]): time.sleep(0.005)
      size=os.get_terminal_size(0)
      with open(sys.argv[3],'w') as f: f.write(str(size.columns)+'x'+str(size.lines))
      os.write(1,b'AFTER')
      time.sleep(60)
      """
    let fixture = try EngineWorker(
      program: program,
      arguments: [before.path, after.path, size.path],
      largeTerm: false
    )
    defer { fixture.stop() }
    try eventually {
      fixture.queue.sync {
        fixture.state.screenLines.contains { $0.contains("READY") }
      }
    }
    fixture.queue.sync {
      fixture.consumerPaused = true;
      fixture.observeGeometry = true
    }
    try Data().write(to: before)
    try eventually { fixture.queue.sync { fixture.receivedSequence >= 2 } }
    let response = DispatchSemaphore(value: 0)
    let committed = DispatchSemaphore(value: 0)
    fixture.queue.async {
      fixture.resize(
        columns: 100,
        rows: 30,
        response: response,
        committed: committed
      )
    }
    try #require(response.wait(timeout: .now() + 3) == .success)
    #expect(committed.wait(timeout: .now()) == .timedOut)
    try Data().write(to: after)
    try eventually { fixture.queue.sync { fixture.receivedSequence >= 3 } }
    fixture.queue.sync {
      #expect(fixture.state.columns == 80 && fixture.state.rows == 24)
      #expect(fixture.parseGeometries.isEmpty)
      fixture.consumerPaused = false
      fixture.pump.resume()
    }
    #expect(committed.wait(timeout: .now() + 3) == .success)
    fixture.queue.sync {
      #expect(fixture.parseGeometries == ["BEFORE@80", "AFTER@100"])
      #expect(fixture.state.columns == 100 && fixture.state.rows == 30)
      #expect(
        fixture.state.screenLines.contains { $0.contains("READYBEFOREAFTER") }
      )
      #expect(fixture.errors.isEmpty)
    }
    #expect(try String(contentsOf: size, encoding: .utf8) == "100x30")
  }

  @Test
  func geometryBarrierWaitsForPriorOutputAndReplyAdmissionBeforeLaterBytes() {
    let queue = DispatchQueue(label: "guardian-geometry-cut")
    let pump = GuardianPaneOutput(queue: queue)
    queue.sync {
      var ready = false
      var pendingReply = false
      var columns = 80
      var trace: [String] = []
      pump.canConsume = { ready }
      pump.hasPendingReply = { pendingReply }
      pump.consume = { bytes in
        trace.append("\(String(decoding: bytes, as: UTF8.self))@\(columns)")
        if bytes.first == 65 { pendingReply = true }
        return bytes.count
      }
      pump.acknowledge = { trace.append("ack:\($0)") }
      pump.receive(sequence: 1, bytes: Data("A".utf8))
      pump.afterApplying(through: 1) {
        columns = 100;
        trace.append("resize")
      }
      pump.receive(sequence: 2, bytes: Data("B".utf8))
      #expect(trace.isEmpty && columns == 80)
      ready = true
      pump.resume()
      #expect(trace == ["A@80", "ack:1"])
      #expect(columns == 80)
      pendingReply = false
      pump.resume()
      #expect(trace == ["A@80", "ack:1", "resize", "B@100", "ack:2"])
    }
  }

  @Test(arguments: ["future", "stale", "overlap"])
  func invalidGeometryCutsFailWithoutCommitting(mode: String) {
    let queue = DispatchQueue(label: "guardian-invalid-cut")
    let pump = GuardianPaneOutput(queue: queue)
    queue.sync {
      var failures = 0
      var commits = 0
      pump.canConsume = { false }
      pump.onFailure = { _ in failures += 1 }
      pump.receive(sequence: 1, bytes: Data("A".utf8))
      if mode == "overlap" { pump.afterApplying(through: 1) { commits += 1 } }
      pump.afterApplying(
        through: mode == "future" ? 2 : (mode == "stale" ? 0 : 1)
      ) { commits += 1 }
      #expect(failures == 1 && commits == 0)
    }
  }

  @Test(arguments: [false, true])
  func stalledConsumerCannotExceedRecordOrByteBudget(large: Bool) {
    let queue = DispatchQueue(label: "guardian-output-bound")
    let pump = GuardianPaneOutput(queue: queue)
    queue.sync {
      var failures = 0
      var acknowledgements = 0
      pump.canConsume = { false }
      pump.acknowledge = { _ in acknowledgements += 1 }
      pump.onFailure = { _ in failures += 1 }
      let data = Data(
        repeating: 65,
        count: large ? GuardianWire.outputChunkLimit : 1
      )
      let count =
        large ? (1 << 20) / data.count : GuardianWire.outputRecordLimit
      for sequence in 1 ... count {
        pump.receive(sequence: UInt64(sequence), bytes: data)
      }
      #expect(failures == 0 && acknowledgements == 0)
      pump.receive(sequence: UInt64(count + 1), bytes: data)
      #expect(failures == 1 && acknowledgements == 0)
      pump.canConsume = { true }
      pump.consume = { _ in
        Issue.record("failed stream resumed parsing");
        return 0
      }
      pump.resume()
      #expect(acknowledgements == 0)
    }
  }

  @Test(arguments: ["drain", "exit"])
  func realParserPreservesRepliesAndFinalOutputAcrossGuardianTransport(
    mode: String
  ) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString
    )
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let gate = root.appendingPathComponent("release")
    let result = root.appendingPathComponent("result")
    let fixture = try EngineWorker(
      program: PaneReplyPressureTests.program,
      arguments: [gate.path, result.path, mode],
      largeTerm: mode == "exit"
    )
    defer { fixture.stop() }
    try eventually {
      fixture.queue.sync {
        fixture.state.screenLines.contains { $0.contains("READY") }
      }
    }
    Thread.sleep(forTimeInterval: 0.15)
    let held = fixture.queue.sync { fixture.state.output.count }
    #expect(held > 0 && held <= 64 << 10)
    try Data().write(to: gate, options: .atomic)
    #expect(fixture.done.wait(timeout: .now() + 8) == .success)
    fixture.queue.sync {
      #expect(fixture.state.screenLines.contains { $0.contains("FINAL") })
      #expect(fixture.status == 7)
      #expect(fixture.replyOutstanding == 0)
      #expect(fixture.errors.isEmpty)
      #expect(fixture.sawExiting)
      #expect(fixture.acknowledged > 0)
    }
    #expect(
      try String(contentsOf: result, encoding: .utf8)
        == (mode == "drain" ? "MATCH" : "FINAL_WRITTEN")
    )
  }

  @Test
  func partialRecordIsFilteredOnceAndAcknowledgedOnlyAfterApplication() {
    let queue = DispatchQueue(label: "guardian-output-unit")
    let pump = GuardianPaneOutput(queue: queue)
    queue.sync {
      var ready = false
      var filters = 0
      var applied = Data()
      var acknowledgements: [UInt64] = []
      var ended = false
      pump.canConsume = { ready }
      pump.filter = { bytes in
        filters += 1;
        return bytes + Data("!".utf8)
      }
      pump.consume = { bytes in
        applied.append(bytes[0])
        ready = false
        return 1
      }
      pump.acknowledge = { acknowledgements.append($0) }
      pump.onFinished = { _, _ in ended = true }
      pump.receive(sequence: 1, bytes: Data("AB".utf8))
      #expect(acknowledgements.isEmpty)
      ready = true
      pump.resume()
      #expect(applied == Data("A".utf8))
      #expect(acknowledgements.isEmpty && filters == 1)
      pump.exited(status: 0, forced: false)
      #expect(!ended)
      ready = true
      pump.resume()
      ready = true
      pump.resume()
      #expect(applied == Data("AB!".utf8))
      #expect(acknowledgements == [1] && filters == 1)
      ready = true
      pump.resume()
      #expect(ended)
    }
  }

  private final class EngineWorker: @unchecked Sendable {
    let queue = DispatchQueue(label: "guardian-engine-worker")
    let server: GuardianServer
    let pump: GuardianPaneOutput
    let done = DispatchSemaphore(value: 0)
    var state = TerminalState(
      columns: 80,
      rows: 24,
      scrollbackLimitBytes: 1 << 20
    )
    var parser = Parser()
    var connection: GuardianWorkerConnection?
    lazy var commands = GuardianWorkerCommands(queue: queue) {
      [weak self] command, completion in
      guard let connection = self?.connection else { return false }
      return try connection.submit(command, completion: completion)
    }
    var handle: GuardianPaneHandle?
    var busy = false
    var replyOutstanding = 0
    var status: Int32?
    var consumerPaused = false
    var receivedSequence: UInt64 = 0
    var observeGeometry = false
    var parseGeometries: [String] = []
    var sawExiting = false
    var acknowledged: UInt64 = 0
    var errors: [String] = []

    init(program: String, arguments: [String], largeTerm: Bool) throws {
      server = try GuardianServer(
        launcherPath: launcherPath(),
        peerRequirement: nil
      )
      pump = GuardianPaneOutput(queue: queue)
      let workspace = WorkspaceID()
      let endpoint = server.listenAnonymously()
      let token = try server.provisionWorker(
        workspace: workspace,
        pid: getpid()
      )
      try queue.sync {
        if largeTerm {
          state.terminfoName = String(repeating: "a", count: 16378)
        }
        pump.canConsume = { [weak self] in
          guard let self, !self.consumerPaused else { return false }
          return self.enqueueReply()
        }
        pump.consume = { [weak self] bytes in
          guard let self else { return 0 }
          if self.observeGeometry {
            self.parseGeometries.append(
              "\(String(decoding: bytes, as: UTF8.self))@\(self.state.columns)"
            )
          }
          return self.parser.consumePrefix(
            bytes,
            into: &self.state,
            replyLimit: 1
          )
        }
        pump.hasPendingReply = { [weak self] in
          self.map { $0.busy || !$0.state.output.isEmpty } ?? false
        }
        pump.onBatch = { [weak self] in _ = self?.enqueueReply() }
        pump.onExiting = { [weak self] in
          self?.sawExiting = true
          self?.state.output.removeAll(keepingCapacity: true)
        }
        pump.acknowledge = { [weak self] sequence in
          guard let self, let handle = self.handle else { return }
          self.acknowledged = sequence
          self.connection?.acknowledgeOutput(handle, through: sequence)
        }
        pump.onFinished = { [weak self] status, _ in
          guard let self else { return }
          self.status = status
          self.done.signal()
        }
        pump.onFailure = { [weak self] error in
          self?.errors.append(error.description)
        }
        connection = try GuardianWorkerConnection(
          channel: .connect(endpoint: endpoint, queue: queue),
          workspace: workspace,
          token: token,
          peerRequirement: nil,
          handlers: .init(
            ready: { [weak self] _ in self?.spawn(program, arguments) },
            output: { [weak self] _, sequence, bytes in
              self?.receivedSequence = sequence
              self?.pump.receive(sequence: sequence, bytes: bytes)
            },
            inputReleased: { _, _ in },
            replyReleased: { [weak self] _, bytes in
              guard let self else { return }
              self.replyOutstanding -= bytes
              if self.replyOutstanding < 0 {
                self.errors.append("duplicate reply credit")
              }
              self.pump.resume()
            },
            exiting: { [weak self] _ in self?.pump.exiting() },
            exited: { [weak self] _, status, forced in
              self?.pump.exited(status: status, forced: forced)
            },
            progress: { $0() },
            closed: { [weak self] error in self?.commands.close(error) }
          )
        )
      }
    }

    func resize(
      columns: Int,
      rows: Int,
      response: DispatchSemaphore,
      committed: DispatchSemaphore
    ) {
      guard !busy, let handle else {
        errors.append("resize while busy");
        return
      }
      busy = true
      do {
        _ = try commands.submit(
          .resize(pane: handle, columns: columns, rows: rows)
        ) { [weak self] result in
          guard let self else { return }
          self.busy = false
          if case let .success(.resized(cut)) = result {
            self.pump.afterApplying(through: cut) { [weak self] in
              self?.state.resize(columns: columns, rows: rows)
              committed.signal()
            }
          } else {
            self.errors.append("resize rejected")
          }
          response.signal()
        }
      } catch {
        errors.append(String(describing: error));
        response.signal()
      }
    }

    private func spawn(_ program: String, _ arguments: [String]) {
      let pane = PaneID()
      busy = true
      do {
        _ = try commands.submit(
          .spawn(
            pane: pane,
            launch: LaunchSpec(
              command: ["/usr/bin/python3", "-u", "-c", program] + arguments
            ),
            columns: 80,
            rows: 24
          )
        ) { [weak self] result in
          guard let self else { return }
          self.busy = false
          if case let .success(.spawned(_, process, _)) = result {
            self.handle = GuardianPaneHandle(pane: pane, process: process)
          } else {
            self.errors.append("spawn failed")
          }
          self.pump.resume()
        }
      } catch { errors.append(String(describing: error)) }
    }

    private func enqueueReply() -> Bool {
      if pump.childIsExiting
        || state.output.count > MuxLimits.standard.replyReserveBytes
      {
        state.output.removeAll(keepingCapacity: true)
      }
      guard !state.output.isEmpty else { return true }
      let count = state.output.count
      guard !busy, let handle,
        count <= MuxLimits.standard.replyReserveBytes - replyOutstanding
      else { return false }
      busy = true
      replyOutstanding += count
      do {
        let admitted = try commands.submit(
          .reply(pane: handle, bytes: Data(state.output))
        ) { [weak self] result in
          guard let self else { return }
          self.busy = false
          if case .success(.ok) = result {
            self.state.output.removeAll(keepingCapacity: true)
          } else {
            self.replyOutstanding -= count
            self.state.output.removeAll(keepingCapacity: true)
            if !self.pump.childIsExiting {
              self.errors.append("reply rejected: \(result)")
            }
          }
          self.pump.resume()
        }
        if !admitted {
          replyOutstanding -= count;
          busy = false
        }
      } catch { errors.append(String(describing: error)) }
      return false
    }

    func stop() {
      queue.sync { connection?.close() }
      let stopped = DispatchSemaphore(value: 0)
      server.shutdown { stopped.signal() }
      #expect(stopped.wait(timeout: .now() + 8) == .success)
    }
  }

  private func eventually(_ predicate: () -> Bool) throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate() {
      guard ContinuousClock.now < deadline else {
        throw MuxError(.connectionLost, "engine fixture timed out")
      }
      Thread.sleep(forTimeInterval: 0.01)
    }
  }
}
