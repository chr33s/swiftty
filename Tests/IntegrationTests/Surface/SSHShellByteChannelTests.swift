import Dispatch
import SSHClient
import Synchronization
@testable import RoamingKit
@testable import TerminalSurface
import Testing

struct SSHShellByteChannelTests {
  @Test(arguments: [false, true])
  func repeatedExitMetadataRetainsOneReasonBeforeStart(signaled: Bool) {
    let adapter = SSHShellByteChannel()
    let received = Mutex(Received())
    adapter.receive(.output([0]))
    for code in 0 ..< 10_000 {
      adapter.receive(.exitStatus(code))
      adapter.receive(.exitSignal("TERM"))
    }
    adapter.receive(signaled ? .exitSignal("HUP") : .exitStatus(23))
    #expect(adapter.pendingEventCount == 1)
    adapter.receive(.output([1]))
    adapter.receive(.closed)
    adapter.receive(.exitStatus(42))
    #expect(adapter.pendingEventCount == 3)
    adapter.start(
      TerminalChannelHandler(
        onOutput: { bytes in
          received.withLock { $0.order.append("output \(bytes[0])") }
        },
        onExit: { exit in
          received.withLock {
            $0.exits.append(exit);
            $0.order.append("exit")
          }
        }
      )
    )
    #expect(received.withLock { $0.order } == ["output 0", "output 1", "exit"])
    #expect(
      received.withLock { $0.exits } == [
        signaled ? .signaled("HUP") : .exited(23)
      ]
    )
    #expect(adapter.pendingEventCount == 0)
  }

  private struct Received {
    var order: [String] = []
    var exits: [TerminalChannelExit] = []
  }

  @Test(arguments: [false, true])
  func `close waits for buffered output and exit status during handler handoff`(
    signaled: Bool
  ) throws {
    let adapter = SSHShellByteChannel()
    let received = Mutex(Received())
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    defer { release.signal() }
    adapter.receive(.output([0]))
    adapter.receive(signaled ? .exitSignal("TERM") : .exitStatus(7))
    adapter.receive(.output([1]))
    DispatchQueue.global()
      .async {
        adapter.start(
          TerminalChannelHandler(
            onOutput: { bytes in
              if bytes == [0] {
                received.withLock { $0.order.append("first output begins") }
                entered.signal()
                #expect(release.wait(timeout: .now() + 5) == .success)
                received.withLock { $0.order.append("first output ends") }
              } else {
                received.withLock { $0.order.append("output \(bytes[0])") }
              }
            },
            onExit: { exit in
              received.withLock {
                $0.exits.append(exit)
                $0.order.append("exit")
              }
            }
          )
        )
        finished.signal()
      }
    try #require(entered.wait(timeout: .now() + 5) == .success)
    adapter.receive(.closed)
    // Neither terminal callbacks nor late output may overtake the blocked
    // callback and the buffered exit status.
    adapter.receive(.output([2]))
    adapter.receive(.exitStatus(42))
    adapter.receive(.closed)
    #expect(received.withLock { $0.order } == ["first output begins"])
    release.signal()
    try #require(finished.wait(timeout: .now() + 5) == .success)
    let result = received.withLock { $0 }
    #expect(
      result.order == [
        "first output begins", "first output ends", "output 1", "exit",
      ]
    )
    #expect(result.exits == [signaled ? .signaled("TERM") : .exited(7)])
  }

  @Test
  func `already closed shell retains its exit status until start`() {
    let adapter = SSHShellByteChannel()
    let exits = Mutex<[TerminalChannelExit]>([])
    adapter.receive(.exitStatus(23))
    adapter.receive(.closed)
    adapter.start(
      TerminalChannelHandler(
        onOutput: { _ in Issue.record("unexpected output") },
        onExit: { exit in exits.withLock { $0.append(exit) } }
      )
    )
    #expect(exits.withLock { $0 } == [.exited(23)])
  }

  @Test
  func `callbacks can reenter without overtaking the current output`() {
    let adapter = SSHShellByteChannel()
    let received = Mutex(Received())
    adapter.start(
      TerminalChannelHandler(
        onOutput: { bytes in
          received.withLock { $0.order.append("output \(bytes[0]) begins") }
          if bytes == [0] {
            adapter.receive(.output([1]))
            adapter.receive(.exitStatus(9))
            adapter.receive(.closed)
          }
          received.withLock { $0.order.append("output \(bytes[0]) ends") }
        },
        onExit: { exit in
          received.withLock {
            $0.exits.append(exit)
            $0.order.append("exit")
          }
        }
      )
    )
    adapter.receive(.output([0]))
    let result = received.withLock { $0 }
    #expect(
      result.order == [
        "output 0 begins", "output 0 ends", "output 1 begins", "output 1 ends",
        "exit",
      ]
    )
    #expect(result.exits == [.exited(9)])
  }

  @Test
  func `zero credit shell exit reaches the adapter over SSH`() async throws {
    let server = try await TestSSHServer.start()
    server.state.shellExitStatus.withLock { $0 = 31 }
    var connection: SSHConnection?
    var adapter: SSHShellByteChannel?
    do {
      let openedConnection = try await server.connect()
      connection = openedConnection
      let openedAdapter = try await SSHShellByteChannel.open(
        on: openedConnection,
        columns: 80,
        rows: 24
      )
      adapter = openedAdapter
      let exits = Mutex<[TerminalChannelExit]>([])
      openedAdapter.start(
        TerminalChannelHandler(
          onOutput: { _ in Issue.record("unexpected output") },
          onExit: { exit in exits.withLock { $0.append(exit) } }
        )
      )
      try #require(try await waitUntil { exits.withLock { !$0.isEmpty } })
      #expect(exits.withLock { $0 } == [.exited(31)])
    } catch {
      await adapter?.close()
      await connection?.close()
      await server.shutdown()
      throw error
    }
    await adapter?.close()
    await connection?.close()
    await server.shutdown()
  }
}
