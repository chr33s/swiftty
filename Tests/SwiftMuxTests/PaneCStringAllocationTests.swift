import SwiftMuxGuardian
import Darwin
import SwiftMuxProtocol
@testable import SwiftMuxService
import TestSupport
import Testing

@Suite(.serialized)
struct PaneCStringAllocationTests {
  @Test(arguments: [false, true])
  func allocationFailureRejectsLauncherAndFreesCopies(
    _ environment: Bool
  ) throws {
    let allocator = CStringAllocationFixture(
      failingString: environment ? "SWIFTTY_FAULT=value" : "fault input"
    )
    let launcher = PaneLauncher(
      launcherPath: try launcherPath(),
      innerTerm: "xterm-256color"
    )
    let spec = LaunchSpec(
      command: ["/usr/bin/true", "fault input", "最後"],
      environment: ["SWIFTTY_FAULT": "value"]
    )
    do {
      let child = try launcher.launch(
        spec,
        pane: PaneID(),
        workspace: WorkspaceID(),
        columns: 10,
        rows: 2,
        copyingCString: allocator.copy,
        freeingCString: allocator.release
      )
      let owned = OwnedChildWait(child.pid)
      close(child.master)
      close(child.slave)
      #expect(owned.terminate())
      Issue.record("Incomplete vector spawned a launcher")
    } catch {
      #expect(error.code == .launchFailed)
      #expect(error.message.contains("strdup"))
      #expect(error.message.contains(String(cString: strerror(ENOMEM))))
    }
    #expect(allocator.allocations == allocator.frees)
    #expect(allocator.liveCount == 0 && allocator.invalidFrees == 0)
  }
}
