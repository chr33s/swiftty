import Dispatch
import Foundation
import SwiftMuxProtocol
import Synchronization
import Testing

struct SMXOwnershipTests {
  private final class ReleaseProbe: Sendable {}

  private func observe(_ condition: () -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    return condition()
  }

  @Test
  func releasingChannelClosesItsNativePeer() async throws {
    let queue = DispatchQueue(label: "smx-ownership-channel")
    let listener = SMXListener(anonymousOn: queue)
    defer { listener.cancel() }
    let server = Mutex<SMXChannel?>(nil)
    let received = Mutex(false)
    let closed = Mutex(false)
    defer { server.withLock { $0?.cancel() } }
    listener.activate(connectionQueue: queue) { channel in
      server.withLock { $0 = channel }
      channel.activate { event in
        switch event {
        case .message: received.withLock { $0 = true }
        case .closed: closed.withLock { $0 = true }
        }
      }
    }
    var client: SMXChannel? = SMXChannel.connect(
      endpoint: listener.endpoint,
      queue: queue,
    )
    defer { client?.cancel() }
    weak let weakClient = client
    client?.activate { _ in }
    client?.send(Data([1]))
    try #require(await observe { received.withLock { $0 } })
    client = nil
    #expect(weakClient == nil)
    #expect(try await observe { closed.withLock { $0 } })
  }

  @Test
  func releasingListenerReleasesItsNativeAcceptHandler() async throws {
    let queue = DispatchQueue(label: "smx-ownership-listener")
    var probe: ReleaseProbe? = ReleaseProbe()
    weak let weakProbe = probe
    var listener: SMXListener? = SMXListener(anonymousOn: queue)
    defer { listener?.cancel() }
    listener?
      .activate(connectionQueue: queue) { [probe = probe!] channel in
        withExtendedLifetime(probe) { channel.cancel() }
      }
    probe = nil
    #expect(weakProbe != nil)
    listener = nil
    #expect(try await observe { weakProbe == nil })
  }
}
