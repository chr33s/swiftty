import Crypto
import Foundation
import SSHClient
import SSHIdentity

/// Keychain wiring from build configuration (spec.ssh-identity.md §10).
/// `SwifttyKeychainAccessGroup` in Info.plist carries the expanded
/// `$(AppIdentifierPrefix)dev.chr33s.swiftty` group; an unexpanded or
/// missing value (unsigned SwiftPM hosts) uses the default group.
package enum IdentityKeychainConfiguration {
  package static var accessGroup: String? {
    guard
      let group = Bundle.main.object(
        forInfoDictionaryKey: "SwifttyKeychainAccessGroup"
      ) as? String, !group.isEmpty, !group.hasPrefix("."), !group.contains("$(")
    else { return nil }
    return group
  }

  package static func secretStore() -> any IdentitySecretStore {
    if UITesting.storageDirectory != nil {
      return InMemoryIdentitySecretStore()
    }
    return KeychainIdentitySecretStore(accessGroup: accessGroup)
  }

  package static func savedPasswordStore() -> any SavedPasswordStore {
    if UITesting.storageDirectory != nil {
      return InMemorySavedPasswordStore()
    }
    return KeychainSavedPasswordStore(accessGroup: accessGroup)
  }

  package static func legacyKeySource() -> any LegacyKeySource {
    if UITesting.storageDirectory != nil { return InMemoryLegacyKeySource() }
    return KeychainLegacyKeySource()
  }
}

/// Why an identity operation did not complete. Messages carry no secrets.
public enum IdentityOperationError: Error, Hashable, Sendable {
  case invalidName
  case tooManyIdentities
  case cancelled
  /// The connection snapshot could not be written.
  case storeUnavailable
  case keychain(IdentitySecretError)
  case integrityConflict
  case importFailed(OpenSSHImportError)
  case notFound
  /// iCloud Keychain identities need a verified current iCloud account.
  case accountRequired
  case accountVerificationUnavailable
  case keyNotAvailableInCurrentAccount
  case accountChanged
  case unavailable(IdentityResolutionError)
  /// The supplied key is not the one this identity names.
  case publicKeyMismatch
  /// Saved, but not yet readable to verify; finished automatically later.
  case pendingVerification
  /// An unrecognized iCloud Keychain item, which may belong to another
  /// device: restore it rather than delete it.
  case syncedOrphan
  /// The algorithm cannot use the requested storage, for example an
  /// imported key in the Secure Enclave.
  case unsupportedKeyType
  case secureEnclave(SecureEnclaveKeyError)

  public var message: String {
    switch self {
    case .unsupportedKeyType:
      "Only new P-256 keys can be kept in the Secure Enclave."
    case .secureEnclave(.unavailable):
      "This device has no Secure Enclave. No key was saved."
    case .secureEnclave:
      "The Secure Enclave could not create a key. No key was saved."
    case .invalidName: "Enter a name of up to 64 characters."
    case .tooManyIdentities:
      "You can save up to \(ConnectionStore.maxIdentities) keys."
    case .cancelled: "Cancelled. Any unused key will be removed automatically."
    case .storeUnavailable: "Saved keys could not be written."
    case .keychain(.protectedDataUnavailable):
      "Unlock this device, then try again."
    case .keychain(.missingEntitlement):
      "This build cannot use the Keychain. No key was saved."
    case .keychain: "The Keychain refused the operation."
    case .integrityConflict:
      "A different key is already stored for this identity. Nothing was replaced."
    case .importFailed(let error): error.message
    case .notFound: "The key no longer exists."
    case .accountRequired:
      "Sign in to iCloud to manage keys stored in iCloud Keychain."
    case .accountVerificationUnavailable:
      "This build cannot verify an iCloud account. You can save a device-only key."
    case .keyNotAvailableInCurrentAccount:
      "That key isn't available in the current account. Nothing was removed."
    case .accountChanged:
      "The account changed. Pending changes stay with the original account."
    case .unavailable(let error):
      (error.availability ?? .unsupported).summary + "."
    case .syncedOrphan:
      "This key syncs with iCloud Keychain and may be in use on your other "
        + "devices. Restore it, or turn on iCloud Sync to see its details."
    case .pendingVerification:
      "The key was saved but could not be checked yet. It appears here once "
        + "this device is unlocked; don't create it again."
    case .publicKeyMismatch:
      "That key does not match this identity's fingerprint."
    }
  }
}

/// SSH identity lifecycle over the Keychain and the connection snapshot
/// (§5, §7). Every change follows a durable intent: record it, write the
/// Keychain item, read it back and verify, then publish metadata and
/// complete in one commit. There is no load-or-create operation, and login
/// resolution (`resolve`) never mutates anything.
@MainActor
public final class SSHIdentityStore {
  private weak var app: (any ConnectionOwner)?
  public let secrets: any IdentitySecretStore
  package let legacy: any LegacyKeySource
  /// Stable account identity from the configured account provider. Checking
  /// an account does not enable metadata sync or prove Keychain delivery.
  package var currentICloudAccount: (@MainActor () async -> String?)?

  package init(
    app: any ConnectionOwner,
    secrets: any IdentitySecretStore,
    legacy: any LegacyKeySource
  ) {
    self.app = app
    self.secrets = secrets
    self.legacy = legacy
  }

  private var snapshot: ConnectionSnapshot {
    app?.connections ?? ConnectionSnapshot()
  }

  private struct AccountContext: Equatable {
    let generation: Int
    let account: String?
  }

  package var accountGeneration: Int { app?.accountGeneration ?? 0 }
  private var activeIntents: Set<UUID> = []
  private var accountContext: AccountContext {
    AccountContext(
      generation: accountGeneration,
      account: snapshot.boundAccount
    )
  }

  /// Invalidates old results even when the user switches away and back.
  package func accountDidChange() { app?.invalidateAccountContext() }

  private func check(_ context: AccountContext) throws(IdentityOperationError) {
    guard context == accountContext else { throw .accountChanged }
  }

  private func captureKeychainAccount(
    _ context: AccountContext,
    for identity: SSHIdentityMetadata? = nil
  ) async throws(IdentityOperationError) -> String {
    guard let currentICloudAccount else {
      throw .accountVerificationUnavailable
    }
    let account = await currentICloudAccount()
    try check(context)
    guard !Task.isCancelled else { throw .cancelled }
    guard let account, !account.isEmpty else { throw .accountRequired }
    guard context.account == nil || context.account == account else {
      throw .accountChanged
    }
    if let identity, identity.storage == .iCloudKeychain,
      let owner = snapshot.scopes[
        ConnectionSnapshot.identityRecord(identity.id)
      ], owner != account
    {
      throw .accountChanged
    }
    return account
  }

  private func checkKeychainAccount(
    _ intent: IdentityIntent,
    context: AccountContext
  ) async throws(IdentityOperationError) {
    try check(context)
    guard intent.account == context.account else { throw .accountChanged }
    let expected =
      intent.keychainAccount
      ?? (intent.requiresKeychainAccount ? intent.account : nil)
    if let expected {
      guard context.account == nil || context.account == expected else {
        throw .accountChanged
      }
      guard let currentICloudAccount else {
        throw .accountVerificationUnavailable
      }
      let actual = await currentICloudAccount()
      try check(context)
      guard actual == expected else { throw .accountChanged }
    } else if intent.requiresKeychainAccount {
      // An old unbound intent has no evidence of its originating account.
      // Never infer that ownership from whichever account is signed in now.
      throw .accountRequired
    }
  }

  /// A persisted binding does not prove which account is signed in after
  /// relaunch. Offline/unknown accounts defer recovery without deleting keys.
  private func verified(_ context: AccountContext) async -> Bool {
    guard context == accountContext, !Task.isCancelled else { return false }
    if let account = context.account {
      guard let database = app?.cloudDatabase,
        (try? await database.accountID()) == account
      else { return false }
    }
    return context == accountContext && !Task.isCancelled
  }

  private func commit(
    _ mutate: (inout ConnectionSnapshot) throws(ConnectionStore.StoreError) ->
      Void
  ) throws(IdentityOperationError) {
    guard let app, app.commitConnections(mutate) else {
      throw .storeUnavailable
    }
  }

  // MARK: Resolution

  /// A non-secret identity selection retained by a deferred authentication.
  /// Renames may advance its revision; a different key, storage policy or
  /// account must never be substituted when the lookup eventually starts.
  package struct AuthenticationReference: Hashable, Sendable {
    package let id: UUID
    package let metadata: SSHIdentityMetadata?
    package let scope: String?
    package let generation: Int

    package init(
      id: UUID,
      metadata: SSHIdentityMetadata?,
      scope: String?,
      generation: Int
    ) {
      self.id = id
      self.metadata = metadata
      self.scope = scope
      self.generation = generation
    }

    package func hasSameIdentity(as other: Self) -> Bool {
      id == other.id && scope == other.scope && generation == other.generation
        && metadata?.publicKey == other.metadata?.publicKey
        && metadata?.storage == other.metadata?.storage
        && metadata?.isDeleted == other.metadata?.isDeleted
    }
  }

  package func authenticationReference(_ id: UUID) -> AuthenticationReference {
    AuthenticationReference(
      id: id,
      metadata: snapshot.identity(id),
      scope: snapshot.scopes[ConnectionSnapshot.identityRecord(id)],
      generation: accountGeneration
    )
  }

  package func resolve(
    _ reference: AuthenticationReference
  ) async throws(IdentityResolutionError) -> IdentitySecret {
    try validate(reference)
    // resolve(id) captures the current verified description before its read.
    // Once that authentication starts, later sync changes do not retarget it.
    return try await resolve(reference.id)
  }

  /// Check a retained action without reading or retaining private key material.
  package func validate(
    _ reference: AuthenticationReference
  ) throws(IdentityResolutionError) {
    guard reference.generation == accountGeneration,
      reference.scope
        == snapshot.scopes[ConnectionSnapshot.identityRecord(reference.id)],
      let reviewed = reference.metadata,
      let current = snapshot.identity(reference.id)
    else { throw .unknownIdentity }
    guard !reviewed.isDeleted, !current.isDeleted else { throw .deleted }
    guard reviewed.publicKey == current.publicKey,
      reviewed.storage == current.storage, current.isValid,
      snapshot.identityConflicts[reference.id] == nil
    else { throw .integrityConflict }
    guard snapshot.isVisible(ConnectionSnapshot.identityRecord(reference.id))
    else { throw .unknownIdentity }
  }

  /// Exactly the selected identity, verified, for one authentication.
  public func resolve(
    _ id: UUID
  ) async throws(IdentityResolutionError) -> IdentitySecret {
    // Another iCloud account's identities are quarantined, not usable.
    guard snapshot.isVisible(ConnectionSnapshot.identityRecord(id)) else {
      throw .unknownIdentity
    }
    if snapshot.identityConflicts[id] != nil { throw .integrityConflict }
    return try await IdentityResolver(secrets: secrets)
      .resolve(snapshot.identity(id))
  }

  public func availability(_ id: UUID) async -> IdentityAvailability {
    guard let metadata = snapshot.identity(id) else { return .unsupported }
    if snapshot.identityConflicts[id] != nil { return .integrityConflict }
    return await IdentityResolver(secrets: secrets).availability(of: metadata)
  }

  // MARK: Creation

  /// Generates and saves a new identity. The identity appears in pickers
  /// only after its key is stored and verified. A `.secureEnclave` policy
  /// makes a device-bound P-256 key inside the Secure Enclave; with
  /// `requireUserPresence` each use asks for Face ID, Touch ID or the
  /// passcode (spec.ssh-identity.md §13.2).
  public func generate(
    name: String,
    algorithm: SSHKeyAlgorithm = .ed25519,
    policy: IdentityStoragePolicy,
    requireUserPresence: Bool = true
  ) async throws(IdentityOperationError) -> SSHIdentityMetadata {
    let secret: IdentitySecret
    if policy == .secureEnclave {
      guard algorithm == .ecdsaP256 else { throw .unsupportedKeyType }
      do {
        secret = try SecureEnclaveKeys.generate(
          requireUserPresence: requireUserPresence
        )
      } catch { throw .secureEnclave(error) }
    } else {
      secret = IdentitySecret(key: .generate(algorithm))
    }
    return try await create(
      secret,
      name: name,
      policy: policy,
      kind: .generate
    )
  }

  /// Imports an OpenSSH Ed25519 key after the user confirmed its
  /// fingerprint (see `inspect`). `passphrase` opens an encrypted key and is
  /// never stored (spec.ssh-identity.md §6.4).
  public func importKey(
    _ data: Data,
    passphrase: String? = nil,
    name: String,
    policy: IdentityStoragePolicy
  ) async throws(IdentityOperationError) -> SSHIdentityMetadata {
    // Imported software keys cannot be moved into the Secure Enclave.
    guard policy != .secureEnclave else { throw .unsupportedKeyType }
    let context = accountContext
    let keychainAccount =
      policy == .iCloudKeychain
      ? try await captureKeychainAccount(context) : nil
    let key: ImportedOpenSSHKey
    do {
      key = try await OpenSSHImportGate.shared.decode(
        data,
        passphrase: passphrase
      )
    } catch .cancelled { throw .cancelled } catch { throw .importFailed(error) }
    try check(context)
    return try await create(
      key.secret,
      name: name,
      policy: policy,
      kind: .importKey,
      keychainAccount: keychainAccount
    )
  }

  /// Parses `data` for confirmation without saving anything. An encrypted
  /// key needs no passphrase here.
  public func inspect(
    _ data: Data
  ) async throws(IdentityOperationError) -> OpenSSHKeyInspection {
    do { return try await OpenSSHImportGate.shared.inspect(data) } catch {
      throw .importFailed(error)
    }
  }

  /// Identities already holding this public key: duplicate detection only,
  /// never a substitute at login.
  public func identities(
    withFingerprint fingerprint: String
  ) -> [SSHIdentityMetadata] {
    snapshot.visibleIdentities.filter { $0.fingerprint == fingerprint }
  }

  private func create(
    _ secret: IdentitySecret,
    name: String,
    policy: IdentityStoragePolicy,
    kind: IdentityIntent.Kind,
    reassign: [UUID] = [],
    id: UUID = UUID(),
    keychainAccount: String? = nil
  ) async throws(IdentityOperationError) -> SSHIdentityMetadata {
    let context = accountContext
    guard SSHIdentityMetadata.isValidName(name) else { throw .invalidName }
    guard
      snapshot.identity(id) != nil
        || snapshot.visibleIdentities.count < ConnectionStore.maxIdentities
    else { throw .tooManyIdentities }
    var keychainAccount = keychainAccount
    if policy == .iCloudKeychain, keychainAccount == nil {
      keychainAccount = try await captureKeychainAccount(context)
    }
    try check(context)
    guard !Task.isCancelled else { throw .cancelled }
    let metadata = SSHIdentityMetadata(
      id: id,
      name: name,
      publicKeyLine: secret.publicKeyLine,
      storage: policy,
      revision: LogicalRevision(counter: 0, deviceID: snapshot.deviceID)
    )
    try validateDestination(id, publicKey: metadata.publicKey, policy: policy)
    let intent = IdentityIntent(
      id: UUID(),
      identityID: id,
      kind: kind,
      policy: policy,
      name: name,
      publicKey: metadata.publicKey,
      reassign: reassign,
      stage: .recorded,
      createdAt: .now,
      account: context.account,
      keychainAccount: keychainAccount
    )
    try await checkKeychainAccount(intent, context: context)
    guard !Task.isCancelled else { throw .cancelled }
    try commit { $0.intents.append(intent) }
    activeIntents.insert(intent.id)
    defer { activeIntents.remove(intent.id) }
    // Create without overwriting. A duplicate may be an earlier attempt's
    // item; verification decides.
    var createdSecret = false
    do {
      try await secrets.add(secret, id: id, policy: policy)
      createdSecret = true
    } catch .duplicate {} catch {
      try await handleCancellation(of: intent, createdSecret: false)
      try check(context)
      // Nothing was written: forget the intent.
      try? commit { $0.intents.removeAll { $0.id == intent.id } }
      throw .keychain(error)
    }
    try await handleCancellation(of: intent, createdSecret: createdSecret)
    try check(context)
    do { try await verify(intent) } catch .integrityConflict {
      // A different key now holds this UUID. Cancellation must not delete it.
      try await handleCancellation(of: intent, createdSecret: false)
      try check(context)
      // A different key holds this UUID: never replaced or published.
      try? commit { $0.intents.removeAll { $0.id == intent.id } }
      throw .integrityConflict
    } catch .accountChanged {
      try await handleCancellation(of: intent, createdSecret: createdSecret)
      throw .accountChanged
    } catch {
      try await handleCancellation(of: intent, createdSecret: createdSecret)
      try check(context)
      // Written but not yet verifiable (for example the device locked):
      // the intent stays, and `recover()` verifies and publishes it.
      throw .pendingVerification
    }
    try await handleCancellation(of: intent, createdSecret: createdSecret)
    try check(context)
    try publish(intent)
    guard let published = snapshot.identity(id) else { throw .storeUnavailable }
    return published
  }

  /// Persist cancellation before trying cleanup. A failed deletion must
  /// resume as a deletion, never publish the cancelled creation on relaunch.
  /// This updates only the original intent even if its account is now hidden;
  /// the actual deletion still requires that account's verified context.
  private func handleCancellation(
    of intent: IdentityIntent,
    createdSecret: Bool
  ) async throws(IdentityOperationError) {
    guard Task.isCancelled else { return }
    guard createdSecret else {
      try commit { $0.intents.removeAll { $0.id == intent.id } }
      throw .cancelled
    }
    var cleanup = IdentityIntent(
      id: intent.id,
      identityID: intent.identityID,
      kind: .deleteSecret,
      policy: intent.policy,
      name: intent.name,
      publicKey: intent.publicKey,
      reassign: [],
      stage: .recorded,
      createdAt: intent.createdAt,
      account: intent.account,
      keychainAccount: intent.keychainAccount
    )
    try commit { snapshot in
      guard
        let index = snapshot.intents.firstIndex(where: { $0.id == intent.id })
      else { return }
      // Enabling sync may have explicitly adopted this local intent while
      // its operation was suspended. Preserve that latest binding.
      cleanup.account = snapshot.intents[index].account
      snapshot.intents[index] = cleanup
    }
    // Cleanup gets its own cancellation state, while the durable intent
    // survives a locked Keychain, account switch, or process exit.
    await Task { await finishDeletion(cleanup) }.value
    throw .cancelled
  }

  private func verify(
    _ intent: IdentityIntent
  ) async throws(IdentityOperationError) {
    let context = accountContext
    try await checkKeychainAccount(intent, context: context)
    let stored: IdentitySecret
    do {
      stored = try await secrets.read(
        id: intent.identityID,
        policy: intent.policy
      )
    } catch { throw .keychain(error) }
    try await checkKeychainAccount(intent, context: context)
    guard
      stored.publicKeyLine
        == intent.publicKey
    else { throw .integrityConflict }
  }

  /// Publishes verified metadata and completes the intent in one commit.
  private func publish(
    _ intent: IdentityIntent,
    completingAccountReview: Bool = false
  ) throws(IdentityOperationError) {
    guard intent.account == snapshot.boundAccount else { throw .accountChanged }
    try validateDestination(
      intent.identityID,
      publicKey: intent.publicKey,
      policy: intent.policy
    )
    guard SSHKeyAlgorithm(canonicalPublicKeyLine: intent.publicKey) != nil
    else { throw .integrityConflict }
    try commit { snapshot in
      if intent.policy == .iCloudKeychain, let owner = intent.keychainAccount {
        snapshot.unverifiedKeychainIdentities?.remove(intent.identityID)
        snapshot.selectKeychainAccount(owner)
        snapshot.scopes[ConnectionSnapshot.identityRecord(intent.identityID)] =
          owner
      }
      snapshot.insertIdentity(
        SSHIdentityMetadata(
          id: intent.identityID,
          name: intent.name,
          publicKeyLine: intent.publicKey,
          storage: intent.policy,
          createdAt: intent.createdAt,
          revision: LogicalRevision(counter: 0, deviceID: snapshot.deviceID)
        )
      )
      Self.reassign(intent.reassign, to: intent.identityID, in: &snapshot)
      switch intent.kind {
      case .withdraw(let source):
        snapshot.tombstoneIdentity(source)
        if let old = snapshot.identity(source) {
          snapshot.intents.append(
            Self.deletion(
              of: old,
              account: intent.account,
              keychainAccount: intent.keychainAccount
            )
          )
        }
      case .migrateLegacy(let label):
        for host in snapshot.visibleHosts
        where host.auth == .legacyKey(label: label) {
          var moved = host
          moved.auth = .key(identityID: intent.identityID)
          snapshot.upsertHost(moved)
        }
        if !snapshot.migration.pendingCleanup.contains(label) {
          snapshot.migration.pendingCleanup.append(label)
        }
      default: break
      }
      snapshot.intents.removeAll {
        $0.id == intent.id
          || (completingAccountReview && $0.identityID == intent.identityID
            && $0.canRestoreAfterAccountReview)
      }
    }
  }

  private static func reassign(
    _ hosts: [UUID],
    to id: UUID,
    in snapshot: inout ConnectionSnapshot
  ) {
    for hostID in hosts
    where snapshot.isVisible(ConnectionSnapshot.hostRecord(hostID)) {
      guard var host = snapshot.hosts.first(where: { $0.id == hostID }) else {
        continue
      }
      host.auth = .key(identityID: id)
      snapshot.upsertHost(host)
    }
  }

  private static func deletion(
    of identity: SSHIdentityMetadata,
    account: String?,
    keychainAccount: String?
  ) -> IdentityIntent {
    IdentityIntent(
      id: UUID(),
      identityID: identity.id,
      kind: .deleteSecret,
      policy: identity.storage,
      name: identity.name,
      publicKey: identity.publicKey,
      reassign: [],
      stage: .recorded,
      createdAt: .now,
      account: account,
      keychainAccount: keychainAccount
    )
  }

  // MARK: Changes

  /// Restores an older approved description only after an explicit decision
  /// for the current account and a fresh fingerprint check. Never writes keys.
  package func restoreAccountReviewedIdentity(
    _ id: UUID
  ) async throws(IdentityOperationError) {
    let context = accountContext
    guard snapshot.unverifiedKeychainIdentities?.contains(id) == true,
      let original = snapshot.identity(id), !original.isDeleted
    else { throw .notFound }
    let account = try await captureKeychainAccount(context)
    let intent = IdentityIntent(
      id: UUID(),
      identityID: id,
      kind: .importKey,
      policy: .iCloudKeychain,
      name: original.name,
      publicKey: original.publicKey,
      reassign: [],
      stage: .verified,
      createdAt: original.createdAt,
      account: context.account,
      keychainAccount: account
    )
    try await verify(intent)
    try check(context)
    guard !Task.isCancelled else { throw .cancelled }
    guard snapshot.unverifiedKeychainIdentities?.contains(id) == true,
      snapshot.identity(id) == original
    else { throw .integrityConflict }
    let name = ConnectionSnapshot.identityRecord(id)
    let cached = snapshot.accounts[account]?.cachedRecords?[name]
    if case .identity(let remote?, _)? = cached {
      guard !remote.isDeleted else { throw .notFound }
      guard remote.publicKey == original.publicKey,
        remote.storage == original.storage
      else { throw .integrityConflict }
    }
    try commit { snapshot in
      snapshot.unverifiedKeychainIdentities?.remove(id)
      snapshot.scopes[name] = account
      snapshot.accounts[account]?.cachedRecords?.removeValue(forKey: name)
      snapshot.selectKeychainAccount(account)
      if case .identity(let remote?, _)? = cached {
        ConnectionSyncCoordinator.merge(
          remote,
          name: name,
          account: account,
          into: &snapshot
        )
      }
      if let identity = snapshot.identity(id) {
        snapshot.enqueue(name, revision: identity.revision)
      }
    }
  }

  public func rename(_ id: UUID, to name: String) throws(IdentityOperationError)
  {
    guard SSHIdentityMetadata.isValidName(name) else { throw .invalidName }
    guard snapshot.isVisible(ConnectionSnapshot.identityRecord(id)),
      snapshot.identity(id)?.isDeleted == false
    else { throw .notFound }
    try commit { $0.renameIdentity(id, to: name) }
  }

  /// Deletes an identity: publishes its tombstone, then deletes exactly its
  /// own Keychain item (an iCloud item's deletion propagates to the user's
  /// other devices). Referencing hosts keep their now-unresolved reference;
  /// the server's `authorized_keys` is untouched.
  public func delete(_ id: UUID) async throws(IdentityOperationError) {
    let context = accountContext
    guard snapshot.isVisible(ConnectionSnapshot.identityRecord(id)),
      let identity = snapshot.identity(id), !identity.isDeleted
    else { throw .notFound }
    let keychainAccount =
      identity.storage == .iCloudKeychain
      ? try await captureKeychainAccount(context, for: identity) : nil
    try check(context)
    guard snapshot.identity(id)?.publicKey == identity.publicKey,
      snapshot.identity(id)?.isDeleted == false
    else { throw .notFound }
    let intent = Self.deletion(
      of: identity,
      account: context.account,
      keychainAccount: keychainAccount
    )
    try commit { snapshot in
      if let keychainAccount {
        snapshot.scopes[ConnectionSnapshot.identityRecord(id)] = keychainAccount
      }
      snapshot.tombstoneIdentity(id)
      snapshot.intents.append(intent)
    }
    await finishDeletion(intent)
  }

  private func finishDeletion(_ intent: IdentityIntent) async {
    guard intent.account == snapshot.boundAccount, !Task.isCancelled else {
      return
    }
    let context = accountContext
    guard await verified(context) else { return }
    do {
      // A retry must not delete different key material that now holds this
      // UUID. An already absent item needs only the idempotent deletion.
      do { try await verify(intent) } catch .keychain(.notFound) {}
      try await checkKeychainAccount(intent, context: context)
      try await secrets.delete(id: intent.identityID, policy: intent.policy)
      try await checkKeychainAccount(intent, context: context)
      try? commit { $0.intents.removeAll { $0.id == intent.id } }
    } catch {
      // Kept for retry on the next launch or recovery pass.
    }
  }

  /// Reads and verifies the matching key without authorizing a deletion.
  package func prepareLegacyDeletion(
    _ id: UUID
  ) async throws(IdentityOperationError) -> LegacyKeyDeletionReview {
    let context = accountContext
    guard let original = snapshot.intents.first(where: { $0.id == id }),
      original.requiresDeletionReview
    else { throw .notFound }
    guard
      !snapshot.visibleIdentities.contains(where: {
        $0.id == original.identityID
      })
    else { throw .integrityConflict }
    let account = try await captureKeychainAccount(context)
    var checked = original
    checked.account = context.account
    checked.keychainAccount = account
    do { try await verify(checked) } catch .keychain(.notFound) {
      throw .keyNotAvailableInCurrentAccount
    }
    try check(context)
    guard !Task.isCancelled else { throw .cancelled }
    guard snapshot.intents.contains(original),
      let fingerprint = SSHPublicKeyFormat.fingerprint(
        openSSHPublicKey: original.publicKey
      )
    else { throw .integrityConflict }
    return LegacyKeyDeletionReview(
      intent: original,
      account: account,
      generation: context.generation,
      metadataAccount: context.account,
      fingerprint: fingerprint
    )
  }

  /// Explicitly authorizes removal in the reviewed account. False means the
  /// decision is durable but the removal is still pending; recovery retries it.
  package func confirmLegacyDeletion(
    _ review: LegacyKeyDeletionReview
  ) async throws(IdentityOperationError) -> Bool {
    let context = AccountContext(
      generation: review.generation,
      account: review.metadataAccount
    )
    func checkedIntent() throws(IdentityOperationError) -> IdentityIntent {
      try check(context)
      guard snapshot.intents.contains(review.intent),
        review.intent.requiresDeletionReview,
        !snapshot.visibleIdentities.contains(where: {
          $0.id == review.intent.identityID
        })
      else { throw .integrityConflict }
      var intent = review.intent
      intent.account = context.account
      intent.keychainAccount = review.account
      return intent
    }
    let intent = try checkedIntent()
    do { try await verify(intent) } catch .keychain(.notFound) {
      throw .keyNotAvailableInCurrentAccount
    }
    _ = try checkedIntent()
    guard !Task.isCancelled else { throw .cancelled }
    try commit { snapshot in
      guard
        let index = snapshot.intents.firstIndex(where: { $0.id == intent.id })
      else { return }
      snapshot.intents[index] = intent
    }
    await finishDeletion(intent)
    return !snapshot.intents.contains(where: { $0.id == intent.id })
  }

  /// **Create an iCloud copy**: a new UUID for the same key material in
  /// iCloud Keychain, after explicit consent. `reassign` hosts move to it
  /// in the same commit; the original stays until deleted.
  public func createICloudCopy(
    of id: UUID,
    name: String,
    reassign: [UUID]
  ) async throws(IdentityOperationError) -> SSHIdentityMetadata {
    let context = accountContext
    let keychainAccount = try await captureKeychainAccount(
      context,
      for: snapshot.identity(id)
    )
    let secret = try await sourceSecret(id)
    try check(context)
    return try await create(
      secret,
      name: name,
      policy: .iCloudKeychain,
      kind: .iCloudCopy(source: id),
      reassign: reassign,
      keychainAccount: keychainAccount
    )
  }

  /// **Withdraw from iCloud and keep locally**: a verified device-only copy
  /// first, then host reassignment, then the old identity's tombstone and
  /// exact synchronizable-item deletion, retried until done. Not a remote
  /// revocation, and no proof that every prior copy was erased.
  public func withdrawFromICloud(
    _ id: UUID,
    name: String,
    reassign: [UUID]
  ) async throws(IdentityOperationError) -> SSHIdentityMetadata {
    let context = accountContext
    guard snapshot.isVisible(ConnectionSnapshot.identityRecord(id)),
      snapshot.identity(id)?.storage == .iCloudKeychain
    else { throw .notFound }
    let keychainAccount = try await captureKeychainAccount(
      context,
      for: snapshot.identity(id)
    )
    let secret = try await sourceSecret(id)
    try check(context)
    let copy = try await create(
      secret,
      name: name,
      policy: .deviceOnly,
      kind: .withdraw(source: id),
      reassign: reassign,
      keychainAccount: keychainAccount
    )
    for intent in snapshot.intents
    where intent.kind == .deleteSecret && intent.identityID == id {
      await finishDeletion(intent)
    }
    return copy
  }

  private func sourceSecret(
    _ id: UUID
  ) async throws(IdentityOperationError) -> IdentitySecret {
    do { return try await resolve(id) } catch { throw .unavailable(error) }
  }

  /// Restores a missing key for an existing identity from an imported file
  /// whose public key exactly matches. The caller confirms the match first.
  public func repair(
    _ id: UUID,
    with data: Data,
    passphrase: String? = nil
  ) async throws(IdentityOperationError) {
    let context = accountContext
    guard snapshot.isVisible(ConnectionSnapshot.identityRecord(id)),
      let identity = snapshot.identity(id), !identity.isDeleted
    else { throw .notFound }
    let keychainAccount =
      identity.storage == .iCloudKeychain
      ? try await captureKeychainAccount(context, for: identity) : nil
    let key: ImportedOpenSSHKey
    do {
      key = try await OpenSSHImportGate.shared.decode(
        data,
        passphrase: passphrase
      )
    } catch { throw .importFailed(error) }
    try check(context)
    guard
      key.secret.publicKeyLine
        == identity.publicKey
    else { throw .publicKeyMismatch }
    let intent = IdentityIntent(
      id: UUID(),
      identityID: id,
      kind: .importKey,
      policy: identity.storage,
      name: identity.name,
      publicKey: identity.publicKey,
      reassign: [],
      stage: .secretWritten,
      createdAt: .now,
      account: context.account,
      keychainAccount: keychainAccount
    )
    try await checkKeychainAccount(intent, context: context)
    guard !Task.isCancelled else { throw .cancelled }
    do {
      try await secrets.add(key.secret, id: id, policy: identity.storage)
    } catch .duplicate {} catch { throw .keychain(error) }
    try await verify(intent)
    try check(context)
  }

  // MARK: Orphans

  /// Unrecognized items, including old interrupted creations whose account
  /// ownership was never recorded. Restoring one requires explicit approval.
  public func orphans() async -> [(id: UUID, policy: IdentityStoragePolicy)] {
    let context = accountContext
    var found: [(UUID, IdentityStoragePolicy)] = []
    for policy in IdentityStoragePolicy.allCases {
      guard let ids = try? await secrets.storedIdentities(policy: policy) else {
        continue
      }
      guard context == accountContext else { return [] }
      for id in ids.subtracting(knownIdentityIDs)
        .sorted(by: { $0.uuidString < $1.uuidString })
      { found.append((id, policy)) }
    }
    return found
  }

  private var knownIdentityIDs: Set<UUID> {
    Set((snapshot.identities + snapshot.cachedIdentities).map(\.id))
      .union(
        snapshot.intents.filter { !$0.canRestoreAfterAccountReview }
          .map(\.identityID)
      )
      .union(snapshot.identityConflicts.keys)
  }

  /// Publishes an orphaned item under its own UUID after user approval.
  public func adoptOrphan(
    _ id: UUID,
    policy: IdentityStoragePolicy,
    name: String
  ) async throws(IdentityOperationError) {
    let context = accountContext
    guard SSHIdentityMetadata.isValidName(name) else { throw .invalidName }
    guard !knownIdentityIDs.contains(id) else { throw .integrityConflict }
    let keychainAccount =
      policy == .iCloudKeychain
      ? try await captureKeychainAccount(context) : nil
    let secret: IdentitySecret
    do { secret = try await secrets.read(id: id, policy: policy) } catch {
      throw .keychain(error)
    }
    try check(context)
    guard !knownIdentityIDs.contains(id) else { throw .integrityConflict }
    let intent = IdentityIntent(
      id: UUID(),
      identityID: id,
      kind: .importKey,
      policy: policy,
      name: name,
      publicKey: secret.publicKeyLine,
      reassign: [],
      stage: .verified,
      createdAt: .now,
      account: context.account,
      keychainAccount: keychainAccount
    )
    try await checkKeychainAccount(intent, context: context)
    guard !Task.isCancelled else { throw .cancelled }
    guard !knownIdentityIDs.contains(id),
      snapshot.intents
        .filter({ $0.identityID == id && $0.canRestoreAfterAccountReview })
        .allSatisfy({ $0.policy == policy && $0.publicKey == intent.publicKey })
    else { throw .integrityConflict }
    try publish(intent, completingAccountReview: true)
  }

  public func deleteOrphan(
    _ id: UUID,
    policy: IdentityStoragePolicy
  ) async throws(IdentityOperationError) {
    let context = accountContext
    guard !knownIdentityIDs.contains(id) else { throw .integrityConflict }
    // A synchronizable item without metadata here may be another device's
    // key in transit; deleting it would remove it everywhere.
    guard policy.isDeviceBound else { throw .syncedOrphan }
    do { try await secrets.delete(id: id, policy: policy) } catch {
      throw .keychain(error)
    }
    try check(context)
    try commit { snapshot in
      snapshot.intents.removeAll {
        $0.identityID == id && $0.canRestoreAfterAccountReview
      }
    }
  }

  // MARK: Recovery and migration

  /// A reused UUID must still name the approved, live identity. In particular,
  /// a concurrent tombstone or same-UUID delivery cannot be ignored by insert.
  private func validateDestination(
    _ id: UUID,
    publicKey: String,
    policy: IdentityStoragePolicy
  ) throws(IdentityOperationError) {
    guard snapshot.isVisible(ConnectionSnapshot.identityRecord(id)) else {
      throw .accountChanged
    }
    guard snapshot.identityConflicts[id] == nil else {
      throw .integrityConflict
    }
    if let existing = snapshot.identity(id) {
      guard !existing.isDeleted, existing.publicKey == publicKey,
        existing.storage == policy
      else { throw .integrityConflict }
    } else if snapshot.cachedIdentities.contains(where: { $0.id == id }) {
      throw .accountChanged
    }
  }

  private func canReuseMigratedIdentity(_ identity: SSHIdentityMetadata) -> Bool
  {
    identity.storage == .deviceOnly && !identity.isDeleted
      && snapshot.identity(identity.id) == identity
      && snapshot.identityConflicts[identity.id] == nil
      && snapshot.isVisible(ConnectionSnapshot.identityRecord(identity.id))
  }

  private var recovery: Task<Void, Never>?
  package var isRecovering: Bool { recovery != nil }

  /// Resumes interrupted intents and the version-1 label migration, joining
  /// a pass already in flight. Safe to run repeatedly: mappings, UUIDs and
  /// fingerprints are stable across reruns, and a temporarily locked
  /// Keychain defers rather than counting a key as missing.
  public func recover() async { await startRecovery().value }

  @discardableResult
  package func startRecovery() -> Task<Void, Never> {
    if let recovery { return recovery }
    let task = Task {
      await performRecovery()
      recovery = nil
    }
    recovery = task
    return task
  }

  private func performRecovery() async {
    let context = accountContext
    for intent in snapshot.intents {
      guard context == accountContext, !Task.isCancelled else { return }
      await resume(intent)
    }
    guard context == accountContext, !Task.isCancelled else { return }
    await migrateLegacyLabels()
    await cleanUpLegacyItems()
  }

  private func resume(_ intent: IdentityIntent) async {
    guard intent.account == snapshot.boundAccount,
      !activeIntents.contains(intent.id), !Task.isCancelled
    else { return }
    let context = accountContext
    activeIntents.insert(intent.id)
    defer { activeIntents.remove(intent.id) }
    switch intent.kind {
    case .deleteSecret: await finishDeletion(intent)
    case .generate, .importKey, .iCloudCopy, .withdraw, .migrateLegacy:
      guard await verified(context) else { return }
      do {
        try await verify(intent)
        try check(context)
        guard !Task.isCancelled else { return }
        try publish(intent)
        if case .withdraw(let source) = intent.kind {
          for pending in snapshot.intents
          where pending.kind == .deleteSecret && pending.identityID == source {
            await finishDeletion(pending)
          }
        }
      } catch .keychain(.notFound) {
        guard context == accountContext else { return }
        // The item was never written. Nothing was published, so the
        // intent is dropped: a generated or imported secret is gone, and a
        // copy, withdrawal or migration can be retried from its source.
        try? commit { $0.intents.removeAll { $0.id == intent.id } }
      } catch {
        // Locked, entitlement or store failures: keep for a later pass.
      }
    }
  }

  /// §9 steps 2–5, one label at a time.
  package func migrateLegacyLabels() async {
    let context = accountContext
    let labels = Set(
      snapshot.visibleHosts.compactMap {
        if case .legacyKey(let label) = $0.auth { return label }
        return nil
      }
    )
    .subtracting(snapshot.migration.unresolved)
    guard !snapshot.migration.completed || !labels.isEmpty else { return }
    var deferred = false
    for label in labels.sorted() {
      guard context == accountContext, !Task.isCancelled else { return }
      // A stable mapping, persisted before any Keychain write.
      if snapshot.migration.labelMap[label] == nil {
        guard (try? commit({ $0.migration.labelMap[label] = UUID() })) != nil
        else { return }
      }
      guard let id = snapshot.migration.labelMap[label] else { return }
      // Recovery owns an existing intent; do not start a second operation
      // under a different account or duplicate one whose Keychain is locked.
      if snapshot.intents.contains(where: { $0.identityID == id }) {
        deferred = true
        continue
      }
      if let identity = snapshot.identity(id) {
        guard canReuseMigratedIdentity(identity) else {
          deferred = true
          continue
        }
        let availability = await IdentityResolver(secrets: secrets)
          .availability(of: identity)
        guard context == accountContext else { return }
        guard canReuseMigratedIdentity(identity) else {
          deferred = true
          continue
        }
        if availability == .available {
          do {
            try commit { snapshot in
              for host in snapshot.visibleHosts
              where host.auth == .legacyKey(label: label) {
                var moved = host
                moved.auth = .key(identityID: id)
                snapshot.upsertHost(moved)
              }
            }
          } catch { deferred = true }
          continue
        }
        // The exact legacy key may repair a missing replacement. Locked or
        // mismatched material must remain deferred, never overwritten.
        if availability != .unavailableOnThisDevice {
          deferred = true
          continue
        }
      } else if !snapshot.isVisible(ConnectionSnapshot.identityRecord(id))
        || snapshot.cachedIdentities.contains(where: { $0.id == id })
      {
        deferred = true
        continue
      }
      let secret: IdentitySecret
      do { secret = try await legacy.read(label: label) } catch .notFound {
        guard context == accountContext else { return }
        if snapshot.identity(id) == nil {
          try? commit { $0.migration.unresolved.append(label) }
        } else {
          // A known replacement may be explicitly repaired later. Keep
          // checking that UUID instead of permanently excluding its label.
          deferred = true
        }
        continue
      } catch {
        deferred = true
        continue
      }
      guard context == accountContext, !Task.isCancelled else { return }
      let name = SSHIdentityMetadata.isValidName(label) ? label : "Migrated key"
      do {
        _ = try await create(
          secret,
          name: name,
          policy: .deviceOnly,
          kind: .migrateLegacy(label: label),
          id: id
        )
      } catch { deferred = true }
    }
    guard context == accountContext else { return }
    try? commit { $0.migration.completed = !deferred }
  }

  /// §9 step 6: legacy items go only after verified replacement and
  /// committed references.
  package func cleanUpLegacyItems() async {
    let context = accountContext
    for label in snapshot.migration.pendingCleanup {
      guard context == accountContext, !Task.isCancelled else { return }
      guard let id = snapshot.migration.labelMap[label],
        let identity = snapshot.identity(id),
        canCleanUpLegacy(label, identity: identity),
        await IdentityResolver(secrets: secrets).availability(of: identity)
          == .available, context == accountContext,
        canCleanUpLegacy(label, identity: identity)
      else { continue }
      do {
        let original: IdentitySecret?
        do { original = try await legacy.read(label: label) } catch .notFound {
          original = nil
        }
        guard context == accountContext,
          canCleanUpLegacy(label, identity: identity)
        else { continue }
        if let original {
          guard
            original.publicKeyLine
              == identity.publicKey
          else { continue }
          try await legacy.delete(label: label)
        }
        guard context == accountContext else { return }
        try? commit { $0.migration.pendingCleanup.removeAll { $0 == label } }
      } catch { continue }
    }
  }

  private func canCleanUpLegacy(
    _ label: String,
    identity: SSHIdentityMetadata
  ) -> Bool {
    snapshot.migration.labelMap[label] == identity.id
      && canReuseMigratedIdentity(identity)
      && !(snapshot.hosts + snapshot.cachedHosts)
        .contains { $0.auth == .legacyKey(label: label) }
  }
}
