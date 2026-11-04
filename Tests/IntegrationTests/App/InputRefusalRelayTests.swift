import Dispatch
import Foundation
@testable import RoamingApp
import TerminalSurface
import Testing

extension MainActorIntegrationTests {
  @MainActor
  @Suite(.timeLimit(.minutes(1)))
  struct InputRefusalRelayTests {
    @Test
    func burstKeepsOnePendingUpdateWithLatestReason() async throws {
      var received: [InputRefusal] = []
      let relay = InputRefusalRelay { received.append($0) }
      for _ in 0 ..< 10000 { relay.report(.backpressure) }
      relay.report(.invalid)
      #expect(received.isEmpty)
      #expect(try await eventually { received == [.invalid] })
      await drainMainQueue()
      #expect(received == [.invalid])
      relay.close()
    }

    @Test
    func closeDiscardsPendingAndFutureUpdates() async {
      var received: [InputRefusal] = []
      let relay = InputRefusalRelay { received.append($0) }
      relay.report(.backpressure)
      relay.close()
      relay.report(.invalid)
      await drainMainQueue()
      #expect(received.isEmpty)
    }

    @Test
    func receiverCanReportAnotherRefusal() async throws {
      var received: [InputRefusal] = []
      var relay: InputRefusalRelay?
      relay = InputRefusalRelay { refusal in
        received.append(refusal)
        if refusal == .backpressure { relay?.report(.invalid) }
      }
      relay?.report(.backpressure)
      #expect(try await eventually { received == [.backpressure, .invalid] })
      relay?.close()
      relay = nil
    }

    @Test
    func pendingUpdateDoesNotRetainRelay() async {
      var received: [InputRefusal] = []
      var relay: InputRefusalRelay? = InputRefusalRelay { received.append($0) }
      weak let weakRelay = relay
      relay?.report(.backpressure)
      relay = nil
      #expect(weakRelay == nil)
      await drainMainQueue()
      #expect(received.isEmpty)
    }

    private func drainMainQueue() async {
      await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
      }
    }

    private func eventually(_ condition: () -> Bool) async throws -> Bool {
      let deadline = ContinuousClock.now + .seconds(2)
      while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try await Task.sleep(for: .milliseconds(5))
      }
      return true
    }
  }
}
