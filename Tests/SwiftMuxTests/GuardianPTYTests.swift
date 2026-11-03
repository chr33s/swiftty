import Darwin
import Dispatch
import Foundation
import SwiftMuxGuardian
import SwiftMuxProtocol
import Synchronization
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct GuardianPTYTests {
  @Test
  func guardianRetainsChildAndBackpressuresWithoutAReadyConsumer() throws {
    let queue = DispatchQueue(label: "guardian-pty-test")
    let observations = Observations()
    let paused = DispatchSemaphore(value: 0)
    let payload = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let count = 128 << 10
    let process = GuardianPTY(
      id: PaneID(),
      workspace: WorkspaceID(),
      queue: queue,
      limits: .standard
    )
    let launcher = try PaneLauncher(
      launcherPath: launcherPath(),
      innerTerm: SMX.fallbackInnerTerm
    )
    try queue.sync {
      #expect(process.resize(columns: 80, rows: 24) == EBADF)
      process.canConsume = { observations.ready.withLock { $0 } }
      process.consume = { bytes in
        let total = observations.output.withLock { data in
          data.append(contentsOf: bytes)
          return data.count
        }
        if total >= count { payload.signal() }
        return bytes.count
      }
      process.onBatch = {
        if !observations.ready.withLock({ $0 }) { paused.signal() }
      }
      process.onInputReleased = { bytes in
        observations.released.withLock { $0 += bytes }
      }
      process.onFinished = { status, _ in
        observations.finalStatus.withLock { $0 = status }
        finished.signal()
      }
      // A real process blocks on its PTY while the consumer is unavailable.
      // There is no terminal engine or service in this fixture.
      let program = """
        import os,tty
        tty.setraw(0)
        data=b'x'*\(count)
        while data: data=data[os.write(1,data):]
        assert os.read(0,1)==b'!'
        os.write(1,b'FINAL')
        os._exit(7)
        """
      try process.launch(
        LaunchSpec(command: ["/usr/bin/python3", "-c", program]),
        launcher: launcher,
        columns: 80,
        rows: 24
      )
    }
    defer {
      process.terminate()
      _ = finished.wait(timeout: .now() + 7)
    }
    #expect(paused.wait(timeout: .now() + 5) == .success)
    #expect(observations.output.withLock { $0.isEmpty })
    let originalPID = process.pid
    #expect(originalPID > 0 && kill(originalPID, 0) == 0)
    queue.sync {
      #expect(process.resize(columns: 100, rows: 30) == 0)
      observations.ready.withLock { $0 = true }
      // Retry the suspended read after consumer credit returns.
      process.flush()
    }
    #expect(payload.wait(timeout: .now() + 5) == .success)
    #expect(process.pid == originalPID)
    queue.sync {
      process.appendInput([0x21])
      process.flush()
    }
    #expect(finished.wait(timeout: .now() + 5) == .success)
    #expect(observations.finalStatus.withLock { $0 } == 7)
    #expect(observations.released.withLock { $0 } == 1)
    #expect(
      observations.output.withLock { $0 } == Array(
        repeating: UInt8(0x78),
        count: count
      ) + Array("FINAL".utf8)
    )
  }
  private final class Observations: Sendable {
    let ready = Mutex(false)
    let output = Mutex<[UInt8]>([])
    let released = Mutex(0)
    let finalStatus = Mutex<Int32?>(nil)
  }

}
