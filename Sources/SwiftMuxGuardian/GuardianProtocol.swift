import Foundation
import SwiftMuxProtocol
import SwiftMuxXPC

/// Internal worker/guardian protocol. Never accepted directly from an SMX or
/// RST frontend. The supervisor provisions a one-use token for a specific PID.
package enum GuardianWire {
  package static let version = 1
  package static let recordLimit = 1 << 20
  /// A command and its cached result must fit one workspace's dedup budget.
  package static let commandRecordLimit = ((1 << 20) - 1024) / 2
  package static let inputChunkLimit = 64 << 10
  package static let outputChunkLimit = 64 << 10
  package static let outputRecordLimit = 128
  package static let commandWindow = 128
}

package struct GuardianAuthority: Codable, Equatable, Sendable {
  package var incarnation: UUID
  package var workspace: WorkspaceID
  package var generation: UInt64

  package init(incarnation: UUID, workspace: WorkspaceID, generation: UInt64) {
    self.incarnation = incarnation
    self.workspace = workspace
    self.generation = generation
  }
}

package struct GuardianPaneHandle: Codable, Equatable, Sendable {
  package let pane: PaneID
  package let process: UUID
  package init(pane: PaneID, process: UUID) {
    self.pane = pane
    self.process = process
  }
}

package enum GuardianCommand: Codable, Equatable, Sendable {
  case spawn(pane: PaneID, launch: LaunchSpec, columns: Int, rows: Int)
  case input(pane: GuardianPaneHandle, writer: UUID, bytes: Data)
  case reply(pane: GuardianPaneHandle, bytes: Data)
  case beginPaste(
    pane: GuardianPaneHandle,
    writer: UUID,
    id: UInt64,
    bracketed: Bool
  )
  case appendPaste(
    pane: GuardianPaneHandle,
    writer: UUID,
    id: UInt64,
    text: String
  )
  case endPaste(pane: GuardianPaneHandle, writer: UUID, id: UInt64)
  case cancelPaste(
    pane: GuardianPaneHandle,
    writer: UUID,
    id: UInt64,
    discardDeferredInput: Bool
  )
  case cancelInput(pane: GuardianPaneHandle)
  case resize(pane: GuardianPaneHandle, columns: Int, rows: Int)
  case end(pane: GuardianPaneHandle)
  case forget(pane: GuardianPaneHandle)
}

package enum GuardianRequest: Codable, Sendable {
  case subscribeGateway(authority: GuardianAuthority)
  case gatewayApplied(authority: GuardianAuthority, revision: UInt64)
  case hello(version: Int, workspace: WorkspaceID, token: UUID)
  case command(
    authority: GuardianAuthority,
    sequence: UInt64,
    body: GuardianCommand
  )
  /// Only acknowledged results can be retired. Older retries remain invalid.
  case retire(authority: GuardianAuthority, through: UInt64)
  /// Sent only after a barrier has run on every pane queue and the workspace
  /// queue. Transport activity alone does not establish worker progress.
  case progress(authority: GuardianAuthority, probe: UUID)
  /// Cumulative acknowledgement of output actually applied by the worker.
  case outputAck(
    authority: GuardianAuthority,
    pane: GuardianPaneHandle,
    through: UInt64
  )
}

package enum GuardianResult: Codable, Equatable, Sendable {
  case ok
  case admitted(bytes: Int)
  case spawned(pid: Int32, process: UUID)
  /// Apply output through this cut using the old geometry, then commit the
  /// acknowledged geometry before parsing later records or pane mutations.
  case resized(outputThrough: UInt64)
  case pasteCancelled(wrote: Bool)
  case rejected(MuxError)
}

package enum GuardianEvent: Codable, Sendable {
  case welcome(authority: GuardianAuthority)
  case endpointPublished(instance: ServerInstanceID)
  case gatewayBinding(GuardianGatewayBinding)
  case probe(UUID)
  case result(sequence: UInt64, value: GuardianResult)
  /// Not admitted; retain this sequence and retry after capacity returns.
  case retry(sequence: UInt64)
  case output(pane: GuardianPaneHandle, sequence: UInt64, bytes: Data)
  case inputReleased(pane: GuardianPaneHandle, bytes: Int)
  case replyReleased(pane: GuardianPaneHandle, bytes: Int)
  /// Stop generating replies, but continue applying output until `exited`.
  case exiting(pane: GuardianPaneHandle)
  case exited(pane: GuardianPaneHandle, status: Int32, forced: Bool)
  case refused(MuxError)
}

package struct GuardianPaneInventory: Codable, Sendable {
  package let pane: PaneID
  package let process: UUID
  package let pid: Int32
  package let finished: Bool
}

package struct GuardianWorkspaceInventory: Codable, Sendable {
  package let authority: GuardianAuthority
  package let available: Bool
  package let worker: GuardianWorkerInventory?
  package let panes: [GuardianPaneInventory]
  package var starting = false
  package var launchError: MuxError?
  /// From the retained, validated build pin; nil is unknown, never inferred.
  package var workerProtocol: Int? = nil
}

package struct GuardianWorkerInventory: Codable, Sendable {
  package let pid: Int32
  package let build: String
  package let finished: Bool
  /// Raw waitpid status; nil while alive or if ownership was lost externally.
  package let status: Int32?
}

/// Only an endpoint-carrying XPC record may carry this publication.
package struct GuardianEndpointPublication: Codable, Sendable {
  package let version: Int
  package let authority: GuardianAuthority
  package let instance: ServerInstanceID
}

package struct GuardianWorkerEndpoint: Sendable {
  package let authority: GuardianAuthority
  package let instance: ServerInstanceID
  package let pid: Int32
  package let endpoint: SMXEndpoint
}

package struct GuardianGatewayBinding: Codable, Sendable {
  package let authority: GuardianAuthority
  package let revision: UInt64
  package let gateway: UUID?
  package let pid: Int32?
  package let writer: UUID?
}
