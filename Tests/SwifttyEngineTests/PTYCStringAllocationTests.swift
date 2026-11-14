#if os(macOS)
import Darwin
@testable import SwifttyEngine
import TestSupport
import Testing

struct PTYCStringAllocationTests {
  @Test(arguments: [false, true], [false, true])
  func allocationFailureRejectsSpawnAndFreesCopies(
    _ environment: Bool,
    _ retainingSlave: Bool
  ) {
    let allocator = CStringAllocationFixture(
      failingString: environment ? "SWIFTTY_FAULT=value" : "fault input"
    )
    let config = SessionConfiguration(
      command: ["/usr/bin/true", "fault input", "最後"],
      environment: ["SWIFTTY_FAULT": "value"]
    )
    do {
      let process = try PTYProcess.spawn(
        config,
        columns: 10,
        rows: 2,
        cellPixelSize: (0, 0),
        retainingSlaveForDrain: retainingSlave,
        copyingCString: allocator.copy,
        freeingCString: allocator.release
      )
      let owned = OwnedChildWait(process.pid)
      #expect(owned.terminate())
      Issue.record("Incomplete argument/environment vector spawned a child")
    } catch {
      #expect(error.code == ENOMEM)
      #expect(error.operation == "strdup")
    }
    #expect(allocator.allocations == allocator.frees)
    #expect(allocator.liveCount == 0 && allocator.invalidFrees == 0)
  }
}
#endif
