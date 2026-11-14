import Foundation

/// Test-only hooks for the XCUITest suite in Tests/AppUITests, active only
/// when the app is launched with the `-ui-testing` argument. They change no
/// behaviour: they isolate on-disk state and expose the visible terminal
/// text to UI automation.
public enum UITesting {
  /// Whether the app was launched by the UI test suite.
  public static let isEnabled = ProcessInfo.processInfo.arguments.contains("-ui-testing")

  /// A fresh, empty state directory for this launch (saved hosts, trusted
  /// keys, transfer manifests), so tests never see or touch real app data.
  package static let storageDirectory: URL? = {
    guard isEnabled else { return nil }
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "Swiftty-UITests", directoryHint: .isDirectory)
    try? FileManager.default.removeItem(at: directory)
    return directory
  }()

  /// A separate, cleared defaults domain for remembered session ids.
  /// (`UserDefaults` is thread-safe; it is just not marked `Sendable`.)
  nonisolated(unsafe) public static let defaults: UserDefaults? = {
    guard isEnabled else { return nil }
    let suite = "dev.swiftty.roaming.ui-testing"
    let defaults = UserDefaults(suiteName: suite)
    defaults?.removePersistentDomain(forName: suite)
    return defaults
  }()
}
