import Darwin
import Dispatch
import Foundation
import SwiftMuxGuardian
import SwiftMuxProtocol
import SwiftMuxXPC

/// A gateway-owned native listener for one selected workspace authority.
/// Endpoint possession is not authorization. Every frontend is authenticated and
/// resolves the current worker through the guardian before its relay is admitted.
/// Sendable: admissions and live relays are touched only on `queue`.
package final class GatewayNativeEndpoint: @unchecked Sendable {
  private struct Admission {
    let channel: SMXChannel
    let task: Task<Void, Never>
    let permit: GatewayNativeAdmission.Permit
  }

  private struct Live {
    let relay: GatewayNativeRelay
    let permit: GatewayNativeAdmission.Permit
  }

  private let queue = DispatchQueue(label: "swiftmux.gateway.native-endpoint")
  private let listener: SMXListener
  private let supervisor: GatewaySupervisor
  private var authority: GuardianAuthority
  private let peerRequirement: String?
  private let capacity: Int
  private let admission: GatewayNativeAdmission
  // Confined to queue, including relay callbacks.
  private var pending: [UUID: Admission] = [:]
  private var relays: [UUID: Live] = [:]
  private var closed = false

  package init(
    supervisor: GatewaySupervisor,
    authority: GuardianAuthority,
    peerRequirement: String?,
    capacity: Int = 64,
    admission: GatewayNativeAdmission? = nil
  ) throws {
    guard capacity > 0, capacity <= 256 else {
      throw MuxError(.invalidRequest, "invalid native endpoint capacity")
    }
    self.supervisor = supervisor
    self.authority = authority
    self.peerRequirement = peerRequirement
    self.capacity = capacity
    self.admission = try admission ?? GatewayNativeAdmission(limit: capacity)
    listener = SMXListener(anonymousOn: queue)
    listener.activate(connectionQueue: queue) { [weak self] channel in
      guard let self else {
        channel.cancel()
        return
      }
      self.accept(channel)
    }
  }

  package var endpoint: SMXEndpoint { listener.endpoint }

  package var connectionCount: Int {
    get async {
      await withCheckedContinuation { continuation in
        queue.async {
          continuation.resume(returning: self.pending.count + self.relays.count)
        }
      }
    }
  }

  // Relay deinitialization cancels its channels without invoking callbacks.
  deinit {
    listener.cancel()
    for admission in pending.values {
      admission.task.cancel()
      admission.channel.cancel()
    }
  }

  /// Completes after all channels have been cancelled on their owning queue.
  /// No End or writer grant is issued by this listener.
  package func close() async {
    await withCheckedContinuation { continuation in
      queue.async {
        self.finish()
        continuation.resume()
      }
    }
  }

  // Returning releases the local admission/relay snapshots before close resumes.
  private func finish() {
    closed = true
    listener.cancel()
    let admissions = pending.values
    pending.removeAll()
    for admission in admissions {
      admission.task.cancel()
      admission.channel.cancel()
    }
    let liveRelays = Array(relays.values)
    relays.removeAll()
    for live in liveRelays { live.relay.close() }
  }

  /// A planned replacement released this listener's workspace to `next`.
  /// New frontends resolve the candidate; live relays continue on it.
  package func rebind(to next: GuardianAuthority) {
    queue.async { [self] in
      guard !closed, next.workspace == authority.workspace,
        next.generation > authority.generation
      else { return }
      authority = next
      let live = relays.values.map(\.relay)
      guard !live.isEmpty else { return }
      let supervisor = supervisor
      Task { [weak self] in
        // The candidate publishes its endpoint just after release.
        let deadline = ContinuousClock.now + .seconds(10)
        var endpoint: GuardianWorkerEndpoint?
        while endpoint == nil, ContinuousClock.now < deadline {
          endpoint = try? await supervisor.workerEndpoint(next)
          if endpoint == nil { try? await Task.sleep(for: .milliseconds(20)) }
        }
        guard let self else { return }
        self.queue.async {
          for relay in live {
            if let endpoint {
              relay.rebind(to: endpoint)
            } else {
              relay.close(MuxError(.connectionLost, "replacement unreachable"))
            }
          }
        }
      }
    }
  }

  private func accept(_ channel: SMXChannel) {
    guard !closed, pending.count + relays.count < capacity,
      channel.peerEUID == geteuid(),
      peerRequirement.map({ channel.requirePeer(codeSigning: $0) }) ?? true
    else {
      channel.cancel()
      return
    }
    guard let permit = admission.acquire() else {
      channel.cancel()
      return
    }
    let id = UUID()
    let supervisor = supervisor
    let authority = authority
    let task = Task { [weak self] in
      let result: Result<GuardianWorkerEndpoint, MuxError>
      do {
        let endpoint = try await supervisor.workerEndpoint(authority)
        try Task.checkCancellation()
        result = .success(endpoint)
      } catch {
        result = .failure(
          (error as? MuxError)
            ?? MuxError(.connectionLost, "native route admission cancelled")
        )
      }
      guard let self else {
        channel.cancel()
        return
      }
      self.queue.async { self.complete(id, result: result) }
    }
    pending[id] = Admission(channel: channel, task: task, permit: permit)
  }

  private func complete(
    _ id: UUID,
    result: Result<GuardianWorkerEndpoint, MuxError>
  ) {
    guard let admission = pending.removeValue(forKey: id) else { return }
    guard !closed, case let .success(endpoint) = result else {
      admission.channel.cancel()
      return
    }
    do {
      let relay = try GatewayNativeRelay(
        frontend: admission.channel,
        worker: endpoint,
        peerRequirement: peerRequirement,
        closed: { [weak self] _ in self?.relays.removeValue(forKey: id) }
      )
      relays[id] = Live(relay: relay, permit: admission.permit)
    } catch { admission.channel.cancel() }
  }
}
