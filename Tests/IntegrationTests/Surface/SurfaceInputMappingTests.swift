import SessionCore
import Synchronization
import SwifttyCore
import Testing

@testable import RoamingKit
@testable import TerminalSurface

struct SurfaceInputMappingTests {
  @Test
  func `special keys map one to one with their modifiers`() {
    let pairs: [(Key, SemanticKeyName)] = [
      (.enter, .enter), (.tab, .tab), (.backspace, .backspace),
      (.escape, .escape), (.up, .up), (.down, .down), (.left, .left),
      (.right, .right), (.home, .home), (.end, .end), (.pageUp, .pageUp),
      (.pageDown, .pageDown), (.insert, .insert), (.delete, .delete),
      (.function(1), .function(1)), (.function(12), .function(12)),
    ]
    for (key, name) in pairs {
      #expect(SemanticKey(KeyEvent(key)) == SemanticKey(name))
    }
    #expect(
      SemanticKey(KeyEvent(.up, modifiers: [.shift, .alt, .control]))
        == SemanticKey(.up, modifiers: [.shift, .alt, .control])
    )
  }

  @Test
  func `character keys keep their scalar and modifiers`() {
    #expect(
      SemanticKey(KeyEvent(.character("c"), modifiers: .control))
        == SemanticKey(.character("c"), modifiers: .control)
    )
    #expect(
      SemanticKey(KeyEvent(.character("é"))) == SemanticKey(.character("é"))
    )
  }

  @Test
  func `repeats map like presses and releases are dropped`() {
    #expect(SemanticKey(KeyEvent(.left, action: .repeat)) == SemanticKey(.left))
    #expect(SemanticKey(KeyEvent(.left, action: .release)) == nil)
  }

  @Test
  func `command shortcuts and unrepresentable keys never become remote input`()
  {
    #expect(SemanticKey(KeyEvent(.character("v"), modifiers: .command)) == nil)
    #expect(
      SemanticKey(KeyEvent(.enter, modifiers: [.command, .shift])) == nil
    )
    #expect(SemanticKey(KeyEvent(.function(13))) == nil)
    #expect(SemanticKey(KeyEvent(.function(0))) == nil)
    #expect(SemanticKey(KeyEvent(.character("\u{1B}"))) == nil)
    #expect(SemanticKey(KeyEvent(.character("\u{7F}"))) == nil)
    #expect(SemanticKey(KeyEvent(.character("\u{85}"))) == nil)
  }

  @Test
  func `mapped keys round-trip through the wire spelling`() throws {
    let key = try #require(SemanticKey(KeyEvent(.function(5), modifiers: .alt)))
    #expect(SemanticKeyName(wireName: key.name.wireName) == key.name)
    let operation = SurfaceInput.key(key).operation
    #expect(throws: Never.self) { try operation.validate() }
  }

  @Test
  func `terminal input maps to surface input`() {
    #expect(SurfaceInput(TerminalInput.text("ls")) == .text("ls"))
    #expect(SurfaceInput(TerminalInput.paste("a\nb")) == .paste("a\nb"))
    #expect(
      SurfaceInput(TerminalInput.key(KeyEvent(.enter)))
        == .key(SemanticKey(.enter))
    )
    #expect(SurfaceInput(TerminalInput.text("")) == nil)
    #expect(SurfaceInput(TerminalInput.paste("")) == nil)
    #expect(SurfaceInput(TerminalInput.focus(true)) == nil)
    #expect(SurfaceInput(TerminalInput.bytes([0x1B])) == nil)
    #expect(
      SurfaceInput(
        TerminalInput.key(KeyEvent(.character("q"), modifiers: .command))
      ) == nil
    )
  }
}

struct OrderedInputPumpTests {
  final class Log: Sendable {
    let submitted = Mutex<[SurfaceInput]>([])
    let results = Mutex<[SurfaceInputResult]>([])
  }

  @Test(arguments: [false, true])
  func invalidPayloadIsRefusedBeforeQueueRetention(paste: Bool) async {
    let log = Log()
    let gate = Mutex(false)
    let entered = Mutex(false)
    let pump = OrderedInputPump(
      limit: 2,
      submit: { input in
        entered.withLock { $0 = true }
        while !gate.withLock({ $0 }) {
          try? await Task.sleep(for: .milliseconds(1))
        }
        log.submitted.withLock { $0.append(input) }
        return .accepted(sequence: nil)
      },
      onResult: { _, result in log.results.withLock { $0.append(result) } }
    )
    defer {
      gate.withLock { $0 = true };
      pump.close()
    }
    #expect(pump.enqueue(.text("first")))
    #expect(await eventually { entered.withLock { $0 } })
    let oversized = String(
      repeating: "🙂",
      count: RSTLimits.maxPasteBytes / 4 + 1
    )
    #expect(!pump.enqueue(paste ? .paste(oversized) : .text(oversized)))
    #expect(pump.queuedCount == 0)
    #expect(log.results.withLock { $0 } == [.refused(.invalid)])
    let boundary = String(repeating: "🙂", count: RSTLimits.maxPasteBytes / 4)
    #expect(pump.enqueue(paste ? .paste(boundary) : .text(boundary)))
    #expect(pump.enqueue(.text("last")))
    #expect(!pump.enqueue(.text(oversized)))
    #expect(log.results.withLock { $0.last } == .refused(.backpressure))
    pump.close()
    #expect(!pump.enqueue(.text(oversized)))
    #expect(log.results.withLock { $0.last } == .refused(.closed))
    gate.withLock { $0 = true }
    #expect(
      await eventually { log.submitted.withLock { $0 } == [.text("first")] }
    )
    #expect(await eventually { log.results.withLock { $0.count } == 6 })
  }

  @Test
  func `input is submitted serially in arrival order`() async {
    let log = Log()
    let pump = OrderedInputPump(submit: { input in
      // Uneven latency would reorder per-key tasks.
      if case .text(let text) = input, Int(text)! % 3 == 0 {
        try? await Task.sleep(for: .milliseconds(2))
      }
      log.submitted.withLock { $0.append(input) }
      return .accepted(sequence: nil)
    })
    let expected = (0 ..< 50).map { SurfaceInput.text(String($0)) }
    for input in expected { #expect(pump.enqueue(input)) }
    #expect(await eventually { log.submitted.withLock { $0.count } == 50 })
    #expect(log.submitted.withLock { $0 } == expected)
  }

  @Test
  func `a full or closed pump refuses and reports instead of queueing`() async {
    let log = Log()
    let gate = Mutex(false)
    let pump = OrderedInputPump(
      limit: 2,
      submit: { _ in
        while !gate.withLock({ $0 }) {
          try? await Task.sleep(for: .milliseconds(1))
        }
        return .accepted(sequence: nil)
      },
      onResult: { _, result in log.results.withLock { $0.append(result) } }
    )
    #expect(pump.enqueue(.text("a")))
    // Wait for the first to be taken by the drain, then fill the queue.
    #expect(await eventually { pump.queuedCount == 0 })
    #expect(pump.enqueue(.text("b")))
    #expect(pump.enqueue(.text("c")))
    #expect(!pump.enqueue(.text("d")))
    #expect(log.results.withLock { $0 } == [.refused(.backpressure)])
    pump.close()
    #expect(!pump.enqueue(.text("e")))
    gate.withLock { $0 = true }
    #expect(await eventually { log.results.withLock { $0.count } == 5 })
    let results = log.results.withLock { $0 }
    #expect(results.filter { $0 == .refused(.closed) }.count == 3)
    #expect(results.filter(\.isAccepted).count == 1)
  }
}
