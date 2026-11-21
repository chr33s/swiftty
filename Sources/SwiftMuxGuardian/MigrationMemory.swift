import Darwin
import Foundation

/// Peak-memory admission for planned replacement (spec.durability.md §7.2
/// step 1). While both workers run and the guardian holds the checkpoint,
/// the host needs roughly the old worker's footprint twice over.
package struct MigrationMemory: Sendable {
  /// Bytes the system can supply without paging out other work.
  package var available: @Sendable () -> UInt64
  /// The worker's physical footprint.
  package var footprint: @Sendable (Int32) -> UInt64

  package init(
    available: @escaping @Sendable () -> UInt64,
    footprint: @escaping @Sendable (Int32) -> UInt64
  ) {
    self.available = available
    self.footprint = footprint
  }

  /// A floor for tiny workers: the transfer itself buffers chunks.
  package static let minimumReserve: UInt64 = 64 << 20

  /// Bytes to require before preparing: a candidate as large as the old
  /// worker, plus a checkpoint copy no larger than it.
  package func required(for pid: Int32) -> UInt64 {
    let (doubled, overflow) = footprint(pid).multipliedReportingOverflow(by: 2)
    return overflow ? .max : max(Self.minimumReserve, doubled)
  }

  package static let system = MigrationMemory(
    available: {
      var stats = vm_statistics64()
      var count = mach_msg_type_number_t(
        MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size
      )
      let result = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
          host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
      }
      guard result == KERN_SUCCESS else { return 0 }
      let pages =
        UInt64(stats.free_count) + UInt64(stats.inactive_count)
        + UInt64(stats.purgeable_count)
      return pages * UInt64(getpagesize())
    },
    footprint: { pid in
      var info = rusage_info_v4()
      let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
          proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
        }
      }
      return result == 0 ? info.ri_phys_footprint : 0
    }
  )
}
