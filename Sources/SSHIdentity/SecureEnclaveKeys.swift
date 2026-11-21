import Crypto
import Foundation
import SSHClient

#if canImport(Security)
import Security
#endif

/// Why a Secure Enclave key could not be made (spec.ssh-identity.md §13.2).
public enum SecureEnclaveKeyError: Error, Hashable, Sendable {
  /// No Secure Enclave on this device (for example a simulator).
  case unavailable
  case accessControl
  case generationFailed
}

/// Device-bound P-256 keys generated inside the Secure Enclave. The
/// private key never leaves it; Swiftty stores only the sealed handle.
public enum SecureEnclaveKeys {
  public static var isAvailable: Bool {
    #if canImport(Darwin)
    SecureEnclave.isAvailable
    #else
    false
    #endif
  }

  /// A new key. With `requireUserPresence`, every signature needs Face ID,
  /// Touch ID or the device passcode; without it, the device must merely
  /// be unlocked. Either way the key is unusable on any other device.
  public static func generate(
    requireUserPresence: Bool
  ) throws(SecureEnclaveKeyError) -> IdentitySecret {
    #if canImport(Darwin) && canImport(Security)
    guard SecureEnclave.isAvailable else { throw .unavailable }
    var flags: SecAccessControlCreateFlags = [.privateKeyUsage]
    if requireUserPresence { flags.insert(.userPresence) }
    guard
      let access = SecAccessControlCreateWithFlags(
        nil,
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        flags,
        nil
      )
    else { throw .accessControl }
    do {
      let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
      return IdentitySecret(key: .secureEnclaveP256(key))
    } catch { throw .generationFailed }
    #else
    throw .unavailable
    #endif
  }
}
