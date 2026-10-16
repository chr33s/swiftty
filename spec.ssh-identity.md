# SSH identity, Keychain storage, and iCloud sync

**Status:** Proposed; documentation only, not an implementation or test report.  
**Version:** 0.1  
**Date:** 2026-10-16  
**Target:** `chr33s/swiftty`  
**Reference implementation:** `chr33s/shell`  
**Reviewed revisions:** Swiftty `b45ebc40518d92ab87c0abc3507790e0401e5787`; Shell `8069632c971107c05330bd56da9e32bbb7866793`.

MUST, MUST NOT, and SHOULD are normative. Numerical bounds below are proposed product limits, not measured performance or Apple platform limits.

## 1. Goal and interpretation

Make an SSH identity a first-class, reusable object: generate or import a key, save it securely, select it for a host, and optionally use the same identity on another supported Apple device through iCloud Keychain. Synchronize connection profiles and public identity metadata separately through CloudKit.

“From Shell” means adapting Shell's identity, storage, and synchronization behavior into Swiftty. It does **not** mean reading an installed Shell app's private storage, sharing Shell's Keychain access group or CloudKit container, or introducing a dependency on the Shell application. Cross-app data migration requires a separate, explicit export/import design.

This extends the roaming clients, not the terminal renderer or the Mac host service. Once accepted, it supersedes the device-only credential-sync exclusion in `spec.roaming.md` §2 for the platforms below, and replaces label-driven implicit key creation. Host trust, pairing-code verification, RST/1, SwiftMux ownership, leases, and ordinary-SSH fallback rules remain unchanged. [W1–W6]

## 2. Current implementation and required changes

| Reviewed behavior | Change required |
|---|---|
| `AuthMethodReference` has `.password` and `.keychainKey(label:)`; profiles contain references rather than secrets. | Preserve that separation; introduce stable UUID identity references and an explicit versioned decoder. [W1] |
| `HostProfileStore` writes version-1 `hosts.json`, limited to 256 hosts and 1 MiB. | Migrate without losing IDs, host settings, or credentials; add durable metadata and sync state. [W2] |
| `SSHEd25519Key` already generates keys, formats public keys, and computes fingerprints. | Reuse these primitives instead of replacing the SSH stack. [W3] |
| `KeychainEd25519KeyStore` stores raw Ed25519 private material as generic-password items, with synchronization disabled and `AfterFirstUnlockThisDeviceOnly`. | Add explicit storage policy, UUID addressing, typed failures, and scoped migration. [W3] |
| `SSHAccess` uses service `dev.chr33s.swiftty.ssh-key`; both credential resolution and public-key display call `loadOrCreateKey(label:)`. | Login and display MUST become read-only. A missing key MUST NOT create a replacement. [W4] |
| `HostEditorView` exposes a Keychain toggle and free-text label. | Replace it with an identity picker and explicit Generate/Import actions. [W5] |
| Shell separates CloudKit public records from Keychain secrets; its resolver preserves explicit identity selection. | Adapt those contracts, not its full feature set or singleton graph. [S1–S3] |

Shell's offline queue and sync manager are useful references, but not drop-in components. In particular, do not copy queue-error handling that merely logs a failed persistence operation, retry-count pruning that discards changes, or silent relaxation of authentication policy for synchronizable keys. [S3–S5]

## 3. Scope

### 3.1 Required first release

Full feature support targets iPhone, iPad, Mac Catalyst, and windowed visionOS, retaining the repository's 27.0 deployment minimums and Swift 6.4 toolchain. The existing native Mac application remains the local terminal/host; Mac users manage remote identities through the Catalyst client. [W6–W8]

Required capabilities are Ed25519 generation; bounded OpenSSH Ed25519 private-key import, including supported encrypted keys; reusable identities; public-key copy/export; Keychain persistence; device-only or iCloud Keychain storage; profile/public-metadata sync; optional known-host sync; recovery UI; and migration of existing Swiftty keys.

Passwords continue to use the existing prompt/session-memory behavior. Persistent password storage and saved import passphrases are not part of this change.

### 3.2 Explicit exclusions

RSA/ECDSA authentication expansion, Secure Enclave keys, user certificates, SSH agents, forwarding, ProxyJump, full `~/.ssh/config` import, private-key export, automatic server authorization, and cross-app Shell vault sharing are deferred. Shell supports a broader identity surface; this release deliberately retains Swiftty's Ed25519 transport boundary. [S1, W3, W6]

For this feature's first release, tvOS retains local key authentication and explicit generation, without new import or cloud-sync UI. This is a product boundary, not a claim that Apple APIs universally prohibit those features. tvOS must still receive the read-only login fix. Watch remains a companion with no credentials, identity store, SSH connection, or new cloud entitlements. Existing platform builds must continue to pass. [W6, W7]

## 4. User experience

### 4.1 Keys

Add **Settings → SSH Keys** and a shortcut from the host editor. Each row displays name, Ed25519 algorithm, SHA-256 public fingerprint, storage policy, and local availability. Detail actions are Rename, Copy/Export Public Key where supported, Show Referencing Hosts, and Delete.

**Generate:** enter a name, select storage, and confirm. Default to **This device only**. Generate and save before publishing the identity to the picker. Show the public key and explain that it must be authorized on the server; creating a key does not install it remotely.

**Import:** use a user-selected file, or an explicit paste action where supported. Show the parsed algorithm and fingerprint before confirmation. For an encrypted key, request the passphrase through a secure field. Never inspect the clipboard automatically or interpret imported text as a command.

Imported keys are normalized into Keychain-protected private material. Explain that the original file passphrase is used for import only, not requested on every connection. Do not persist the passphrase or a decrypted temporary file.

### 4.2 Hosts and login

The authentication picker offers **Password** or **SSH key**. The key picker uses UUIDs; display names need not be unique and renaming cannot break hosts. An unavailable identity remains visible with an explanation rather than disappearing or becoming Password.

Use the selected identity for pairing, workspace discovery/bootstrap, ordinary SSH, attention requests, reconnect, and SFTP. Reuse existing connection-attempt limits; do not try every stored key or create a password fallback. Authentication rejection may display the selected public key with server-authorization instructions.

### 4.3 Sync controls and honest status

Offer **Sync profiles and key metadata**, off by default, and **Sync trusted hosts**, separately off by default. Explain that hostnames, usernames, labels, and public keys are not private-key material but remain sensitive configuration.

Secret synchronization is selected per identity at creation/import. Enabling metadata sync MUST NOT convert device-only keys into synchronizable items. Metadata sync can be disabled while existing iCloud Keychain identities remain OS-managed; the UI must explain that distinction.

Show separate metadata states (`off`, `pending`, `up to date`, `offline`, `account required`, `error`) and identity availability. A successful local Keychain write is not evidence that another device received the key. “Refresh” fetches metadata and retries local lookup; it must not claim to force iCloud Keychain delivery. [A1, A4]

## 5. Models and ownership

All names in this section are proposed interfaces, not claims of existing symbols.

| Type | Required contract |
|---|---|
| `AuthMethodReference` v2 | `password`, `key(identityID: UUID)`, preserved unsupported variants; legacy label decoding exists only for migration. |
| `SSHIdentityMetadata` | UUID, name, algorithm, canonical public key, fingerprint, immutable storage policy, creation time, modification revision, optional deletion tombstone. No private bytes or Keychain persistent references. |
| `IdentityStoragePolicy` | `deviceOnly` or `iCloudKeychain`; immutable for a given UUID in v1. |
| `IdentityAvailability` | available, unavailableOnThisDevice, awaitingKeyMaterial, protectedDataUnavailable, unsupported, deleted, integrityConflict. Computed locally, never synced as authoritative state. |
| `SSHIdentityStore` | Explicit generate/import/read/rename/delete operations; no load-or-create operation on the login path. |
| `IdentityResolver` | Resolve exactly the selected UUID; validate derived public material against its metadata; return a typed credential or a typed failure. |
| `ConnectionStore` | Actor-owned, versioned, atomic non-secret snapshot covering profiles, identities, trust metadata, pending mutations, server state, tombstones, and migration journals. |
| `ConnectionSyncCoordinator` | Foreground CloudKit scheduling, account isolation, conflict handling, and durable acknowledgments; cannot read secret bytes. |

Private key material belongs only to the Keychain adapter and short-lived authentication/import operations. Credential values MUST NOT conform to persistence or diagnostic protocols that expose their contents.

Use a single atomic snapshot for related local data/outbox/checkpoint changes, not independently updated JSON files advertised as a transaction. Advance in-memory committed state only after the write succeeds. Keep corruption distinct from an empty store, retain a recoverable previous snapshot, and never overwrite an unreadable store with defaults.

Proposed bounds: 256 live hosts, 256 live identities, 1,024 live trust entries, and 16 MiB per connection-state snapshot. Preserve existing host-field validation. Tombstones count toward storage bounds but cannot be silently pruned; storage exhaustion is a visible recoverable error, not successful saving or sync.

### 5.1 Identity invariants

A UUID identifies one immutable public/private key pair. It cannot be reused for different key material, including during rotation. Rotation creates a new identity and requires explicit host reassignment.

Matching labels are never a credential-resolution rule. Fingerprints support duplicate detection and explicit repair, not automatic substitution of another identity. If reimporting exactly the expected public key to repair a missing UUID, confirm the match before associating it. A same-UUID/different-public-key result is an integrity error that blocks authentication.

## 6. Authentication and key import

### 6.1 Connection sequence

1. Validate the profile and capture its identity reference for the connection attempt.
2. Preserve the existing unknown-host prompt and pairing-code checks. On the authenticated transport, verify the presented host key before offering a credential; an earlier probe is not sufficient by itself.
3. Resolve the selected identity without mutation. Acquire secret material only for the authentication operation, respecting protected-data availability.
4. Authenticate through the existing SwiftNIO SSH Ed25519 path. A missing, rejected, deleted, unsupported, or mismatched identity fails closed.
5. Release application-held material promptly after authentication. A reconnect that needs SSH authentication resolves the identity again.

Cancellation must prevent late authentication, generation, persistence, or profile changes. Background/noninteractive callers cannot open credential UI. Sync changes affect future attempts, not an already-captured connection target or live writer lease. Deleting an identity does not terminate a remote process or revoke a key already authorized on the server. [W4, W6]

### 6.2 Import format and limits

Adapt the relevant Shell parser/normalizer/decryption logic, with provenance and security review. Required v1 input is one `openssh-key-v1` Ed25519 identity, either unencrypted or bcrypt-encrypted with `aes128-ctr`/`aes256-ctr`, matching the reviewed Shell decryption surface. Other ciphers, KDFs, algorithms, certificates, and public-only files receive explicit unsupported-input errors. [S6]

Validate every length before allocation, key count, cipher/KDF pairing, check integers, deterministic padding, public/private consistency, and complete consumption of the input. Reject encrypted ciphers paired with a `none` KDF. Proposed limits: 64 KiB input, one key, 1 KiB comment, 1 KiB UTF-8 passphrase, 1 KiB KDF salt, and bcrypt rounds from 1 through 64. Do not trim or normalize passphrases. Report keys exceeding limits rather than silently weakening them.

Parsing/KDF work runs off the main actor with bounded concurrency. Cancellation discards its eventual result; a synchronous bounded cryptographic call may need to finish before cleanup, and must not be misrepresented as preemptively cancelled.

Shell's implementation imports Citadel and native crypto modules. It cannot be pasted into Swiftty unchanged. Select and pin a reviewed, minimal bcrypt/AES implementation behind the import adapter; do not add a second SSH client or depend on private Swift Crypto implementation symbols. Record licenses and dependency compatibility before encrypted import is enabled. Do not invent cryptographic primitives. [S6, W8]

## 7. Keychain contract

### 7.1 Storage attributes

Use `kSecClassGenericPassword` for canonical Ed25519 secret payloads. Proposed service: `dev.chr33s.swiftty.ssh-identity.v1`; account: lowercase identity UUID. Read the resolved access group from build configuration and specify it on every scoped operation.

| Policy | Synchronizable | Accessibility for new items |
|---|---|---|
| This device only | `false` | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` |
| iCloud Keychain | `true` | `kSecAttrAccessibleWhenUnlocked` |

Synchronizable items cannot use a `ThisDeviceOnly` accessibility class. Use the data-protection Keychain for any native macOS implementation rather than accidentally targeting its legacy file-based Keychain. Catalyst must be tested as its own destination. [A1–A3]

This release promises unlocked-device protection, not per-use biometric protection. Do not silently remove an authentication requirement to enable sync. Any future biometric/Secure Enclave policy needs a separate compatibility contract and explicit consent; app-level biometric UI must not be described as hardware enforcement on an exportable synced key. [S3]

### 7.2 Query, write, and error rules

Normal reads and all mutations specify class, service, account, access group, and exact synchronization policy. Broad synchronization queries are reserved for controlled migration/diagnostics and must inspect duplicates; never arbitrarily take the first match. Do not use persistent Keychain references as cross-device IDs. [A1]

Create without overwriting. On a duplicate item, load and compare the public identity; a different key is an integrity failure. Treat only `errSecItemNotFound` as absence. Locked/protected data, cancelled authentication, missing entitlements, malformed material, and other status codes remain distinct failures.

Coordinate Keychain and metadata through durable, non-secret operation intents: record intent, write the item, read back and verify, publish metadata, then mark completion. A failed step must be retryable after relaunch. Never delete the only verified copy before the replacement is durable. Orphan recovery examines only the app's exact namespace and never publishes an unapproved identity automatically.

Do not log private bytes, passphrases, Keychain query dictionaries, or imported file contents. Minimize secret copies and clear owned buffers where practical; do not claim guaranteed zeroization of all Swift/Crypto copies. Protect file-picker scopes, purge temporary UI state, and redact sensitive screens when inactive.

### 7.3 Changing storage and deletion

Storage policy is immutable per identity in v1, avoiding conflicting in-place policy changes across devices. **Create an iCloud copy** creates a new UUID for the same key material after explicit consent; it may reassign selected local host profiles transactionally. The original remains until explicitly deleted, and the UI identifies the duplicate public fingerprint.

**Delete this device-only identity** affects local secret storage only. **Delete this iCloud identity** requests deletion of the synchronizable item and publishes a metadata tombstone. Warn that deletion propagates to other participating devices, is asynchronous, and does not remove the public key from a server's `authorized_keys`. [A1]

**Withdraw from iCloud and keep locally** must first create and verify a new device-only identity, persist selected host reassignments, then durably schedule the old identity's tombstone and exact Keychain deletion. Retry incomplete steps. Never label this as immediate remote revocation or proof that all prior copies were erased.

Deleting a host never deletes a shared identity. Identity deletion shows referencing hosts; retain their unresolved references unless the user explicitly reassigns them. Receiving a remote tombstone blocks new use, but must not trigger deletion of unrelated or device-only Keychain items.

## 8. CloudKit synchronization

### 8.1 Container and records

Use Swiftty's own proposed container `iCloud.dev.chr33s.swiftty`, the user's private database, and a custom zone `SwifttyConnectionsV1`. This is a proposed identifier, not a verified provisioned resource. Never reuse `iCloud.dev.chr33s.shell`. [S1, S5]

| Record type | Payload |
|---|---|
| `SwifttyHostProfileV1` | Stable host ID, nickname, host, port, username, explicit auth type/identity UUID, revision, tombstone. |
| `SwifttySSHIdentityV1` | UUID, name, algorithm, public key, fingerprint, storage policy, creation/revision metadata, tombstone. |
| `SwifttyKnownHostV1` | Canonical host/port identity, algorithm and public key, fingerprint, trust provenance, revision, tombstone. |

Use deterministic record names based on entity type and UUID; derive known-host record names from a versioned canonical endpoint encoding, not display text. Define DNS case normalization, IPv6 handling, and ports consistently with `HostIdentity`; do not merge DNS aliases through resolution.

Cloud payloads, offline queues, and local metadata MUST NOT contain private keys, import passphrases, passwords, RST grants, attachment tokens, QUIC/TLS private identities, live sessions, terminal contents, scrollback, command history, or device-local Keychain references. Keychain is the only secret-sync channel. Public metadata is not automatically entitled to the same security claims as iCloud Keychain; avoid a blanket claim that every CloudKit field is end-to-end encrypted. [S1, A4, A5]

### 8.2 Durable foreground synchronization

Adapt Shell's explicit CloudKit operation/queue/checkpoint approach behind an actor, not its entire manager. This release intentionally does not introduce CKSyncEngine or background remote-notification execution. Fetch/send on launch, foreground activation, explicit Refresh, and a debounced local edit while active. Coalesce work; network reachability is a hint, not proof of success. Do not keep the app alive for sync or interfere with SSH/RST deadlines. [S4, S5, W7]

Persist a local mutation and its outgoing operation together before reporting Save complete. Coalesce repeated edits to the same entity while preserving tombstones. An acknowledgment removes only the exact operation revision it sent; a newer edit made in flight must remain queued.

Apply a fetched page and persist its server checkpoint in the same committed snapshot. For a valid but unsupported record, persist a bounded opaque representation before advancing; quarantine malformed records with diagnostics. Never skip data because a local write failed. After an expired change token, perform a full refetch while preserving unsent local changes and tombstones.

Use server change tags and conflict-aware saves, not unconditional overwrites. Retry transient failures with bounded exponential backoff, jitter, and server retry-after guidance. Quota, entitlement, schema, and validation errors remain visible and durable. Do not discard an operation after an arbitrary number of retries. Handle partial successes per record. Zone loss must not silently recreate/upload an old account's cache; require a reconciled current account and explicit recovery.

### 8.3 Conflict and deletion rules

Use a persisted logical revision `(counter, deviceID)` for deterministic non-security metadata conflict resolution; advance counters beyond observed revisions rather than trusting wall-clock order. Keep server change tags for concurrency detection.

Names may converge deterministically. Treat host/port/username/auth selection as one connection tuple; conflicting concurrent changes require review rather than field-by-field synthesis. A remote edit never retargets an active session. Same-UUID key-material changes are quarantined, not merged.

Known-host conflicts are security conflicts: never replace a locally trusted key by last-write-wins. Retain the existing pin, block the conflicting connection, and require explicit verification. Remote deletion must not silently turn a changed key into a fresh, untrusted-host prompt; retain a review-required marker. Known-host sync is an explicit delegation of trust decisions between the user's devices, not a replacement for host verification.

Deletion wins for a given entity UUID. A stale device cannot recreate it by uploading an older edit; restoration creates a new UUID after user action. Keep tombstones without time-based garbage collection in v1. Remote profile deletion does not kill a live shell; it prevents subsequent saved-profile connection attempts.

### 8.4 Independent delivery and account changes

Expect profiles, public identity records, and Keychain items in any order. Metadata without a secret yields **Key not available on this device** with retry and repair actions. Do not assert that absence proves sync is still running: Keychain may be disabled, delayed, inaccessible, or the key may be permanently missing. A secret without approved metadata remains an orphan, not an automatic login choice.

Keep local-only data separate from account-bound sync data. Partition cached records, queues, checkpoints, and operation intents by CloudKit account. Use an account-generation token so results from an old context cannot commit after a switch.

On sign-out/account switch, stop sync, invalidate in-flight work, quarantine the previous account's state, and do not publish it to the new account. Do not globally delete synchronizable Keychain items merely because the account changed. Require account confirmation and explicit consent before publishing local data to a newly selected account. Creating an iCloud identity requires a verified current account context, while local-only keys remain usable without iCloud.

CloudKit account availability is not evidence that iCloud Keychain is enabled. The app cannot promise to control the OS's retention or propagation of already synchronizable items. UI explanations must distinguish app-level metadata controls from system Keychain behavior.

## 9. Existing Swiftty migration

Run a resumable migration before enabling new identity writes or synchronization.

1. Read and validate version-1 `hosts.json`; retain the original recoverable snapshot. Preserve host UUIDs, endpoints, names, and password selection.
2. For each distinct referenced label, persist one stable label-to-UUID mapping. Multiple hosts using the exact same label remain associated with one identity.
3. Read only service `dev.chr33s.swiftty.ssh-key`, the exact legacy label, and `synchronizable=false`, with the legacy app access scope. Do not search unrelated services or Shell's access group. [W4]
4. If present, derive its public key/fingerprint, create and verify the new device-only item, and commit metadata plus all affected references. Existing keys are not automatically uploaded or rotated.
5. If absent, preserve an unresolved legacy reference with a repair action. Do not call `loadOrCreateKey`. Do not upload a misleading complete identity/profile until its legacy reference is repaired. If access is temporarily blocked, defer rather than treating the key as missing.
6. Remove a legacy item only after verified replacement and committed references, with cleanup recorded for retry. Document the point after which older builds cannot read the new store; never silently downgrade v2 to v1.

Check actual signed access groups before migration. An entitlement change that loses access to old items blocks release until a tested compatibility path exists. Re-running after any interruption must preserve the same mappings and fingerprints.

## 10. Implementation map and delivery sequence

| Area | Work |
|---|---|
| `Sources/SSHClient/Ed25519Keys.swift` | Retain generation/public formatting and compatibility interfaces; remove app login dependence on load-or-create. |
| New `Sources/SSHIdentity/` | Identity models, resolver, Keychain adapter, import adapter, typed errors, injectable stores. |
| `Apps/Shared/HostProfile.swift`, `HostProfileStore.swift` | Versioned auth decoding, stable references, compatibility migration. |
| New `Apps/Shared/ConnectionStore.swift`, `ConnectionSyncCoordinator.swift` | Atomic non-secret state, operation journals, private CloudKit sync. |
| `Apps/Shared/SSHAccess.swift` | Inject resolver; preserve host/pairing checks; share behavior across all SSH callers. |
| `Apps/Shared/HostViews.swift`, `RoamingAppModel.swift`; new key/settings views | Picker, generation/import, lifecycle handling, availability and recovery UI. |
| `Package.swift`, `Apps/project.yml`, entitlement sources and `Scripts/configure-links.sh` | Wire client-only dependencies and configured capabilities; preserve generated Associated Domains entitlements. |
| Tests plus `README.md`, `spec.roaming.md`, `spec.connection-setup.md` | Contract tests, migration fixtures, platform evidence, and accepted-scope cross-references. |

Proposed access group: `$(AppIdentifierPrefix)dev.chr33s.swiftty`, expanded from one build setting into both entitlements and runtime configuration. Enable CloudKit only for participating direct clients; configure development/production containers and deploy the production schema before TestFlight verification. Missing capability errors must not fall back to plaintext files. Do not add client credential access to SwifttyEngine, SwiftMux services, `swifttyd`, or Watch. [W7, A6]

**P1 — Local identity foundation:** stable IDs, explicit creation/import, read-only resolution, migration, device-only Keychain tests. Ship no sync promises.

**P2 — Key management UI and encrypted import:** identity picker, public export, deletion references, audited import dependencies and negative fixtures.

**P3 — iCloud Keychain:** signed access-group validation, immutable per-identity policy, two-device delivery and withdrawal tests.

**P4 — CloudKit:** atomic outbox/checkpoints, account isolation, opt-in profile/metadata sync, conflicts, tombstones, optional trust sync.

**P5 — Release gates:** real-device matrix, interrupted-operation tests, production schema/signing verification, documentation updates. A feature flag may hide unfinished UI, but must not reverse migrated data or erase credentials.

## 11. Acceptance criteria

All checks are pending. No builds, device tests, cloud provisioning, or implementation changes were performed when this specification was written.

| ID | Required evidence |
|---|---|
| KEY-01 | Generate and import Ed25519, relaunch, and authenticate with the same fingerprint. |
| KEY-02 | Two profiles share an identity; rename changes neither references nor fingerprint. |
| KEY-03 | Missing/deleted/locked/corrupt items never generate a key or trigger password fallback, including public-key display and noninteractive access. |
| KEY-04 | Unknown/changed host keys and pairing-code mismatches block credential offering; test the actual authenticated transport, not only the probe. |
| KEY-05 | Encrypted import covers correct/wrong passphrase, bad padding/check integers, unsupported cipher/KDF, mismatched public/private material, oversized lengths, excessive KDF work, and cancellation. |
| KEY-06 | Duplicate Keychain writes preserve the existing identity; same UUID with different bytes/public key fails closed. |
| KEY-07 | Password login, ordinary SSH, SFTP, roaming bootstrap/reconnect, and attention access retain existing behavior and lifecycle limits. |
| MIG-01 | Version-1 migration preserves host IDs and key fingerprints; shared labels remain shared; absent keys stay unresolved. |
| MIG-02 | Inject failure after every journal, Keychain, snapshot, and cleanup step; relaunch completes safely without credential loss or identity replacement. |
| SEC-01 | Inspect serialized snapshots, queues, CloudKit fields, logs, crash diagnostics, and inactive-app snapshots for absence of private material/passphrases. |
| SEC-02 | Verify exact Keychain accessibility, synchronization flags, service/account/group scoping, and missing-entitlement behavior on signed builds. |
| SYN-01 | Signed devices A and B use the same opted-in key; a device-only key's public metadata never makes its private material available on B. |
| SYN-02 | Exercise metadata-first, secret-first, missing-key, offline, locked-device, disabled-Keychain, and unavailable-account cases without replacement or false completion claims. |
| SYN-03 | An offline edit survives process death; an acknowledgment for revision N cannot discard revision N+1. |
| SYN-04 | Fetch/write failures do not advance checkpoints; token expiry/full fetch, partial failures, quota, and schema errors preserve unsent changes. |
| SYN-05 | Concurrent rename converges; conflicting connection tuples require review; identity and known-host conflicts block rather than overwrite. |
| SYN-06 | A stale offline device cannot resurrect a tombstoned identity/profile; sync disabling does not silently delete cloud secrets. |
| SYN-07 | Account switch during fetch, send, import publication, or withdrawal cannot commit or upload old-account work into the new account. |
| SYN-08 | Withdrawal preserves a verified local copy, retries failed synchronized deletion, and never claims server-side revocation or immediate remote erasure. |
| PLAT-01 | Build all existing targets; run full feature checks on physical iPhone/iPad, Mac Catalyst, and visionOS with exact OS, SDK, team, entitlement, and dependency versions recorded. |
| PLAT-02 | tvOS retains local login without import/sync controls; Watch and host services gain no credential access or cloud dependencies. |
| REL-01 | Production CloudKit schema and signed TestFlight-to-TestFlight cross-device behavior pass; simulator-only results cannot satisfy sync release gates. |

## 12. Decisions and remaining verification

The design decisions are explicit: Ed25519 first; device-only default; opt-in metadata sync; per-identity secret sync; no silent fallback; no shared Shell vault; immutable key material/storage policy; foreground CloudKit; no automatic server authorization.

Implementation must still verify the actual provisioned container/access groups and legacy accessibility, select and pin the import crypto dependency, measure proposed KDF bounds on supported hardware, and execute the acceptance matrix. These are release gates, not claims that the repository already satisfies them.

## References

Repository references are pinned to the revisions reviewed for this document.

- **W1:** [Swiftty HostProfile.swift](https://github.com/chr33s/swiftty/blob/b45ebc40518d92ab87c0abc3507790e0401e5787/Apps/Shared/HostProfile.swift).
- **W2:** [Swiftty HostProfileStore.swift](https://github.com/chr33s/swiftty/blob/b45ebc40518d92ab87c0abc3507790e0401e5787/Apps/Shared/HostProfileStore.swift).
- **W3:** [Swiftty Ed25519Keys.swift](https://github.com/chr33s/swiftty/blob/b45ebc40518d92ab87c0abc3507790e0401e5787/Sources/SSHClient/Ed25519Keys.swift).
- **W4:** [Swiftty SSHAccess.swift](https://github.com/chr33s/swiftty/blob/b45ebc40518d92ab87c0abc3507790e0401e5787/Apps/Shared/SSHAccess.swift).
- **W5:** [Swiftty HostViews.swift](https://github.com/chr33s/swiftty/blob/b45ebc40518d92ab87c0abc3507790e0401e5787/Apps/Shared/HostViews.swift).
- **W6:** [Swiftty README](https://github.com/chr33s/swiftty/blob/b45ebc40518d92ab87c0abc3507790e0401e5787/README.md) and [roaming specification](https://github.com/chr33s/swiftty/blob/b45ebc40518d92ab87c0abc3507790e0401e5787/spec.roaming.md).
- **W7:** [Swiftty Apps/project.yml](https://github.com/chr33s/swiftty/blob/b45ebc40518d92ab87c0abc3507790e0401e5787/Apps/project.yml).
- **W8:** [Swiftty Package.swift](https://github.com/chr33s/swiftty/blob/b45ebc40518d92ab87c0abc3507790e0401e5787/Package.swift).
- **S1:** [Shell product specification, especially §§3–8](https://github.com/chr33s/shell/blob/8069632c971107c05330bd56da9e32bbb7866793/docs/specs/shell.md).
- **S2:** [Shell ConnectionKeyResolver.swift](https://github.com/chr33s/shell/blob/8069632c971107c05330bd56da9e32bbb7866793/shell/Features/SSH/Keys/ConnectionKeyResolver.swift).
- **S3:** [Shell KeychainManager.swift](https://github.com/chr33s/shell/blob/8069632c971107c05330bd56da9e32bbb7866793/shell/Core/Security/KeychainManager.swift).
- **S4:** [Shell CloudKitOfflineQueue.swift](https://github.com/chr33s/shell/blob/8069632c971107c05330bd56da9e32bbb7866793/shell/Core/CloudKit/CloudKitOfflineQueue.swift).
- **S5:** [Shell CloudKitSyncManager.swift](https://github.com/chr33s/shell/blob/8069632c971107c05330bd56da9e32bbb7866793/shell/Core/CloudKit/CloudKitSyncManager.swift).
- **S6:** [Shell OpenSSHKeyDecryption.swift](https://github.com/chr33s/shell/blob/8069632c971107c05330bd56da9e32bbb7866793/shell/Features/SSH/Keys/OpenSSHKeyDecryption.swift).
- **A1:** [Apple: kSecAttrSynchronizable](https://developer.apple.com/documentation/security/ksecattrsynchronizable).
- **A2:** [Apple: kSecAttrAccessible](https://developer.apple.com/documentation/security/ksecattraccessible).
- **A3:** [Apple: TN3137, On Mac keychain APIs and implementations](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains).
- **A4:** [Apple: iCloud Keychain security overview](https://support.apple.com/guide/security/icloud-keychain-security-overview-sec1c89c6f3b/web).
- **A5:** [Apple: iCloud data security overview](https://support.apple.com/en-us/102651).
- **A6:** [Apple: Sharing access to keychain items among a collection of apps](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps).
