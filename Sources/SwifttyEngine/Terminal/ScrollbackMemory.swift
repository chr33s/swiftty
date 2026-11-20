import Darwin

/// Darwin virtual-memory adapter for dedicated cell mappings.
///
/// Only regions returned by `map` may be reclaimed, reused or unmapped.
/// Swift heap, `Array` and shared allocations never reach `madvise`.
enum ScrollbackMemory {
  static let pageSize = Int(getpagesize())

  /// Whether the mapped (reclaimable, compressible) backend is validated
  /// on this platform: native macOS and iOS/iPadOS (measured on a physical
  /// iPad, see spec.scrollback.md §17). Catalyst, visionOS and tvOS keep
  /// heap chunks until measured.
  static var isSupported: Bool {
    #if (os(macOS) || os(iOS)) && !targetEnvironment(macCatalyst)
    true
    #else
    false
    #endif
  }

  /// `bytes` rounded up to whole pages; traps on overflow.
  static func roundUp(_ bytes: Int) -> Int {
    precondition(bytes >= 0)
    let (sum, overflow) = bytes.addingReportingOverflow(pageSize - 1)
    precondition(!overflow, "mapping size overflow")
    return sum / pageSize * pageSize
  }

  static func roundDown(_ bytes: Int) -> Int {
    precondition(bytes >= 0)
    return bytes / pageSize * pageSize
  }

  /// A private anonymous mapping of whole pages, zero-filled and lazily
  /// committed by the OS; nil when address space is unavailable.
  static func map(_ bytes: Int) -> UnsafeMutableRawPointer? {
    precondition(bytes > 0 && bytes % pageSize == 0)
    let p = mmap(
      nil,
      bytes,
      PROT_READ | PROT_WRITE,
      MAP_PRIVATE | MAP_ANON,
      -1,
      0
    )
    return p == MAP_FAILED ? nil : p
  }

  /// Ends a mapping created by `map`. Called exactly once per mapping.
  static func unmap(_ p: UnsafeMutableRawPointer, _ bytes: Int) {
    let result = munmap(p, bytes)
    precondition(result == 0, "munmap failed")
  }

  /// Marks pages reusable: their contents may be discarded at any time and
  /// must no longer be trusted. Returns false if the advice was refused.
  static func reclaim(_ p: UnsafeMutableRawPointer, _ bytes: Int) -> Bool {
    precondition(Int(bitPattern: p) % pageSize == 0 && bytes % pageSize == 0)
    return madvise(p, bytes, MADV_FREE_REUSABLE) == 0
  }

  /// Recommits pages previously passed to `reclaim` before writing them.
  static func reuse(_ p: UnsafeMutableRawPointer, _ bytes: Int) {
    precondition(Int(bitPattern: p) % pageSize == 0 && bytes % pageSize == 0)
    // Failure only affects accounting: the pages remain mapped and writable.
    _ = madvise(p, bytes, MADV_FREE_REUSE)
  }
}

/// Current process memory, sampled through supported platform APIs.
public struct ProcessMemorySample: Sendable, Equatable {
  /// Resident set size in bytes.
  public var residentBytes: Int
  /// Physical footprint (what Activity Monitor reports) in bytes.
  public var physicalFootprintBytes: Int

  /// Samples the current task; zeros when the query fails.
  public static func current() -> ProcessMemorySample {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    guard result == KERN_SUCCESS else {
      return ProcessMemorySample(residentBytes: 0, physicalFootprintBytes: 0)
    }
    return ProcessMemorySample(
      residentBytes: Int(info.resident_size),
      physicalFootprintBytes: Int(info.phys_footprint)
    )
  }
}
