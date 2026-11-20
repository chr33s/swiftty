import Crypto
import Darwin
import Foundation
import SessionCore
import Synchronization
import Testing

@testable import SSHClient

/// Captures every checkpointed manifest, like durable app storage.
final class ManifestLog: Sendable {
  let latest = Mutex<TransferManifest?>(nil)
  let count = Mutex(0)

  var checkpoint: TransferCheckpoint {
    { manifest in
      // Round-trip through the persisted form.
      let decoded = try? TransferManifest.decode(manifest.encoded())
      self.latest.withLock { $0 = decoded }
      self.count.withLock { $0 += 1 }
    }
  }
}

/// A temporary local workspace plus a server.
struct TransferFixture {
  let server: TestSSHServer
  let local: URL

  static func make() async throws -> TransferFixture {
    let local = FileManager.default.temporaryDirectory.appendingPathComponent(
      "sftp-local-" + UUID().uuidString
    )
    try FileManager.default.createDirectory(
      at: local,
      withIntermediateDirectories: true
    )
    do {
      return TransferFixture(
        server: try await TestSSHServer.start(),
        local: local
      )
    } catch {
      try? FileManager.default.removeItem(at: local)
      throw error
    }
  }

  func cleanup() async {
    await server.shutdown()
    try? FileManager.default.removeItem(at: local)
  }

  var staging: URL { local.appendingPathComponent("staging") }

  func sourceFile(size: Int, seed: UInt64 = 1) throws -> (URL, Data) {
    var rng = SplitMix64(seed: seed)
    let data = Data(
      (0 ..< size).map { _ in UInt8.random(in: 0 ... 255, using: &rng) }
    )
    let url = local.appendingPathComponent("source-\(seed).bin")
    try data.write(to: url)
    return (url, data)
  }

  func remoteFile(_ path: String, data: Data) throws {
    try data.write(to: server.url(path))
  }

  func remoteData(_ path: String) -> Data? {
    try? Data(contentsOf: server.url(path))
  }

  func remoteNames() -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: server.root.path))?
      .sorted() ?? []
  }

  func session() async throws -> (SSHConnection, SFTPClient) {
    let connection = try await server.connect()
    do { return (connection, try await connection.openSFTP()) } catch {
      await connection.close()
      throw error
    }
  }

  /// Runs `body` until it completes, reconnecting after each dropped
  /// connection. Returns the number of attempts.
  func untilComplete(
    maxAttempts: Int = 6,
    _ body: (SFTPClient) async throws -> Void
  ) async throws -> Int {
    for attempt in 1 ... maxAttempts {
      let (connection, client) = try await session()
      do {
        try await body(client)
        await connection.close()
        return attempt
      } catch {
        await connection.close()
        guard let error = error as? SFTPError, error == .connectionClosed else {
          throw error
        }
      }
    }
    Issue.record("transfer did not complete")
    return maxAttempts
  }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct SFTPTransferTests {
  private static var caseInsensitiveTemporaryVolume: Bool {
    (try? FileManager.default.temporaryDirectory.resourceValues(forKeys: [
      .volumeSupportsCaseSensitiveNamesKey
    ]))?
    .volumeSupportsCaseSensitiveNames == false
  }
  static let fileSize = 19 * 32 * 1024 + 1234

  @Test
  func failedSFTPInitializationClosesFreshConnection() async throws {
    let fixture = try await TransferFixture.make()
    fixture.server.state.faults.withLock { $0.rejectSessionChannel = true }
    do {
      await #expect(throws: (any Error).self) {
        _ = try await fixture.session()
      }
      #expect(
        try await waitUntil(timeout: .seconds(1)) {
          fixture.server.state.connections.withLock { $0.channels.isEmpty }
        }
      )
    } catch {
      await fixture.cleanup()
      throw error
    }
    await fixture.cleanup()
  }

  @Test
  func unexpectedTransferFailureClosesConnectionWithoutRetry() async throws {
    let fixture = try await TransferFixture.make()
    let observed = Mutex<SFTPClient?>(nil)
    do {
      await #expect(throws: SFTPError.requestTimedOut) {
        _ = try await fixture.untilComplete { client in
          observed.withLock { $0 = client }
          throw SFTPError.requestTimedOut
        }
      }
      let client = try #require(observed.withLock { $0 })
      let clientRemainsActive = client.isActive
      #expect(!clientRemainsActive)
      #expect(client.channel.parent?.isActive == false)
      #expect(fixture.server.state.sftpInitializations.withLock { $0 } == 1)
      try? await client.channel.parent?.close()
    } catch {
      try? await observed.withLock { $0 }?.channel.parent?.close()
      await fixture.cleanup()
      throw error
    }
    await fixture.cleanup()
  }

  @Test
  func multibyteDestinationUsesABoundedTemporaryName() async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    let (source, data) = try fixture.sourceFile(size: 1024)
    let path = "/" + String(repeating: "🙂", count: 60) + ".bin"
    var manifest = try await SFTPTransfers.prepareUpload(
      source: source,
      remotePath: path,
      stagingDirectory: fixture.staging
    )
    let temporary = try #require(manifest.remoteTemporaryPath)
    #expect(URL(fileURLWithPath: temporary).lastPathComponent.utf8.count <= 255)
    let (connection, client) = try await fixture.session()
    defer { Task { await connection.close() } }
    try await SFTPTransfers.upload(&manifest, client: client)
    #expect(manifest.isComplete)
    #expect(fixture.remoteData(path) == data)
  }

  @Test
  func unrepresentableTemporaryPathIsRejectedBeforeStaging() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    await #expect(throws: SFTPTransferError.invalidRemotePath) {
      _ = try await SFTPTransfers.prepareUpload(
        source: directory.appendingPathComponent("missing"),
        remotePath: String(repeating: "d", count: 4093) + "/x",
        stagingDirectory: directory
      )
    }
    #expect(!FileManager.default.fileExists(atPath: directory.path))
  }

  @Test(arguments: ["regular", "symlink", "directory", "fifo"])
  func uploadPreparationRejectsAReplacedSource(
    _ replacement: String
  ) async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source")
    let target = directory.appendingPathComponent("target")
    let staging = directory.appendingPathComponent("staging")
    let bytes = Data("owned upload bytes".utf8)
    try bytes.write(to: source)
    try bytes.write(to: target)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: source.path
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: target.path
    )
    func prepare() async throws -> TransferManifest {
      try await SFTPTransfers.prepareUpload(
        source: source,
        remotePath: "/upload",
        stagingDirectory: staging,
        beforeCopyForTesting: {
          if replacement == "symlink" {
            try FileManager.default.removeItem(at: source)
            try FileManager.default.createSymbolicLink(
              at: source,
              withDestinationURL: target
            )
          } else if replacement == "directory" {
            try FileManager.default.removeItem(at: source)
            try FileManager.default.createDirectory(
              at: source,
              withIntermediateDirectories: false
            )
          } else if replacement == "fifo" {
            try FileManager.default.removeItem(at: source)
            guard mkfifo(source.path, 0o600) == 0 else { throw posixError() }
          }
        }
      )
    }
    if replacement == "regular" {
      let manifest = try await prepare()
      #expect(manifest.sourceSize == UInt64(bytes.count))
      #expect(
        try Data(contentsOf: URL(fileURLWithPath: manifest.localPath)) == bytes
      )
      let attributes = try FileManager.default.attributesOfItem(
        atPath: manifest.localPath
      )
      #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o400)
    } else {
      await #expect(throws: SFTPTransferError.notRegularFile) {
        _ = try await prepare()
      }
      #expect(
        (try? FileManager.default.contentsOfDirectory(atPath: staging.path))?
          .isEmpty != false
      )
    }
    let targetAttributes = try FileManager.default.attributesOfItem(
      atPath: target.path
    )
    #expect(
      (targetAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600
    )
    #expect(try Data(contentsOf: target) == bytes)
  }

  @Test
  func localFileRejectsUnrepresentableRanges() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString
    )
    let original = Data([1, 2, 3])
    try original.write(to: path)
    defer { try? FileManager.default.removeItem(at: path) }
    let file = try await LocalFile.open(path.path, flags: O_RDWR)
    defer { Darwin.close(file.fd) }
    for offset in [UInt64.max, UInt64(off_t.max)] {
      await #expect(throws: POSIXError(.EOVERFLOW)) {
        _ = try await file.read(at: offset, count: 1)
      }
      await #expect(throws: POSIXError(.EOVERFLOW)) {
        try await file.write([9], at: offset)
      }
    }
    await #expect(throws: POSIXError(.EOVERFLOW)) {
      try await file.truncate(to: UInt64.max)
    }
    await #expect(throws: POSIXError(.EINVAL)) {
      _ = try await file.read(at: 0, count: -1)
    }
    #expect(try await file.read(at: 0, count: 3) == Array(original))
  }

  @Test(arguments: ["symlink", "directory", "fifo"])
  func resumedLocalFilesMustBeRegular(_ kind: String) async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("resumed")
    let target = directory.appendingPathComponent("target")
    try Data([1, 2, 3]).write(to: target)
    switch kind {
    case "symlink":
      try FileManager.default.createSymbolicLink(
        at: path,
        withDestinationURL: target
      )
    case "directory":
      try FileManager.default.createDirectory(
        at: path,
        withIntermediateDirectories: false
      )
    default: try #require(mkfifo(path.path, 0o600) == 0)
    }
    // Do not strand the legacy blocking worker while proving that a FIFO
    // descriptor is incorrectly admitted. The helper must also reject it
    // when the caller already requested nonblocking access.
    let flags = kind == "fifo" ? O_RDWR | O_NONBLOCK : O_RDONLY
    await #expect(throws: SFTPTransferError.notRegularFile) {
      let file = try await LocalFile.open(path.path, flags: flags)
      Darwin.close(file.fd)
    }
  }

  @Test
  func downloadDoesNotWriteThroughAReplacedTemporarySymlink() async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    let target = fixture.local.appendingPathComponent("untouched")
    let destination = fixture.local.appendingPathComponent("destination")
    let original = Data([1, 2, 3])
    try original.write(to: target)
    try fixture.remoteFile("/source", data: Data([4, 5, 6, 7]))
    var manifest = try SFTPTransfers.prepareDownload(
      remotePath: "/source",
      temporaryDirectory: fixture.local,
      destination: destination
    )
    try FileManager.default.createSymbolicLink(
      at: URL(fileURLWithPath: manifest.localPath),
      withDestinationURL: target
    )
    let (connection, client) = try await fixture.session()
    defer { Task { await connection.close() } }
    await #expect(throws: SFTPTransferError.notRegularFile) {
      try await SFTPTransfers.download(&manifest, client: client)
    }
    let targetBytes = try Data(contentsOf: target)
    let published = FileManager.default.fileExists(atPath: destination.path)
    #expect(targetBytes == original)
    #expect(!published)
    await connection.close()
    await fixture.cleanup()
  }

  @Test(arguments: ["regular", "symlink"])
  func downloadRejectsAReplacedVerifiedTemporaryPath(
    _ replacement: String
  ) async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    let target = fixture.local.appendingPathComponent("other-file")
    let destination = fixture.local.appendingPathComponent("destination")
    let unrelated = Data([1, 2, 3])
    try unrelated.write(to: target)
    try fixture.remoteFile("/source", data: Data([4, 5, 6, 7]))
    var manifest = try SFTPTransfers.prepareDownload(
      remotePath: "/source",
      temporaryDirectory: fixture.local,
      destination: destination
    )
    let (connection, client) = try await fixture.session()
    defer { Task { await connection.close() } }
    await #expect(throws: SFTPTransferError.stagedSourceChanged) {
      try await SFTPTransfers.download(&manifest, client: client) {
        checkpoint in
        guard checkpoint.state == .verifying else { return }
        do {
          let temporary = URL(fileURLWithPath: checkpoint.localPath)
          try FileManager.default.removeItem(at: temporary)
          if replacement == "symlink" {
            try FileManager.default.createSymbolicLink(
              at: temporary,
              withDestinationURL: target
            )
          } else {
            try unrelated.write(to: temporary)
          }
        } catch { Issue.record(error) }
      }
    }
    let published = FileManager.default.fileExists(atPath: destination.path)
    let targetBytes = try Data(contentsOf: target)
    #expect(!manifest.isComplete)
    #expect(!published)
    #expect(targetBytes == unrelated)
    await connection.close()
    await fixture.cleanup()
  }

  @Test
  func oversizedRemoteFileIsRejectedBeforeReading() async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    try fixture.remoteFile("/source.bin", data: Data([1]))
    fixture.server.state.faults.withLock { $0.reportedFileSize = UInt64.max }
    let (connection, client) = try await fixture.session()
    defer { Task { await connection.close() } }
    var manifest = try SFTPTransfers.prepareDownload(
      remotePath: "/source.bin",
      temporaryDirectory: fixture.local,
      destination: fixture.local.appendingPathComponent("download.bin")
    )
    await #expect(throws: SFTPTransferError.fileTooLarge) {
      try await SFTPTransfers.download(&manifest, client: client)
    }
    #expect(fixture.server.state.reads.withLock { $0 } == 0)
    #expect(manifest.acknowledgedOffset == 0)
    #expect(!manifest.isComplete)
  }

  @Test(arguments: ["chunkSize", "maxOutstanding", "maxRestarts"])
  func mutatedInvalidOptionsAreRejected(field: String) async throws {
    var options = SFTPTransferOptions()
    switch field {
    case "chunkSize": options.chunkSize = 0
    case "maxOutstanding": options.maxOutstanding = 0
    default: options.maxRestarts = -1
    }
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    let (connection, client) = try await fixture.session()
    defer { Task { await connection.close() } }
    var manifest = try SFTPTransfers.prepareDownload(
      remotePath: "/source.bin",
      temporaryDirectory: fixture.local,
      destination: fixture.local.appendingPathComponent("download.bin")
    )
    await #expect(throws: SFTPTransferError.invalidOptions) {
      try await SFTPTransfers.download(
        &manifest,
        client: client,
        options: options
      )
    }
    manifest = TransferManifest(
      direction: .upload,
      localPath: manifest.localPath,
      remotePath: "/dest.bin",
      sourceSize: 0
    )
    await #expect(throws: SFTPTransferError.invalidOptions) {
      try await SFTPTransfers.upload(
        &manifest,
        client: client,
        options: options
      )
    }
    #expect(fixture.server.state.sftpRequests.withLock { $0 } == 0)
  }

  @Test(arguments: ["upload", "download", "verify"])
  func stalledFirstResponseBoundsTheTransferWindow(
    pipeline: String
  ) async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    let (source, data) = try fixture.sourceFile(size: 32 * 1024)
    try fixture.remoteFile("/source.bin", data: data)
    let (connection, client) = try await fixture.session()
    defer { Task { await connection.close() } }
    let manifest =
      pipeline == "upload"
      ? try await SFTPTransfers.prepareUpload(
        source: source,
        remotePath: "/dest.bin",
        stagingDirectory: fixture.staging
      )
      : try SFTPTransfers.prepareDownload(
        remotePath: "/source.bin",
        temporaryDirectory: fixture.local,
        destination: fixture.local.appendingPathComponent("download.bin")
      )
    let options = SFTPTransferOptions(chunkSize: 1024, maxOutstanding: 4)
    fixture.server.state.faults.withLock {
      $0.holdNextWriteResponse = pipeline == "upload"
      $0.holdNextReadResponse = pipeline != "upload"
    }
    let transfer = Task {
      var working = manifest
      if pipeline == "upload" {
        try await SFTPTransfers.upload(
          &working,
          client: client,
          options: options
        )
      } else if pipeline == "download" {
        try await SFTPTransfers.download(
          &working,
          client: client,
          options: options
        )
      } else {
        let digest = try await SFTPTransfers.remoteSHA256(
          client: client,
          path: "/source.bin",
          length: UInt64(data.count),
          options: options,
          gate: OpenTransferGate(),
          expectEOF: true
        )
        #expect(digest == hexString(SHA256.hash(data: data)))
      }
      return working
    }
    #expect(
      try await waitUntil {
        fixture.server.state.heldSFTPResponse.withLock { $0 != nil }
      }
    )
    func requests() -> Int {
      pipeline == "upload"
        ? fixture.server.state.writes.withLock { $0 }
        : fixture.server.state.reads.withLock { $0 }
    }
    #expect(try await waitUntil { requests() >= 4 })
    try await Task.sleep(for: .milliseconds(100))
    #expect(requests() == 4)
    let release = fixture.server.state.heldSFTPResponse.withLock { pending in
      defer { pending = nil }
      return pending
    }
    release?()
    let finished = try await transfer.value
    if pipeline == "upload" {
      #expect(finished.isComplete)
      #expect(fixture.remoteData("/dest.bin") == data)
    } else if pipeline == "download" {
      #expect(finished.isComplete)
      #expect(
        try Data(
          contentsOf: fixture.local.appendingPathComponent("download.bin")
        ) == data
      )
    }
  }

  @Test
  func `sftp client lists stats and rejects bad paths`() async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    for name in ["a", "b", "c", "d", "e"] {
      try fixture.remoteFile("/" + name, data: Data(name.utf8))
    }
    try FileManager.default.createDirectory(
      at: fixture.server.url("/dir"),
      withIntermediateDirectories: false
    )
    let (connection, client) = try await fixture.session()
    defer { Task { await connection.close() } }

    let entries = try await client.listDirectory("/")
    #expect(entries.map(\.filename) == ["a", "b", "c", "d", "dir", "e"])
    #expect(
      entries.first { $0.filename == "dir" }?.attributes.isDirectory == true
    )
    #expect(try await client.stat("/a").size == 1)
    #expect(try await client.realpath("/a/") == "/a")
    await #expect(throws: SFTPError.self) {
      _ = try await client.stat("/missing")
    }
    await #expect(throws: SFTPError.invalidPath) {
      _ = try await client.stat("")
    }
    await #expect(throws: SFTPError.invalidPath) {
      _ = try await client.stat("a\u{0}b")
    }
    let handle = try await client.open("/a", flags: [.read])
    #expect(
      try await client.read(handle, offset: 0, length: 10) == Array("a".utf8)
    )
    #expect(try await client.read(handle, offset: 1, length: 10) == nil)
    #expect(try await client.fstat(handle).isRegularFile)
    try await client.close(handle)
    await #expect(throws: SFTPError.invalidLength) {
      _ = try await client.read(handle, offset: 0, length: 0)
    }
  }

  @Test
  func `upload completes with verified identical content`() async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    let (source, data) = try fixture.sourceFile(size: Self.fileSize)
    let log = ManifestLog()
    var manifest = try await SFTPTransfers.prepareUpload(
      source: source,
      remotePath: "/upload.bin",
      stagingDirectory: fixture.staging
    )
    #expect(manifest.sourceSize == UInt64(data.count))
    #expect(manifest.sourceSHA256 == hexString(SHA256.hash(data: data)))
    #expect(manifest.remoteTemporaryPath!.hasPrefix("/.upload.bin."))

    let (connection, client) = try await fixture.session()
    try await SFTPTransfers.upload(
      &manifest,
      client: client,
      checkpoint: log.checkpoint
    )
    await connection.close()
    #expect(manifest.state == .completed)
    #expect(log.latest.withLock { $0 } == manifest)
    #expect(fixture.remoteData("/upload.bin") == data)
    #expect(fixture.remoteNames() == ["upload.bin"])
    #expect(!FileManager.default.fileExists(atPath: manifest.localPath))
    // Writes use the outstanding window, never append mode.
    #expect(fixture.server.state.writes.withLock { $0 } == 20)
  }

  @Test(arguments: [2, 5, 9, 14, 21, 26, 30, 34])
  func `interrupted upload resumes to an identical file`(
    dropAfter: Int
  ) async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    let (source, data) = try fixture.sourceFile(size: Self.fileSize, seed: 7)
    let log = ManifestLog()
    var manifest = try await SFTPTransfers.prepareUpload(
      source: source,
      remotePath: "/dest.bin",
      stagingDirectory: fixture.staging
    )
    fixture.server.state.faults.withLock { $0.dropAfterRequests = dropAfter }

    let attempts = try await fixture.untilComplete { client in
      do {
        try await SFTPTransfers.upload(
          &manifest,
          client: client,
          checkpoint: log.checkpoint
        )
      } catch {
        // Never complete when interrupted; the checkpoint matches.
        #expect(manifest.state != .completed)
        #expect(log.latest.withLock { $0 }.map { $0 == manifest } ?? true)
        throw error
      }
    }
    #expect(attempts == 2)
    #expect(manifest.state == .completed)
    #expect(fixture.remoteData("/dest.bin") == data)
    #expect(fixture.remoteNames() == ["dest.bin"])
  }

  @Test
  func `resume keeps a verified prefix and restarts on an altered one`()
    async throws
  {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    let (source, data) = try fixture.sourceFile(size: Self.fileSize, seed: 3)
    var manifest = try await SFTPTransfers.prepareUpload(
      source: source,
      remotePath: "/dest.bin",
      stagingDirectory: fixture.staging
    )
    // open + several writes, then drop.
    fixture.server.state.faults.withLock { $0.dropAfterRequests = 12 }
    var (connection, client) = try await fixture.session()
    await #expect(throws: SFTPError.connectionClosed) {
      try await SFTPTransfers.upload(&manifest, client: client)
    }
    await connection.close()
    #expect(manifest.state == .transferring)
    #expect(manifest.acknowledgedOffset > 0)
    #expect(manifest.acknowledgedOffset % 32768 == 0)
    let firstTemp = try #require(manifest.remoteTemporaryPath)

    // Corrupt the retained prefix on the server.
    let tempURL = fixture.server.url(firstTemp)
    var corrupted = try Data(contentsOf: tempURL)
    corrupted[100] ^= 0xFF
    try corrupted.write(to: tempURL)

    (connection, client) = try await fixture.session()
    try await SFTPTransfers.upload(&manifest, client: client)
    await connection.close()
    #expect(manifest.state == .completed)
    #expect(manifest.restartCount == 1)
    #expect(manifest.remoteTemporaryPath != firstTemp)
    #expect(fixture.remoteData("/dest.bin") == data)
    // The corrupted temporary file was discarded.
    #expect(fixture.remoteNames() == ["dest.bin"])
  }

  @Test
  func `intact prefix is reused without restarting`() async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    let (source, data) = try fixture.sourceFile(size: Self.fileSize, seed: 4)
    var manifest = try await SFTPTransfers.prepareUpload(
      source: source,
      remotePath: "/dest.bin",
      stagingDirectory: fixture.staging
    )
    fixture.server.state.faults.withLock { $0.dropAfterRequests = 14 }
    var (connection, client) = try await fixture.session()
    await #expect(throws: SFTPError.self) {
      try await SFTPTransfers.upload(&manifest, client: client)
    }
    await connection.close()
    try #require(
      try await waitUntil {
        fixture.server.state.connections.withLock { $0.channels.isEmpty }
      },
      "old server connection did not finish before capturing writes"
    )
    let retained = manifest.acknowledgedOffset
    #expect(retained > 0)
    let writesBefore = fixture.server.state.writes.withLock { $0 }

    (connection, client) = try await fixture.session()
    try await SFTPTransfers.upload(&manifest, client: client)
    await connection.close()
    #expect(manifest.restartCount == 0)
    let resent = fixture.server.state.writes.withLock { $0 } - writesBefore
    let remaining = (UInt64(data.count) - retained + 32767) / 32768
    #expect(UInt64(resent) == remaining)
    #expect(fixture.remoteData("/dest.bin") == data)
  }

  @Test
  func `lost rename response is inspected before retrying`() async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    let (source, data) = try fixture.sourceFile(size: 100_000, seed: 5)
    let log = ManifestLog()
    var manifest = try await SFTPTransfers.prepareUpload(
      source: source,
      remotePath: "/dest.bin",
      stagingDirectory: fixture.staging
    )
    fixture.server.state.faults.withLock { $0.dropRenameResponse = true }

    var (connection, client) = try await fixture.session()
    await #expect(throws: SFTPError.connectionClosed) {
      try await SFTPTransfers.upload(
        &manifest,
        client: client,
        checkpoint: log.checkpoint
      )
    }
    await connection.close()
    // The rename happened, but the client cannot know that yet.
    #expect(manifest.state == .renaming)
    #expect(log.latest.withLock { $0?.state } == .renaming)
    #expect(fixture.remoteData("/dest.bin") == data)

    // Resume from the persisted manifest only.
    var resumed = try #require(log.latest.withLock { $0 })
    (connection, client) = try await fixture.session()
    try await SFTPTransfers.upload(&resumed, client: client)
    await connection.close()
    #expect(resumed.state == .completed)
    #expect(fixture.server.state.renames.withLock { $0 } == 1)
    #expect(fixture.remoteData("/dest.bin") == data)
  }

  @Test
  func `existing destination is never overwritten without a decision`()
    async throws
  {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    let (source, data) = try fixture.sourceFile(size: 70_000, seed: 6)
    let original = Data("keep me".utf8)
    try fixture.remoteFile("/dest.bin", data: original)
    var manifest = try await SFTPTransfers.prepareUpload(
      source: source,
      remotePath: "/dest.bin",
      stagingDirectory: fixture.staging
    )

    var (connection, client) = try await fixture.session()
    await #expect(throws: SFTPTransferError.destinationExists) {
      try await SFTPTransfers.upload(&manifest, client: client)
    }
    #expect(manifest.state == .conflict)
    #expect(fixture.remoteData("/dest.bin") == original)
    await connection.close()

    // Conflict appearing after the bytes moved: temp is kept, verified.
    try FileManager.default.removeItem(at: fixture.server.url("/dest.bin"))
    fixture.server.state.faults.withLock { $0.dropAfterRequests = 8 }
    (connection, client) = try await fixture.session()
    await #expect(throws: SFTPError.self) {
      try await SFTPTransfers.upload(&manifest, client: client)
    }
    await connection.close()
    try fixture.remoteFile("/dest.bin", data: original)
    (connection, client) = try await fixture.session()
    await #expect(throws: SFTPTransferError.destinationExists) {
      try await SFTPTransfers.upload(&manifest, client: client)
    }
    await connection.close()
    #expect(manifest.state == .conflict)
    #expect(fixture.remoteData("/dest.bin") == original)
    #expect(fixture.remoteNames().count == 2)

    // An explicit decision replaces it.
    manifest.overwriteExisting = true
    (connection, client) = try await fixture.session()
    try await SFTPTransfers.upload(&manifest, client: client)
    await connection.close()
    #expect(manifest.state == .completed)
    #expect(fixture.remoteData("/dest.bin") == data)
    #expect(fixture.remoteNames() == ["dest.bin"])
  }

  @Test(arguments: [3, 7, 11, 18, 24, 31])
  func `interrupted download resumes to a verified identical file`(
    dropAfter: Int
  ) async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    let (_, data) = try fixture.sourceFile(size: Self.fileSize, seed: 9)
    try fixture.remoteFile("/remote.bin", data: data)
    let destination = fixture.local.appendingPathComponent("downloaded.bin")
    let log = ManifestLog()
    var manifest = try SFTPTransfers.prepareDownload(
      remotePath: "/remote.bin",
      temporaryDirectory: fixture.local,
      destination: destination
    )
    fixture.server.state.faults.withLock { $0.dropAfterRequests = dropAfter }

    let attempts = try await fixture.untilComplete { client in
      do {
        try await SFTPTransfers.download(
          &manifest,
          client: client,
          checkpoint: log.checkpoint
        )
      } catch {
        let drop = fixture.server.state.lastSFTPDrop.withLock { $0 }
        #expect(
          error as? SFTPError == .connectionClosed,
          "unexpected interruption error; disconnect observation: \(String(describing: drop))"
        )
        #expect(manifest.state != .completed)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        throw error
      }
    }
    #expect(attempts == 2)
    #expect(manifest.state == .completed)
    #expect(manifest.sourceSHA256 == hexString(SHA256.hash(data: data)))
    #expect(try Data(contentsOf: destination) == data)
    #expect(!FileManager.default.fileExists(atPath: manifest.localPath))
  }

  @Test
  func `download restarts when the remote prefix changed`() async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    let (_, data) = try fixture.sourceFile(size: Self.fileSize, seed: 10)
    try fixture.remoteFile("/remote.bin", data: data)
    let destination = fixture.local.appendingPathComponent("out.bin")
    var manifest = try SFTPTransfers.prepareDownload(
      remotePath: "/remote.bin",
      temporaryDirectory: fixture.local,
      destination: destination
    )
    fixture.server.state.faults.withLock { $0.dropAfterRequests = 12 }
    var (connection, client) = try await fixture.session()
    await #expect(throws: SFTPError.self) {
      try await SFTPTransfers.download(&manifest, client: client)
    }
    await connection.close()
    #expect(manifest.acknowledgedOffset > 0)

    // Same size (and likely mtime second), different prefix bytes.
    var changed = data
    changed[10] ^= 0x55
    try fixture.remoteFile("/remote.bin", data: changed)
    let identity = manifest.remoteIdentity
    let attributes = try FileManager.default.attributesOfItem(
      atPath: fixture.server.url("/remote.bin").path
    )
    if let date = identity?.modificationTime {
      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: Double(date))],
        ofItemAtPath: fixture.server.url("/remote.bin").path
      )
    }
    _ = attributes

    (connection, client) = try await fixture.session()
    try await SFTPTransfers.download(&manifest, client: client)
    await connection.close()
    #expect(manifest.restartCount == 1)
    #expect(try Data(contentsOf: destination) == changed)
  }

  @Test
  func `download refuses to replace an existing local file`() async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    try fixture.remoteFile("/remote.bin", data: Data("new".utf8))
    let destination = fixture.local.appendingPathComponent("exists.bin")
    try Data("old".utf8).write(to: destination)
    var manifest = try SFTPTransfers.prepareDownload(
      remotePath: "/remote.bin",
      temporaryDirectory: fixture.local,
      destination: destination
    )
    let (connection, client) = try await fixture.session()
    defer { Task { await connection.close() } }
    await #expect(throws: SFTPTransferError.destinationExists) {
      try await SFTPTransfers.download(&manifest, client: client)
    }
    #expect(manifest.state == .conflict)
    #expect(try Data(contentsOf: destination) == Data("old".utf8))

    manifest.overwriteExisting = true
    try await SFTPTransfers.download(&manifest, client: client)
    #expect(manifest.state == .completed)
    #expect(try Data(contentsOf: destination) == Data("new".utf8))
  }

  @Test
  func `non-regular files are rejected for transfer`() async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    try FileManager.default.createDirectory(
      at: fixture.server.url("/dir"),
      withIntermediateDirectories: false
    )
    var manifest = try SFTPTransfers.prepareDownload(
      remotePath: "/dir",
      temporaryDirectory: fixture.local,
      destination: fixture.local.appendingPathComponent("x")
    )
    let (connection, client) = try await fixture.session()
    defer { Task { await connection.close() } }
    await #expect(throws: SFTPTransferError.notRegularFile) {
      try await SFTPTransfers.download(&manifest, client: client)
    }
    await #expect(throws: SFTPTransferError.notRegularFile) {
      _ = try await SFTPTransfers.prepareUpload(
        source: fixture.local,
        remotePath: "/x",
        stagingDirectory: fixture.staging
      )
    }
    #expect(throws: SFTPTransferError.invalidRemotePath) {
      _ = try SFTPTransfers.prepareDownload(
        remotePath: "/dir/",
        temporaryDirectory: fixture.local,
        destination: fixture.local
      )
    }
  }

  @Test
  func `paused gate holds bulk work and cancellation stays resumable`()
    async throws
  {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    let (source, data) = try fixture.sourceFile(size: Self.fileSize, seed: 11)
    let gate = TransferPauseGate()
    await gate.pause()
    let log = ManifestLog()
    let manifest = try await SFTPTransfers.prepareUpload(
      source: source,
      remotePath: "/dest.bin",
      stagingDirectory: fixture.staging
    )
    let (connection, client) = try await fixture.session()
    defer { Task { await connection.close() } }

    let task = Task {
      var copy = manifest
      try await SFTPTransfers.upload(
        &copy,
        client: client,
        gate: gate,
        checkpoint: log.checkpoint
      )
      return copy
    }
    #expect(
      try await waitUntil { log.latest.withLock { $0?.state } == .transferring }
    )
    try await Task.sleep(for: .milliseconds(100))
    #expect(fixture.server.state.writes.withLock { $0 } == 0)
    task.cancel()
    await #expect(throws: CancellationError.self) { _ = try await task.value }

    var resumed = try #require(log.latest.withLock { $0 })
    #expect(resumed.state == .transferring)
    await gate.resume()
    try await SFTPTransfers.upload(&resumed, client: client, gate: gate)
    #expect(resumed.state == .completed)
    #expect(fixture.remoteData("/dest.bin") == data)
  }

  @Test
  func `manifest encoding is bounded and non-secret`() throws {
    var manifest = TransferManifest(
      direction: .upload,
      localPath: "/staged",
      remotePath: "/r",
      sourceSize: 10,
      sourceSHA256: String(repeating: "0", count: 64)
    )
    manifest.acknowledgedOffset = 5
    let data = try manifest.encoded()
    #expect(try TransferManifest.decode(data) == manifest)
    manifest.acknowledgedOffset = 11
    #expect(throws: EncodingError.self) { try manifest.encoded() }
    let invalidData = try JSONEncoder().encode(manifest)
    #expect(throws: DecodingError.self) {
      _ = try TransferManifest.decode(invalidData)
    }
    #expect(throws: DecodingError.self) {
      _ = try TransferManifest.decode(Data(count: 70_000))
    }
  }
}

// Destination aliases and safe publication on the native filesystem.
extension SFTPTransferTests {
  @Test(arguments: ["live", "dangling"])
  func downloadDestinationSymlinksRequireOverwriteApproval(
    _ kind: String
  ) async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    let bytes = Data("download".utf8)
    let old = Data("unrelated".utf8)
    try fixture.remoteFile("/source", data: bytes)
    let target = fixture.local.appendingPathComponent("symlink-target")
    if kind == "live" { try old.write(to: target) }
    let destination = fixture.local.appendingPathComponent("destination")
    try FileManager.default.createSymbolicLink(
      at: destination,
      withDestinationURL: target
    )
    var manifest = try SFTPTransfers.prepareDownload(
      remotePath: "/source",
      temporaryDirectory: fixture.local,
      destination: destination
    )
    let (connection, client) = try await fixture.session()
    defer { Task { await connection.close() } }
    await #expect(throws: SFTPTransferError.destinationExists) {
      try await SFTPTransfers.download(&manifest, client: client)
    }
    #expect(manifest.state == .conflict)
    let retainedLink = try FileManager.default.destinationOfSymbolicLink(
      atPath: destination.path
    )
    #expect(retainedLink == target.path)
    manifest.overwriteExisting = true
    try await SFTPTransfers.download(&manifest, client: client)
    let published = try Data(contentsOf: destination)
    var info = Darwin.stat()
    try #require(lstat(destination.path, &info) == 0)
    #expect(info.st_mode & S_IFMT == S_IFREG)
    #expect(manifest.isComplete)
    #expect(published == bytes)
    if kind == "live" {
      let targetBytes = try Data(contentsOf: target)
      #expect(targetBytes == old)
    } else {
      let targetExists = FileManager.default.fileExists(atPath: target.path)
      #expect(!targetExists)
    }
    await connection.close()
    await fixture.cleanup()
  }

  @Test(arguments: ["file", "directory", "symlink", "fifo", "missing"])
  func discardOnlyRemovesTheTemporaryDirectoryEntry(_ kind: String) async throws
  {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("destination")
    let target = directory.appendingPathComponent("unrelated")
    let bytes = Data([1, 2, 3])
    try bytes.write(to: destination)
    try bytes.write(to: target)
    let manifest = try SFTPTransfers.prepareDownload(
      remotePath: "/source",
      temporaryDirectory: directory,
      destination: destination
    )
    let temporary = URL(fileURLWithPath: manifest.localPath)
    let nested = temporary.appendingPathComponent("unrelated")
    switch kind {
    case "file": try bytes.write(to: temporary)
    case "directory":
      try FileManager.default.createDirectory(
        at: temporary,
        withIntermediateDirectories: false
      )
      try bytes.write(to: nested)
    case "symlink":
      try FileManager.default.createSymbolicLink(
        at: temporary,
        withDestinationURL: target
      )
    case "fifo": try #require(mkfifo(temporary.path, 0o600) == 0)
    default: break
    }
    await SFTPTransfers.discard(manifest, client: nil)
    var info = Darwin.stat()
    let retained = lstat(temporary.path, &info) == 0
    #expect(retained == (kind == "directory"))
    if kind == "directory" {
      let nestedBytes = try? Data(contentsOf: nested)
      #expect(nestedBytes == bytes)
    }
    let destinationBytes = try Data(contentsOf: destination)
    let targetBytes = try Data(contentsOf: target)
    #expect(destinationBytes == bytes)
    #expect(targetBytes == bytes)
  }

  @Test
  func uploadCompletionDoesNotRecursivelyRemoveAReplacedStage() async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    let (source, bytes) = try fixture.sourceFile(size: 4)
    var manifest = try await SFTPTransfers.prepareUpload(
      source: source,
      remotePath: "/destination",
      stagingDirectory: fixture.staging
    )
    let temporary = URL(fileURLWithPath: manifest.localPath)
    let nested = temporary.appendingPathComponent("unrelated")
    let (connection, client) = try await fixture.session()
    defer { Task { await connection.close() } }
    try await SFTPTransfers.upload(&manifest, client: client) { checkpoint in
      guard checkpoint.isComplete else { return }
      do {
        try FileManager.default.removeItem(at: temporary)
        try FileManager.default.createDirectory(
          at: temporary,
          withIntermediateDirectories: false
        )
        try bytes.write(to: nested)
      } catch { Issue.record(error) }
    }
    let nestedBytes = try? Data(contentsOf: nested)
    let remoteBytes = try Data(contentsOf: fixture.server.url("/destination"))
    #expect(manifest.isComplete)
    #expect(nestedBytes == bytes)
    #expect(remoteBytes == bytes)
    await connection.close()
    await fixture.cleanup()
  }

  @Test(
    arguments: ["same", "dot", "parent-symlink", "hardlink"],
    [false, true]
  )
  func downloadRejectsADestinationAlias(
    _ kind: String,
    _ overwrite: Bool
  ) async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    let destination = fixture.local.appendingPathComponent("destination")
    let original = Data("keep this".utf8)
    try original.write(to: destination)
    try fixture.remoteFile("/source", data: Data("replacement".utf8))
    var manifest = try SFTPTransfers.prepareDownload(
      remotePath: "/source",
      temporaryDirectory: fixture.local,
      destination: destination,
      overwriteExisting: overwrite
    )
    switch kind {
    case "same": manifest.localPath = destination.path
    case "dot": manifest.localPath = fixture.local.path + "/./destination"
    case "parent-symlink":
      let alias = fixture.local.appendingPathComponent("alias")
      try FileManager.default.createSymbolicLink(
        at: alias,
        withDestinationURL: fixture.local
      )
      manifest.localPath = alias.appendingPathComponent("destination").path
    default:
      try FileManager.default.linkItem(
        at: destination,
        to: URL(fileURLWithPath: manifest.localPath)
      )
    }
    let (connection, client) = try await fixture.session()
    defer { Task { await connection.close() } }
    let requestsBefore = fixture.server.state.sftpRequests.withLock { $0 }
    await #expect(throws: SFTPTransferError.invalidManifest) {
      try await SFTPTransfers.download(&manifest, client: client)
    }
    let retained = try? Data(contentsOf: destination)
    let requestsAfter = fixture.server.state.sftpRequests.withLock { $0 }
    #expect(retained == original)
    #expect(requestsAfter == requestsBefore)
    #expect(!manifest.isComplete)
    await connection.close()
    await fixture.cleanup()
  }

  @Test(arguments: ["same", "dot", "parent-symlink"])
  func downloadRejectsAnAbsentDestinationAliasBeforeCreatingIt(
    _ kind: String
  ) async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    let destination = fixture.local.appendingPathComponent("destination")
    try fixture.remoteFile("/source", data: Data("replacement".utf8))
    var manifest = try SFTPTransfers.prepareDownload(
      remotePath: "/source",
      temporaryDirectory: fixture.local,
      destination: destination
    )
    if kind == "parent-symlink" {
      let alias = fixture.local.appendingPathComponent("alias")
      try FileManager.default.createSymbolicLink(
        at: alias,
        withDestinationURL: fixture.local
      )
      manifest.localPath = alias.appendingPathComponent("destination").path
    } else {
      manifest.localPath =
        kind == "same"
        ? destination.path : fixture.local.path + "/./destination"
    }
    let (connection, client) = try await fixture.session()
    defer { Task { await connection.close() } }
    let requestsBefore = fixture.server.state.sftpRequests.withLock { $0 }
    await #expect(throws: SFTPTransferError.invalidManifest) {
      try await SFTPTransfers.download(&manifest, client: client)
    }
    let created = FileManager.default.fileExists(atPath: destination.path)
    let requestsAfter = fixture.server.state.sftpRequests.withLock { $0 }
    #expect(!created)
    #expect(requestsAfter == requestsBefore)
    await connection.close()
    await fixture.cleanup()
  }

  @Test(arguments: [
    "same", "dot", "parent-symlink", "hardlink", "destination-symlink",
    "missing-destination",
  ])
  func discardPreservesAnAliasedDownloadDestination(_ kind: String) async throws
  {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("destination")
    let original = Data("keep this".utf8)
    var manifest = try SFTPTransfers.prepareDownload(
      remotePath: "/source",
      temporaryDirectory: directory,
      destination: destination
    )
    let temporary = URL(fileURLWithPath: manifest.localPath)
    if kind == "destination-symlink" {
      try original.write(to: temporary)
      try FileManager.default.createSymbolicLink(
        at: destination,
        withDestinationURL: temporary
      )
    } else {
      try original.write(to: destination)
      switch kind {
      case "same", "missing-destination": manifest.localPath = destination.path
      case "dot": manifest.localPath = directory.path + "/./destination"
      case "parent-symlink":
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(
          at: alias,
          withDestinationURL: directory
        )
        manifest.localPath = alias.appendingPathComponent("destination").path
      default: try FileManager.default.linkItem(at: destination, to: temporary)
      }
    }
    if kind == "missing-destination" { manifest.localDestinationPath = nil }
    await SFTPTransfers.discard(manifest, client: nil)
    let retainedBytes = try? Data(contentsOf: destination)
    var info = Darwin.stat()
    let retainedEntry = lstat(manifest.localPath, &info) == 0
    #expect(retainedBytes == original)
    #expect(retainedEntry)
  }

  @Test(arguments: [
    ("destination", "DESTINATION"), ("straße", "STRASSE"), ("é", "e\u{301}"),
    ("a", "á"),
  ])
  func downloadNameAliasesFollowTheNativeFilesystem(
    _ localName: String,
    _ destinationName: String
  ) async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    let probe = fixture.local.appendingPathComponent("probe")
    try FileManager.default.createDirectory(
      at: probe,
      withIntermediateDirectories: false
    )
    try Data([1]).write(to: probe.appendingPathComponent(localName))
    let aliases = FileManager.default.fileExists(
      atPath: probe.appendingPathComponent(destinationName).path
    )
    let destination = fixture.local.appendingPathComponent(destinationName)
    let bytes = Data("download".utf8)
    try fixture.remoteFile("/source", data: bytes)
    var manifest = try SFTPTransfers.prepareDownload(
      remotePath: "/source",
      temporaryDirectory: fixture.local,
      destination: destination
    )
    manifest.localPath = fixture.local.appendingPathComponent(localName).path
    let (connection, client) = try await fixture.session()
    defer { Task { await connection.close() } }
    let requestsBefore = fixture.server.state.sftpRequests.withLock { $0 }
    if aliases {
      await #expect(throws: SFTPTransferError.invalidManifest) {
        try await SFTPTransfers.download(&manifest, client: client)
      }
      let created = FileManager.default.fileExists(atPath: destination.path)
      let requestsAfter = fixture.server.state.sftpRequests.withLock { $0 }
      #expect(!created)
      #expect(requestsAfter == requestsBefore)
    } else {
      try await SFTPTransfers.download(&manifest, client: client)
      let published = try Data(contentsOf: destination)
      #expect(manifest.isComplete)
      #expect(published == bytes)
    }
    await connection.close()
    await fixture.cleanup()
  }

  @Test(.enabled(if: Self.caseInsensitiveTemporaryVolume))
  func downloadRejectsACaseAliasedParentBeforeCreatingTheDestination()
    async throws
  {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    let parent = fixture.local.appendingPathComponent("parent")
    try FileManager.default.createDirectory(
      at: parent,
      withIntermediateDirectories: false
    )
    let destination = parent.appendingPathComponent("destination")
    var manifest = try SFTPTransfers.prepareDownload(
      remotePath: "/source",
      temporaryDirectory: fixture.local,
      destination: destination
    )
    manifest.localPath =
      fixture.local.appendingPathComponent("PARENT/destination").path
    let (connection, client) = try await fixture.session()
    defer { Task { await connection.close() } }
    let requestsBefore = fixture.server.state.sftpRequests.withLock { $0 }
    await #expect(throws: SFTPTransferError.invalidManifest) {
      try await SFTPTransfers.download(&manifest, client: client)
    }
    let created = FileManager.default.fileExists(atPath: destination.path)
    let requestsAfter = fixture.server.state.sftpRequests.withLock { $0 }
    #expect(!created)
    #expect(requestsAfter == requestsBefore)
    await connection.close()
    await fixture.cleanup()
  }

  @Test(arguments: [
    "/folder/destination", "/folder/./destination", "/folder//destination",
  ])
  func resumedUploadRejectsATemporaryDestinationAlias(
    _ temporaryPath: String
  ) async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    let (source, _) = try fixture.sourceFile(size: 4)
    let original = Data("protected".utf8)
    try FileManager.default.createDirectory(
      at: fixture.server.url("/folder"),
      withIntermediateDirectories: false
    )
    try fixture.remoteFile("/folder/destination", data: original)
    var manifest = try await SFTPTransfers.prepareUpload(
      source: source,
      remotePath: "/folder/destination",
      stagingDirectory: fixture.staging
    )
    manifest.remoteTemporaryPath = temporaryPath
    manifest.state = .transferring
    manifest.acknowledgedOffset = 1
    let (connection, client) = try await fixture.session()
    defer { Task { await connection.close() } }
    let requestsBefore = fixture.server.state.sftpRequests.withLock { $0 }
    await #expect(throws: SFTPTransferError.invalidManifest) {
      try await SFTPTransfers.upload(&manifest, client: client)
    }
    let retained = try? Data(
      contentsOf: fixture.server.url("/folder/destination")
    )
    let requestsAfter = fixture.server.state.sftpRequests.withLock { $0 }
    #expect(retained == original)
    #expect(requestsAfter == requestsBefore)
    #expect(!manifest.isComplete)
    await connection.close()
    await fixture.cleanup()
  }

  @Test(arguments: [
    "/folder/destination", "/folder/./destination", "/folder//destination",
  ])
  func discardPreservesARemoteDestinationAlias(
    _ temporaryPath: String
  ) async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    let (source, _) = try fixture.sourceFile(size: 4)
    let original = Data("protected".utf8)
    try FileManager.default.createDirectory(
      at: fixture.server.url("/folder"),
      withIntermediateDirectories: false
    )
    try fixture.remoteFile("/folder/destination", data: original)
    var manifest = try await SFTPTransfers.prepareUpload(
      source: source,
      remotePath: "/folder/destination",
      stagingDirectory: fixture.staging
    )
    manifest.remoteTemporaryPath = temporaryPath
    let (connection, client) = try await fixture.session()
    defer { Task { await connection.close() } }
    let requestsBefore = fixture.server.state.sftpRequests.withLock { $0 }
    await SFTPTransfers.discard(manifest, client: client)
    let retained = try? Data(
      contentsOf: fixture.server.url("/folder/destination")
    )
    let requestsAfter = fixture.server.state.sftpRequests.withLock { $0 }
    let stagedExists = FileManager.default.fileExists(
      atPath: manifest.localPath
    )
    #expect(retained == original)
    #expect(requestsAfter == requestsBefore)
    #expect(!stagedExists)
    await connection.close()
    await fixture.cleanup()
  }

}
