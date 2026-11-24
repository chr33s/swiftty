import Foundation
@testable import RoamingKit
import ScreenProtocol
import SwiftMuxProtocol
import Testing

/// An alias can reach the client before the blob it names (the host
/// aliases digests already on their way). The client waits for the blob
/// instead of requesting the pixels again (KG28 iPhone run), and asks only
/// when no blob comes.
@Suite(.timeLimit(.minutes(1)))
struct RoamingImageAliasTests {
  private static let rgba = [UInt8](repeating: 7, count: 4 * 4 * 4)

  private func blob(key: UInt64) throws -> ImageBlob {
    try #require(
      ImageBlobCodec.encode(
        key: key,
        rgba: Self.rgba,
        width: 4,
        height: 4,
        variant: .full
      )
    )
  }

  private func fixture() async throws -> RoamingFixture {
    let f = try RoamingFixture()
    await f.host.set(features: .required.union(.kittyGraphics))
    try #require(try await f.startActive())
    return f
  }

  @Test
  func `an alias that arrives before its blob waits for it`() async throws {
    let f = try await fixture()
    defer { Task { await f.client.close() } }
    let epoch = try #require(await f.host.currentEpoch)
    let first = try blob(key: 1)
    await f.host.sendControlForTesting(
      .imageAlias(epoch: epoch, key: 2, digest: first.digestHex)
    )
    try await f.host.sendRawSnapshotForTesting(first.encoded())
    let section = FrameImages(
      cellWidth: 8,
      cellHeight: 16,
      images: [FrameImage(key: 2, width: 4, height: 4, bytesPerPixel: 4)],
      placements: []
    )
    #expect(await eventually { f.client.images.missing(section).isEmpty })
    // Past the 2 s wait (scaled by the test clock): no request was needed.
    let waited = f.clock.sleeps.withLock { $0.count }
    _ = await eventually { f.clock.sleeps.withLock { $0.count } > waited }
    try await Task.sleep(for: .milliseconds(500))
    #expect(await f.host.imageRequests.isEmpty)
  }

  @Test
  func `an alias whose blob never comes asks for the pixels`() async throws {
    let f = try await fixture()
    defer { Task { await f.client.close() } }
    let epoch = try #require(await f.host.currentEpoch)
    let digest = String(repeating: "ab", count: 32)
    await f.host.sendControlForTesting(
      .imageAlias(epoch: epoch, key: 3, digest: digest)
    )
    try await Task.sleep(for: .milliseconds(100))
    #expect(await f.host.imageRequests.isEmpty)
    #expect(
      await eventually(.seconds(10)) { await f.host.imageRequests == [[3]] }
    )
  }
}
