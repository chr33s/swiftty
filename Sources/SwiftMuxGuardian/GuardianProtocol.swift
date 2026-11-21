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

  // Planned replacement (spec.durability.md §7). The candidate is admitted
  // only for its transaction; it has no command authority until release.
  case migrationHello(
    version: Int,
    workspace: WorkspaceID,
    transaction: UUID,
    token: UUID
  )
  /// Old worker: admission is closed and every pane queue has settled.
  case migrationFrozen(authority: GuardianAuthority, transaction: UUID)
  /// Old worker: one piece of the checkpoint taken at the cut.
  case migrationChunk(
    authority: GuardianAuthority,
    transaction: UUID,
    offset: Int,
    total: Int,
    bytes: Data
  )
  /// Old worker: the freeze could not settle; abort.
  case migrationRefused(
    authority: GuardianAuthority,
    transaction: UUID,
    error: MuxError
  )
  /// Candidate: imported without effects, with the digest it imported.
  case migrationImported(transaction: UUID, digest: Data)
  /// Candidate: activated and able to serve once released.
  case migrationActivated(transaction: UUID)
  /// The old worker reopened admission after an abort (§7.3).
  case migrationResumed(authority: GuardianAuthority, transaction: UUID)
}

package enum GuardianResult: Codable, Equatable, Sendable {
  case ok
  case admitted(bytes: Int)
  case spawned(pid: Int32, process: UUID, directoryFallback: Bool? = nil)
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

  // Planned replacement (spec.durability.md §7).
  /// To the old worker: close admission and settle for a cut.
  case migrationFreeze(transaction: UUID)
  /// To the old worker: output through the cut is applied; export now.
  case migrationExport(transaction: UUID)
  /// To the old worker before release: resume under this authority.
  case migrationAborted(transaction: UUID, authority: GuardianAuthority)
  /// To the old worker after release: exit without ending any process.
  case migrationRetire(transaction: UUID)
  /// To the candidate: admitted for `transaction`; gates stay closed.
  case migrationWelcome(transaction: UUID, authority: GuardianAuthority)
  case migrationImport(transaction: UUID, offset: Int, total: Int, bytes: Data)
  /// To the candidate: its generation is assigned; confirm it can serve.
  case migrationActivate(transaction: UUID)
  /// To the candidate: released; it now owns the workspace.
  case migrationReleased(transaction: UUID)
}

/// Planned-replacement phases (spec.durability.md §7.1).
package enum GuardianMigrationPhase: String, Codable, Sendable, Equatable {
  case preparing
  case frozen
  /// Aborted from frozen: the candidate is fenced and the old worker has
  /// 500 ms to confirm it resumed before the workspace is unavailable.
  case aborting
  case released
  case finished
}

package enum GuardianMigrationOutcome: String, Codable, Sendable, Equatable {
  /// The candidate owns the workspace.
  case released
  /// Aborted before release; the old worker resumed under fresh authority.
  case resumed
  /// The old worker could not resume, or the candidate failed after
  /// release: processes are retained and the workspace is unavailable.
  case unavailable
  /// End arrived before release and won: the workspace's processes were
  /// terminated and nothing was reopened (MR6).
  case ended
}

package struct GuardianMigrationStatus: Codable, Sendable, Equatable {
  package let transaction: UUID
  package let workspace: WorkspaceID
  package let phase: GuardianMigrationPhase
  package let outcome: GuardianMigrationOutcome?
  package let candidateConnected: Bool
  package let failure: MuxError?
  /// Frozen interval, once finished (milliseconds).
  package let frozenMilliseconds: Int?

  package init(
    transaction: UUID,
    workspace: WorkspaceID,
    phase: GuardianMigrationPhase,
    outcome: GuardianMigrationOutcome?,
    candidateConnected: Bool,
    failure: MuxError?,
    frozenMilliseconds: Int?
  ) {
    self.transaction = transaction
    self.workspace = workspace
    self.phase = phase
    self.outcome = outcome
    self.candidateConnected = candidateConnected
    self.failure = failure
    self.frozenMilliseconds = frozenMilliseconds
  }
}

/// Checkpoint transfer chunks stay well below the record limit.
package enum GuardianMigrationWire {
  package static let chunkBytes = 256 << 10
  package static let checkpointLimit = 256 << 20
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
  /// Why the worker stopped serving, once it has (diagnostics only).
  package var lossReason: MuxError? = nil
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
