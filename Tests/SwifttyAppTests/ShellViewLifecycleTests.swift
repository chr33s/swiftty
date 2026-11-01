import AppKit
import Darwin
import Metal
import SwifttyConfig
import SwifttyCore
@testable import SwifttyMac
import Testing

@MainActor
@Suite(.serialized)
struct ShellViewLifecycleTests {
  nonisolated static let hasMetal = MTLCreateSystemDefaultDevice() != nil

  @Test(.enabled(if: hasMetal), arguments: ["/bin/bash", "/bin/zsh"])
  func exactLaunchAndPassiveEvents(interpreter: String) async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let startup = interpreter == "/bin/bash" ? ".bash_profile" : ".zprofile"
    try "export SWSH_STARTUP_MARKER=profile-loaded\n"
      .write(
        to: directory.appendingPathComponent(startup),
        atomically: true,
        encoding: .utf8
      )
    let resolved = try #require(realpath(directory.path, nil))
    let physical = String(cString: resolved)
    free(resolved)
    let view = try TerminalView(
      configuration: Configuration.configured([
        ("command", "/missing-configured-shell")
      ])
    )
    view.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
    let scale = view.renderer.font.descriptor.scale
    let expectedGrid = view.renderer.gridSize(
      for: CGSize(width: 640 * scale, height: 480 * scale)
    )
    defer { view.stop() }
    var titles: [String] = []
    var exits = 0
    var events: [TerminalEvent] = []
    var snapshotColumns = 0
    view.onTitle = { titles.append($0) }
    view.onExit = { exits += 1 }
    view.onTerminalEvent = { [weak view] event in
      // This synchronous snapshot would deadlock on the session callback queue.
      snapshotColumns = view?.session.snapshot().columns ?? 0
      events.append(event)
    }
    let script = #"""
      printf '\033]0;%s|%s|%s\007' "$1" "$SWSH_VIEW_FIXTURE:$SWSH_STARTUP_MARKER" "$(pwd -P)"
      printf '\033]7;file://localhost/tmp/passive-directory\007'
      printf '\033]133;D;7\007'
      exit 9
      """#
    var profile = Configuration()
    profile.preferredShell = interpreter == "/bin/bash" ? .bash : .zsh
    profile.shellProfiles[profile.preferredShell!.rawValue] =
      ShellLaunchProfile(
        executable: interpreter,
        arguments: ["-l", "-c", script, "fixture", "argument with spaces"],
        environment: [
          "HOME": directory.path, "ZDOTDIR": directory.path,
          "SWSH_VIEW_FIXTURE": "environment with spaces",
        ],
        workingDirectory: directory.path
      )
    try view.start(profile.sessionConfiguration())
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !events.contains(.exited(9)), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    let expectedTitle =
      "argument with spaces|environment with spaces:profile-loaded|\(physical)"
    #expect(titles == [expectedTitle])
    #expect(events.contains(.title(expectedTitle)))
    #expect(events.contains(.workingDirectory("/tmp/passive-directory")))
    #expect(events.contains(.commandFinished(exitCode: 7)))
    #expect(events.contains(.exited(9)))
    #expect(exits == 1)
    #expect(snapshotColumns == expectedGrid.columns)

    view.stop()
    view.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
    try view.start(
      SessionConfiguration(command: [
        interpreter, "-c", #"printf '\033]0;restarted\007'; exit 0"#,
      ])
    )
    let restartDeadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !events.contains(.exited(0)), ContinuousClock.now < restartDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(titles.last == "restarted")
    #expect(events.contains(.exited(0)))
    #expect(exits == 2)
    #expect(
      snapshotColumns
        == view.renderer
        .gridSize(for: CGSize(width: 800 * scale, height: 500 * scale)).columns
    )
  }

  @Test(.enabled(if: hasMetal))
  func forgedCompletionBurstDoesNotEndSession() async throws {
    _ = NSApplication.shared
    let view = try TerminalView(configuration: Configuration())
    defer { view.stop() }
    var exits = 0
    var events: [TerminalEvent] = []
    view.onExit = { exits += 1 }
    view.onTerminalEvent = { events.append($0) }
    try view.start(
      SessionConfiguration(command: [
        "/bin/bash", "-c", "read -r line; exit 23",
      ])
    )
    // Any terminal program can emit these; bursts may be coalesced.
    view.session.feed(
      Array(String(repeating: "\u{1B}]133;D;0\u{7}", count: 100).utf8)
    )
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !events.contains(.commandFinished(exitCode: 0)),
      ContinuousClock.now < deadline
    { try await Task.sleep(for: .milliseconds(10)) }
    #expect(events.contains(.commandFinished(exitCode: 0)))
    #expect(exits == 0)
    #expect(!events.contains(.exited(0)))
    view.session.send(.text("finish\n"))
    let exitDeadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !events.contains(.exited(23)), ContinuousClock.now < exitDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(events.contains(.exited(23)))
    #expect(exits == 1)
  }

  @Test(.enabled(if: hasMetal))
  func eventForwardingKeepsPointerHandling() async throws {
    _ = NSApplication.shared
    let view = try TerminalView(configuration: Configuration())
    defer { view.stop() }
    var events: [TerminalEvent] = []
    view.onTerminalEvent = { events.append($0) }
    view.session.feed(Array("\u{1B}]22;crosshair\u{7}".utf8))
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while events.isEmpty, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(events == [.pointerShape("crosshair")])
    #expect(view.applicationCursor == NSCursor.crosshair)
  }
}
