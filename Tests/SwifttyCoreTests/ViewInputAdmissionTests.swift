import Dispatch
import SwifttyCore
import Synchronization
import Testing

struct ViewInputAdmissionTests {
  @Test
  func queuedViewInputIsBoundedAndPublicSendRemainsUnbounded() {
    let session = TerminalSession()
    let gate = DispatchSemaphore(value: 0)
    session.queue.async { gate.wait() }
    defer { gate.signal() }
    let writes = Mutex<[[UInt8]]>([])
    session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
    let chunk = Array(repeating: UInt8(65), count: 4096)
    var accepted = 0
    for _ in 0 ..< 100 {
      if !session.submitViewInput(.bytes(chunk)) { break }
      accepted += 1
    }
    #expect(accepted == 16)
    #expect(session.pendingViewInputBytes == 64 * 1024)
    #expect(!session.submitViewInput(.key(KeyEvent(.enter))))
    let publicInput = Array(repeating: UInt8(66), count: 128 * 1024)
    session.send(.bytes(publicInput))
    gate.signal()
    _ = session.snapshot()
    #expect(session.pendingViewInputBytes == 0)
    let output = writes.withLock { $0 }
    #expect(output.count == accepted + 1)
    #expect(output.prefix(accepted).allSatisfy { $0 == chunk })
    #expect(output.last == publicInput)
  }

  @Test
  func presentationViewInputIsBoundedBeforeTheSemanticCallback() {
    let session = TerminalSession(presentationColumns: 20, rows: 4)
    let gate = DispatchSemaphore(value: 0)
    session.queue.async { gate.wait() }
    defer { gate.signal() }
    let received = Mutex<[String]>([])
    session.semanticInputHandler = { input in
      if case let .text(text) = input { received.withLock { $0.append(text) } }
    }
    var accepted: [String] = []
    for i in 0 ..< 100 {
      let text = "\(i):" + String(repeating: "x", count: 1000)
      if !session.submitViewInput(.text(text)) { break }
      accepted.append(text)
    }
    #expect(!accepted.isEmpty && accepted.count < 100)
    #expect(session.pendingViewInputBytes <= 64 * 1024)
    gate.signal()
    _ = session.snapshot()
    #expect(received.withLock { $0 } == accepted)
    #expect(session.pendingViewInputBytes == 0)
  }

  #if os(macOS)
  @Test
  func blockedPTYKeepsViewCreditUntilWrittenOrTornDown() throws {
    let session = TerminalSession()
    defer { session.stop() }
    let ready = DispatchSemaphore(value: 0)
    session.onProgramOutput = { _ in ready.signal() }
    try session.start(
      SessionConfiguration(command: [
        "/bin/sh", "-c", "stty raw -echo; printf ready; exec sleep 20",
      ])
    )
    try #require(ready.wait(timeout: .now() + .seconds(5)) == .success)
    let chunk = Array(repeating: UInt8(65), count: 4096)
    var refused = false
    for _ in 0 ..< 256 {
      if !session.submitViewInput(.bytes(chunk)) {
        refused = true
        break
      }
      // Drain the encoder queue: refusal must be caused by PTY pressure,
      // not merely by pending closures that have not encoded their input.
      _ = session.snapshot()
    }
    #expect(refused)
    #expect(session.pendingViewInputBytes > 0)
    #expect(session.pendingViewInputBytes <= 64 * 1024)
    session.stop()
    #expect(session.pendingViewInputBytes == 0)
    #expect(session.submitViewInput(.bytes([66])))
    _ = session.snapshot()
    #expect(session.pendingViewInputBytes == 0)
  }
  #endif
}
