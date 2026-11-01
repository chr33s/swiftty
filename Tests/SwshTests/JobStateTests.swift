import Testing
@testable import Swsh

@Suite
struct JobStateTests {
  @Test
  func aggregateRequiresEveryLiveStageToStop() {
    var job = JobRecord(
      id: JobID(value: 1),
      stages: [.stopped(100, 20), .running(101), .finished(.exited(7))],
      assembling: false
    )
    #expect(job.disposition == .running)
    job.stages[1] = .stopped(101, 20)
    #expect(job.disposition == .stopped)
    job.stages[0] = .awaitingContinuation(100)
    #expect(job.disposition == .running)
    job.stages[0] = .finished(.signaled(15))
    #expect(job.disposition == .stopped)
    job.stages[1] = .finished(.exited(0))
    #expect(job.disposition == .completed(.exited(7)))
  }

  @Test
  func assemblyAndSetupSuspensionAreNotUserStops() {
    var job = JobRecord(
      id: JobID(value: 2),
      stages: [.stopped(100, 19)],
      setupSuspended: true
    )
    #expect(job.disposition == .running)
    job.assembling = false
    #expect(job.disposition == .running)
    job.setupSuspended = false
    #expect(job.disposition == .stopped)
  }

  @Test
  func syntheticLastStageSelectsStatusButDoesNotCompleteLiveNeighbor() {
    var job = JobRecord(
      id: JobID(value: 3),
      stages: [.running(100), .finished(.exited(127))],
      assembling: false
    )
    #expect(job.disposition == .running)
    job.stages[0] = .finished(.signaled(13))
    #expect(job.disposition == .completed(.exited(127)))
  }
}
