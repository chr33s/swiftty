import SessionCore
import SwifttyCore
import Synchronization
import TerminalSurface
import Testing

@Suite(.timeLimit(.minutes(1)))
struct SSHReplyBackpressureTests {
  private actor Gate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
      guard !released else { return }
      await withCheckedContinuation { waiter = $0 }
    }

    func release() {
      released = true
      waiter?.resume()
      waiter = nil
    }
  }

  private final class Channel: TerminalByteChannel {
    let base = FakeByteChannel()
    let gate = Gate()
    let operations = Mutex<[String]>([])
    let entered = Mutex(false)

    func start(_ handler: TerminalChannelHandler) { base.start(handler) }

    func grantCredit(_ count: Int) { base.grantCredit(count) }

    func close() async {
      await base.close()
      await gate.release()
    }

    func write(_ bytes: [UInt8]) async throws {
      entered.withLock { $0 = true }
      await gate.wait()
      operations.withLock { $0.append(String(decoding: bytes, as: UTF8.self)) }
      try await base.write(bytes)
    }

    func resize(columns: Int, rows: Int) async throws {
      entered.withLock { $0 = true }
      await gate.wait()
      operations.withLock { $0.append("resize \(columns)x\(rows)") }
      try await base.resize(columns: columns, rows: rows)
    }
  }

  @Test
  func stalledQueryRepliesWithholdReadCreditAndResumeWithoutLoss() async {
    let session = TerminalSession(columns: 20, rows: 4)
    let channel = Channel()
    let backend = SSHStreamBackend(
      channel: channel,
      session: session,
      outputWindow: 16,
      writeLimit: 16,
    )
    backend.start()
    for _ in 0 ..< 64 { channel.base.feed(Array("\u{1B}[6n".utf8)) }
    #expect(await eventually { backend.unparsedBytes == 0 })
    #expect(channel.base.delivered <= 32)
    #expect(await backend.submit(.text("x")) == .refused(.backpressure))
    await channel.gate.release()
    #expect(await eventually { channel.base.delivered == 256 })
    let expected = Array(String(repeating: "\u{1B}[1;1R", count: 64).utf8)
    #expect(await eventually { channel.base.written == expected })
    #expect(await backend.submit(.text("x")) == .accepted(sequence: nil))
    #expect(
      await eventually {
        channel.base.written == expected + [UInt8(ascii: "x")]
      }
    )
    await backend.close()
  }

  /// The cell size reaches the remote PTY in `window-change`, so remote
  /// programs that size images by pixels (`kitten icat`) work over SSH.
  @Test
  func cellSizeChangesSendWindowChangeWithPixels() async {
    let session = TerminalSession(columns: 20, rows: 4)
    let channel = FakeByteChannel()
    let backend = SSHStreamBackend(channel: channel, session: session)
    backend.start()
    session.setCellPixelSize(width: 9, height: 18)
    #expect(
      await eventually {
        channel.pixelSizes.last.map { $0 == (180, 72) } ?? false
      }
    )
    #expect(
      channel.resizes.last.map { ($0.columns, $0.rows) == (20, 4) } ?? false
    )
  }

  @Test
  func adjacentResizesCoalesceWhileWritesPreserveOrdering() async {
    let session = TerminalSession(columns: 20, rows: 4)
    let channel = Channel()
    let backend = SSHStreamBackend(channel: channel, session: session)
    backend.start()
    #expect(await backend.submit(.text("a")) == .accepted(sequence: nil))
    #expect(await eventually { channel.entered.withLock { $0 } })
    for columns in 21 ... 100 {
      await backend.proposeGrid(columns: columns, rows: 4, )
    }
    #expect(await backend.submit(.text("b")) == .accepted(sequence: nil))
    for columns in 101 ... 180 {
      await backend.proposeGrid(columns: columns, rows: 4, )
    }
    session.withState { _ in }
    await channel.gate.release()
    #expect(
      await eventually {
        channel.base.written == Array("ab".utf8)
          && channel.base.resizes.last?.columns == 180
      }
    )
    #expect(
      channel.operations.withLock { $0 } == [
        "a", "resize 100x4", "b", "resize 180x4",
      ]
    )
    await backend.close()
  }

  @Test
  func closeDoesNotReturnWithheldReadCredit() async {
    let session = TerminalSession(columns: 20, rows: 4)
    let channel = Channel()
    let backend = SSHStreamBackend(
      channel: channel,
      session: session,
      outputWindow: 16,
      writeLimit: 16,
    )
    backend.start()
    for _ in 0 ..< 64 { channel.base.feed(Array("\u{1B}[6n".utf8)) }
    #expect(await eventually { backend.unparsedBytes == 0 })
    let delivered = channel.base.delivered
    #expect(delivered <= 32)
    await backend.close()
    session.withState { _ in }
    #expect(channel.base.delivered == delivered)
    #expect(await backend.submit(.text("x")) == .refused(.closed))
  }
}
