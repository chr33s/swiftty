import Crypto
import Foundation
import SSHClient
import Testing

@testable import SSHIdentity

/// KEY-05: bounded `openssh-key-v1` import, unencrypted and
/// passphrase-protected (spec.ssh-identity.md §6.2, §6.4).
@Suite
struct OpenSSHKeyImporterTests {
  static func fixture(_ name: String) throws -> Data {
    let url = try #require(
      Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
    )
    return try Data(contentsOf: url)
  }

  static func expectedFingerprint(_ name: String) throws -> String {
    let line = String(decoding: try fixture("\(name).pub"), as: UTF8.self)
    return try #require(SSHPublicKeyFormat.fingerprint(openSSHPublicKey: line))
  }

  static func decode(
    _ data: Data,
    passphrase: String? = nil
  ) -> Result<ImportedOpenSSHKey, OpenSSHImportError> {
    Result { () throws(OpenSSHImportError) in
      try OpenSSHKeyImporter.decode(data, passphrase: passphrase)
    }
  }

  static func failure(
    _ data: Data,
    passphrase: String? = nil
  ) -> OpenSSHImportError? {
    if case .failure(let error) = decode(data, passphrase: passphrase) {
      return error
    }
    return nil
  }

  static let passphrase = "correct horse"

  @Test
  func importsAnUnencryptedKey() throws {
    let key = try Self.decode(try Self.fixture("plain")).get()
    #expect(key.fingerprint == (try Self.expectedFingerprint("plain")))
    #expect(key.comment == "plain@fixture")
    #expect(key.inspection.algorithm == "ssh-ed25519")
  }

  /// `plain`, re-encrypted by ssh-keygen with each supported cipher
  /// (Fixtures/README.md).
  @Test(arguments: ["aes128-ctr", "aes256-cbc", "aes128-gcm", "aes256-gcm"])
  func decryptsPassphraseProtectedKeys(_ name: String) throws {
    let data = try Self.fixture(name)
    let key = try Self.decode(data, passphrase: Self.passphrase).get()
    #expect(key.fingerprint == (try Self.expectedFingerprint("plain")))
    #expect(key.comment == "plain@fixture")
    #expect(Self.failure(data) == .passphraseRequired)
    #expect(Self.failure(data, passphrase: "") == .passphraseRequired)
    #expect(Self.failure(data, passphrase: "wrong") == .wrongPassphrase)
  }

  /// ssh-keygen's defaults: aes256-ctr, 16 rounds.
  @Test
  func decryptsADefaultEncryptedKey() throws {
    let data = try Self.fixture("aes256")
    let key = try Self.decode(data, passphrase: Self.passphrase).get()
    let inspection = try OpenSSHKeyImporter.inspect(data)
    #expect(key.fingerprint == inspection.fingerprint)
  }

  /// The public key is in the clear, so confirmation needs no passphrase.
  @Test
  func inspectsEncryptedKeysWithoutAPassphrase() throws {
    let inspection = try OpenSSHKeyImporter.inspect(
      try Self.fixture("aes256-cbc")
    )
    #expect(inspection.isEncrypted)
    #expect(inspection.comment == nil)
    #expect(inspection.fingerprint == (try Self.expectedFingerprint("plain")))
    let plain = try OpenSSHKeyImporter.inspect(try Self.fixture("plain"))
    #expect(!plain.isEncrypted)
    #expect(plain.comment == "plain@fixture")
  }

  @Test
  func refusesUnsupportedEncryption() throws {
    #expect(
      Self.failure(try Self.fixture("chacha20"), passphrase: Self.passphrase)
        == .unsupportedCipher("chacha20-poly1305@openssh.com")
    )
    var b = Builder.encrypted()
    b.kdf = "scrypt"
    #expect(Self.failure(b.data()) == .unsupportedKDF("scrypt"))
    // Cipher and KDF must both be set or both be none.
    b = Builder()
    b.kdf = "bcrypt"
    #expect(Self.failure(b.data()) == .malformed)
    b = Builder()
    b.cipher = "aes256-ctr"
    #expect(Self.failure(b.data()) == .malformed)
  }

  /// KDF parameters are bounded before any key derivation runs.
  @Test
  func boundsKDFParameters() {
    var b = Builder.encrypted(rounds: UInt32(OpenSSHKeyImporter.maxRounds) + 1)
    #expect(
      Self.failure(b.data(), passphrase: Self.passphrase)
        == .workFactorTooHigh(OpenSSHKeyImporter.maxRounds + 1)
    )
    b = Builder.encrypted(rounds: 0)
    #expect(Self.failure(b.data()) == .malformed)
    b = Builder.encrypted(salt: [])
    #expect(Self.failure(b.data()) == .malformed)
    b = Builder.encrypted(
      salt: Array(repeating: 1, count: OpenSSHKeyImporter.maxSaltBytes + 1)
    )
    #expect(Self.failure(b.data()) == .malformed)
    b = Builder.encrypted()
    b.kdfOptions += [0]
    #expect(Self.failure(b.data()) == .malformed)
    // An encrypted section is padded to the AES block size.
    b = Builder.encrypted()
    b.blockSize = 8
    b.comment = Array("odd".utf8)
    #expect(Self.failure(b.data()) == .invalidPadding)
  }

  @Test
  func gcmTagIsRequiredAndAuthenticated() throws {
    let text = String(decoding: try Self.fixture("aes256-gcm"), as: UTF8.self)
    let lines = text.split(separator: "\n").map(String.init)
    var bytes = try #require(
      Data(base64Encoded: lines.dropFirst().dropLast().joined())
    )
    func armored(_ bytes: Data) -> Data {
      Data(
        "\(OpenSSHKeyImporter.beginArmor)\n\(bytes.base64EncodedString())\n"
          .appending(OpenSSHKeyImporter.endArmor + "\n").utf8
      )
    }
    bytes[bytes.count - 1] ^= 1
    #expect(
      Self.failure(armored(bytes), passphrase: Self.passphrase)
        == .wrongPassphrase
    )
    #expect(
      Self.failure(armored(bytes.dropLast()), passphrase: Self.passphrase)
        == .malformed
    )
  }

  @Test
  func keyDerivationStopsWhenCancelled() throws {
    let data = try Self.fixture("aes256")
    #expect(throws: OpenSSHImportError.cancelled) {
      try OpenSSHKeyImporter.decode(
        data,
        passphrase: Self.passphrase,
        isCancelled: { true }
      )
    }
  }

  @Test
  func refusesUnsupportedInputs() throws {
    #expect(
      Self.failure(try Self.fixture("rsa")) == .unsupportedAlgorithm("ssh-rsa")
    )
    #expect(Self.failure(try Self.fixture("plain.pub")) == .publicKeyOnly)
    #expect(Self.failure(try Self.fixture("plain-cert.pub")) == .certificate)
    #expect(Self.failure(Data("hello".utf8)) == .unrecognizedFormat)
    #expect(Self.failure(Data([0xFF, 0xFE])) == .unrecognizedFormat)
    let huge = Data(
      repeating: 0x41,
      count: OpenSSHKeyImporter.maxInputBytes + 1
    )
    #expect(Self.failure(huge) == .inputTooLarge)
  }

  // MARK: Synthetic containers

  /// Builds `openssh-key-v1` containers so each validation rule can be
  /// exercised on its own.
  struct Builder {
    var cipher = "none"
    var kdf = "none"
    var kdfOptions: [UInt8] = []
    var count: UInt32 = 1
    var key = Curve25519.Signing.PrivateKey()
    var publicKey: Curve25519.Signing.PublicKey?
    var check: (UInt32, UInt32) = (7, 7)
    var comment = Array("synthetic".utf8)
    var padding: [UInt8]?
    var trailing: [UInt8] = []
    var privateTail: [UInt8]?
    var blockSize = 8

    /// A bcrypt/aes256-ctr header around an (unencrypted) section: enough
    /// to exercise every check that runs before decryption.
    static func encrypted(
      salt: [UInt8] = Array(repeating: 7, count: 16),
      rounds: UInt32 = 2
    ) -> Builder {
      var b = Builder()
      b.cipher = "aes256-ctr"
      b.kdf = "bcrypt"
      b.kdfOptions = string(salt) + uint32(rounds)
      b.blockSize = 16
      return b
    }

    static func string(_ bytes: [UInt8]) -> [UInt8] {
      let n = UInt32(bytes.count)
      return [
        UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF),
        UInt8(n & 0xFF),
      ] + bytes
    }

    static func uint32(_ n: UInt32) -> [UInt8] {
      [
        UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF),
        UInt8(n & 0xFF),
      ]
    }

    func publicBlob(_ key: Curve25519.Signing.PublicKey) -> [UInt8] {
      Self.string(Array("ssh-ed25519".utf8))
        + Self.string(Array(key.rawRepresentation))
    }

    func section() -> [UInt8] {
      var body = Self.uint32(check.0) + Self.uint32(check.1)
      body += Self.string(Array("ssh-ed25519".utf8))
      body += Self.string(Array(key.publicKey.rawRepresentation))
      body += Self.string(
        privateTail
          ?? (Array(key.rawRepresentation)
            + Array(key.publicKey.rawRepresentation))
      )
      body += Self.string(comment)
      if let padding {
        body += padding
      } else {
        var i: UInt8 = 1
        while body.count % blockSize != 0 {
          body.append(i)
          i += 1
        }
      }
      return body
    }

    func data() -> Data {
      var bytes = Array("openssh-key-v1".utf8) + [0]
      bytes += Self.string(Array(cipher.utf8))
      bytes += Self.string(Array(kdf.utf8))
      bytes += Self.string(kdfOptions)
      bytes += Self.uint32(count)
      bytes += Self.string(publicBlob(publicKey ?? key.publicKey))
      bytes += Self.string(section())
      bytes += trailing
      let body = Data(bytes)
        .base64EncodedString(options: [
          .lineLength64Characters, .endLineWithLineFeed,
        ])
      return Data(
        "\(OpenSSHKeyImporter.beginArmor)\n\(body)\n\(OpenSSHKeyImporter.endArmor)\n"
          .utf8
      )
    }
  }

  @Test
  func syntheticBaselineImports() throws {
    let builder = Builder()
    let key = try Self.decode(builder.data()).get()
    #expect(
      key.secret.ed25519PrivateKey?.publicKey.rawRepresentation
        == builder.key.publicKey.rawRepresentation
    )
    #expect(key.comment == "synthetic")
  }

  @Test
  func validatesStructure() {
    var b = Builder()
    b.check = (1, 2)
    #expect(Self.failure(b.data()) == .malformed)

    b = Builder()
    b.padding = [1, 3]
    #expect(Self.failure(b.data()) == .invalidPadding)

    b = Builder()
    b.trailing = [0]
    #expect(Self.failure(b.data()) == .malformed)

    b = Builder()
    b.count = 2
    #expect(Self.failure(b.data()) == .unsupportedKeyCount(2))
    b.count = 0
    #expect(Self.failure(b.data()) == .malformed)

    b = Builder()
    b.publicKey = Curve25519.Signing.PrivateKey().publicKey
    #expect(Self.failure(b.data()) == .keyMismatch)

    b = Builder()
    b.privateTail =
      Array(b.key.rawRepresentation)
      + Array(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
    #expect(Self.failure(b.data()) == .keyMismatch)

    b = Builder()
    b.comment = Array(repeating: 0x61, count: 1025)
    #expect(Self.failure(b.data()) == .commentTooLarge)
  }

  @Test
  func noneKDFMustHaveEmptyOptions() {
    var b = Builder()
    b.kdfOptions = [0]
    #expect(Self.failure(b.data()) == .malformed)
  }

  @Test
  func oversizedLengthsFailBeforeAllocation() {
    var bytes = Array("openssh-key-v1".utf8) + [0]
    bytes += [0x7F, 0xFF, 0xFF, 0xFF]
    let text =
      "\(OpenSSHKeyImporter.beginArmor)\n\(Data(bytes).base64EncodedString())\n"
      + "\(OpenSSHKeyImporter.endArmor)\n"
    #expect(Self.failure(Data(text.utf8)) == .malformed)
  }

  @Test
  func cancelledImportDiscardsItsResult() async throws {
    let data = try Self.fixture("plain")
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await OpenSSHImportGate().decode(data)
    }
    await #expect(throws: OpenSSHImportError.cancelled) { try await task.value }
  }
}
