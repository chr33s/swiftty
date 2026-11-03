import Darwin
import Dispatch
import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
@testable import SwiftMuxService
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct PaneReplyPressureTests {
  static let program = #"""
    import os,sys,time,tty,threading,select
    tty.setraw(0)
    gate,result,mode=sys.argv[1:]
    def watchdog():
        time.sleep(12)
        os._exit(99)
    threading.Thread(target=watchdog,daemon=True).start()
    count=4 if mode=='drain' else 3
    body=b'4;'+b'1;?;'*2047+b';;'
    request=b'\x1b]'+body+b'\x1b\\'
    if mode=='exit': request=b'\x1bP+q544E\x1b\\'
    expected=b'\x1b]4;1;rgb:bfbf/3939/2a2a\x1b\\'*(2047*count)
    os.write(1,b'READY\n')
    def queries():
        data=request*count
        while data: data=data[os.write(1,data):]
    writer=threading.Thread(target=queries,daemon=True)
    writer.start()
    while not os.path.exists(gate): time.sleep(0.005)
    if mode=='drain':
        offset=0
        deadline=time.monotonic()+4
        while offset<len(expected):
            remaining=deadline-time.monotonic()
            if remaining<=0 or not select.select([0],[],[],remaining)[0]: break
            data=os.read(0,min(65536,len(expected)-offset))
            if not data or data!=expected[offset:offset+len(data)]: break
            offset+=len(data)
        with open(result,'w') as f: f.write('MATCH' if offset==len(expected) else 'MISSING:'+str(offset))
    writer.join(timeout=2)
    if mode=='exit':
        with open(result,'w') as f: f.write('BEFORE_FINAL')
    os.write(1,b'FINAL\n')
    if mode=='exit':
        with open(result,'w') as f: f.write('FINAL_WRITTEN')
    os._exit(7)
    """#

  private func retire(_ service: MuxService) {
    let done = DispatchSemaphore(value: 0)
    service.prepareToExit { done.signal() }
    #expect(done.wait(timeout: .now() + 5) == .success)
  }

  @Test(arguments: ["drain", "exit", "close"])
  func colorQueryBatchesPreserveRepliesAndExitOutput(mode: String) async throws
  {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pane-reply-pressure-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
    )
    let gate = directory.appendingPathComponent("release")
    let result = directory.appendingPathComponent("result")
    var configuration = try MuxServiceConfiguration(
      launcherPath: launcherPath()
    )
    if mode == "exit" {
      // Short requests produce large replies, so the complete query burst
      // is written before exit even when reply pressure pauses parsing.
      configuration.innerTerm = String(repeating: "a", count: 16378)
    }
    let service = try MuxService(configuration: configuration)
    var retired = false
    defer {
      if !retired { retire(service) }
      try? FileManager.default.removeItem(at: directory)
    }
    let c = try await SwiftMuxClient.MuxConnection.connect(
      endpoint: service.listenAnonymously(),
      frontend: .control,
    )
    var launch = shellLaunch()
    launch.command = [
      "/usr/bin/python3", "-u", "-c", Self.program, gate.path, result.path,
      mode,
    ]
    guard
      case let .created(workspace) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: launch, remainOnExit: true, ))
      )
    else { throw MuxError(.invalidRequest, "unexpected workspace") }
    let runtime = try #require(
      await service.runtime(workspace.tabs[0].activePane)
    )
    let ready = ContinuousClock.now + .seconds(4)
    while !runtime.screenLines().contains(where: { $0.contains("READY") }),
      ContinuousClock.now < ready
    { try await Task.sleep(for: .milliseconds(10)) }
    try #require(
      runtime.screenLines().contains(where: { $0.contains("READY") })
    )
    // Hold the child's input reader while the pane parses the query burst.
    try await Task.sleep(for: .milliseconds(100))
    let held: Int = await withCheckedContinuation { continuation in
      runtime.inspect {
        $0.output.count
      } completion: {
        continuation.resume(returning: $0)
      }
    }
    #expect(held > 0 && held <= 64 << 10)
    if mode == "close" {
      let pid = runtime.pid
      retire(service)
      retired = true
      var info = siginfo_t()
      #expect(
        waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == -1
      )
      #expect(errno == ECHILD)
      await c.close()
      return
    }
    try Data().write(to: gate, options: .atomic)
    let deadline = ContinuousClock.now + .seconds(7)
    while !runtime.screenLines().contains(where: { $0.contains("FINAL") }),
      ContinuousClock.now < deadline
    { try await Task.sleep(for: .milliseconds(10)) }
    #expect(runtime.screenLines().contains(where: { $0.contains("FINAL") }))
    #expect(
      try String(contentsOf: result, encoding: .utf8)
        == (mode == "drain" ? "MATCH" : "FINAL_WRITTEN")
    )
    await c.close()
  }
}
