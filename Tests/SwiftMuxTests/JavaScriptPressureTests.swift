import Dispatch
import Foundation
import SwiftMuxProtocol
@testable import SwiftMuxService
import SwifttyJS
import Synchronization
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct JavaScriptPressureTests {
  @Test
  func stdinExpansionFallsBackWhilePTYIsBlocked() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let gate = directory.appendingPathComponent("read")
    let result = directory.appendingPathComponent("result")
    let javascript = JavaScriptRuntime()
    try javascript.evaluate("swiftty.filter.onStdin(() => 'X'.repeat(65536))")
    let blocked = Mutex(false)
    var config = MuxServiceConfiguration(launcherPath: try launcherPath())
    config.javaScriptRuntime = javascript
    config.limits.inputBytesPerPane = 65536
    config.observePaneIO = { _, observation in
      if observation.phase == .writeBlocked { blocked.withLock { $0 = true } }
    }
    let harness = try Harness(configuration: config)
    defer { retire(harness.service) }
    let connection = try await harness.connect(.control)
    let program = """
      import os,sys,tty,time
      tty.setraw(0)
      os.write(1,b'READY\\r\\n')
      deadline=time.monotonic()+10
      while not os.path.exists(sys.argv[1]):
          if time.monotonic()>deadline: os._exit(99)
          time.sleep(0.005)
      data=b''
      while len(data)<65537: data+=os.read(0,65537-len(data))
      with open(sys.argv[2],'w') as f: f.write('MATCH' if data==b'X'*65536+b'a' else 'BAD')
      """
    guard
      case let .created(workspace) = try await connection.execute(
        .newWorkspace(
          NewWorkspaceRequest(
            launch: LaunchSpec(command: [
              "/usr/bin/python3", "-u", "-c", program, gate.path, result.path,
            ]),
            remainOnExit: true
          )
        )
      )
    else { throw MuxError(.invalidRequest) }
    let runtime = try #require(
      await harness.service.runtime(workspace.tabs[0].activePane)
    )
    let readyDeadline = ContinuousClock.now + .seconds(5)
    while !runtime.screenLines().contains(where: { $0.contains("READY") }),
      ContinuousClock.now < readyDeadline
    { try await Task.sleep(for: .milliseconds(10)) }
    try #require(runtime.screenLines().contains { $0.contains("READY") })
    try #require(runtime.reserve(1))
    runtime.write(.text("a"), estimate: 1)
    let blockedDeadline = ContinuousClock.now + .seconds(5)
    while !blocked.withLock({ $0 }) && ContinuousClock.now < blockedDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(blocked.withLock { $0 })
    try #require(runtime.outstandingInput.withLock { $0 } > 0)
    try #require(runtime.reserve(1))
    runtime.write(.text("a"), estimate: 1)
    // Wait for filtering and admission before allowing the child to drain.
    runtime.queue.sync {}
    #expect(
      runtime.outstandingInput.withLock { $0 }
        <= config.limits.inputBytesPerPane
    )
    try Data().write(to: gate)
    let deadline = ContinuousClock.now + .seconds(5)
    while (try? String(contentsOf: result, encoding: .utf8)) != "MATCH",
      ContinuousClock.now < deadline
    { try await Task.sleep(for: .milliseconds(10)) }
    #expect(try String(contentsOf: result, encoding: .utf8) == "MATCH")
    #expect(runtime.outstandingInput.withLock { $0 } == 0)
    await connection.close()
  }

  private func retire(_ service: MuxService) {
    let done = DispatchSemaphore(value: 0)
    service.prepareToExit { done.signal() }
    #expect(done.wait(timeout: .now() + 5) == .success)
  }

  @Test(arguments: ["", "x"])
  func continuousFilteredOutputAllowsInputAndTermination(
    replacement: String
  ) async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let result = directory.appendingPathComponent("input")
    let javascript = JavaScriptRuntime()
    try javascript.evaluate("swiftty.filter.onStdout(() => '\(replacement)')")
    let readBytes = Mutex(0)
    var config = MuxServiceConfiguration(launcherPath: try launcherPath())
    config.javaScriptRuntime = javascript
    config.observePaneIO = { _, observation in
      if observation.phase == .read {
        readBytes.withLock { $0 += observation.byteCount }
      }
    }
    let harness = try Harness(configuration: config)
    var retired = false
    defer { if !retired { retire(harness.service) } }
    let connection = try await harness.connect(.control)
    let program = """
      import os,sys,tty,threading,time
      tty.setraw(0)
      def flood():
          while True: os.write(1,b'x'*4096)
      def watchdog():
          time.sleep(10)
          os._exit(99)
      threading.Thread(target=watchdog,daemon=True).start()
      threading.Thread(target=flood,daemon=True).start()
      data=os.read(0,1)
      with open(sys.argv[1],'wb') as f: f.write(data)
      while True: time.sleep(1)
      """
    guard
      case let .created(workspace) = try await connection.execute(
        .newWorkspace(
          NewWorkspaceRequest(
            launch: LaunchSpec(command: [
              "/usr/bin/python3", "-u", "-c", program, result.path,
            ])
          )
        )
      )
    else { throw MuxError(.invalidRequest) }
    let runtime = try #require(
      await harness.service.runtime(workspace.tabs[0].activePane)
    )
    let floodDeadline = ContinuousClock.now + .seconds(5)
    while readBytes.withLock({ $0 }) < 128 << 10
      && ContinuousClock.now < floodDeadline
    { try await Task.sleep(for: .milliseconds(10)) }
    try #require(readBytes.withLock { $0 } >= 128 << 10)
    let inputStart = ContinuousClock.now
    try #require(runtime.reserve(1))
    runtime.write(.text("k"), estimate: 1)
    while (try? Data(contentsOf: result)) != Data("k".utf8),
      ContinuousClock.now - inputStart < .seconds(2)
    { try await Task.sleep(for: .milliseconds(10)) }
    #expect(try Data(contentsOf: result) == Data("k".utf8))
    #expect(ContinuousClock.now - inputStart < .seconds(2))
    let before = readBytes.withLock { $0 }
    let continuingDeadline = ContinuousClock.now + .seconds(2)
    while readBytes.withLock({ $0 }) == before
      && ContinuousClock.now < continuingDeadline
    { try await Task.sleep(for: .milliseconds(10)) }
    try #require(readBytes.withLock { $0 } > before)
    let closeStart = ContinuousClock.now
    retire(harness.service)
    retired = true
    #expect(ContinuousClock.now - closeStart < .seconds(5))
    #expect(runtime.outstandingInput.withLock { $0 } == 0)
    await connection.close()
  }

  @Test(arguments: [false, true])
  func stdinExpansionRespectsAlreadyAdmittedInput(full: Bool) async throws {
    let javascript = JavaScriptRuntime()
    try javascript.evaluate(
      "swiftty.filter.onStdin(s => s === 'a' ? 'X'.repeat(16) : s)"
    )
    var config = MuxServiceConfiguration(launcherPath: try launcherPath())
    config.javaScriptRuntime = javascript
    config.limits.inputBytesPerPane = 32
    let harness = try Harness(configuration: config)
    defer { retire(harness.service) }
    let connection = try await harness.connect(.control)
    let tail = String(repeating: "b", count: full ? 31 : 15)
    let expected = (full ? "a" : String(repeating: "X", count: 16)) + tail
    let program = """
      import os,tty
      tty.setraw(0)
      os.write(1,b'READY\\r\\n')
      data=b''
      while len(data)<\(expected.utf8.count): data+=os.read(0,\(expected.utf8.count)-len(data))
      os.write(1,b'GOT:'+data+b'\\r\\n')
      """
    guard
      case let .created(workspace) = try await connection.execute(
        .newWorkspace(
          NewWorkspaceRequest(
            launch: LaunchSpec(command: [
              "/usr/bin/python3", "-u", "-c", program,
            ]),
            remainOnExit: true
          )
        )
      )
    else { throw MuxError(.invalidRequest) }
    let runtime = try #require(
      await harness.service.runtime(workspace.tabs[0].activePane)
    )
    let readyDeadline = ContinuousClock.now + .seconds(5)
    while !runtime.screenLines().contains(where: { $0.contains("READY") }),
      ContinuousClock.now < readyDeadline
    { try await Task.sleep(for: .milliseconds(10)) }
    try #require(runtime.screenLines().contains { $0.contains("READY") })
    // Admit both writes before either can run its filter. The second write's
    // credit must remain unavailable to the first write's expansion.
    try runtime.queue.sync {
      try #require(runtime.reserve(1))
      try #require(runtime.reserve(tail.utf8.count))
      runtime.write(.text("a"), estimate: 1)
      runtime.write(.text(tail), estimate: tail.utf8.count)
    }
    let deadline = ContinuousClock.now + .seconds(5)
    while !runtime.screenLines()
      .contains(where: { $0.contains("GOT:" + expected) }),
      ContinuousClock.now < deadline
    { try await Task.sleep(for: .milliseconds(10)) }
    #expect(runtime.screenLines().contains { $0.contains("GOT:" + expected) })
    #expect(runtime.outstandingInput.withLock { $0 } == 0)
    await connection.close()
  }
}
