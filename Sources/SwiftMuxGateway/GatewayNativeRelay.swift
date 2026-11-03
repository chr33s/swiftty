import Darwin
import Dispatch
import Foundation
import SwiftMuxGuardian
import SwiftMuxProtocol
import SwiftMuxXPC

/// One authenticated native frontend routed to one guardian-discovered worker.
/// All methods and callbacks run on the frontend channel queue. The enclosing
/// router owns workspace selection and retains this object until `closed`.
/// Wire identities and acknowledgement timing are preserved; nothing is replayed.
package final class GatewayNativeRelay: @unchecked Sendable {
  private struct CommandCharge {
    let bytes: Int
    let changesAttachment: Bool
    let subscribedPanes: Set<PaneID>?
    let inboxChange: Bool?
  }

  private struct InputCharge {
    let bytes: Int
    let control: Bool
    let deadline: DispatchTime
  }

  private let frontend: SMXChannel
  private let worker: SMXChannel
  private let endpoint: GuardianWorkerEndpoint
  private let onClosed: @Sendable (MuxError) -> Void
  private var hello: Hello?
  private var welcome: Welcome?
  private var ended = false
  private var commands: [UInt64: CommandCharge] = [:]
  private var commandBytes = 0
  private var inputs: [UInt64: InputCharge] = [:]
  private var inputBytes = 0
  private var controlBytes = 0
  private var controlCount = 0
  private var frames: [PaneID: FrameIdentity] = [:]
  private struct InboxCredit: Equatable {
    let revision: UInt64
    let token: UUID?
  }
  private var inbox: [InboxCredit] = []
  private var timer: DispatchSourceTimer?
  private let handshakeDeadline = DispatchTime.now() + 5

  package init(
    frontend: SMXChannel,
    worker endpoint: GuardianWorkerEndpoint,
    peerRequirement: String?,
    closed: @escaping @Sendable (MuxError) -> Void
  ) throws {
    self.frontend = frontend
    self.endpoint = endpoint
    onClosed = closed
    worker = .connect(endpoint: endpoint.endpoint, queue: frontend.queue)
    guard frontend.peerEUID == geteuid(),
      peerRequirement.map({
        frontend.requirePeer(codeSigning: $0)
          && worker.requirePeer(codeSigning: $0)
      }) ?? true
    else {
      frontend.cancel()
      worker.cancel()
      throw MuxError(.unauthorized, "relay peer rejected")
    }
    frontend.activate(recordLimit: { [weak self] in
      SMXCodec.clientRecordLimit(self?.welcome?.limits ?? .standard)
    }) { [weak self] event in
      guard let self else { return }
      switch event {
      case let .message(data): self.receiveFrontend(data)
      case .closed: self.close()
      }
    }
    worker.activate(recordLimit: { [weak self] in
      SMXCodec.serverRecordLimit(self?.welcome?.limits ?? .standard)
    }) { [weak self] event in
      guard let self else { return }
      switch event {
      case let .message(data): self.receiveWorker(data)
      case .closed: self.close()
      }
    }
    armDeadline()
  }

  deinit {
    timer?.cancel()
    frontend.cancel()
    worker.cancel()
  }

  package func close(
    _ error: MuxError = MuxError(.connectionLost, "native relay closed")
  ) {
    guard !ended else { return }
    ended = true
    timer?.cancel()
    timer = nil
    frontend.cancel()
    worker.cancel()
    commands.removeAll()
    inputs.removeAll()
    frames.removeAll()
    inbox.removeAll()
    onClosed(error)
  }

  private func receiveFrontend(_ data: Data) {
    guard !ended else { return }
    do {
      let message = try SMXCodec.decode(
        ClientMessage.self,
        from: data,
        limit: SMXCodec.clientRecordLimit(welcome?.limits ?? .standard)
      )
      if hello == nil {
        guard DispatchTime.now() < handshakeDeadline else {
          throw MuxError(.connectionLost, "frontend handshake timed out")
        }
        guard case var .hello(value) = message, value.forwardedTransport == nil,
          SMX.compatibleVersions.contains(value.protocolVersion)
        else {
          throw MuxError(.unauthorized, "expected an ordinary frontend hello")
        }
        value.forwardedTransport = .local
        // The relay decodes every record to account credit, so it carries
        // JSON full frames only: no SMXB/1 binary frames or deltas.
        value.capabilities.remove(.binaryFrames)
        value.capabilities.remove(.frameDeltas)
        hello = value
        worker.send(
          try SMXCodec.encode(
            ClientMessage.hello(value),
            limit: SMXCodec.clientRecordLimit(.standard)
          )
        )
        return
      }
      guard welcome != nil else {
        throw MuxError(.notAttached, "worker handshake pending")
      }
      switch message {
      case .hello: throw MuxError(.invalidRequest, "duplicate frontend hello")
      case let .request(id, command):
        if case .observeWorkspaceGraph = command {
          reject(
            id,
            MuxError(.unauthorized, "gateway graph subscription is internal")
          )
          return
        }
        guard commands[id] == nil else {
          throw MuxError(.invalidRequest, "duplicate outstanding request")
        }
        guard commands.count < 64, data.count <= (4 << 20) - commandBytes else {
          reject(
            id,
            MuxError(.resourceLimit, "relay command capacity exhausted")
          )
          return
        }
        let inboxChange: Bool?
        if case let .subscribeInbox(on) = command {
          guard !commands.values.contains(where: { $0.inboxChange != nil })
          else {
            reject(
              id,
              MuxError(.quiescing, "inbox subscription change is pending")
            )
            return
          }
          guard
            !on
              || (hello?.capabilities.contains(.inboxAcknowledgementTokens)
                == true
                && welcome?.features.contains(.inboxAcknowledgementTokens)
                  == true)
          else {
            reject(
              id,
              MuxError(
                .incompatibleVersion,
                "relay inbox requires acknowledgement tokens"
              )
            )
            return
          }
          inboxChange = on
        } else {
          inboxChange = nil
        }
        let changesAttachment: Bool
        switch command {
        case .attach, .takeover, .switchWorkspace:
          guard inputs.isEmpty else {
            reject(
              id,
              MuxError(.quiescing, "previous attachment input is settling")
            )
            return
          }
          changesAttachment = true
        case .detach, .detachActive, .endWorkspace, .endAllWorkspaces:
          changesAttachment = true
        default: changesAttachment = false
        }
        let subscribedPanes: Set<PaneID>?
        if case let .setSubscriptions(panes) = command {
          subscribedPanes = Set(panes)
        } else {
          subscribedPanes = nil
        }
        commands[id] = CommandCharge(
          bytes: data.count,
          changesAttachment: changesAttachment,
          subscribedPanes: subscribedPanes,
          inboxChange: inboxChange
        )
        commandBytes += data.count
      case let .input(record):
        guard !commands.values.contains(where: \.changesAttachment) else {
          throw MuxError(.staleAttachment, "input during attachment transition")
        }
        guard inputs[record.sequence] == nil else {
          throw MuxError(.invalidRequest, "input sequence is still outstanding")
        }
        let control: Bool
        switch record.payload {
        case .pasteEnd, .pasteCancel: control = true
        default: control = false
        }
        if control {
          guard controlCount < 32, data.count <= (64 << 10) - controlBytes
          else {
            throw MuxError(
              .resourceLimit,
              "relay cancellation capacity exhausted"
            )
          }
          controlCount += 1
          controlBytes += data.count
        } else {
          guard inputs.count - controlCount < 256,
            data.count <= (4 << 20) - inputBytes
          else {
            throw MuxError(.resourceLimit, "relay input capacity exhausted")
          }
          inputBytes += data.count
        }
        inputs[record.sequence] = InputCharge(
          bytes: data.count,
          control: control,
          deadline: .now() + 5
        )
        armDeadline()
      case let .frameAck(pane, revision, attachment):
        guard let frame = frames[pane], frame.revision == revision,
          frame.attachment == attachment
        else { return }
        frames.removeValue(forKey: pane)
      case let .inboxAck(revision, token):
        guard inbox.first == InboxCredit(revision: revision, token: token)
        else { return }
        inbox.removeFirst()
      case let .requestFullFrame(pane, revision, attachment):
        // Releases the refused frame's credit in place of `frameAck`.
        guard let frame = frames[pane], frame.revision == revision,
          frame.attachment == attachment
        else { return }
        frames.removeValue(forKey: pane)
      }
      worker.send(data)
    } catch {
      close(
        (error as? MuxError)
          ?? MuxError(.invalidRequest, "relay protocol failure")
      )
    }
  }

  private func receiveWorker(_ data: Data) {
    guard !ended else { return }
    do {
      guard worker.peerEUID == geteuid(), worker.peerPID == endpoint.pid else {
        throw MuxError(.unauthorized, "worker identity changed")
      }
      let message = try SMXCodec.decode(
        ServerMessage.self,
        from: data,
        limit: SMXCodec.serverRecordLimit(welcome?.limits ?? .standard)
      )
      if welcome == nil {
        guard DispatchTime.now() < handshakeDeadline else {
          throw MuxError(.connectionLost, "worker handshake timed out")
        }
        guard hello != nil, case var .welcome(value) = message,
          value.server == endpoint.instance, value.forwardedTransport == .local,
          SMX.compatibleVersions.contains(value.protocolVersion)
        else {
          throw MuxError(
            .incompatibleVersion,
            "worker did not acknowledge the relay"
          )
        }
        try value.limits.validateForClient()
        welcome = value
        // Internal discovery is not part of this frontend's command surface.
        value.features.remove(.workspaceGraph)
        value.features.remove(.binaryFrames)
        value.features.remove(.frameDeltas)
        value.forwardedTransport = nil
        frontend.send(
          try SMXCodec.encode(
            ServerMessage.welcome(value),
            limit: SMXCodec.serverRecordLimit(value.limits)
          )
        )
        armDeadline()
        return
      }
      switch message {
      case .welcome, .rejected:
        throw MuxError(.invalidRequest, "unexpected worker handshake")
      case let .reply(id, result):
        guard let charge = commands.removeValue(forKey: id) else {
          throw MuxError(.invalidRequest, "unknown worker reply")
        }
        commandBytes -= charge.bytes
        if case .success = result {
          if charge.changesAttachment { frames.removeAll() }
          if charge.inboxChange == false { inbox.removeAll() }
          if let panes = charge.subscribedPanes {
            frames = frames.filter { panes.contains($0.key) }
          }
        }
      case let .inputAck(sequence, _):
        guard let charge = inputs.removeValue(forKey: sequence) else {
          throw MuxError(.invalidRequest, "unknown input acknowledgement")
        }
        guard DispatchTime.now() < charge.deadline else {
          throw MuxError(
            .connectionLost,
            "worker input acknowledgement timed out"
          )
        }
        if charge.control {
          controlCount -= 1;
          controlBytes -= charge.bytes
        } else {
          inputBytes -= charge.bytes
        }
        armDeadline()
      case let .event(.frame(frame)):
        guard frame.identity.server == endpoint.instance,
          frames[frame.identity.pane] == nil,
          frames.count < welcome!.limits.maxPanes
        else { throw MuxError(.resourceLimit, "worker frame credit exceeded") }
        frames[frame.identity.pane] = frame.identity
      case let .event(.inbox(update)):
        guard update.acknowledgementToken != nil else {
          throw MuxError(.incompatibleVersion, "missing inbox delivery token")
        }
        guard inbox.count < welcome!.limits.inboxPendingUpdates else {
          throw MuxError(.resourceLimit, "worker inbox credit exceeded")
        }
        inbox.append(
          InboxCredit(
            revision: update.revision,
            token: update.acknowledgementToken
          )
        )
      case .event(.detached): frames.removeAll()
      case let .event(.layout(graph)):
        let panes = Set(graph.panes.map(\.id))
        frames = frames.filter { panes.contains($0.key) }
      case .event(.workspaceGraph):
        throw MuxError(.unauthorized, "unexpected internal graph event")
      case .event: break
      }
      frontend.send(data)
    } catch {
      close(
        (error as? MuxError)
          ?? MuxError(.invalidRequest, "relay protocol failure")
      )
    }
  }

  private func reject(_ id: UInt64, _ error: MuxError) {
    if let data = try? SMXCodec.encode(
      ServerMessage.reply(id: id, result: .failure(error)),
      limit: SMXCodec.serverRecordLimit(welcome?.limits ?? .standard)
    ) {
      frontend.send(data)
    } else {
      close()
    }
  }

  private func armDeadline() {
    timer?.cancel()
    timer = nil
    guard !ended else { return }
    let deadline =
      welcome == nil ? handshakeDeadline : inputs.values.map(\.deadline).min()
    guard let deadline else { return }
    let timer = DispatchSource.makeTimerSource(queue: frontend.queue)
    timer.schedule(deadline: deadline)
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      let now = DispatchTime.now()
      if self.welcome == nil && now >= self.handshakeDeadline
        || self.inputs.values.contains(where: { now >= $0.deadline })
      {
        self.close(
          MuxError(.connectionLost, "native relay acknowledgement timed out")
        )
      } else {
        self.armDeadline()
      }
    }
    self.timer = timer
    timer.resume()
  }
}
