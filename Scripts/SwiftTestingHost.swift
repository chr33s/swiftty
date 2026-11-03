import AppKit
import Darwin
import Foundation

/// Swift Testing's versioned ABI for tools loading an existing test binary.
/// https://github.com/swiftlang/swift-testing/blob/main/Sources/Testing/ABI/EntryPoints/ABIEntryPoint.swift
private typealias EntryPoint =
  @convention(thin) @Sendable (
    UnsafeRawBufferPointer?,
    @escaping @Sendable (UnsafeRawBufferPointer) -> Void,
  ) async throws -> Bool

private final class RunEvidence: @unchecked Sendable {
  private let lock = NSLock()
  private var runStarted = false
  private var runEnded = false
  private var functions = 0
  private var started: Set<String> = []
  private var ended: Set<String> = []
  private var valid = true

  func record(_ bytes: UnsafeRawBufferPointer) {
    lock.lock()
    defer { lock.unlock() }
    guard let object = try? JSONSerialization.jsonObject(with: Data(bytes)),
      let record = object as? [String: Any], record["version"] as? Int == 0,
      let payload = record["payload"] as? [String: Any]
    else {
      valid = false
      return
    }
    if record["kind"] as? String == "test" {
      if payload["kind"] as? String == "function" { functions += 1 }
      return
    }
    guard record["kind"] as? String == "event" else {
      valid = false
      return
    }
    switch payload["kind"] as? String {
    case "runStarted":
      valid = valid && !runStarted
      runStarted = true
    case "runEnded":
      valid = valid && runStarted && !runEnded && started == ended
      runEnded = true
    case "testStarted", "testEnded":
      guard runStarted, !runEnded, let id = payload["testID"] as? String else {
        valid = false
        return
      }
      if payload["kind"] as? String == "testStarted" {
        valid = started.insert(id).inserted && valid
      } else {
        valid = started.contains(id) && ended.insert(id).inserted && valid
      }
    default: break
    }
  }

  var completed: Bool {
    lock.lock()
    defer { lock.unlock() }
    return valid && functions > 0 && runStarted && runEnded && started == ended
  }
}

@main
struct SwiftTestingHost {
  static func main() {
    guard let path = ProcessInfo.processInfo.environment["SWIFTTY_TEST_BUNDLE"],
      let bundle = dlopen(path, RTLD_NOW | RTLD_GLOBAL),
      let symbol = dlsym(bundle, "swt_abiv0_getEntryPoint")
    else {
      let reason = dlerror().map { String(cString: $0) } ?? "SWIFTTY_TEST_BUNDLE is unset"
      fputs(
        "Unable to load the Swift Testing bundle or ABI entry point: \(reason)\n",
        stderr,
      )
      exit(1)
    }
    let getter = unsafeBitCast(
      symbol,
      to: (@convention(c) () -> UnsafeRawPointer).self,
    )
    let entry = unsafeBitCast(getter(), to: EntryPoint.self)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    let evidence = RunEvidence()
    Task {
      do {
        // Pin the JSON schema used by the completion audit. Static storage
        // keeps this buffer valid across the asynchronous ABI call.
        // Suites share AppKit state and some synchronously wait for dispatch
        // callbacks. Run them serially so small CI runners cannot starve those
        // callbacks behind unrelated tests on the cooperative thread pool.
        let configuration: StaticString =
          #"{"eventStreamVersion":0,"parallel":false}"#
        let bytes = UnsafeRawBufferPointer(
          start: configuration.utf8Start,
          count: configuration.utf8CodeUnitCount,
        )
        let success = try await entry(bytes) { evidence.record($0) }
        guard success else { exit(1) }
        guard evidence.completed else {
          fputs("Test bundle did not report a complete nonempty run\n", stderr)
          exit(1)
        }
        exit(0)
      } catch {
        fputs("Swift Testing could not start the test run\n", stderr)
        exit(1)
      }
    }
    // Native views and presentations need the application's event loop.
    // CFRunLoop stops do not end it; completion above chooses the status.
    app.run()
    fputs("AppKit loop ended before completed test execution\n", stderr)
    exit(1)
  }
}
