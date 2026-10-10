/// Checks element/byte counts before allocating pointer-backed storage.
@inline(__always)
package func checkedAllocationCount(_ count: Int, _ stride: Int) -> Int {
  precondition(count >= 0 && stride > 0)
  let (result, overflow) = count.multipliedReportingOverflow(by: stride)
  precondition(!overflow, "storage allocation size overflow")
  return result
}
