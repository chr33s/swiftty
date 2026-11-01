import Darwin
import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
import SwiftMuxService
@testable import Swiftty
import Synchronization
import Testing

@MainActor
struct MuxUpdateBundleTests {
  @Test
  func metadataTraversalOnlyRequiresSearchPermissionOnAncestors() throws {
    try #require(geteuid() != 0, "directory permissions must be enforced")
    let fixture = try Fixture()
    defer {
      _ = chmod(fixture.root.path, 0o700)
      try? FileManager.default.removeItem(at: fixture.root)
    }
    try #require(chmod(fixture.root.path, 0o111) == 0)
    // The metadata is readable even though its ancestor cannot be listed.
    let metadata = fixture.current.appendingPathComponent("Contents/Info.plist")
    #expect(!(try Data(contentsOf: metadata)).isEmpty)
    let directory = Darwin.open(fixture.root.path, O_RDONLY | O_DIRECTORY)
    if directory >= 0 { _ = Darwin.close(directory) }
    try #require(directory == -1 && errno == EACCES)
    try MuxUpdateBundle.validate(fixture.candidate, replacing: fixture.current)
  }

  @Test(arguments: [false, true])
  func containedMetadataLinksRemainValid(_ directory: Bool) throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let link =
      directory
      ? fixture.agentFile.deletingLastPathComponent() : fixture.agentFile
    let target = link.deletingLastPathComponent()
      .appendingPathComponent("InternalMetadata")
    try FileManager.default.moveItem(at: link, to: target)
    try FileManager.default.createSymbolicLink(
      at: link,
      withDestinationURL: target
    )
    try MuxUpdateBundle.validate(fixture.candidate, replacing: fixture.current)
  }

  @Test
  func metadataParentReplacementCannotEscapeItsBundle() throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let metadata = fixture.agentFile
    let external = fixture.root.appendingPathComponent("ExternalAgents")
    try FileManager.default.createDirectory(
      at: external,
      withIntermediateDirectories: true
    )
    try FileManager.default.copyItem(
      at: metadata,
      to: external.appendingPathComponent(metadata.lastPathComponent)
    )
    let swapped = Mutex(false)
    #expect(throws: (any Error).self) {
      try MuxUpdateBundle.validate(
        fixture.candidate,
        replacing: fixture.current,
        beforeMetadataOpenForTesting: { file in
          guard file == metadata else { return }
          let parent = file.deletingLastPathComponent()
          try FileManager.default.removeItem(at: parent)
          try FileManager.default.createSymbolicLink(
            at: parent,
            withDestinationURL: external
          )
          swapped.withLock { $0 = true }
        }
      )
    }
    #expect(swapped.withLock { $0 })
  }

  @Test(arguments: [false, true])
  func metadataReplacementCannotBlockOrEscapeItsBundle(
    _ fifo: Bool
  ) async throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let candidate = fixture.candidate
    let current = fixture.current
    let metadata = fixture.agentFile
    let external = fixture.root.appendingPathComponent("External.plist")
    try FileManager.default.copyItem(at: metadata, to: external)
    let swapped = Mutex(false)
    let finished = Mutex(false)
    let validation = Task.detached {
      defer { finished.withLock { $0 = true } }
      do {
        try MuxUpdateBundle.validate(
          candidate,
          replacing: current,
          beforeMetadataOpenForTesting: { file in
            guard file == metadata else { return }
            try FileManager.default.removeItem(at: file)
            if fifo {
              guard mkfifo(file.path, 0o600) == 0 else {
                throw POSIXError(.EIO)
              }
            } else {
              try FileManager.default.createSymbolicLink(
                at: file,
                withDestinationURL: external
              )
            }
            swapped.withLock { $0 = true }
          }
        )
        return false
      } catch { return true }
    }
    let deadline = ContinuousClock.now + .seconds(2)
    while !swapped.withLock({ $0 }), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(swapped.withLock { $0 })
    while !finished.withLock({ $0 }), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(
      finished.withLock { $0 },
      "metadata validation must finish before any FIFO writer appears"
    )
    // Release a blocked old implementation without leaving a hung worker.
    if fifo, !finished.withLock({ $0 }) {
      let writer = Darwin.open(metadata.path, O_WRONLY | O_NONBLOCK)
      try #require(writer >= 0)
      _ = Darwin.close(writer)
    }
    #expect(await validation.value)
  }

  @Test(arguments: [false, true], ["", "/.", "/./.", "/.."])
  func bundleRootsRejectSymbolicLinksBeforeReplacement(
    _ candidateLink: Bool,
    _ suffix: String
  ) throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let link = fixture.root.appendingPathComponent("Alias.app")
    try FileManager.default.createSymbolicLink(
      at: link,
      withDestinationURL: candidateLink ? fixture.candidate : fixture.current
    )
    let supplied = URL(fileURLWithPath: link.path + suffix)
    #expect(throws: MuxUpdateBundle.Invalid.self) {
      try MuxUpdateBundle.validate(
        candidateLink ? supplied : fixture.candidate,
        replacing: candidateLink ? fixture.current : supplied
      )
    }
    try MuxUpdateBundle.validate(fixture.candidate, replacing: fixture.current)
  }

  @Test(arguments: [
    "identifier", "executable", "agent", "launcher", "client", "shell", "plist",
    "same", "nested", "oversized", "metadataLink",
  ])
  func rejectsInvalidOrOverlappingCandidates(_ fault: String) throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var source = fixture.candidate
    switch fault {
    case "identifier": try fixture.info("another.app", at: source)
    case "executable", "agent", "launcher", "client", "shell":
      let name =
        switch fault {
        case "agent": "swiftmux-agent"
        case "launcher": "swmux-launcher"
        case "client": "swmux"
        case "shell": "swsh"
        default: "swiftty"
        }
      try FileManager.default.removeItem(
        at: source.appendingPathComponent("Contents/MacOS/\(name)")
      )
    case "plist": try Data("invalid".utf8).write(to: fixture.agentFile)
    case "metadataLink":
      let outside = fixture.root.appendingPathComponent("ExternalAgents")
      try FileManager.default.createDirectory(
        at: outside,
        withIntermediateDirectories: true
      )
      let bytes = try Data(contentsOf: fixture.agentFile)
      try bytes.write(to: outside.appendingPathComponent(SMX.agentPlistName))
      let folder = fixture.agentFile.deletingLastPathComponent()
      try FileManager.default.removeItem(at: folder)
      try FileManager.default.createSymbolicLink(
        at: folder,
        withDestinationURL: outside
      )
    case "same": source = fixture.current
    case "nested": source = fixture.current.appendingPathComponent("Nested.app")
    default:
      try Data(repeating: 0, count: 256 * 1024 + 1)
        .write(to: source.appendingPathComponent("Contents/Info.plist"))
    }
    #expect(throws: (any Error).self) {
      try MuxUpdateBundle.validate(source, replacing: fixture.current)
    }
  }

  @Test
  func changedBundleIsRejectedBeforeConfirmationOrDetach() throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try MuxUpdateBundle.validate(fixture.candidate, replacing: fixture.current)
    let connects = Mutex(0)
    let coordinator = UpdateCoordinator(
      connect: {
        connects.withLock { $0 += 1 };
        throw MuxError(.connectionLost)
      },
      registration: UnusedRegistration(),
      replace: { _ in Issue.record("unexpected replacement") },
    )
    var reports: [String] = []
    var confirmations = 0
    var detaches = 0
    let controller = MuxUpdateController(
      coordinator: coordinator,
      selectBundle: { fixture.candidate },
      confirmInstall: {
        confirmations += 1;
        return false
      },
      report: { title, _ in reports.append(title) },
      currentBundle: fixture.current,
    )
    controller.stage()
    #expect(controller.staged == fixture.candidate)
    try fixture.info("changed.app", at: fixture.candidate)
    controller.install { detaches += 1 }
    #expect(reports == ["The staged update is not ready."])
    #expect(confirmations == 0)
    #expect(detaches == 0)
    #expect(connects.withLock { $0 } == 0)
    #expect(!controller.installing)
  }

  @Test
  func rejectedSelectionPreservesThePreviousStage() throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var selection = fixture.candidate
    var rejections = 0
    let controller = MuxUpdateController(
      selectBundle: { selection },
      report: { _, _ in rejections += 1 },
      currentBundle: fixture.current,
    )
    controller.stage()
    selection = fixture.current
    controller.stage()
    #expect(controller.staged == fixture.candidate)
    #expect(rejections == 1)
  }

  @Test
  func validationAfterTheBarrierStopsBeforeUnregistration() async throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let service = try MuxService(
      configuration: .init(launcherPath: "/usr/bin/false")
    )
    let endpoint = service.listenAnonymously()
    let observer = try await MuxConnection.connect(
      endpoint: endpoint,
      frontend: .control
    )
    let coordinator = UpdateCoordinator(
      connect: {
        try await MuxConnection.connect(endpoint: endpoint, frontend: .control)
      },
      registration: UnusedRegistration(),
      replace: { _ in Issue.record("unexpected replacement") },
      validate: { bundle in
        try await MainActor.run {
          try fixture.info("changed.after.barrier", at: bundle)
          try MuxUpdateBundle.validate(bundle, replacing: fixture.current)
        }
      },
    )
    await coordinator.stage(fixture.candidate)
    guard case .failed = await coordinator.install(endWorkspaces: false) else {
      Issue.record("expected validation failure")
      await observer.close()
      return
    }
    guard case let .status(status) = try await observer.execute(.status) else {
      throw MuxError(.invalidRequest)
    }
    #expect(!status.quiescing)
    #expect(await service.isEmpty)
    await observer.close()
  }

  private struct Fixture {
    let root: URL
    let current: URL
    let candidate: URL
    var agentFile: URL {
      candidate.appendingPathComponent(
        "Contents/Library/LaunchAgents/\(SMX.agentPlistName)"
      )
    }

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString
      )
      current = root.appendingPathComponent("Current.app")
      candidate = root.appendingPathComponent("New.app")
      for bundle in [current, candidate] {
        try FileManager.default.createDirectory(
          at: bundle.appendingPathComponent("Contents/MacOS"),
          withIntermediateDirectories: true
        )
        try info("com.chr33s.swiftty", at: bundle)
      }
      for name in [
        "swiftty", "swiftmux-agent", "swmux-launcher", "swmux", "swsh",
      ] {
        let file = candidate.appendingPathComponent("Contents/MacOS/\(name)")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o755],
          ofItemAtPath: file.path
        )
      }
      try FileManager.default.createDirectory(
        at: agentFile.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let agent: [String: Any] = [
        "Label": SMX.defaultMachService,
        "BundleProgram": "Contents/MacOS/swiftmux-agent",
        "AssociatedBundleIdentifiers": ["com.chr33s.swiftty"],
        "MachServices": [SMX.defaultMachService: true],
      ]
      try PropertyListSerialization.data(
        fromPropertyList: agent,
        format: .xml,
        options: 0
      )
      .write(to: agentFile)
    }

    func info(_ identifier: String, at bundle: URL) throws {
      let value = [
        "CFBundleIdentifier": identifier, "CFBundleExecutable": "swiftty",
        "CFBundlePackageType": "APPL",
      ]
      try PropertyListSerialization.data(
        fromPropertyList: value,
        format: .xml,
        options: 0
      )
      .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
    }
  }
}

private struct UnusedRegistration: AgentRegistration {
  func unregister() async throws { Issue.record("unexpected unregister") }
  func register() async throws { Issue.record("unexpected register") }
}
