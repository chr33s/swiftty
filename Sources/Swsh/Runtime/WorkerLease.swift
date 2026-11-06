#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// One supervisor-owned read endpoint per source worker. The worker announces its
/// reaper before evaluating source and keeps the write end CLOEXEC. EOF therefore
/// distinguishes an exec replacement from a process that still owns child cleanup.
struct WorkerLease: ~Copyable {
  let pid: pid_t
  private let input: OwnedFD
  private var announced = false

  init(pid: pid_t, input: consuming OwnedFD) {
    self.pid = pid
    self.input = input
  }

  mutating func isSupervising() -> Bool {
    input.withDescriptor { fd in
      var byte: UInt8 = 0
      while true {
        let count = systemRead(fd, &byte, 1)
        if count == 1 {
          announced = byte == 1;
          continue
        }
        if count < 0 && errno == EINTR { continue }
        if count == 0 || (count < 0 && errno != EAGAIN) { announced = false }
        return announced
      }
    }
  }
}
