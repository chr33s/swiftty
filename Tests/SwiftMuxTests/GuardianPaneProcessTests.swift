import Darwin
import Dispatch
import Foundation
import SwiftMuxGuardian
import SwiftMuxProtocol
@testable import SwiftMuxService
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct GuardianPaneProcessTests {
  @Test
  func runtimeUsesGuardianPTYForRepliesInputResizeAndFinalOutput() throws {
    let harness = try Harness(replyRefusals: 3)
    defer { harness.stop() }
    let program = #"""
      import os,tty,fcntl,termios,struct
      tty.setraw(0)
      os.write(1,b'READY\x1b[5n')
      reply=b''
      while len(reply)<4: reply+=os.read(0,4-len(reply))
      os.write(1,b'REPLY' if reply==b'\x1b[0n' else b'BADREPLY')
      data=os.read(0,1)
      rows,cols,_,_=struct.unpack('HHHH',fcntl.ioctl(0,termios.TIOCGWINSZ,b'\0'*8))
      os.write(1,('%dx%d'% (cols,rows)).encode() if data==b'x' else b'BADINPUT')
      raise SystemExit(7)
      """#
    try harness.launch(program)
    let pid = harness.process.pid
    #expect(pid > 0)
    try eventually {
      harness.runtime.screenLines().contains { $0.contains("REPLY") }
    }
    harness.runtime.resize(columns: 100, rows: 30)
    try eventually {
      harness.queue.sync { harness.runtime.geometryGeneration == 1 }
    }
    #expect(harness.runtime.reserve(1))
    harness.runtime.write(.text("x"), estimate: 1)
    #expect(harness.finished.wait(timeout: .now() + 5) == .success)
    #expect(
      harness.runtime.screenLines().contains { $0.contains("READYREPLY100x30") }
    )
    harness.queue.sync {
      #expect(harness.process.finished)
      #expect(harness.process.exitStatus == 7)
      #expect(harness.process.pid == pid)
      #expect(harness.failures.isEmpty)
      #expect(harness.runtime.outstandingInput.withLock { $0 } == 0)
    }
    #expect(harness.server.inventory().first?.panes.first?.pid == pid)
  }

  @Test
  func transportLossRetainsChildAndFailsPendingGeometryWithoutInventingExit()
    throws
  {
    let harness = try Harness()
    defer { harness.stop() }
    try harness.launch("import os,time; os.write(1,b'READY'); time.sleep(60)")
    try eventually {
      harness.runtime.screenLines().contains { $0.contains("READY") }
    }
    let pid = harness.process.pid
    harness.queue.sync { harness.process.canConsume = { false } }
    harness.runtime.resize(columns: 100, rows: 30)
    // The result is allowed to arrive, but the pane cannot commit its cut.
    #expect(harness.resized.wait(timeout: .now() + 3) == .success)
    harness.queue.sync {
      #expect(harness.runtime.geometryGeneration == 0)
      harness.connection.close()
      #expect(!harness.process.finished)
      #expect(harness.process.exitStatus == nil)
      #expect(!harness.process.isOpen)
      #expect(harness.failures.count == 1)
    }
    let captured = DispatchSemaphore(value: 0)
    harness.runtime.captureFrame(
      server: ServerInstanceID(),
      attachment: AttachmentID(),
      layoutRevision: 0
    ) { result in
      if case let .failure(error) = result {
        #expect(error.code == .connectionLost)
      } else {
        Issue.record("lost worker returned a ready frame")
      }
      captured.signal()
    }
    #expect(captured.wait(timeout: .now() + 3) == .success)
    try eventually { harness.server.inventory().first?.available == false }
    #expect(kill(pid, 0) == 0)
    #expect(harness.finished.wait(timeout: .now()) == .timedOut)
    let cancelled = DispatchSemaphore(value: 0)
    harness.runtime.pasteCancel(
      id: 1,
      failure: { error in
        #expect(error.code == .connectionLost)
        cancelled.signal()
      }
    ) { _ in
      Issue.record("lost cancellation must not report aborted or partial")
      cancelled.signal()
    }
    #expect(cancelled.wait(timeout: .now() + 2) == .success)
  }

  @Test(arguments: ["drain", "exit"])
  func actualRuntimePreservesRepliesAndExitUnderPressure(mode: String) throws {
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
    let harness = try Harness(
      innerTerm: mode == "exit"
        ? String(repeating: "a", count: 16378) : SMX.fallbackInnerTerm
    )
    defer { harness.stop() }
    try harness.launch(
      PaneReplyPressureTests.program,
      arguments: [gate.path, result.path, mode]
    )
    try eventually {
      harness.runtime.screenLines().contains { $0.contains("READY") }
    }
    Thread.sleep(forTimeInterval: 0.15)
    try Data().write(to: gate, options: .atomic)
    #expect(harness.finished.wait(timeout: .now() + 8) == .success)
    #expect(harness.runtime.screenLines().contains { $0.contains("FINAL") })
    #expect(
      try String(contentsOf: result, encoding: .utf8)
        == (mode == "drain" ? "MATCH" : "FINAL_WRITTEN")
    )
    harness.queue.sync {
      #expect(harness.process.exitStatus == 7)
      #expect(harness.failures.isEmpty)
    }
  }

  @Test
  func guardianPasteCancellationPreservesExactMarkersAndCredit() throws {
    let harness = try Harness()
    defer { harness.stop() }
    try harness.launch(
      #"""
      import os,tty,time
      tty.setraw(0)
      os.write(1,b'\x1b[?2004hREADY')
      expected=b'\x1b[200~ABC\x1b[201~'
      data=b''
      while len(data)<len(expected): data+=os.read(0,len(expected)-len(data))
      os.write(1,b'MATCH' if data==expected else b'WRONG')
      time.sleep(60)
      """#
    )
    try eventually {
      harness.runtime.screenLines().contains { $0.contains("READY") }
    }
    #expect(harness.runtime.reserve(12))
    harness.runtime.pasteBegin(id: 1, estimate: 12)
    #expect(harness.runtime.reserve(6))
    harness.runtime.pasteChunk(id: 1, text: "ABC", estimate: 6)
    try eventually { harness.runtime.outstandingInput.withLock { $0 } == 6 }
    let cancelled = DispatchSemaphore(value: 0)
    harness.runtime.pasteCancel(
      id: 1,
      failure: { error in
        Issue.record(error);
        cancelled.signal()
      }
    ) { state in
      #expect(state == .partial)
      cancelled.signal()
    }
    #expect(cancelled.wait(timeout: .now() + 3) == .success)
    try eventually {
      harness.runtime.screenLines().contains { $0.contains("MATCH") }
    }
    #expect(harness.runtime.outstandingInput.withLock { $0 } == 0)
    harness.queue.sync { #expect(harness.failures.isEmpty) }
  }

  private func eventually(_ predicate: () -> Bool) throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate() {
      guard ContinuousClock.now < deadline else {
        throw MuxError(.connectionLost, "guardian pane timed out")
      }
      Thread.sleep(forTimeInterval: 0.01)
    }
  }

  private final class Harness: @unchecked Sendable {
    let server: GuardianServer
    let workspace = WorkspaceID()
    let ready = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let resized = DispatchSemaphore(value: 0)
    var runtime: PaneRuntime!
    var process: GuardianPaneProcess!
    var queue: DispatchQueue!
    var connection: GuardianWorkerConnection!
    var writer: UUID?
    var failures: [MuxError] = []
    var replyRefusals: Int
    lazy var commands = GuardianWorkerCommands(queue: queue) {
      [unowned self] command, completion in
      try connection.submit(command, completion: completion)
    }

    init(
      innerTerm: String = SMX.fallbackInnerTerm,
      replyRefusals: Int = 0
    ) throws {
      self.replyRefusals = replyRefusals
      server = try GuardianServer(
        launcherPath: launcherPath(),
        peerRequirement: nil
      )
      let endpoint = server.listenAnonymously()
      let token = try server.provisionWorker(
        workspace: workspace,
        pid: getpid()
      )
      runtime = PaneRuntime(
        id: PaneID(),
        workspace: workspace,
        columns: 80,
        rows: 24,
        historyBytes: 0,
        innerTerm: innerTerm,
        limits: .standard,
        processFactory: { [unowned self] id, _, queue, limits in
          self.queue = queue
          let value = GuardianPaneProcess(
            id: id,
            queue: queue,
            limits: limits,
            transport: GuardianPaneTransport(
              submit: { [unowned self] command, completion in
                if case .reply = command, self.replyRefusals > 0 {
                  self.replyRefusals -= 1
                  return false
                }
                return try commands.submit(command) { [self] result in
                  completion(result)
                  if case .resize = command { resized.signal() }
                }
              },
              cancelUnsent: { [unowned self] in
                commands.cancelUnsentInput(
                  pane: $0,
                  paste: $1,
                  includingOrdinaryInput: $2
                )
              },
              acknowledge: { [unowned self] in
                connection.acknowledgeOutput($0, through: $1)
              },
              retire: { [unowned self] completion in
                guard let handle = process.handle else {
                  completion(nil);
                  return
                }
                do {
                  let accepted = try commands.submit(.forget(pane: handle)) {
                    result in
                    switch result {
                    case .success(.ok): completion(nil)
                    case let .success(.rejected(error)), let .failure(error):
                      completion(error)
                    default:
                      completion(
                        MuxError(.invalidRequest, "invalid forget result")
                      )
                    }
                  }
                  if !accepted {
                    completion(
                      MuxError(.resourceLimit, "command admission full")
                    )
                  }
                } catch {
                  completion(MuxError(.invalidRequest, "forget failed"))
                }
              },
              writer: { [unowned self] in writer },
              failed: { [unowned self] error in
                failures.append(error);
                connection.close()
              }
            )
          )
          process = value
          return value
        }
      )
      runtime.onEvent = { [weak self] in
        if case .finished = $0 { self?.finished.signal() }
      }
      try queue.sync {
        connection = try GuardianWorkerConnection(
          channel: .connect(endpoint: endpoint, queue: queue),
          workspace: workspace,
          token: token,
          peerRequirement: nil,
          handlers: .init(
            ready: { [weak self] _ in self?.ready.signal() },
            output: { [weak self] in
              self?.process.receive(.output(pane: $0, sequence: $1, bytes: $2))
            },
            inputReleased: { [weak self] in
              self?.process.receive(.inputReleased(pane: $0, bytes: $1))
            },
            replyReleased: { [weak self] in
              self?.process.receive(.replyReleased(pane: $0, bytes: $1))
            },
            exiting: { [weak self] in self?.process.receive(.exiting(pane: $0))
            },
            exited: { [weak self] in
              self?.process.receive(.exited(pane: $0, status: $1, forced: $2))
            },
            progress: { $0() },
            closed: { [weak self] error in
              self?.process.unavailable(error)
              self?.commands.close(error)
            }
          )
        )
      }
      guard ready.wait(timeout: .now() + 3) == .success else {
        throw MuxError(.connectionLost, "guardian not ready")
      }
      let gateway = UUID()
      server.replaceGateway(gateway)
      let capability = try server.grantWriter(
        workspace: workspace,
        gateway: gateway
      )
      queue.sync { writer = capability }
    }

    func launch(_ program: String, arguments: [String] = []) throws {
      let launcher = try PaneLauncher(
        launcherPath: launcherPath(),
        innerTerm: SMX.fallbackInnerTerm
      )
      let launched = DispatchSemaphore(value: 0)
      queue.async { [self] in
        runtime.launch(
          LaunchSpec(
            command: ["/usr/bin/python3", "-u", "-c", program] + arguments
          ),
          launcher: launcher
        ) { result in
          if case let .failure(error) = result { Issue.record(error) }
          launched.signal()
        }
      }
      #expect(launched.wait(timeout: .now() + 5) == .success)
    }
    func stop() {
      queue.sync { connection.close() }
      let stopped = DispatchSemaphore(value: 0)
      server.shutdown { stopped.signal() }
      #expect(stopped.wait(timeout: .now() + 8) == .success)
    }
  }
}
