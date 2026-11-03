import Darwin
import Foundation
import SwiftMuxGateway
import SwiftMuxProtocol
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct GatewayUpdateStagingTests {
  private typealias Fixture = GatewayUpdateArtifactTests.Fixture

  @Test
  func publishedCopySurvivesSourceChangesAndCannotBeOverwritten() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let root = try stagingRoot(fixture)
    let store = try staging(root)
    let staged = try store.stage(fixture.bundle)
    #expect(
      staged.bundle == root.appendingPathComponent("candidate-1/Gateway.app")
    )
    #expect(staged.bundle != fixture.bundle)
    let original = try Data(
      contentsOf: staged.bundle.appendingPathComponent(
        "Contents/Resources/gateway-build.json"
      )
    )
    var declaration = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: fixture.metadata))
        as? [String: Any]
    )
    declaration["workerProtocols"] = [99]
    try JSONSerialization.data(withJSONObject: declaration)
      .write(to: fixture.metadata)
    try fixture.sign()
    #expect(throws: MuxError.self) { try store.stage(fixture.bundle) }
    #expect(
      try store.load("candidate-1").manifest.workerProtocols
        == Array(SMX.compatibleVersions)
    )
    #expect(
      try Data(
        contentsOf: staged.bundle.appendingPathComponent(
          "Contents/Resources/gateway-build.json"
        )
      ) == original
    )
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: root.path) == [
        "candidate-1"
      ]
    )
    try FileManager.default.removeItem(at: fixture.bundle)
    #expect(
      try staging(root).load("candidate-1").manifest.build == "candidate-1"
    )
  }

  @Test
  func invalidSourceDoesNotDisturbPublishedBuild() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let root = try stagingRoot(fixture)
    let store = try staging(root)
    _ = try store.stage(fixture.bundle)
    try Data("not a manifest".utf8).write(to: fixture.metadata)
    #expect(throws: (any Error).self) { try store.stage(fixture.bundle) }
    #expect(try store.load("candidate-1").manifest.build == "candidate-1")
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: root.path) == [
        "candidate-1"
      ]
    )
  }

  @Test(arguments: ["public", "symlink", "file", "nested"])
  func unsafeRootOrRecursiveCopyIsRefused(kind: String) throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let root = try stagingRoot(fixture)
    switch kind {
    case "public":
      #expect(chmod(root.path, 0o755) == 0)
      #expect(throws: MuxError.self) { try staging(root) }
    case "symlink":
      let link = fixture.root.appendingPathComponent("link")
      try FileManager.default.createSymbolicLink(
        at: link,
        withDestinationURL: root
      )
      #expect(throws: MuxError.self) { try staging(link) }
    case "file":
      let file = fixture.root.appendingPathComponent("file")
      try Data().write(to: file)
      #expect(throws: MuxError.self) { try staging(file) }
    default:
      let nested = fixture.bundle.appendingPathComponent(
        "Contents/Resources/Staging"
      )
      try FileManager.default.createDirectory(
        at: nested,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      try fixture.sign()
      let store = try staging(nested)
      #expect(throws: MuxError.self) { try store.stage(fixture.bundle) }
      #expect(
        try FileManager.default.contentsOfDirectory(atPath: nested.path).isEmpty
      )
    }
  }

  @Test
  func loadRefusesTraversalAndRevalidatesPublishedBytes() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let root = try stagingRoot(fixture)
    let store = try staging(root)
    let staged = try store.stage(fixture.bundle)
    for build in [
      "", "..", ".hidden", "../candidate-1", "candidate-1/Gateway.app",
      String(repeating: "x", count: 129),
    ] { #expect(throws: MuxError.self) { try store.load(build) } }
    try Data("{}".utf8)
      .write(
        to: staged.bundle.appendingPathComponent(
          "Contents/Resources/gateway-build.json"
        )
      )
    #expect(throws: (any Error).self) { try store.load("candidate-1") }
  }

  @Test
  func competingPublishersCommitExactlyOneCopy() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let root = try stagingRoot(fixture)
    let publishers = [try staging(root), try staging(root)]
    let source = fixture.bundle
    let jobs = publishers.map { publisher in
      Task.detached { Result { try publisher.stage(source) } }
    }
    var successes = 0
    var refusals = 0
    for job in jobs {
      switch await job.value {
      case .success: successes += 1
      case let .failure(error):
        #expect((error as? MuxError)?.code == .launchFailed)
        refusals += 1
      }
    }
    #expect(successes == 1 && refusals == 1)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: root.path) == [
        "candidate-1"
      ]
    )
    #expect(
      try staging(root).load("candidate-1").manifest.build == "candidate-1"
    )
  }

  private func stagingRoot(_ fixture: Fixture) throws -> URL {
    let root = fixture.root.appendingPathComponent("GatewayVersions")
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    return root
  }

  private func staging(_ root: URL) throws -> GatewayUpdateStaging {
    try GatewayUpdateStaging(
      root: root,
      bundleRequirement: Fixture.bundleRequirement,
      executableRequirement: Fixture.executableRequirement,
      installation: Fixture.policy()
    )
  }
}
