import Darwin
import Dispatch
import Foundation
import SwiftMuxClient
import SwiftMuxGuardian
import SwiftMuxProtocol
@testable import SwiftMuxService
import Synchronization
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct PaneProcessAdmissionTests {
  @Test
  func delayedResizeCommitsOnlyAcknowledgedGeometryAndCoalescesPendingRequests()
    throws
  {
    let created = Mutex<DelayedProcess?>(nil)
    let runtime = PaneRuntime(
      id: PaneID(),
      workspace: WorkspaceID(),
      columns: 80,
      rows: 24,
      historyBytes: 0,
      limits: .standard,
      processFactory: { id, workspace, queue, limits in
        let process = DelayedProcess(
          id: id,
          workspace: workspace,
          queue: queue,
          limits: limits
        )
        process.deferResize = true
        created.withLock { $0 = process }
        return process
      }
    )
    let process = try #require(created.withLock { $0 })
    let finished = DispatchSemaphore(value: 0)
    runtime.onEvent = { if case .finished = $0 { finished.signal() } }
    defer {
      runtime.queue.sync { process.releaseResize() }
      runtime.terminate()
      #expect(finished.wait(timeout: .now() + 8) == .success)
    }
    let launcher = try PaneLauncher(
      launcherPath: launcherPath(),
      innerTerm: SMX.fallbackInnerTerm
    )
    let launched = DispatchSemaphore(value: 0)
    runtime.queue.async {
      runtime.launch(
        LaunchSpec(command: ["/bin/sleep", "60"]),
        launcher: launcher
      ) { result in
        if case let .failure(error) = result { Issue.record(error) }
        launched.signal()
      }
    }
    try #require(launched.wait(timeout: .now() + 5) == .success)
    runtime.resize(columns: 100, rows: 30)
    runtime.queue.sync {
      #expect(process.resizeCompletion != nil)
      #expect(runtime.geometryGeneration == 0)
    }
    #expect(runtime.screenLines().count == 24)
    let controls = GeometryObservations()
    for _ in 0 ..< PaneRuntime.inputOperationLimit {
      runtime.scroll(.bottom) { error in
        #expect(error == nil)
        controls.values.withLock { $0.append(runtime.geometryGeneration) }
      }
    }
    let overflow = DispatchSemaphore(value: 0)
    runtime.clearScreen { error in
      #expect(error?.code == .resourceLimit)
      overflow.signal()
    }
    #expect(overflow.wait(timeout: .now() + 2) == .success)
    #expect(controls.values.withLock { $0.isEmpty })
    for _ in 0 ..< PaneRuntime.inputOperationLimit {
      try #require(runtime.reserve(1))
      runtime.write(.text("x"), estimate: 1)
    }
    runtime.queue.sync {
      #expect(process.admissions.isEmpty)
      #expect(
        runtime.outstandingInput.withLock { $0 }
          == PaneRuntime.inputOperationLimit
      )
    }
    #expect(!runtime.reserve(0))
    for rows in 31 ... 40 { runtime.resize(columns: 120, rows: rows) }
    runtime.discardUnwrittenInput()
    runtime.queue.sync {
      #expect(process.inputCancellations == 1)
      #expect(process.admissions.isEmpty)
      #expect(runtime.outstandingInput.withLock { $0 } == 0)
      #expect(runtime.geometryGeneration == 0)
      #expect(controls.values.withLock { $0.isEmpty })
      process.releaseResize()
      #expect(
        controls.values.withLock {
          $0 == Array(repeating: 1, count: PaneRuntime.inputOperationLimit)
        }
      )
      #expect(runtime.geometryGeneration == 1)
    }
    runtime.queue.sync {
      #expect(process.resizeCompletion != nil)
      #expect(runtime.geometryGeneration == 1)
    }
    #expect(runtime.screenLines().count == 30)
    try #require(runtime.reserve(1))
    runtime.write(.text("y"), estimate: 1)
    runtime.queue.sync {
      #expect(process.admissions.isEmpty)
      process.releaseResize()
      #expect(process.admissions.count == 1)
      process.releaseAdmissions()
    }
    #expect(runtime.screenLines().count == 40)
    runtime.queue.sync {
      #expect(runtime.geometryGeneration == 11)
      process.resizeError = MuxError(.invalidRequest, "injected resize failure")
    }
    runtime.resize(columns: 140, rows: 50)
    try #require(runtime.reserve(12))
    runtime.pasteBegin(id: 99, estimate: 12)
    try #require(runtime.reserve(3))
    runtime.pasteChunk(id: 99, text: "bad", estimate: 3)
    runtime.pasteEnd(id: 99)
    let resetRejected = DispatchSemaphore(value: 0)
    runtime.resetTerminal { error in
      #expect(error?.code == .invalidRequest)
      resetRejected.signal()
    }
    #expect(resetRejected.wait(timeout: .now()) == .timedOut)
    runtime.queue.sync {
      #expect(process.admissions.isEmpty)
      process.releaseResize()
      #expect(process.admissions.isEmpty)
      #expect(!process.hasOpenPaste)
      #expect(runtime.outstandingInput.withLock { $0 } == 0)
    }
    #expect(resetRejected.wait(timeout: .now() + 2) == .success)
    #expect(runtime.screenLines().count == 40)
    runtime.queue.sync { #expect(runtime.geometryGeneration == 11) }
    let captured = DispatchSemaphore(value: 0)
    runtime.captureFrame(
      server: ServerInstanceID(),
      attachment: AttachmentID(),
      layoutRevision: 0
    ) { result in
      if case let .failure(error) = result {
        #expect(error.code == .invalidRequest)
      } else {
        Issue.record("failed resize advertised a ready frame")
      }
      captured.signal()
    }
    #expect(captured.wait(timeout: .now() + 2) == .success)
  }

  @Test
  func writtenInputDoesNotRefundOperationSlotsBeforeAdmissionResponses() throws
  {
    let created = Mutex<DelayedProcess?>(nil)
    let runtime = PaneRuntime(
      id: PaneID(),
      workspace: WorkspaceID(),
      columns: 80,
      rows: 24,
      historyBytes: 0,
      limits: .standard,
      processFactory: { id, workspace, queue, limits in
        let process = DelayedProcess(
          id: id,
          workspace: workspace,
          queue: queue,
          limits: limits
        )
        created.withLock { $0 = process }
        return process
      }
    )
    let process = try #require(created.withLock { $0 })
    let finished = DispatchSemaphore(value: 0)
    runtime.onEvent = { if case .finished = $0 { finished.signal() } }
    defer {
      runtime.queue.sync { process.releaseAdmissions() }
      runtime.terminate()
      #expect(finished.wait(timeout: .now() + 8) == .success)
    }
    let count = PaneRuntime.inputOperationLimit
    let program = """
      import os,tty,time
      tty.setraw(0)
      os.write(1,b'READY')
      data=b''
      while len(data)<\(count + 1): data+=os.read(0,\(count + 1)-len(data))
      os.write(1,b'MATCH' if data==b'x'*\(count + 1) else b'WRONG')
      time.sleep(60)
      """
    let launcher = try PaneLauncher(
      launcherPath: launcherPath(),
      innerTerm: SMX.fallbackInnerTerm
    )
    let launched = DispatchSemaphore(value: 0)
    runtime.queue.async {
      runtime.launch(
        LaunchSpec(command: ["/usr/bin/python3", "-c", program]),
        launcher: launcher
      ) { result in
        if case let .failure(error) = result { Issue.record(error) }
        launched.signal()
      }
    }
    try #require(launched.wait(timeout: .now() + 5) == .success)
    try eventually { runtime.screenLines().contains { $0.contains("READY") } }
    for _ in 0 ..< count {
      try #require(runtime.reserve(1))
      runtime.write(.text("x"), estimate: 1)
    }
    runtime.queue.sync {
      #expect(process.admissions.count == count)
      #expect(runtime.outstandingInput.withLock { $0 } == 0)
    }
    #expect(!runtime.reserve(0))
    runtime.discardUnwrittenInput()
    runtime.queue.sync {
      #expect(process.inputCancellations == 1)
      #expect(process.admissions.count == count)
      process.admissions.removeFirst()()
    }
    try #require(runtime.reserve(1))
    runtime.write(.text("x"), estimate: 1)
    runtime.queue.sync {
      #expect(process.admissions.count == count)
      process.releaseAdmissions()
    }
    #expect(!runtime.reserve(-1))
    #expect(!runtime.reserve(Int.max))
    try #require(runtime.reserve(0))
    runtime.write(.text(""), estimate: 0)
    runtime.queue.sync { #expect(process.admissions.isEmpty) }
    try eventually { runtime.screenLines().contains { $0.contains("MATCH") } }
  }

  @Test
  func serviceWaitsForDelayedLaunchAndReapsLateChildDuringShutdown()
    async throws
  {
    let created = Mutex<DelayedProcess?>(nil)
    let started = DispatchSemaphore(value: 0)
    var config = try MuxServiceConfiguration(launcherPath: launcherPath())
    config.paneProcessFactory = { id, workspace, queue, limits in
      let process = DelayedProcess(
        id: id,
        workspace: workspace,
        queue: queue,
        limits: limits
      )
      process.deferLaunch = true
      process.started = { started.signal() }
      created.withLock { $0 = process }
      return process
    }
    let service = try MuxService(configuration: config)
    let client = try await MuxConnection.connect(
      endpoint: service.listenAnonymously(),
      frontend: .control
    )
    let creation = Task {
      try await client.execute(
        .newWorkspace(
          NewWorkspaceRequest(
            launch: LaunchSpec(command: ["/bin/sleep", "60"])
          )
        )
      )
    }
    try #require(await wait(started, seconds: 5))
    let process = try #require(created.withLock { $0 })
    var retired = false
    defer { if !retired { retire(service, process: process) } }
    let pid = process.pid
    #expect(pid > 0 && kill(pid, 0) == 0)
    #expect(await service.pendingLaunches == 1)
    let stopped = DispatchSemaphore(value: 0)
    service.prepareToExit { stopped.signal() }
    #expect(await !wait(stopped, seconds: 0.05))
    process.queue.sync { process.releaseLaunch() }
    do {
      _ = try await creation.value
      Issue.record("late launch joined a quiescing graph")
    } catch let error as MuxError { #expect(error.code == .quiescing) }
    retired = await wait(stopped)
    #expect(retired)
    #expect(await service.pendingLaunches == 0)
    var status: Int32 = 0
    #expect(waitpid(pid, &status, WNOHANG) == -1)
    #expect(errno == ECHILD)
    await client.close()
  }

  @Test
  func pasteCreditAndCancellationDoNotAssumeImmediateAdmissionResults() throws {
    let created = Mutex<DelayedProcess?>(nil)
    let runtime = PaneRuntime(
      id: PaneID(),
      workspace: WorkspaceID(),
      columns: 80,
      rows: 24,
      historyBytes: 0,
      limits: .standard,
      processFactory: { id, workspace, queue, limits in
        let process = DelayedProcess(
          id: id,
          workspace: workspace,
          queue: queue,
          limits: limits
        )
        created.withLock { $0 = process }
        return process
      }
    )
    let process = try #require(created.withLock { $0 })
    let finished = DispatchSemaphore(value: 0)
    runtime.onEvent = { if case .finished = $0 { finished.signal() } }
    defer {
      runtime.queue.sync {
        process.releaseAdmissions()
        process.releaseCancellation()
      }
      runtime.terminate()
      #expect(finished.wait(timeout: .now() + 8) == .success)
    }
    let launcher = try PaneLauncher(
      launcherPath: launcherPath(),
      innerTerm: SMX.fallbackInnerTerm
    )
    let launched = DispatchSemaphore(value: 0)
    let program = #"""
      import os,tty,time
      tty.setraw(0)
      os.write(1,b'\x1b[?2004hREADY')
      expected=b'\x1b[200~ABC\x1b[201~'
      data=b''
      while len(data)<len(expected): data+=os.read(0,len(expected)-len(data))
      os.write(1,b'MATCH' if data==expected else b'WRONG')
      time.sleep(60)
      """#
    runtime.queue.async {
      runtime.launch(
        LaunchSpec(command: ["/usr/bin/python3", "-c", program]),
        launcher: launcher
      ) { result in
        if case let .failure(error) = result { Issue.record(error) }
        launched.signal()
      }
    }
    try #require(launched.wait(timeout: .now() + 5) == .success)
    try eventually { runtime.screenLines().contains { $0.contains("READY") } }
    #expect(runtime.reserve(12))
    runtime.pasteBegin(id: 1, estimate: 12)
    runtime.queue.sync { process.deferResize = true }
    runtime.resize(columns: 100, rows: 30)
    #expect(runtime.reserve(6))
    runtime.pasteChunk(id: 1, text: "ABC", estimate: 6)
    runtime.queue.sync {
      #expect(process.admissions.count == 2)
      // Opener and payload already reached the real PTY; the conservative
      // chunk estimate and future closer remain reserved until admission.
      #expect(runtime.outstandingInput.withLock { $0 } == 9)
      process.releaseAdmissions()
      #expect(runtime.outstandingInput.withLock { $0 } == 6)
    }
    let cancelled = DispatchSemaphore(value: 0)
    let outcome = PasteOutcome()
    runtime.pasteCancel(id: 1, failure: { Issue.record($0) }) { value in
      outcome.value.withLock { $0 = value };
      cancelled.signal()
    }
    runtime.queue.sync {
      #expect(runtime.outstandingInput.withLock { $0 } == 0)
      #expect(outcome.value.withLock { $0 } == nil)
      process.releaseCancellation()
    }
    #expect(cancelled.wait(timeout: .now() + 3) == .success)
    #expect(outcome.value.withLock { $0 } == .partial)
    runtime.queue.sync {
      #expect(runtime.geometryGeneration == 0)
      #expect(process.resizeCompletion != nil)
      process.releaseResize()
    }
    try eventually { runtime.screenLines().contains { $0.contains("MATCH") } }
  }

  @Test
  func pendingRetirementKeepsCapacityHistoryAndExitBarrierReserved()
    async throws
  {
    let created = Mutex<DelayedProcess?>(nil)
    var config = MuxServiceConfiguration(launcherPath: try launcherPath())
    config.limits.maxPanes = 1
    config.paneProcessFactory = { id, workspace, queue, limits in
      let process = DelayedProcess(
        id: id,
        workspace: workspace,
        queue: queue,
        limits: limits
      )
      process.deferRetirement = true
      created.withLock { $0 = process }
      return process
    }
    let service = try MuxService(configuration: config)
    let client = try await MuxConnection.connect(
      endpoint: service.listenAnonymously(),
      frontend: .control
    )
    guard
      case let .created(workspace) = try await client.execute(
        .newWorkspace(
          NewWorkspaceRequest(
            launch: LaunchSpec(command: ["/bin/sleep", "60"])
          )
        )
      )
    else { throw MuxError(.invalidRequest, "missing workspace") }
    let process = try #require(created.withLock { $0 })
    var stopped = false
    defer {
      if !stopped {
        process.queue.sync { process.releaseRetirement() }
        retire(service, process: process)
      }
    }
    _ = try await client.execute(.endWorkspace(.id(workspace.id)))
    let deadline = ContinuousClock.now + .seconds(5)
    while process.queue.sync(execute: { process.retirementCompletion == nil }) {
      try #require(ContinuousClock.now < deadline)
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await service.panes.isEmpty)
    #expect(await service.retiringPanes.count == 1)
    #expect(await service.paneCount == 1)
    #expect(await service.allocatedHistoryBytes > 0)
    #expect(await !service.isEmpty)
    await #expect(throws: MuxError.self) {
      try await client.execute(
        .newWorkspace(
          NewWorkspaceRequest(
            launch: LaunchSpec(command: ["/bin/sh", "-c", "exit 0"])
          )
        )
      )
    }
    let done = DispatchSemaphore(value: 0)
    service.prepareToExit { done.signal() }
    #expect(await !wait(done, seconds: 0.05))
    process.queue.sync { process.releaseRetirement() }
    stopped = await wait(done)
    #expect(stopped)
    #expect(await service.retiringPanes.isEmpty)
    #expect(await service.allocatedHistoryBytes == 0)
    #expect(await service.isEmpty)
    await client.close()
  }

  @Test(arguments: [false, true])
  func retirementRetriesOnlyExplicitCapacityRefusal(
    retryable: Bool
  ) async throws {
    let created = Mutex<DelayedProcess?>(nil)
    var config = MuxServiceConfiguration(launcherPath: try launcherPath())
    config.paneProcessFactory = { id, workspace, queue, limits in
      let process = DelayedProcess(
        id: id,
        workspace: workspace,
        queue: queue,
        limits: limits
      )
      process.retirementFailure = MuxError(
        retryable ? .resourceLimit : .connectionLost,
        "injected retirement outcome"
      )
      created.withLock { $0 = process }
      return process
    }
    let service = try MuxService(configuration: config)
    let client = try await MuxConnection.connect(
      endpoint: service.listenAnonymously(),
      frontend: .control
    )
    _ = try await client.execute(
      .newWorkspace(
        NewWorkspaceRequest(
          launch: LaunchSpec(command: ["/bin/sh", "-c", "exit 0"])
        )
      )
    )
    let process = try #require(created.withLock { $0 })
    let deadline = ContinuousClock.now + .seconds(5)
    if retryable {
      while await !service.isEmpty {
        try #require(ContinuousClock.now < deadline)
        try await Task.sleep(for: .milliseconds(10))
      }
      process.queue.sync { #expect(process.retirementAttempts == 2) }
      #expect(await service.retirementFailures.isEmpty)
    } else {
      while await service.retirementFailures.isEmpty {
        try #require(ContinuousClock.now < deadline)
        try await Task.sleep(for: .milliseconds(10))
      }
      try await Task.sleep(for: .milliseconds(150))
      process.queue.sync {
        #expect(process.retirementAttempts == 1)
        #expect(process.finished)
      }
      #expect(await service.paneCount == 1)
      #expect(await !service.isEmpty)
    }
    // This injected-failure fixture's child is already reaped. Dropping the
    // service releases the retained bookkeeping; no retry is forced on loss.
    await client.close()
  }

  private final class GeometryObservations: Sendable {
    let values = Mutex<[UInt64]>([])
  }

  private final class PasteOutcome: Sendable {
    let value = Mutex<PasteState?>(nil)
  }

  private func eventually(_ predicate: () -> Bool) throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate() {
      guard ContinuousClock.now < deadline else {
        throw MuxError(.connectionLost, "pane admission timed out")
      }
      Thread.sleep(forTimeInterval: 0.01)
    }
  }

  private func wait(
    _ semaphore: DispatchSemaphore,
    seconds: Double = 8
  ) async -> Bool {
    await withCheckedContinuation { continuation in
      DispatchQueue.global()
        .async {
          continuation.resume(
            returning: semaphore.wait(timeout: .now() + seconds) == .success
          )
        }
    }
  }

  private func retire(_ service: MuxService, process: DelayedProcess) {
    process.queue.sync { process.releaseLaunch() }
    let done = DispatchSemaphore(value: 0)
    service.prepareToExit { done.signal() }
    #expect(done.wait(timeout: .now() + 8) == .success)
  }
}

/// Actual PTY/writer with delayed response delivery. This exercises the runtime
/// against bytes written before their admission response, as XPC permits.
private final class DelayedProcess: PaneProcess, @unchecked Sendable {
  let inner: GuardianPTY
  let queue: DispatchQueue
  var deferLaunch = false
  var started: (() -> Void)?
  var launchResult: (() -> Void)?
  var admissions: [() -> Void] = []
  var cancellation: (() -> Void)?
  var inputCancellations = 0
  init(
    id: PaneID,
    workspace: WorkspaceID,
    queue: DispatchQueue,
    limits: MuxLimits
  ) {
    self.queue = queue
    inner = GuardianPTY(
      id: id,
      workspace: workspace,
      queue: queue,
      limits: limits
    )
  }
  var pid: Int32 { inner.pid }
  var isOpen: Bool { inner.isOpen }
  var exitStatus: Int32? { inner.exitStatus }
  var finished: Bool { inner.finished }
  var childIsExiting: Bool { inner.childIsExiting }
  var replyReserve: Int { inner.replyReserve }
  var hasOpenPaste: Bool { inner.hasOpenPaste }
  var pasteID: UInt64? { inner.pasteID }
  var canConsume: (() -> Bool)? {
    get { inner.canConsume }
    set { inner.canConsume = newValue }
  }
  var consume: ((UnsafeBufferPointer<UInt8>) -> Int)? {
    get { inner.consume }
    set { inner.consume = newValue }
  }
  var filter: ((Data) -> Data)? {
    get { inner.filter }
    set { inner.filter = newValue }
  }
  var hasPendingReply: (() -> Bool)? {
    get { inner.hasPendingReply }
    set { inner.hasPendingReply = newValue }
  }
  var onBatch: (() -> Void)? {
    get { inner.onBatch }
    set { inner.onBatch = newValue }
  }
  var onInputReleased: ((Int) -> Void)? {
    get { inner.onInputReleased }
    set { inner.onInputReleased = newValue }
  }
  var onUnavailable: ((MuxError) -> Void)? {
    get { inner.onUnavailable }
    set { inner.onUnavailable = newValue }
  }
  var onFinished: ((Int32, Bool) -> Void)? {
    get { inner.onFinished }
    set { inner.onFinished = newValue }
  }
  func start(
    _ spec: LaunchSpec,
    launcher: PaneLauncher,
    columns: Int,
    rows: Int,
    completion: @escaping @Sendable (Result<Void, MuxError>) -> Void
  ) {
    inner.start(spec, launcher: launcher, columns: columns, rows: rows) {
      [self] result in
      if deferLaunch {
        launchResult = { completion(result) }
      } else {
        completion(result)
      }
      started?()
    }
  }
  func releaseLaunch() {
    let callback = launchResult;
    launchResult = nil;
    callback?()
  }
  func releaseAdmissions() {
    let callbacks = admissions;
    admissions.removeAll();
    for callback in callbacks { callback() }
  }
  func releaseCancellation() {
    let callback = cancellation;
    cancellation = nil;
    callback?()
  }
  func appendInput(
    _ bytes: [UInt8],
    admitted: @escaping @Sendable (Int) -> Void
  ) {
    inner.appendInput(bytes) { [self] count in
      admissions.append { admitted(count) }
    }
  }
  func appendReply(_ bytes: [UInt8]) -> Bool { inner.appendReply(bytes) }
  func beginPaste(
    id: UInt64,
    bracketed: Bool,
    admitted: @escaping @Sendable (Int) -> Void
  ) {
    inner.beginPaste(id: id, bracketed: bracketed) { [self] bytes in
      admissions.append { admitted(bytes) }
    }
  }
  func appendPaste(
    id: UInt64,
    text: String,
    admitted: @escaping @Sendable (Int) -> Void
  ) {
    inner.appendPaste(id: id, text: text) { [self] bytes in
      admissions.append { admitted(bytes) }
    }
  }
  func endPaste(id: UInt64) { inner.endPaste(id: id) }
  func cancelPaste(
    id: UInt64,
    discardDeferredInput: Bool,
    completion: @escaping @Sendable (Result<Bool, MuxError>) -> Void
  ) {
    inner.cancelPaste(id: id, discardDeferredInput: discardDeferredInput) {
      [self] wrote in cancellation = { completion(wrote) }
    }
  }
  func cancelInput() {
    inputCancellations += 1;
    inner.cancelInput()
  }
  var resizeError: MuxError?
  var deferResize = false
  var resizeCompletion: (() -> Void)?
  func resize(
    columns: Int,
    rows: Int,
    completion: @escaping @Sendable (Result<Void, MuxError>) -> Void
  ) {
    if let resizeError {
      resizeCompletion = { completion(.failure(resizeError)) }
      return
    }
    inner.resize(columns: columns, rows: rows) { [self] result in
      if deferResize {
        resizeCompletion = { completion(result) }
      } else {
        completion(result)
      }
    }
  }
  func releaseResize() {
    let callback = resizeCompletion
    resizeCompletion = nil
    callback?()
  }
  func flush() { inner.flush() }
  var deferRetirement = false
  var retirementAttempts = 0
  var retirementFailure: MuxError?
  var retirementCompletion: (() -> Void)?
  func retire(completion: @escaping @Sendable (MuxError?) -> Void) {
    retirementAttempts += 1
    if let error = retirementFailure {
      retirementFailure = nil
      completion(error)
      return
    }
    inner.retire { [self] error in
      if deferRetirement {
        retirementCompletion = { completion(error) }
      } else {
        completion(error)
      }
    }
  }
  func releaseRetirement() {
    let callback = retirementCompletion
    retirementCompletion = nil
    callback?()
  }
  func terminate() { inner.terminate() }
  func terminationStateForTesting() -> String {
    inner.terminationStateForTesting()
  }
}
