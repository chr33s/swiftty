import Crypto
import Foundation
import SSHClient
import SSHIdentity
import TerminalSurface

/// Why an SSH connection for a saved host could not be made. Messages
/// carry no secrets.
enum SSHAccessError: Error, Equatable, Sendable {
  /// The user dismissed a password or trust prompt.
  case cancelled
  /// The selected SSH identity cannot authenticate on this device. Fails
  /// closed: no key is generated and no password is asked for.
  case keyUnavailable(IdentityResolutionError)
  /// A version-1 key label that migration could not find; the host must
  /// be assigned an identity explicitly.
  case keyNeedsRepair
  /// A sign-in method written by a newer version of the app.
  case unsupportedAuthMethod
  /// The host presented a key different from the trusted one. Blocked
  /// until the user removes the old key deliberately (spec §5.1).
  case hostKeyChanged
  /// The user did not trust an unknown host key.
  case hostKeyRejected
  /// The presented (or already trusted) key is not one the confirmed
  /// pairing code named. Blocked before any credential was sent.
  case hostKeyMismatch
  case trustStoreUnavailable
  /// The server refused the credential. For key authentication this
  /// carries the `authorized_keys` line to install on the Mac.
  case authenticationFailed(publicKeyLine: String?)
  /// No SSH connection (network, DNS, timeout, refused).
  case unreachable

  var title: LocalizedStringResource {
    switch self {
    case .cancelled: .localized("Sign-in cancelled")
    case .keyUnavailable: .localized("Key unavailable")
    case .keyNeedsRepair: .localized("Choose a key")
    case .unsupportedAuthMethod: .localized("Sign-in method not supported")
    case .hostKeyChanged: .localized("Host key changed")
    case .hostKeyRejected: .localized("Host key not trusted")
    case .hostKeyMismatch: .localized("Host key doesn't match the code")
    case .trustStoreUnavailable: .localized("Trusted keys unavailable")
    case .authenticationFailed: .localized("Authentication failed")
    case .unreachable: .localized("Mac unreachable over SSH")
    }
  }

  /// Localized plain text, so the key line it can carry is never read as
  /// Markdown.
  var detail: String {
    switch self {
    case .cancelled:
      String(localized: "No credentials were sent.", bundle: #bundle)
    case .keyUnavailable(let reason):
      switch reason {
      case .unknownIdentity, .deleted:
        String(
          localized: """
            The SSH key selected for this host was deleted or is not on this \
            device. Edit the host to choose another key. No credentials were sent.
            """,
          bundle: #bundle
        )
      case .unavailableOnThisDevice:
        String(
          localized: """
            The selected key is stored only on another device. Choose a key \
            saved on this device. No credentials were sent.
            """,
          bundle: #bundle
        )
      case .awaitingKeyMaterial:
        String(
          localized: """
            The selected key is not available on this device. iCloud Keychain may \
            be off, delayed or unable to deliver it. No credentials were sent.
            """,
          bundle: #bundle
        )
      case .protectedDataUnavailable:
        String(
          localized:
            "Unlock this device to use the selected key. No credentials were sent.",
          bundle: #bundle
        )
      case .integrityConflict:
        String(
          localized: """
            The stored key does not match the selected key's fingerprint, so it \
            was not used. No credentials were sent.
            """,
          bundle: #bundle
        )
      case .unsupported:
        String(
          localized:
            "The Keychain could not be read. No credentials were sent.",
          bundle: #bundle
        )
      case .cancelled:
        String(localized: "No credentials were sent.", bundle: #bundle)
      }
    case .keyNeedsRepair:
      String(
        localized: """
          This host used a key that was not found during the update. Edit the host \
          to choose or import a key. No credentials were sent.
          """,
        bundle: #bundle
      )
    case .unsupportedAuthMethod:
      String(
        localized: """
          This host was saved by a newer version of Swiftty. Update the app or \
          edit the host. No credentials were sent.
          """,
        bundle: #bundle
      )
    case .hostKeyChanged:
      String(
        localized: """
          The key presented differs from the trusted key, so the connection was blocked. \
          Verify the Mac's key before removing the old one.
          """,
        bundle: #bundle
      )
    case .hostKeyRejected:
      String(
        localized:
          "The connection was closed before any credentials were sent.",
        bundle: #bundle
      )
    case .hostKeyMismatch:
      String(
        localized: """
          The Mac's SSH key is not one listed in the connection code, so the \
          connection was blocked before any credentials were sent. Show the \
          code again on the intended Mac.
          """,
        bundle: #bundle
      )
    case .trustStoreUnavailable:
      String(
        localized:
          "The list of trusted host keys could not be read or written.",
        bundle: #bundle
      )
    case .authenticationFailed(let line?):
      String(
        localized:
          "Add this public key to ~/.ssh/authorized_keys on the Mac:\n\(line)",
        bundle: #bundle
      )
    case .authenticationFailed(nil):
      String(localized: "The server rejected the credentials.", bundle: #bundle)
    case .unreachable:
      String(
        localized:
          "Check that the Mac is reachable and Remote Login is enabled.",
        bundle: #bundle
      )
    }
  }
}

/// SSH connection services shared by the terminal, the ordinary-SSH
/// fallback and SFTP: host-key trust with explicit prompts, credentials
/// from memory or the Keychain, and connection setup.
///
/// Secrets stay in memory: passwords in `RoamingAppModel`, keys in the
/// Keychain. Nothing here logs or persists them.
@MainActor
final class SSHAccess {
  private weak var app: RoamingAppModel?
  /// Records local trust decisions for opt-in trust sync.
  let trustStore: any HostTrustStore
  /// The underlying file store, written directly only by sync.
  let trustFile: FileHostTrustStore

  init(app: RoamingAppModel, trustStore: FileHostTrustStore? = nil) {
    self.app = app
    let file =
      trustStore ?? FileHostTrustStore(fileURL: RoamingStorage.knownHostsURL)
    self.trustFile = file
    self.trustStore = SyncedHostTrustStore(base: file, app: app)
  }

  /// `expectedHostKeys` are fingerprints from a confirmed pairing code;
  /// the server must present one of them.
  func configuration(
    for host: HostProfile,
    expectedHostKeys: Set<String>? = nil
  ) -> SSHClient.SSHClientConfiguration {
    SSHClient.SSHClientConfiguration(
      host: host.host,
      port: host.port,
      username: host.username,
      expectedHostKeyFingerprints: expectedHostKeys
    )
  }

  /// The credential for `host`: a password from memory or a prompt, or
  /// exactly the SSH identity the profile selects. Resolution is read-only:
  /// a missing key is an error, never a reason to create one.
  func credential(
    for host: HostProfile,
    retry: Bool = false,
    rejectedPassword: String? = nil
  ) async throws(SSHAccessError) -> SSHCredential {
    let host = try await migrated(host)
    return try await credential(
      for: host,
      reference: authenticationReference(for: host),
      retry: retry,
      rejectedPassword: rejectedPassword
    )
  }

  private func authenticationReference(
    for host: HostProfile
  ) -> SSHIdentityStore.AuthenticationReference? {
    guard case .key(let id) = host.auth else { return nil }
    return app?.identityStore.authenticationReference(id)
  }

  private func credential(
    for host: HostProfile,
    reference: SSHIdentityStore.AuthenticationReference?,
    retry: Bool,
    rejectedPassword: String?
  ) async throws(SSHAccessError) -> SSHCredential {
    switch host.auth {
    case .password:
      guard let app,
        let password = await app.password(
          for: host,
          retry: retry,
          rejectedPassword: rejectedPassword
        )
      else { throw .cancelled }
      return .password(password)
    case .key:
      guard let app, let reference else { throw .cancelled }
      do {
        return .ed25519(
          try await app.identityStore.resolve(reference).privateKey
        )
      } catch .cancelled { throw .cancelled } catch {
        throw .keyUnavailable(error)
      }
    case .legacyKey: throw .keyNeedsRepair
    case .unsupported: throw .unsupportedAuthMethod
    }
  }

  /// `host` as saved after any version-1 label migration in flight. Right
  /// after an upgrade, a connection waits for that pass rather than
  /// reporting a key that is about to migrate as needing repair.
  func migrated(_ host: HostProfile) async throws(SSHAccessError) -> HostProfile
  {
    guard !Task.isCancelled else { throw .cancelled }
    guard case .legacyKey = host.auth, let app,
      !app.connections.migration.completed || app.identityStore.isRecovering
    else { return host }
    let context = app.hostMutationContext(for: host)
    let wasCurrent = app.hostMutationIsCurrent(context)
    await app.identityStore.recover()
    guard !Task.isCancelled, context.accountGeneration == app.accountGeneration
    else { throw .cancelled }
    // Only a saved, unchanged legacy target may acquire its mapped identity.
    // Unsaved or stale drafts cannot adopt a record merely sharing their UUID.
    guard wasCurrent else { return host }
    guard let current = app.hostAfterLegacyMigration(context) else {
      throw .cancelled
    }
    return current
  }

  /// The bootstrap endpoint for `host`'s roaming client. A key host
  /// resolves its identity per bootstrap; only a password is fetched now.
  func bootstrapEndpoint(
    for host: HostProfile
  ) async throws(SSHAccessError) -> SSHEndpoint {
    let host = try await migrated(host)
    if let source = keySource(for: host) {
      return endpoint(for: host, source: source)
    }
    return endpoint(for: host, credential: try await credential(for: host))
  }

  /// A terminal's interactive probe and later bootstraps share one selection.
  /// Never recapture identity metadata after the probe has suspended.
  func bootstrapEndpoint(
    for selection: HostConnectionSelection
  ) async throws(SSHAccessError) -> SSHEndpoint {
    guard let app, app.hostMutationIsCurrent(selection.context),
      !Task.isCancelled
    else { throw .cancelled }
    if let source = keySource(reference: selection.identity) {
      return endpoint(for: selection.host, source: source)
    }
    let credential = try await credential(
      for: selection.host,
      reference: selection.identity,
      retry: false,
      rejectedPassword: nil
    )
    return endpoint(for: selection.host, source: .fixed(credential))
  }

  /// The `authorized_keys` line for a key-authenticated host, from public
  /// metadata only: displaying it never reads or creates a private key.
  func publicKeyLine(for host: HostProfile) -> String? {
    guard case .key(let id) = host.auth, let identity = app?.identity(id),
      !identity.isDeleted
    else { return nil }
    return identity.authorizedKeysLine
  }

  /// A connection after host-key verification (prompting for an unknown
  /// key) and authentication. A rejected password is asked for once more.
  /// With `expectedHostKeys` (a confirmed pairing code), a presented or
  /// already trusted key outside that set blocks before any credential.
  func connect(
    _ host: HostProfile,
    interactive: Bool = true,
    expectedHostKeys: Set<String>? = nil
  ) async throws(SSHAccessError) -> SSHConnection {
    let host = try await migrated(host)
    return try await authenticate(
      host,
      reference: authenticationReference(for: host),
      interactive: interactive,
      expectedHostKeys: expectedHostKeys
    )
  }

  /// Reconcile only verified legacy migration; all other changes require a
  /// new selection. No private key is retained by the returned value.
  func prepare(
    _ selection: HostConnectionSelection
  ) async throws(SSHAccessError) -> HostConnectionSelection {
    guard let app, selection.host.id == selection.context.id else {
      throw .cancelled
    }
    var selection = selection
    if !app.hostMutationIsCurrent(selection.context) {
      guard let migrated = app.hostAfterLegacyMigration(selection.context),
        migrated.auth != selection.host.auth
      else { throw .cancelled }
      selection = app.connectionSelection(for: migrated)
    }
    let host = try await migrated(selection.host)
    if host == selection.host { return selection }
    guard app.hostAfterLegacyMigration(selection.context) == host else {
      throw .cancelled
    }
    return app.connectionSelection(for: host)
  }

  /// The selection is prepared separately so a browser can retain successful
  /// migration even when authentication is subsequently cancelled.
  func connectPrepared(
    _ selection: HostConnectionSelection
  ) async throws(SSHAccessError) -> SSHConnection {
    guard let app, app.hostMutationIsCurrent(selection.context),
      !Task.isCancelled
    else { throw .cancelled }
    return try await authenticate(
      selection.host,
      reference: selection.identity,
      interactive: true,
      expectedHostKeys: nil
    )
  }

  private func authenticate(
    _ host: HostProfile,
    reference: SSHIdentityStore.AuthenticationReference?,
    interactive: Bool,
    expectedHostKeys: Set<String>?
  ) async throws(SSHAccessError) -> SSHConnection {
    if !interactive, case .password = host.auth { throw .cancelled }
    switch host.auth {
    case .legacyKey: throw .keyNeedsRepair
    case .unsupported: throw .unsupportedAuthMethod
    case .password, .key: break
    }
    try await settleTrust(
      for: host,
      interactive: interactive,
      expectedHostKeys: expectedHostKeys
    )
    var retry = false
    var rejectedPassword: String?
    while true {
      let credential = try await credential(
        for: host,
        reference: reference,
        retry: retry,
        rejectedPassword: rejectedPassword
      )
      do {
        return try await connect(
          host,
          credential: credential,
          interactive: interactive,
          expectedHostKeys: expectedHostKeys
        )
      } catch .authenticationFailed(let line) {
        guard case .password = host.auth, !retry else {
          throw .authenticationFailed(publicKeyLine: line)
        }
        retry = true
        if case let .password(password) = credential {
          rejectedPassword = password
        }
      }
    }
  }

  /// Settles an unknown host key before any credential is asked for, so
  /// the user never types a password for a server they have not trusted
  /// (spec §5.1). The probe connection offers no credential.
  private func settleTrust(
    for host: HostProfile,
    interactive: Bool,
    expectedHostKeys: Set<String>? = nil
  ) async throws(SSHAccessError) {
    guard let identity = configuration(for: host).hostIdentity else { return }
    let known: String?
    do { known = try await trustStore.trustedKey(for: identity) } catch {
      throw .trustStoreUnavailable
    }
    if let known {
      // A pairing code never replaces or overrides a trusted key: one that
      // the code does not name blocks without contacting the server.
      if let expectedHostKeys,
        !expectedHostKeys.contains(
          SSHPublicKeyFormat.fingerprint(openSSHPublicKey: known) ?? ""
        )
      {
        throw .hostKeyMismatch
      }
      // Without a code, a known key is checked during sign-in, before any
      // credential is offered. With one, the presented key is checked
      // against both the code and the store before a credential is even
      // asked for.
      guard expectedHostKeys != nil else { return }
    } else {
      guard interactive else { throw .hostKeyRejected }
    }
    do {
      _ = try await SSHConnection.verifyHostKey(
        configuration: configuration(
          for: host,
          expectedHostKeys: expectedHostKeys
        ),
        trustStore: trustStore,
        trustDecider: interactive
          ? trustDecider(for: host, matchesPairingCode: expectedHostKeys != nil)
          : RejectUnknownHostKeys() as any HostTrustDecider
      )
    } catch let error as SSHClientError {
      throw await map(error, host: host)
    } catch is CancellationError { throw .cancelled } catch {
      throw .unreachable
    }
  }

  /// Asks the user about an unknown key for `host`. With a pairing code,
  /// the verifier asks only after the key matched it.
  private func trustDecider(
    for host: HostProfile,
    matchesPairingCode: Bool = false
  ) -> ClosureHostTrustDecider {
    ClosureHostTrustDecider { [weak app] request in
      guard let app else { return .reject }
      let prompt = TrustPrompt(
        host: host,
        kind: .unknownKey,
        keyAlgorithm: request.keyType,
        fingerprint: request.fingerprint,
        matchesPairingCode: matchesPairingCode
      )
      return await app.requestTrust(prompt) == .trust
        ? .trustAndRemember : .reject
    }
  }

  /// Connects with `credential`, asking the user about an unknown key.
  func connect(
    _ host: HostProfile,
    credential: SSHCredential,
    interactive: Bool = true,
    expectedHostKeys: Set<String>? = nil
  ) async throws(SSHAccessError) -> SSHConnection {
    let decider: any HostTrustDecider =
      interactive
      ? trustDecider(for: host, matchesPairingCode: expectedHostKeys != nil)
      : RejectUnknownHostKeys()
    do {
      return try await SSHConnection.connect(
        configuration: configuration(
          for: host,
          expectedHostKeys: expectedHostKeys
        ),
        credential: credential,
        trustStore: trustStore,
        trustDecider: decider
      )
    } catch let error as SSHClientError {
      throw await map(
        error,
        host: host,
        interactive: interactive,
        credential: credential
      )
    } catch is CancellationError { throw .cancelled } catch {
      throw .unreachable
    }
  }

  /// The bootstrap endpoint for automatic roaming (re)connects. The host
  /// key must already be trusted: reconnects never prompt. A key-signed
  /// host resolves its identity again for every bootstrap, so the app does
  /// not hold the private key between them and a deleted or changed
  /// identity stops future attempts.
  func endpoint(for host: HostProfile, credential: SSHCredential) -> SSHEndpoint
  { endpoint(for: host, source: keySource(for: host) ?? .fixed(credential)) }

  /// A per-bootstrap identity lookup for a key host, else `nil`.
  private func keySource(for host: HostProfile) -> SSHEndpoint.CredentialSource?
  { keySource(reference: authenticationReference(for: host)) }

  private func keySource(
    reference: SSHIdentityStore.AuthenticationReference?
  ) -> SSHEndpoint.CredentialSource? {
    guard let reference, let store = app?.identityStore else { return nil }
    return .resolved { @Sendable in
      do throws(IdentityResolutionError) {
        return .ed25519(try await store.resolve(reference).privateKey)
      } catch { throw SSHAccessError.keyUnavailable(error) }
    }
  }

  private func endpoint(
    for host: HostProfile,
    source: SSHEndpoint.CredentialSource
  ) -> SSHEndpoint {
    SSHEndpoint(
      configuration: configuration(for: host),
      credentialSource: source,
      trustStore: trustStore,
      trustDecider: RejectUnknownHostKeys()
    )
  }

  private func map(
    _ error: SSHClientError,
    host: HostProfile,
    interactive: Bool = true,
    credential: SSHCredential? = nil
  ) async -> SSHAccessError {
    switch error {
    case let .hostKeyChanged(_, _, presented):
      // Shown, never accepted: a changed key always blocks.
      if interactive, let app {
        let prompt = TrustPrompt(
          host: host,
          kind: .changedKey,
          keyAlgorithm: "Presented key",
          fingerprint: presented
        )
        app.notifyChangedKey(prompt)
      }
      return .hostKeyChanged
    case .hostKeyRejected: return .hostKeyRejected
    case .hostKeyMismatch: return .hostKeyMismatch
    case .trustStoreUnavailable: return .trustStoreUnavailable
    case .authenticationFailed:
      if let credential, case let .password(password) = credential {
        app?.forgetRejectedPassword(password, for: host)
      }
      return .authenticationFailed(publicKeyLine: publicKeyLine(for: host))
    default: return .unreachable
    }
  }
}
