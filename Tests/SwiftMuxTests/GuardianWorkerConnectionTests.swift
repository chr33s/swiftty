import Darwin
import Dispatch
import Foundation
import SwiftMuxGuardian
import SwiftMuxProtocol
import SwiftMuxXPC
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct GuardianWorkerConnectionTests {
  @Test
  func retriesOnlyExplicitNonAdmissionAndReportsLostOutcomeSeparately() throws {
    let serverQueue = DispatchQueue(label: "guardian-scripted-server")
    let listener = SMXListener(anonymousOn: serverQueue)
    let channels = Mutex<[SMXChannel]>([])
    let attempts = Mutex<[Data]>([])
    let workspace = WorkspaceID()
    let authority = GuardianAuthority(
      incarnation: UUID(),
      workspace: workspace,
      generation: 1
    )
    listener.activate(connectionQueue: serverQueue) { channel in
      channels.withLock { $0.append(channel) }
      channel.activate(recordLimit: { GuardianWire.recordLimit }) { event in
        guard case let .message(bytes) = event,
          let request = try? JSONDecoder()
            .decode(GuardianRequest.self, from: bytes)
        else { return }
        let response: GuardianEvent
        switch request {
        case .hello: response = .welcome(authority: authority)
        case let .command(_, sequence, _):
          let count = attempts.withLock {
            $0.append(bytes);
            return $0.count
          }
          if sequence == 2 {
            channel.cancel();
            return
          }
          response =
            count == 1
            ? .retry(sequence: sequence)
            : .result(sequence: sequence, value: .ok)
        default: return
        }
        channel.send(try! JSONEncoder().encode(response))
      }
    }
    defer {
      channels.withLock { for channel in $0 { channel.cancel() } }
      listener.cancel()
    }
    let queue = DispatchQueue(label: "guardian-scripted-worker")
    let ready = DispatchSemaphore(value: 0)
    let losses = Mutex(0)
    let connection = try GuardianWorkerConnection(
      channel: .connect(endpoint: listener.endpoint, queue: queue),
      workspace: workspace,
      token: UUID(),
      peerRequirement: nil,
      handlers: .init(
        ready: { _ in ready.signal() },
        output: { _, _, _ in },
        inputReleased: { _, _ in },
        exited: { _, _, _ in },
        progress: { $0() },
        closed: { _ in losses.withLock { $0 += 1 } }
      )
    )
    defer { queue.sync { connection.close() } }
    #expect(ready.wait(timeout: .now() + 3) == .success)
    let handle = GuardianPaneHandle(pane: PaneID(), process: UUID())
    #expect(
      try command(
        connection,
        queue,
        .resize(pane: handle, columns: 80, rows: 24)
      ) == .ok
    )
    let requests = attempts.withLock { $0 }
    #expect(requests.count == 2)
    #expect(requests.first == requests.last)
    do {
      _ = try command(connection, queue, .end(pane: handle))
      Issue.record("unknown command outcome was reported as a guardian result")
    } catch let error as MuxError { #expect(error.code == .connectionLost) }
    #expect(attempts.withLock { $0.count } == 3)
    #expect(losses.withLock { $0 } == 1)
  }

  @Test
  func commandsRetireAndHealthRequiresPaneQueueProgress() throws {
    let server = try GuardianServer(
      launcherPath: launcherPath(),
      peerRequirement: nil,
      progressTimeout: 1
    )
    defer {
      let stopped = DispatchSemaphore(value: 0)
      server.shutdown { stopped.signal() }
      #expect(stopped.wait(timeout: .now() + 8) == .success)
    }
    let endpoint = server.listenAnonymously()
    let workspace = WorkspaceID()
    let token = try server.provisionWorker(workspace: workspace, pid: getpid())
    let queue = DispatchQueue(label: "guardian-worker-test.workspace")
    let paneQueue = DispatchQueue(label: "guardian-worker-test.pane")
    let ready = DispatchSemaphore(value: 0)
    let closed = DispatchSemaphore(value: 0)
    let output = DispatchSemaphore(value: 0)
    let received = Mutex<(GuardianPaneHandle, UInt64, Data)?>(nil)
    let connection = try GuardianWorkerConnection(
      channel: .connect(endpoint: endpoint, queue: queue),
      workspace: workspace,
      token: token,
      peerRequirement: nil,
      handlers: .init(
        ready: { _ in ready.signal() },
        output: { pane, sequence, data in
          received.withLock { $0 = (pane, sequence, data) }
          output.signal()
        },
        inputReleased: { _, _ in },
        exited: { _, _, _ in },
        progress: { complete in paneQueue.async(execute: complete) },
        closed: { _ in closed.signal() }
      )
    )
    defer { queue.sync { connection.close() } }
    #expect(ready.wait(timeout: .now() + 3) == .success)
    // Oversized requests fail before admission and leave sequence 1 usable.
    do {
      _ = try queue.sync {
        try connection.submit(
          .spawn(
            pane: PaneID(),
            launch: LaunchSpec(command: [
              "/usr/bin/true",
              String(repeating: "x", count: GuardianWire.commandRecordLimit),
            ]),
            columns: 80,
            rows: 24
          )
        ) { _ in Issue.record("oversized command got a result") }
      }
      Issue.record("oversized command was admitted")
    } catch let error as MuxError { #expect(error.code == .resourceLimit) }
    let id = PaneID()
    let result = Mutex<Result<GuardianResult, MuxError>?>(nil)
    let completed = DispatchSemaphore(value: 0)
    let program = """
      import os,tty,time
      tty.setraw(0)
      os.write(1,b'READY')
      assert os.read(0,1)==b'!'
      os.write(1,b'DONE')
      time.sleep(60)
      """
    try queue.sync { () throws -> Void in
      #expect(
        try connection.submit(
          .spawn(
            pane: id,
            launch: LaunchSpec(command: ["/usr/bin/python3", "-c", program]),
            columns: 80,
            rows: 24
          )
        ) { value in
          result.withLock { $0 = value }
          completed.signal()
        }
      )
      // This request must remain with the caller, consuming no sequence.
      #expect(
        try !connection.submit(
          .spawn(
            pane: PaneID(),
            launch: LaunchSpec(command: ["/usr/bin/true"]),
            columns: 80,
            rows: 24
          )
        ) { _ in Issue.record("unadmitted command got a result") }
      )
    }
    #expect(completed.wait(timeout: .now() + 3) == .success)
    let spawned = try #require(result.withLock { $0 }).get()
    guard case let .spawned(pid, process) = spawned else {
      Issue.record("spawn failed: \(spawned)")
      return
    }
    let handle = GuardianPaneHandle(pane: id, process: process)
    #expect(output.wait(timeout: .now() + 3) == .success)
    let first = try #require(received.withLock { $0 })
    #expect(first.2 == Data("READY".utf8))
    queue.sync { connection.acknowledgeOutput(first.0, through: first.1) }

    // More than two complete server result windows proves results retire;
    // no caller-issued retire or synthetic guardian responses are involved.
    for _ in 0 ..< (GuardianWire.commandWindow * 2 + 1) {
      #expect(
        try command(
          connection,
          queue,
          .resize(pane: handle, columns: 100, rows: 30)
        ) == .resized(outputThrough: first.1)
      )
    }
    let gateway = UUID()
    server.replaceGateway(gateway)
    let writer = try server.grantWriter(workspace: workspace, gateway: gateway)
    #expect(
      try command(
        connection,
        queue,
        .input(pane: handle, writer: writer, bytes: Data("!".utf8))
      ) == .admitted(bytes: 1)
    )
    #expect(output.wait(timeout: .now() + 3) == .success)
    let second = try #require(received.withLock { $0 })
    #expect(second.2 == Data("DONE".utf8))
    #expect(second.1 > first.1)
    queue.sync { connection.acknowledgeOutput(second.0, through: second.1) }

    let blocked = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    paneQueue.async {
      blocked.signal();
      release.wait()
    }
    #expect(blocked.wait(timeout: .now() + 3) == .success)
    // The workspace transport still answers commands; only the pane queue
    // stalls. Its pending barrier must prevent automatic health renewal.
    #expect(
      try command(
        connection,
        queue,
        .resize(pane: handle, columns: 90, rows: 25)
      ) == .resized(outputThrough: second.1)
    )
    #expect(closed.wait(timeout: .now() + 3) == .success)
    #expect(server.inventory().first?.available == false)
    #expect(kill(pid, 0) == 0)
    try queue.sync { () throws -> Void in
      #expect(
        try !connection.submit(.end(pane: handle)) { _ in
          Issue.record("closed connection admitted a command")
        }
      )
    }
  }

  private func command(
    _ connection: GuardianWorkerConnection,
    _ queue: DispatchQueue,
    _ command: GuardianCommand
  ) throws -> GuardianResult {
    let result = Mutex<Result<GuardianResult, MuxError>?>(nil)
    let completed = DispatchSemaphore(value: 0)
    try queue.sync { () throws -> Void in
      #expect(
        try connection.submit(command) { value in
          result.withLock { $0 = value }
          completed.signal()
        }
      )
    }
    #expect(completed.wait(timeout: .now() + 3) == .success)
    return try #require(result.withLock { $0 }).get()
  }
}
