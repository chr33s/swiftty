#if os(macOS)
import Darwin

/// Darwin may expose its internal EREDRIVEOPEN (-6) when concurrent
/// callers open /dev/ptmx. Redrive that allocation a finite number of
/// times; ordinary POSIX errors retain their original result.
package enum PTYAllocation {
  package static func open(
    master: inout Int32,
    slave: inout Int32,
    name: UnsafeMutablePointer<CChar>? = nil,
    attributes: UnsafeMutablePointer<termios>? = nil,
    size: UnsafeMutablePointer<winsize>? = nil
  ) throws(POSIXError) {
    try redrive {
      let result = Darwin.openpty(&master, &slave, name, attributes, size)
      return (result, errno)
    }
  }

  package static func redrive(
    _ allocate: () -> (result: Int32, error: Int32)
  ) throws(POSIXError) {
    for attempt in 0 ..< 3 {
      let result = allocate()
      if result.result == 0 { return }
      guard result.error == -6, attempt < 2 else {
        throw POSIXError("openpty", code: result.error)
      }
    }
  }
}
#endif
