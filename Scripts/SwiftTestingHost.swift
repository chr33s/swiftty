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

/// The run's configuration JSON, written once before the run and only
/// read after.
private struct ConfigurationBytes: @unchecked Sendable {
  let bytes: UnsafeRawBufferPointer
}

private final class RunEvidence: @unchecked Sendable {
  private let lock = NSLock()
  private var runStarted = false
  private var runEnded = false
  private var functions = 0
  private var started: Set<String> = []
  private var ended: Set<String> = []
  private var valid = true
  /// A filtered run may select no test in this bundle.
  let allowsEmpty: Bool

  init(allowsEmpty: Bool) { self.allowsEmpty = allowsEmpty }

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
    return valid && (functions > 0 || allowsEmpty) && runStarted && runEnded
      && started == ended
  }
}

/// A bundle built by a swift.org toolchain links that toolchain's
/// libTesting.dylib, while Xcode's XCTest can also load Testing.framework.
/// Both copies export the ABI entry point, but each discovers only tests
/// registered against its own types, so use the copy the bundle links.
private func entryPointSymbol(
  bundle: UnsafeMutableRawPointer
) -> UnsafeMutableRawPointer? {
  let environment = ProcessInfo.processInfo.environment
  guard let library = environment["SWIFTTY_TESTING_LIBRARY"], !library.isEmpty
  else { return dlsym(bundle, "swt_abiv0_getEntryPoint") }
  // An @rpath install name resolves through DYLD_*_PATH, so match its tail.
  // dyld reports absolute images by their resolved path.
  func resolved(_ path: String) -> String {
    guard let real = realpath(path, nil) else { return path }
    defer { free(real) }
    return String(cString: real)
  }
  let relative =
    library.hasPrefix("@rpath/") ? String(library.dropFirst(7)) : nil
  let absolute = resolved(library)
  for index in 0 ..< _dyld_image_count() {
    guard let name = _dyld_get_image_name(index).map({ String(cString: $0) }),
      relative.map({ name.hasSuffix("/" + $0) })
        ?? (resolved(name) == absolute),
      let image = dlopen(name, RTLD_NOW | RTLD_NOLOAD)
    else { continue }
    if let symbol = dlsym(image, "swt_abiv0_getEntryPoint") { return symbol }
  }
  fputs(
    "The test bundle's Swift Testing library \(library) is not loaded\n",
    stderr
  )
  return nil
}

@main
struct SwiftTestingHost {
  static func main() {
    // The runtime has already read it for this host. Children inherit it,
    // and privileged ones such as /usr/bin/python3 then print a warning
    // into the terminal output tests compare byte for byte.
    unsetenv("SWIFT_BACKTRACE")
    guard let path = ProcessInfo.processInfo.environment["SWIFTTY_TEST_BUNDLE"],
      let bundle = dlopen(path, RTLD_NOW | RTLD_GLOBAL),
      let symbol = entryPointSymbol(bundle: bundle)
    else {
      let reason =
        dlerror().map { String(cString: $0) }
        ?? (ProcessInfo.processInfo.environment["SWIFTTY_TEST_BUNDLE"] == nil
          ? "SWIFTTY_TEST_BUNDLE is unset" : "entry point not found")
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
    // Newline-separated patterns (`--filter` in test-native.sh).
    let filters =
      (ProcessInfo.processInfo.environment["SWIFTTY_TEST_FILTER"] ?? "")
      .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    let evidence = RunEvidence(allowsEmpty: !filters.isEmpty)
    var arguments: [String: Any] = ["eventStreamVersion": 0, "parallel": false]
    if !filters.isEmpty { arguments["filter"] = filters }
    // Never freed: the ABI call reads it until the process exits.
    let encoded = try! JSONSerialization.data(withJSONObject: arguments)
    let storage = UnsafeMutableRawBufferPointer.allocate(
      byteCount: encoded.count,
      alignment: 1
    )
    storage.copyBytes(from: encoded)
    let configuration = ConfigurationBytes(
      bytes: UnsafeRawBufferPointer(storage)
    )
    Task {
      do {
        // `configuration` pins the JSON schema used by the completion audit.
        // Suites share AppKit state and some synchronously wait for dispatch
        // callbacks. Run them serially so small CI runners cannot starve those
        // callbacks behind unrelated tests on the cooperative thread pool.
        let success = try await entry(configuration.bytes) {
          evidence.record($0)
        }
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
