import Crypto
import Foundation

/// Why the selected identity cannot authenticate (§6.1). Each case fails
/// closed: no replacement key is generated, no other key is tried and
/// there is no password fallback.
public enum IdentityResolutionError: Error, Hashable, Sendable {
  /// The profile names an identity this device has no metadata for.
  case unknownIdentity
  case deleted
  case unavailableOnThisDevice
  case awaitingKeyMaterial
  case protectedDataUnavailable
  case unsupported
  /// The stored key does not match the identity's public key, or the
  /// identity's metadata is itself invalid.
  case integrityConflict
  case cancelled

  public var availability: IdentityAvailability? {
    switch self {
    case .unknownIdentity, .cancelled: nil
    case .deleted: .deleted
    case .unavailableOnThisDevice: .unavailableOnThisDevice
    case .awaitingKeyMaterial: .awaitingKeyMaterial
    case .protectedDataUnavailable: .protectedDataUnavailable
    case .unsupported: .unsupported
    case .integrityConflict: .integrityConflict
    }
  }
}

/// Read-only resolution of exactly one selected identity (§5, §6.1).
/// Never creates, replaces or searches for keys.
public struct IdentityResolver: Sendable {
  public let secrets: any IdentitySecretStore

  public init(secrets: any IdentitySecretStore) { self.secrets = secrets }

  /// The private key for `metadata`, verified against its public key.
  /// Callers hold the result only for the authentication operation.
  public func resolve(
    _ metadata: SSHIdentityMetadata?
  ) async throws(IdentityResolutionError) -> IdentitySecret {
    guard let metadata else { throw .unknownIdentity }
    guard !metadata.isDeleted else { throw .deleted }
    guard metadata.isValid else { throw .integrityConflict }
    guard !Task.isCancelled else { throw .cancelled }
    let secret: IdentitySecret
    do {
      secret = try await secrets.read(id: metadata.id, policy: metadata.storage)
    } catch { throw Self.map(error, policy: metadata.storage) }
    guard !Task.isCancelled else { throw .cancelled }
    guard secret.publicKeyLine == metadata.publicKey,
      secret.matches(metadata.storage)
    else { throw .integrityConflict }
    return secret
  }

  /// Local availability, without returning key material.
  public func availability(
    of metadata: SSHIdentityMetadata
  ) async -> IdentityAvailability {
    do {
      _ = try await resolve(metadata)
      return .available
    } catch { return error.availability ?? .unsupported }
  }

  static func map(
    _ error: IdentitySecretError,
    policy: IdentityStoragePolicy
  ) -> IdentityResolutionError {
    switch error {
    case .notFound:
      policy.isDeviceBound ? .unavailableOnThisDevice : .awaitingKeyMaterial
    case .protectedDataUnavailable: .protectedDataUnavailable
    case .authenticationCancelled: .cancelled
    case .malformed, .ambiguous, .duplicate: .integrityConflict
    case .missingEntitlement, .status: .unsupported
    }
  }
}
