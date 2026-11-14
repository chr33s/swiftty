#if os(macOS)
import Darwin
import Dispatch
import Synchronization
@testable import SwifttyEngine
import Testing

struct PTYAllocationTests {
  @Test
  func `kernel redrive completes without losing the allocation`() throws {
    var calls = 0
    try PTYAllocation.redrive {
      calls += 1
      return calls < 3 ? (-1, -6) : (0, 0)
    }
    #expect(calls == 3)
  }

  @Test(arguments: [Int32(-6), EINTR, EIO, EMFILE])
  func `persistent allocation errors are bounded and preserved`(error: Int32) {
    var calls = 0
    do {
      try PTYAllocation.redrive {
        calls += 1
        return (-1, error)
      }
      Issue.record("persistent error accepted")
    } catch let failure {
      #expect(failure.operation == "openpty")
      #expect(failure.code == error)
    }
    #expect(calls == (error == -6 ? 3 : 1))
  }

  @Test
  func `concurrent allocations return usable terminal descriptors`() {
    let failures = Mutex<[String]>([])
    DispatchQueue.concurrentPerform(iterations: 32) { _ in
      for _ in 0 ..< 300 {
        var master: Int32 = -1
        var slave: Int32 = -1
        do {
          try PTYAllocation.open(master: &master, slave: &slave)
          if isatty(master) == 0 || isatty(slave) == 0 {
            failures.withLock { $0.append("allocation is not a terminal") }
          }
          close(master)
          close(slave)
        } catch { failures.withLock { $0.append(String(describing: error)) } }
      }
    }
    #expect(failures.withLock { $0 }.isEmpty)
  }

  @Test
  func `allocation preserves slave name and initial geometry`() throws {
    var master: Int32 = -1
    var slave: Int32 = -1
    var name = [CChar](repeating: 0, count: 128)
    var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
    try PTYAllocation.open(
      master: &master,
      slave: &slave,
      name: &name,
      size: &size
    )
    defer {
      close(master)
      close(slave)
    }
    var actual = winsize()
    let geometry = ioctl(slave, TIOCGWINSZ, &actual)
    #expect(geometry == 0)
    #expect(actual.ws_row == 24 && actual.ws_col == 80)
    var masterName = [CChar](repeating: 0, count: 128)
    let named = masterName.withUnsafeMutableBufferPointer {
      ioctl(master, TIOCPTYGNAME, $0.baseAddress!)
    }
    #expect(named == 0)
    #expect(name == masterName)
  }

}
#endif
