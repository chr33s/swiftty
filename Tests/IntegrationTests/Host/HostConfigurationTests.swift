#if os(macOS)
import Darwin
import Foundation
import ScreenProtocol
import Testing

@testable import TerminalHost

@Suite(.timeLimit(.minutes(1)))
struct HostConfigurationTests {
  @Test(arguments: [
    "state", "directory with spaces/子", "../state", ".", "./state",
    "state%23#?", "~state",
  ])
  func relativeStateUsesTheConfigurationParentAndEncodingKeepsItsLocation(
    _ path: String
  ) throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let parent = directory.appendingPathComponent("configuration")
    try FileManager.default.createDirectory(
      at: parent,
      withIntermediateDirectories: false
    )
    let file = parent.appendingPathComponent("config.json")
    let raw = HostConfiguration(
      bindAddress: "127.0.0.1",
      advertisedHost: "owned.example",
      stateDirectory: path
    )
    try JSONEncoder().encode(raw).write(to: file)
    let loaded = try HostConfiguration.load(from: file)
    let expected = parent.appendingPathComponent(path).standardizedFileURL
    #expect(loaded.stateDirectory == expected.path)
    #expect(loaded.stateDirectoryURL.path == expected.path)
    #expect(loaded.stateDirectory?.hasPrefix("/") == true)
    let socket = expected.appendingPathComponent("control.sock").path
    #expect(loaded.socketPath == socket)
    #expect(
      try HostConfiguration.resolvedSocketPath(environment: [
        HostConfiguration.environmentKey: file.path
      ]) == socket
    )
    let moved = directory.appendingPathComponent("normalized.json")
    try JSONEncoder().encode(loaded).write(to: moved)
    #expect(try HostConfiguration.load(from: moved) == loaded)
    try JSONEncoder().encode(raw).write(to: moved)
    #expect(
      try HostConfiguration.load(from: moved).stateDirectoryURL.path
        == directory.appendingPathComponent(path).standardizedFileURL.path
    )
  }

  @Test(arguments: [false, true])
  func absoluteAndDefaultStateRetainTheirLocations(_ useDefault: Bool) throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("config.json")
    let state = directory.appendingPathComponent("absolute state")
    let raw = HostConfiguration(
      bindAddress: "127.0.0.1",
      advertisedHost: "owned.example",
      stateDirectory: useDefault ? nil : state.path
    )
    try JSONEncoder().encode(raw).write(to: file)
    let loaded = try HostConfiguration.load(from: file)
    #expect(loaded == raw)
    #expect(
      loaded.stateDirectoryURL.path
        == (useDefault ? ControlDirectory.defaultURL.path : state.path)
    )
  }

  @Test
  func directConstructionDecodingAndMutationUseTheSharedRoamingBase() throws {
    var raw = HostConfiguration(
      bindAddress: "127.0.0.1",
      advertisedHost: "owned.example",
      stateDirectory: "relative-state"
    )
    let expected = ControlDirectory.defaultURL.appendingPathComponent(
      "relative-state"
    )
    #expect(raw.stateDirectoryURL.path == expected.path)
    let decoded = try JSONDecoder()
      .decode(HostConfiguration.self, from: JSONEncoder().encode(raw))
    #expect(decoded == raw)
    #expect(decoded.stateDirectoryURL.path == expected.path)
    raw.stateDirectory = "other-state"
    #expect(
      raw.stateDirectoryURL.path
        == ControlDirectory.defaultURL.appendingPathComponent("other-state")
        .path
    )
  }

  @Test(
    arguments: ["stateDirectory", "bindAddress", "advertisedHost"],
    ["", "prefix\0suffix"]
  )
  func emptyOrNulFieldsCannotSelectAControlSocket(
    _ field: String,
    _ value: String
  ) throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("config.json")
    var object: [String: Any] = [
      "bindAddress": "127.0.0.1", "advertisedHost": "owned.example",
      "stateDirectory": "state",
    ]
    object[field] = value
    let data = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(HostConfiguration.self, from: data)
    }
    try data.write(to: file)
    #expect(throws: DecodingError.self) {
      try HostConfiguration.load(from: file)
    }
    #expect(throws: DecodingError.self) {
      try HostConfiguration.resolvedSocketPath(environment: [
        HostConfiguration.environmentKey: file.path
      ])
    }
  }

  @Test
  func nulConfigPathCannotLoadItsExistingPrefix() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("config.json")
    let raw = HostConfiguration(
      bindAddress: "127.0.0.1",
      advertisedHost: "owned.example",
      stateDirectory: directory.path
    )
    try JSONEncoder().encode(raw).write(to: file)
    let path = file.path + "\0suffix"
    #expect(throws: POSIXError(.EINVAL)) {
      try HostConfiguration.load(from: URL(fileURLWithPath: path))
    }
    #expect(throws: POSIXError(.EINVAL)) {
      try HostConfiguration.resolvedSocketPath(environment: [
        HostConfiguration.environmentKey: path
      ])
    }
    #expect(try HostConfiguration.load(from: file) == raw)
  }

  @Test
  func helperReachesTheSocketSelectedByTheLoadedRelativeConfiguration()
    async throws
  {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("config.json")
    let raw = HostConfiguration(
      bindAddress: "127.0.0.1",
      advertisedHost: "owned.example",
      stateDirectory: "state"
    )
    try JSONEncoder().encode(raw).write(to: file)
    let agent = try HostConfiguration.load(from: file)
    try ControlDirectory.prepare(agent.stateDirectoryURL)
    let reply = try BootstrapEnvelope.encode(BootstrapResponse.sessions([]))
    let server = try ControlSocketServer(directory: agent.stateDirectoryURL) {
      _ in reply
    }
    try server.start()
    defer { server.stop() }
    let helper = try HostConfiguration.resolvedSocketPath(environment: [
      HostConfiguration.environmentKey: file.path
    ])
    #expect(helper == server.path)
    let request = try BootstrapEnvelope.encode(
      BootstrapRequest(operation: .list)
    )
    let received = BootstrapService.forward(
      envelope: request,
      socketPath: helper
    )
    #expect(
      try BootstrapEnvelope.decode(BootstrapResponse.self, from: received)
        == .sessions([])
    )
  }
}
#endif
