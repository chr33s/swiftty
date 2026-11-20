import Foundation

/// Remote file metadata recorded with a transfer (spec §10). Size and
/// modification time detect obvious changes, but never prove content
/// identity on their own; resume always re-hashes the retained prefix.
public struct RemoteFileIdentity: Hashable, Sendable, Codable {
  public var size: UInt64
  /// Seconds since 1970, as reported by SFTP v3 (32-bit).
  public var modificationTime: UInt32?
  public var permissions: UInt32?

  public init(size: UInt64, modificationTime: UInt32?, permissions: UInt32?) {
    self.size = size
    self.modificationTime = modificationTime
    self.permissions = permissions
  }
}

/// Persistable, non-secret checkpoint of one resumable SFTP transfer
/// (spec §10). Holds paths, offsets and hashes only: never credentials,
/// tokens or file contents.
///
/// `acknowledgedOffset` is the highest *contiguous* offset known to be
/// complete: every byte before it was acknowledged (upload) or written
/// locally from verified reads (download). Resume re-verifies that prefix
/// by SHA-256 before trusting it.
public struct TransferManifest: Hashable, Sendable, Codable, Identifiable {
  public static let maxEncodedBytes = 64 * 1024
  public enum Direction: String, Hashable, Sendable, Codable {
    case upload, download
  }

  public enum State: String, Hashable, Sendable, Codable {
    /// Source staged; no remote work has started.
    case staged
    /// Bytes are being moved; `acknowledgedOffset` is resumable.
    case transferring
    /// All bytes moved; whole-content verification pending.
    case verifying
    /// Upload verified; the rename's outcome may be unknown and must be
    /// inspected before any retry.
    case renaming
    /// The destination already exists and overwriting was not approved.
    case conflict
    /// Verified and published. Never set for an unverified file.
    case completed
    /// Unrecoverable without user intervention.
    case failed
  }

  public let id: UUID
  public let direction: Direction
  public var state: State

  /// Upload: the immutable staged copy in app-controlled storage.
  /// Download: the local temporary file receiving the remote bytes.
  public var localPath: String
  /// Upload: the final remote destination. Download: the remote source.
  public var remotePath: String
  /// Upload only: the uniquely named temporary file beside the
  /// destination. Replaced by a fresh name whenever the upload restarts.
  public var remoteTemporaryPath: String?
  /// Download only: where the verified file is published.
  public var localDestinationPath: String?
  /// Whether the caller explicitly approved replacing an existing
  /// destination. Defaults to `false` (spec §10).
  public var overwriteExisting: Bool

  /// Size of the source: the staged file for uploads, the remote file
  /// (as first observed) for downloads.
  public var sourceSize: UInt64
  /// Lowercase hex SHA-256 of the staged source (uploads). Downloads
  /// fill it in only once the complete file is verified.
  public var sourceSHA256: String?
  public var acknowledgedOffset: UInt64
  /// Lowercase hex SHA-256 of bytes `0 ..< acknowledgedOffset` as
  /// written locally (downloads); checked again on resume.
  public var prefixSHA256: String?
  /// Remote metadata: the source file (download) or the last observed
  /// temporary file (upload).
  public var remoteIdentity: RemoteFileIdentity?
  /// Number of times the transfer restarted from offset zero.
  public var restartCount: Int

  public init(
    id: UUID = UUID(),
    direction: Direction,
    localPath: String,
    remotePath: String,
    remoteTemporaryPath: String? = nil,
    localDestinationPath: String? = nil,
    overwriteExisting: Bool = false,
    sourceSize: UInt64,
    sourceSHA256: String? = nil
  ) {
    self.id = id
    self.direction = direction
    self.state = .staged
    self.localPath = localPath
    self.remotePath = remotePath
    self.remoteTemporaryPath = remoteTemporaryPath
    self.localDestinationPath = localDestinationPath
    self.overwriteExisting = overwriteExisting
    self.sourceSize = sourceSize
    self.sourceSHA256 = sourceSHA256
    self.acknowledgedOffset = 0
    self.prefixSHA256 = nil
    self.remoteIdentity = nil
    self.restartCount = 0
  }

  /// Whether this manifest describes a verified, published file.
  public var isComplete: Bool { state == .completed }

  /// Progress remains within the source and restart history is nonnegative.
  /// Checked at decode and again when mutable manifests are resumed.
  public var hasValidProgress: Bool {
    acknowledgedOffset <= sourceSize && restartCount >= 0
  }

  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(self)
    guard data.count <= Self.maxEncodedBytes, hasValidProgress else {
      throw EncodingError.invalidValue(
        self,
        .init(
          codingPath: [],
          debugDescription: "invalid or oversized transfer manifest"
        )
      )
    }
    return data
  }

  /// Decodes a stored manifest, rejecting oversized input before parsing.
  public static func decode(_ data: Data) throws -> TransferManifest {
    guard data.count <= Self.maxEncodedBytes else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: [], debugDescription: "manifest too large")
      )
    }
    let manifest = try JSONDecoder().decode(TransferManifest.self, from: data)
    guard manifest.hasValidProgress else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: [], debugDescription: "invalid transfer progress")
      )
    }
    return manifest
  }
}
