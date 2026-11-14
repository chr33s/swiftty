import Darwin
@testable import SwifttyEngine
import Testing
import TestSupport

struct CStringVectorTests {
  @Test(arguments: 0 ..< 6)
  func failedCopyNeverInvokesSpawnBodyAndFreesBothVectors(_ failure: Int) {
    let strings = ["program", "spaces '$'", "漢👩‍💻", ""]
    let env = ["MODE=test", "EMPTY="]
    let allocator = CStringAllocationFixture(failingAt: failure)
    var invoked = false
    do {
      try CStringVector.withStrings(
        strings,
        copying: allocator.copy,
        freeing: allocator.release
      ) { _ throws(POSIXError) in
        try CStringVector.withStrings(
          env,
          copying: allocator.copy,
          freeing: allocator.release
        ) { _ in invoked = true }
      }
      Issue.record("Failed allocation was accepted")
    } catch {
      #expect(error.code == ENOMEM)
      #expect(error.operation == "strdup")
    }
    #expect(!invoked)
    #expect(allocator.attempts == failure + 1)
    #expect(allocator.allocations == allocator.frees)
    #expect(allocator.liveCount == 0)
    #expect(allocator.invalidFrees == 0)
  }

  @Test
  func successfulVectorsPreserveEveryStringAndOneFinalTerminator() throws {
    for strings in [[], ["program", "漢👩‍💻", "", "spaces '$'"]] {
      let allocator = CStringAllocationFixture()
      let count = try CStringVector.withStrings(
        strings,
        copying: allocator.copy,
        freeing: allocator.release
      ) { pointers in
        for (index, string) in strings.enumerated() {
          #expect(pointers[index].map { String(cString: $0) } == string)
        }
        #expect(pointers[strings.count] == nil)
        return strings.count
      }
      #expect(count == strings.count)
      #expect(allocator.allocations == strings.count)
      #expect(allocator.frees == strings.count && allocator.liveCount == 0)
      #expect(allocator.invalidFrees == 0)
    }
  }

  @Test
  func bodyErrorReleasesCopiesAndKeepsItsError() {
    let allocator = CStringAllocationFixture()
    do {
      let _: Int = try CStringVector.withStrings(
        ["a", "b"],
        copying: allocator.copy,
        freeing: allocator.release
      ) { _ throws(POSIXError) in throw POSIXError("body", code: EBUSY) }
      Issue.record("Body failure was lost")
    } catch { #expect(error.code == EBUSY && error.operation == "body") }
    #expect(allocator.allocations == 2 && allocator.frees == 2)
    #expect(allocator.liveCount == 0 && allocator.invalidFrees == 0)
  }

  @Test
  func embeddedNULIsRejectedBeforeItsCopyOrBody() {
    let allocator = CStringAllocationFixture()
    var invoked = false
    do {
      try CStringVector.withStrings(
        ["a", "b\0c"],
        copying: allocator.copy,
        freeing: allocator.release
      ) { _ in invoked = true }
      Issue.record("Truncated string was accepted")
    } catch { #expect(error.code == EINVAL) }
    #expect(!invoked && allocator.attempts == 1)
    #expect(allocator.frees == 1 && allocator.liveCount == 0)
  }
}
