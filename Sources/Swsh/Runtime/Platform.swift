#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// System calls whose names collide with members in this module. Each forwards
// to the platform C library without changing arguments or errno.
func systemRead(
  _ fd: Int32,
  _ buffer: UnsafeMutableRawPointer?,
  _ count: Int
) -> Int { read(fd, buffer, count) }
func systemWrite(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int
{ write(fd, buffer, count) }
@discardableResult
func systemClose(_ fd: Int32) -> Int32 { close(fd) }
func systemOpen(
  _ path: UnsafePointer<CChar>,
  _ flags: Int32,
  _ mode: mode_t
) -> Int32 { open(path, flags, mode) }
func systemPipe(_ descriptors: UnsafeMutablePointer<Int32>) -> Int32 {
  pipe(descriptors)
}
func systemPoll(
  _ descriptors: UnsafeMutablePointer<pollfd>,
  _ count: Int,
  _ timeout: Int32
) -> Int32 { poll(descriptors, nfds_t(count), timeout) }

#if canImport(Darwin)
let systemDatagramSocket = SOCK_DGRAM
#else
let systemDatagramSocket = Int32(SOCK_DGRAM.rawValue)
#endif
