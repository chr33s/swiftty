import Dispatch
import Foundation
@testable import SwiftMuxGuardian
import SwiftMuxProtocol
@testable import SwiftMuxService
import Synchronization
import Testing

/// Cleanup commands are best effort (review regression): a paste end the
/// command queue withdrew, a superseded writer or an exited pane must not
/// be treated as a lost transport.
@Suite(.serialized)
struct GuardianPaneControlTests {
  final class Recorder: @unchecked Sendable {
    let commands = Mutex<
      [(GuardianCommand, GuardianWorkerCommands.Completion)]
    >([])
    let failures = Mutex<[MuxError]>([])
  }

  private func process(_ recorder: Recorder) -> GuardianPaneProcess {
    let process = GuardianPaneProcess(
      id: PaneID(),
      queue: DispatchQueue(label: "pane-control-test"),
      limits: .standard,
      transport: GuardianPaneTransport(
        submit: { command, completion in
          recorder.commands.withLock { $0.append((command, completion)) }
          return true
        },
        cancelUnsent: { _, _, _ in },
        acknowledge: { _, _ in },
        retire: { $0(nil) },
        writer: { UUID() },
        failed: { error in recorder.failures.withLock { $0.append(error) } }
      )
    )
    process.queue.sync {
      process.adopt(
        GuardianPaneHandle(pane: PaneID(), process: UUID()),
        pid: 1,
        appliedOutput: 0
      )
    }
    return process
  }

  /// The last submitted command's completion, answered with `result`.
  private func answer(
    _ recorder: Recorder,
    _ process: GuardianPaneProcess,
    _ result: Result<GuardianResult, MuxError>
  ) {
    let completion = recorder.commands.withLock { $0.last!.1 }
    process.queue.sync { completion(result) }
  }

  @Test(arguments: [MuxError.Code.staleAttachment, .notFound, .paneExited])
  func aRejectedPasteEndIsNotATransportFailure(code: MuxError.Code) {
    let recorder = Recorder()
    let process = process(recorder)
    process.queue.sync { process.beginPaste(id: 1, bracketed: false) { _ in } }
    answer(recorder, process, .success(.admitted(bytes: 0)))
    process.queue.sync { process.endPaste(id: 1) }
    answer(recorder, process, .success(.rejected(MuxError(code, "withdrawn"))))
    #expect(recorder.failures.withLock { $0 }.isEmpty)
  }

  @Test
  func aRejectedInputCancellationOfAnExitedPaneIsNotATransportFailure() {
    let recorder = Recorder()
    let process = process(recorder)
    process.queue.sync { process.cancelInput() }
    answer(
      recorder,
      process,
      .success(.rejected(MuxError(.notFound, "pane is not running")))
    )
    #expect(recorder.failures.withLock { $0 }.isEmpty)
  }

  @Test
  func anUnexpectedControlFailureStillLosesTheTransport() {
    let recorder = Recorder()
    let process = process(recorder)
    process.queue.sync { process.cancelInput() }
    answer(
      recorder,
      process,
      .success(.rejected(MuxError(.invalidRequest, "protocol violation")))
    )
    #expect(recorder.failures.withLock { $0 }.count == 1)
  }
}
