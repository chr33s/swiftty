import Darwin
import Dispatch
import Foundation
import SwiftMuxGateway
@testable import SwiftMuxGuardian
import SwiftMuxProtocol
import SwiftMuxXPC
import Synchronization
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct NativeRelayTests {
  @Test
  func sharedAdmissionRemainsBoundedAcrossConcurrentListeners() throws {
    let admission = try GatewayNativeAdmission(limit: 4)
    let retained = Mutex<[GatewayNativeAdmission.Permit]>([])
    DispatchQueue.concurrentPerform(iterations: 128) { _ in
      if let permit = admission.acquire() {
        retained.withLock { $0.append(permit) }
      }
    }
    #expect(admission.count == 4)
    #expect(retained.withLock { $0.count } == 4)
    retained.withLock { $0.removeAll() }
    #expect(admission.count == 0)
    let next = admission.acquire()
    #expect(next != nil)
    withExtendedLifetime(next) { #expect(admission.count == 1) }
  }

  @Test
  func layeredPeerPolicyCannotReassignOrWeakenXPCRequirement() {
    let queue = DispatchQueue(label: "relay-signing-policy-test")
    let listener = SMXListener(anonymousOn: queue)
    listener.activate(connectionQueue: queue) { $0.cancel() }
    let channel = SMXChannel.connect(endpoint: listener.endpoint, queue: queue)
    defer {
      channel.cancel();
      listener.cancel()
    }
    let requirement = "identifier \"com.chr33s.swiftty.policy-test\""
    #expect(channel.requirePeer(codeSigning: requirement))
    #expect(channel.requirePeer(codeSigning: requirement))
    #expect(!channel.requirePeer(codeSigning: "anchor apple"))
    channel.activate { _ in }
    #expect(channel.requirePeer(codeSigning: requirement))
    #expect(!channel.requirePeer(codeSigning: "anchor apple"))
  }

  @Test
  func requestWindowCannotBeOverwrittenOrRetiredBeforeReply() throws {
    let workerQueue = DispatchQueue(label: "relay-worker-test")
    let relayQueue = DispatchQueue(label: "relay-router-test")
    let clientQueue = DispatchQueue(label: "relay-client-test")
    let workerListener = SMXListener(anonymousOn: workerQueue)
    let relayListener = SMXListener(anonymousOn: relayQueue)
    let worker = Mutex<SMXChannel?>(nil)
    let relay = Mutex<GatewayNativeRelay?>(nil)
    let requests = Mutex<[UInt64]>([])
    let replies = Mutex<[ServerMessage]>([])
    let ready = DispatchSemaphore(value: 0)
    let response = DispatchSemaphore(value: 0)
    let forwarded = DispatchSemaphore(value: 0)
    let ended = DispatchSemaphore(value: 0)
    let instance = ServerInstanceID()
    workerListener.activate(connectionQueue: workerQueue) { channel in
      worker.withLock { $0 = channel }
      channel.activate { event in
        guard case let .message(data) = event,
          let message = try? SMXCodec.decode(
            ClientMessage.self,
            from: data,
            limit: 1 << 20
          )
        else { return }
        switch message {
        case let .hello(hello):
          channel.send(
            try! SMXCodec.encode(
              ServerMessage.welcome(
                Welcome(
                  protocolVersion: SMX.protocolVersion,
                  build: SMX.build,
                  server: instance,
                  acceptedProfile: nil,
                  limits: .standard,
                  innerTerm: SMX.fallbackInnerTerm,
                  forwardedTransport: hello.forwardedTransport
                )
              ),
              limit: 1 << 20
            )
          )
        case let .request(id, _):
          requests.withLock { $0.append(id) };
          forwarded.signal()
        default: break
        }
      }
    }
    let endpoint = GuardianWorkerEndpoint(
      authority: GuardianAuthority(
        incarnation: UUID(),
        workspace: WorkspaceID(),
        generation: 1
      ),
      instance: instance,
      pid: getpid(),
      endpoint: workerListener.endpoint
    )
    relayListener.activate(connectionQueue: relayQueue) { channel in
      do {
        let value = try GatewayNativeRelay(
          frontend: channel,
          worker: endpoint,
          peerRequirement: nil,
          closed: { _ in ended.signal() }
        )
        relay.withLock { $0 = value }
      } catch { channel.cancel() }
    }
    let frontend = SMXChannel.connect(
      endpoint: relayListener.endpoint,
      queue: clientQueue
    )
    frontend.activate { event in
      guard case let .message(data) = event,
        let message = try? SMXCodec.decode(
          ServerMessage.self,
          from: data,
          limit: 1 << 20
        )
      else { return }
      if case .welcome = message {
        ready.signal()
      } else {
        replies.withLock { $0.append(message) };
        response.signal()
      }
    }
    defer {
      frontend.cancel()
      relayQueue.sync { relay.withLock { $0 }?.close() }
      worker.withLock { $0 }?.cancel()
      workerListener.cancel()
      relayListener.cancel()
    }
    func send(_ message: ClientMessage) throws {
      frontend.send(try SMXCodec.encode(message, limit: 1 << 20))
    }
    try send(.hello(Hello(frontend: .native)))
    #expect(ready.wait(timeout: .now() + 3) == .success)
    try send(.request(id: 900, command: .subscribeInbox(true)))
    #expect(response.wait(timeout: .now() + 3) == .success)
    guard
      case let .reply(900, .failure(unsupported)) = try #require(
        replies.withLock { $0.first }
      )
    else {
      throw MuxError(.invalidRequest, "legacy worker inbox was not refused")
    }
    #expect(unsupported.code == .incompatibleVersion)
    #expect(requests.withLock { $0.isEmpty })
    replies.withLock { $0.removeAll() }
    for id in 1 ... 65 { try send(.request(id: UInt64(id), command: .status)) }
    for _ in 0 ..< 64 {
      #expect(forwarded.wait(timeout: .now() + 3) == .success)
    }
    #expect(response.wait(timeout: .now() + 3) == .success)
    guard
      case let .reply(65, .failure(error)) = try #require(
        replies.withLock { $0.first }
      )
    else { throw MuxError(.invalidRequest, "missing capacity refusal") }
    #expect(error.code == .resourceLimit)
    #expect(requests.withLock { $0.count } == 64)
    worker.withLock { $0 }?
      .send(
        try SMXCodec.encode(
          ServerMessage.reply(id: 1, result: .success(.ok)),
          limit: 4096
        )
      )
    #expect(response.wait(timeout: .now() + 3) == .success)
    try send(.request(id: 66, command: .status))
    #expect(forwarded.wait(timeout: .now() + 3) == .success)
    #expect(requests.withLock { $0.last } == 66)
    try send(.request(id: 66, command: .status))
    #expect(ended.wait(timeout: .now() + 3) == .success)
  }
}
