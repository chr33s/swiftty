import Foundation
import Observation
import SSHClient
import SSHIdentity

/// Opt-in, foreground-only CloudKit sync of host profiles, public identity
/// metadata and, separately, trusted host keys (spec.ssh-identity.md §8).
///
/// Runs on launch, foreground activation, explicit Refresh and a debounced
/// local edit while active; it never keeps the app alive and never reads
/// Keychain secrets. Every page of fetched changes is applied together with
/// its checkpoint in one snapshot commit; an acknowledgment removes only
/// the exact revision it sent. Work belongs to one CloudKit account, and an
/// account switch invalidates in-flight work through a generation token.
@MainActor
@Observable
public final class ConnectionSyncCoordinator {
  /// Metadata sync state shown in Settings (§4.3). Identity availability
  /// is reported separately, from the Keychain.
  public enum Status: Hashable, Sendable {
    case off
    case pending
    case upToDate(Date)
    case offline
    case accountRequired
    /// The iCloud account differs from the one local data was synced with:
    /// that account's data is hidden until the user confirms.
    case accountChanged
    /// The zone vanished on the server; recovery needs explicit action.
    case zoneRecoveryRequired
    case error(String)

    public var summary: String {
      switch self {
      case .off: "Off"
      case .pending: "Pending"
      case .upToDate: "Up to date"
      case .offline: "Offline"
      case .accountRequired: "iCloud account required"
      case .accountChanged: "iCloud account changed"
      case .zoneRecoveryRequired: "Synced data missing from iCloud"
      case .error(let message): message
      }
    }
  }

  public private(set) var status: Status = .off
  /// The account last verified by `accountID()`, if any.
  public private(set) var currentAccount: String?

  /// Revocation takes effect even when the durable settings write fails.
  /// Keep retrying that write before any later refresh or explicit opt-in.
  private var pendingMetadataDisable = false
  private var pendingTrustDisable = false

  public var metadataSyncEnabled: Bool {
    !pendingMetadataDisable && snapshot.settings.metadataSync
  }

  public var trustSyncEnabled: Bool {
    !pendingTrustDisable && snapshot.settings.trustSync
  }

  @ObservationIgnored
  private weak var app: (any ConnectionOwner)?
  @ObservationIgnored
  package let database: any ConnectionCloudDatabase
  /// Bumped on account change; results from an older generation never
  /// commit (§8.4).
  @ObservationIgnored
  package private(set) var generation = 0
  @ObservationIgnored
  private var running: Task<Void, Never>?
  @ObservationIgnored
  private var runningToken: UUID?
  @ObservationIgnored
  private var rerun = false
  @ObservationIgnored
  private var debounce: Task<Void, Never>?
  @ObservationIgnored
  package var isActive = true
  @ObservationIgnored
  package var debounceDelay: Duration = .seconds(2)
  @ObservationIgnored
  package var now: @MainActor () -> Date = { Date() }
  /// Records per save request.
  package static let batchSize = 200
  package static let maxPagesPerRun = 64

  package init(app: any ConnectionOwner, database: any ConnectionCloudDatabase) {
    self.app = app
    self.database = database
  }

  private var snapshot: ConnectionSnapshot {
    app?.connections ?? ConnectionSnapshot()
  }

  /// Commits on behalf of sync; never schedules another sync by itself.
  @discardableResult
  private func commit(
    generation: Int,
    _ mutate: (inout ConnectionSnapshot) -> Void
  ) -> Bool {
    guard generation == self.generation, let app else { return false }
    return app.commitConnections(notifySync: false) { mutate(&$0) }
  }

  // MARK: Scheduling

  /// A debounced sync after a local edit, while the app is active.
  package func localChange() {
    guard metadataSyncEnabled, isActive else { return }
    status = .pending
    debounce?.cancel()
    debounce = Task { [weak self, debounceDelay] in
      try? await Task.sleep(for: debounceDelay)
      guard !Task.isCancelled else { return }
      self?.refresh()
    }
  }

  /// Launch, foreground or explicit Refresh: verify the selected account,
  /// then fetch and send only while metadata sync is enabled. Account
  /// isolation remains active when uploads are disabled.
  @discardableResult
  public func refresh() -> Task<Void, Never>? {
    if let running {
      rerun = true
      return running
    }
    let generation = generation
    let token = UUID()
    let task = Task { [weak self] in
      guard let self else { return }
      repeat {
        rerun = false
        await run(generation: generation)
      } while rerun && generation == self.generation && !Task.isCancelled
      if runningToken == token {
        running = nil
        runningToken = nil
      }
    }
    running = task
    runningToken = token
    return task
  }

  public func setActive(_ active: Bool) {
    isActive = active
    if !active { debounce?.cancel() }
  }

  /// The system reported an iCloud account change: stop, invalidate
  /// in-flight work and re-verify before anything else commits.
  public func accountDidChange() {
    app?.invalidateAccountContext()
    generation += 1
    running?.cancel()
    running = nil
    debounce?.cancel()
    currentAccount = nil
    commit(generation: generation) {
      $0.selectKeychainAccount(nil)
      $0.selectAccount(nil)
    }
    refresh()
  }

  // MARK: Settings

  /// Turns metadata sync on for the current account (that is the user's
  /// consent for this account) or off. Turning it off keeps local data and
  /// never deletes cloud records or synchronizable Keychain items.
  public func setMetadataSync(_ enabled: Bool) async throws(CloudSyncError) {
    guard enabled else {
      pendingMetadataDisable = true
      generation += 1
      running?.cancel()
      running = nil
      debounce?.cancel()
      status = .off
      guard persistSyncRevocations() else { throw .settingsNotSaved }
      return
    }
    guard persistSyncRevocations() else { throw .settingsNotSaved }
    let generation = generation
    let account = try await database.accountID()
    guard generation == self.generation, !Task.isCancelled else { return }
    currentAccount = account
    guard
      commit(
        generation: generation,
        { snapshot in
          snapshot.settings.metadataSync = true
          Self.bind(&snapshot, to: account)
        }
      )
    else { throw .settingsNotSaved }
    refresh()
  }

  @discardableResult
  private func persistSyncRevocations() -> Bool {
    guard pendingMetadataDisable || pendingTrustDisable else { return true }
    guard
      commit(
        generation: generation,
        {
          if pendingMetadataDisable { $0.settings.metadataSync = false }
          if pendingTrustDisable { $0.settings.trustSync = false }
        }
      )
    else { return false }
    pendingMetadataDisable = false
    pendingTrustDisable = false
    return true
  }

  /// Confirms publishing this device's local-only data to the current,
  /// newly selected account (§8.4).
  public func confirmCurrentAccount() async throws(CloudSyncError) {
    let generation = generation
    let account = try await database.accountID()
    guard generation == self.generation, !Task.isCancelled else { return }
    currentAccount = account
    commit(generation: generation) { Self.bind(&$0, to: account) }
    refresh()
  }

  /// Binds local data to `account` and queues every visible, publishable
  /// entity that the account has not acknowledged at its current revision.
  package static func bind(_ snapshot: inout ConnectionSnapshot, to account: String) {
    snapshot.accounts[account, default: AccountPartition()].consented = true
    snapshot.selectKeychainAccount(account)
    snapshot.selectAccount(account)
    for index in snapshot.intents.indices {
      let intent = snapshot.intents[index]
      if intent.account == nil, !intent.hasUnverifiedAccount,
        intent.keychainAccount == nil || intent.keychainAccount == account
      {
        snapshot.intents[index].account = account
      }
    }
    let synced = snapshot.accounts[account]?.synced ?? [:]
    func queue(_ name: String, _ revision: LogicalRevision?) {
      guard let revision, snapshot.isVisible(name), synced[name] != revision
      else { return }
      snapshot.enqueue(name, revision: revision)
    }
    for host in snapshot.hosts {
      queue(
        ConnectionSnapshot.hostRecord(host.id),
        snapshot.hostRevisions[host.id]
      )
    }
    for (id, tombstone) in snapshot.hostTombstones
    where snapshot.scopes[ConnectionSnapshot.hostRecord(id)] == account {
      queue(ConnectionSnapshot.hostRecord(id), tombstone.revision)
    }
    for identity in snapshot.identities
    where !identity.isDeleted
      || snapshot.scopes[ConnectionSnapshot.identityRecord(identity.id)]
        == account
    { queue(ConnectionSnapshot.identityRecord(identity.id), identity.revision) }
    if snapshot.settings.trustSync {
      for (name, record) in snapshot.knownHosts
      where record.provenance == .local || snapshot.scopes[name] == account {
        queue(name, record.revision)
      }
    }
  }

  /// Trusted-host sync, separately opt-in. Enabling it records this
  /// device's current trusted keys for upload.
  @discardableResult
  public func setTrustSync(
    _ enabled: Bool,
    trustedKeys: [HostIdentity: String]
  ) -> Bool {
    guard enabled else {
      pendingTrustDisable = true
      let saved = persistSyncRevocations()
      refresh()
      return saved
    }
    guard persistSyncRevocations() else { return false }
    let saved = commit(generation: generation) { snapshot in
      snapshot.settings.trustSync = enabled
      for (identity, key) in trustedKeys {
        snapshot.recordLocalTrust(
          host: identity.host,
          port: identity.port,
          publicKey: key,
          fingerprint: SSHPublicKeyFormat.fingerprint(openSSHPublicKey: key)
            ?? ""
        )
      }
      if let account = snapshot.boundAccount {
        Self.bind(&snapshot, to: account)
      }
    }
    if saved { refresh() }
    return saved
  }

  /// Explicit recovery after zone loss: re-creates the zone for the
  /// verified current account and re-uploads that account's data.
  public func recoverZone() async throws(CloudSyncError) {
    let generation = generation
    let account = try await database.accountID()
    guard generation == self.generation, !Task.isCancelled else { return }
    guard account == snapshot.boundAccount else {
      status = .accountChanged
      return
    }
    commit(generation: generation) { snapshot in
      var partition = snapshot.accounts[account] ?? AccountPartition()
      partition.zoneLost = false
      partition.zoneReady = false
      partition.changeToken = nil
      partition.systemFields = [:]
      partition.synced = [:]
      partition.hostBases = [:]
      snapshot.accounts[account] = partition
      Self.bind(&snapshot, to: account)
    }
    refresh()
  }

  // MARK: Run

  private func run(generation: Int) async {
    persistSyncRevocations()
    let account: String
    do { account = try await database.accountID() } catch {
      guard generation == self.generation else { return }
      if error == .accountRequired {
        // Signed out: quarantine the previous account's data (§8.4). It
        // returns when the user signs in to that account again.
        commit(generation: generation) {
          $0.selectKeychainAccount(nil)
          $0.selectAccount(nil)
        }
        currentAccount = nil
        status = metadataSyncEnabled ? .accountRequired : .off
      } else {
        status = metadataSyncEnabled ? .offline : .off
      }
      return
    }
    guard generation == self.generation, !Task.isCancelled else { return }
    currentAccount = account
    guard commit(generation: generation, { $0.selectKeychainAccount(account) })
    else { return }
    if snapshot.boundAccount != account {
      if snapshot.accounts[account]?.consented == true {
        // Back to an account the user already synced with.
        commit(generation: generation) { $0.selectAccount(account) }
      } else {
        // Quarantine the previous account's data; publish nothing until the
        // user confirms this account.
        commit(generation: generation) { $0.selectAccount(nil) }
        status = metadataSyncEnabled ? .accountChanged : .off
        return
      }
    }
    guard metadataSyncEnabled else {
      status = .off
      return
    }
    var partition: AccountPartition {
      snapshot.accounts[account] ?? AccountPartition()
    }
    if partition.zoneLost {
      status = .zoneRecoveryRequired
      return
    }
    if let retryAt = partition.retryAt, retryAt > now() {
      status = .pending
      return
    }
    do {
      if !partition.zoneReady {
        try await database.createZone()
        guard
          commit(
            generation: generation,
            { $0.accounts[account]?.zoneReady = true }
          )
        else { return }
      }
      try await fetch(account: account, generation: generation)
      guard generation == self.generation, !Task.isCancelled,
        metadataSyncEnabled
      else { return }
      try await send(account: account, generation: generation)
      guard generation == self.generation, !Task.isCancelled else { return }
      commit(generation: generation) { snapshot in
        snapshot.accounts[account]?.attempts = 0
        snapshot.accounts[account]?.retryAt = nil
        snapshot.accounts[account]?.lastError = nil
      }
      status = partition.outbox.isEmpty ? .upToDate(now()) : .pending
    } catch {
      guard generation == self.generation else { return }
      handle(error, account: account, generation: generation)
    }
  }

  private func handle(_ error: CloudSyncError, account: String, generation: Int)
  {
    switch error {
    case .zoneNotFound:
      commit(generation: generation) { $0.accounts[account]?.zoneLost = true }
      status = .zoneRecoveryRequired
    case .accountRequired: status = .accountRequired
    case _ where error.isTransient:
      let attempts = (snapshot.accounts[account]?.attempts ?? 0) + 1
      let delay = Self.backoff(attempt: attempts, hint: error)
      commit(generation: generation) { snapshot in
        snapshot.accounts[account]?.attempts = attempts
        snapshot.accounts[account]?.retryAt = now().addingTimeInterval(delay)
      }
      status = error == .networkUnavailable ? .offline : .pending
    default:
      // Quota, entitlement, schema and validation errors stay visible and
      // durable; queued work is never discarded.
      commit(generation: generation) {
        $0.accounts[account]?.lastError = error.message
      }
      status = .error(error.message)
    }
  }

  /// Bounded exponential backoff with jitter, honoring a server hint.
  package static func backoff(attempt: Int, hint: CloudSyncError) -> TimeInterval {
    if case .retryAfter(let seconds?) = hint {
      return min(max(seconds, 1), 3600)
    }
    let base = min(pow(2, Double(min(attempt, 10))), 900)
    return base * Double.random(in: 0.8 ... 1.2)
  }

  // MARK: Fetch

  private func fetch(
    account: String,
    generation: Int
  ) async throws(CloudSyncError) {
    var pages = 0
    while pages < Self.maxPagesPerRun {
      pages += 1
      let token = snapshot.accounts[account]?.changeToken
      let page: CloudChangePage
      do {
        page = try await database.fetchChanges(since: token)
      } catch .changeTokenExpired {
        // Full refetch; unsent changes and tombstones stay queued.
        guard
          commit(
            generation: generation,
            { $0.accounts[account]?.changeToken = nil }
          )
        else { return }
        continue
      }
      guard generation == self.generation, !Task.isCancelled else { return }
      // The page and its checkpoint commit together, or neither does.
      let applied = commit(generation: generation) { snapshot in
        for record in page.changed {
          Self.apply(record, account: account, to: &snapshot)
        }
        for name in page.deleted {
          // A hard delete (for example the user removing iCloud data):
          // forget server state; local data is neither deleted nor
          // re-uploaded automatically.
          snapshot.accounts[account]?.systemFields[name] = nil
          snapshot.accounts[account]?.synced[name] = nil
        }
        snapshot.accounts[account]?.changeToken = page.token
      }
      guard applied else { throw .other(-1) }
      await applyTrustInbox(generation: generation)
      if !page.moreComing { return }
    }
  }

  // MARK: Send

  private func send(
    account: String,
    generation: Int
  ) async throws(CloudSyncError) {
    // Conflicts merge and requeue; a few passes settle them.
    for _ in 0 ..< 3 {
      let entries =
        (snapshot.accounts[account]?.outbox.values).map(Array.init) ?? []
      let pending = entries.sorted { $0.recordName < $1.recordName }
      guard !pending.isEmpty else { return }
      var conflicted = false
      for start in stride(from: 0, to: pending.count, by: Self.batchSize) {
        // Consent, revisions and conflict state can change during a previous
        // save. Build only this batch from the current publishable outbox.
        let batch = pending[
          start ..< min(start + Self.batchSize, pending.count)
        ]
        .compactMap { entry -> (OutboxEntry, CloudRecord)? in
          guard !entry.recordName.hasPrefix("knownhost-") || trustSyncEnabled,
            let current = snapshot.accounts[account]?.outbox[entry.recordName],
            let record = Self.record(
              for: current,
              account: account,
              in: snapshot
            )
          else { return nil }
          return (current, record)
        }
        guard !batch.isEmpty else { continue }
        guard generation == self.generation, !Task.isCancelled,
          metadataSyncEnabled
        else { return }
        let results = try await database.save(batch.map(\.1))
        guard generation == self.generation, !Task.isCancelled else { return }
        var firstError: CloudSyncError?
        commit(generation: generation) { snapshot in
          for (entry, sent) in batch {
            switch results[entry.recordName] {
            case .success(let saved)?:
              Self.acknowledge(
                entry,
                sent: sent,
                saved: saved,
                account: account,
                in: &snapshot
              )
            case .failure(.recordMissing)?:
              conflicted = true
              snapshot.accounts[account]?.systemFields[entry.recordName] = nil
            case .failure(.conflict(let server))?:
              conflicted = true
              snapshot.accounts[account]?.systemFields[entry.recordName] =
                server.systemFields
              Self.apply(server, account: account, to: &snapshot)
            case .failure(let error)?:
              if firstError == nil { firstError = error }
            case nil: if firstError == nil { firstError = .other(-2) }
            }
          }
        }
        await applyTrustInbox(generation: generation)
        if let firstError { throw firstError }
      }
      if !conflicted { return }
    }
  }

  /// Removes the outbox entry only if it still names the revision sent.
  package static func acknowledge(
    _ entry: OutboxEntry,
    sent: CloudRecord,
    saved: CloudRecord,
    account: String,
    in snapshot: inout ConnectionSnapshot
  ) {
    snapshot.accounts[account]?.systemFields[entry.recordName] =
      saved.systemFields
    snapshot.accounts[account]?.synced[entry.recordName] = entry.revision
    if snapshot.accounts[account]?.outbox[entry.recordName]?.revision
      == entry.revision
    {
      snapshot.accounts[account]?.outbox[entry.recordName] = nil
    }
    // The agreed base is the tuple the server received, not the current
    // one: an edit made while the save was in flight is still unsent.
    if sent.type == ConnectionRecords.host,
      case .value(let host) = ConnectionRecords.decodeHost(sent)
    {
      snapshot.accounts[account]?.hostBases[host.profile.id] =
        host.deletedAt == nil ? ConnectionTuple(host.profile) : nil
    }
  }

  /// The record to send for `entry`, built from current state, or `nil`
  /// while it must not be published (conflict review, unresolved legacy
  /// label, trust sync off).
  package static func record(
    for entry: OutboxEntry,
    account: String,
    in snapshot: ConnectionSnapshot
  ) -> CloudRecord? {
    let name = entry.recordName
    guard snapshot.scopes[name] == account else { return nil }
    let tag = snapshot.accounts[account]?.systemFields[name]
    if name.hasPrefix("host-") {
      guard let id = UUID(uuidString: String(name.dropFirst(5))),
        snapshot.hostConflicts[id] == nil
      else { return nil }
      let host = snapshot.hosts.first { $0.id == id }
      let tombstone = snapshot.hostTombstones[id]
      guard let revision = tombstone?.revision ?? snapshot.hostRevisions[id],
        let fields = ConnectionRecords.encode(
          host: tombstone == nil ? host : nil,
          id: id,
          revision: revision,
          tombstone: tombstone
        )
      else { return nil }
      return CloudRecord(
        name: name,
        type: ConnectionRecords.host,
        fields: fields,
        systemFields: tag
      )
    }
    if name.hasPrefix("identity-") {
      guard let id = UUID(uuidString: String(name.dropFirst(9))),
        snapshot.identityConflicts[id] == nil,
        let identity = snapshot.identity(id)
      else { return nil }
      return CloudRecord(
        name: name,
        type: ConnectionRecords.identity,
        fields: ConnectionRecords.encode(identity: identity),
        systemFields: tag
      )
    }
    if name.hasPrefix("knownhost-"), snapshot.settings.trustSync,
      let record = snapshot.knownHosts[name]
    {
      return CloudRecord(
        name: name,
        type: ConnectionRecords.knownHost,
        fields: ConnectionRecords.encode(knownHost: record),
        systemFields: tag
      )
    }
    return nil
  }

  // MARK: Apply

  /// Applies one fetched (or conflicting server) record (§8.3).
  package static func apply(
    _ record: CloudRecord,
    account: String,
    to snapshot: inout ConnectionSnapshot
  ) {
    snapshot.accounts[account, default: AccountPartition()]
      .systemFields[record.name] = record.systemFields
    switch record.type {
    case ConnectionRecords.host:
      switch ConnectionRecords.decodeHost(record) {
      case .value(let remote):
        merge(remote, name: record.name, account: account, into: &snapshot)
      case .unsupported: keepOpaque(record, account: account, in: &snapshot)
      case .malformed(let reason):
        quarantine(record, reason, account: account, in: &snapshot)
      }
    case ConnectionRecords.identity:
      switch ConnectionRecords.decodeIdentity(record) {
      case .value(let remote):
        merge(remote, name: record.name, account: account, into: &snapshot)
      case .unsupported: keepOpaque(record, account: account, in: &snapshot)
      case .malformed(let reason):
        quarantine(record, reason, account: account, in: &snapshot)
      }
    case ConnectionRecords.knownHost:
      switch ConnectionRecords.decodeKnownHost(record) {
      case .value(let remote):
        snapshot.activateRecord(record.name, for: account)
        snapshot.observe(remote.revision)
        snapshot.scopes[record.name] = account
        snapshot.trustInbox[record.name] = remote
      case .unsupported: keepOpaque(record, account: account, in: &snapshot)
      case .malformed(let reason):
        quarantine(record, reason, account: account, in: &snapshot)
      }
    default: keepOpaque(record, account: account, in: &snapshot)
    }
  }

  package static func keepOpaque(
    _ record: CloudRecord,
    account: String,
    in snapshot: inout ConnectionSnapshot
  ) {
    guard let data = try? JSONEncoder().encode(record),
      data.count <= ConnectionRecords.maxOpaqueBytes,
      (snapshot.accounts[account]?.opaque.count ?? 0)
        < ConnectionRecords.maxOpaqueRecords
        || snapshot.accounts[account]?.opaque[record.name] != nil
    else {
      quarantine(
        record,
        "unsupported record too large",
        account: account,
        in: &snapshot
      )
      return
    }
    snapshot.accounts[account]?.opaque[record.name] = data
  }

  package static func quarantine(
    _ record: CloudRecord,
    _ reason: String,
    account: String,
    in snapshot: inout ConnectionSnapshot
  ) {
    snapshot.accounts[account]?.quarantine[record.name] =
      "\(record.type): \(reason)"
  }

  package static func merge(
    _ remote: ConnectionRecords.RemoteHost,
    name: String,
    account: String,
    into snapshot: inout ConnectionSnapshot
  ) {
    let id = remote.profile.id
    snapshot.activateRecord(name, for: account)
    snapshot.observe(remote.revision)
    snapshot.scopes[name] = account
    snapshot.accounts[account]?.synced[name] = remote.revision
    // Deletion wins for a UUID; a stale device cannot resurrect it.
    if let tombstone = snapshot.hostTombstones[id] {
      if remote.deletedAt == nil {
        snapshot.enqueue(name, revision: tombstone.revision)
      }
      return
    }
    if let deletedAt = remote.deletedAt {
      let local = snapshot.hostRevisions[id]
      snapshot.hosts.removeAll { $0.id == id }
      let revision = max(local ?? remote.revision, remote.revision)
      snapshot.hostRevisions[id] = revision
      snapshot.hostTombstones[id] = HostTombstone(
        revision: revision,
        deletedAt: deletedAt
      )
      snapshot.hostConflicts[id] = nil
      snapshot.accounts[account]?.outbox[name] = nil
      snapshot.accounts[account]?.hostBases[id] = nil
      return
    }
    let remoteTuple = ConnectionTuple(remote.profile)
    guard let index = snapshot.hosts.firstIndex(where: { $0.id == id }) else {
      guard snapshot.hosts.count < ConnectionStore.maxHosts else {
        quarantine(
          CloudRecord(name: name, type: ConnectionRecords.host, fields: [:]),
          "host limit reached",
          account: account,
          in: &snapshot
        )
        return
      }
      snapshot.hosts.append(remote.profile)
      snapshot.hostRevisions[id] = remote.revision
      snapshot.accounts[account]?.hostBases[id] = remoteTuple
      return
    }
    let local = snapshot.hosts[index]
    let localRevision = snapshot.hostRevisions[id]
    if localRevision == remote.revision {
      snapshot.accounts[account]?.hostBases[id] = remoteTuple
      return
    }
    let pending = snapshot.accounts[account]?.outbox[name] != nil
    let base = snapshot.accounts[account]?.hostBases[id]
    let localTuple = ConnectionTuple(local)
    let remoteNewer = localRevision.map { remote.revision > $0 } ?? true
    var merged = local
    if !pending {
      guard remoteNewer else {
        snapshot.enqueue(name, revision: localRevision ?? snapshot.tick())
        return
      }
      merged = remote.profile
    } else if localTuple != remoteTuple {
      let localChanged = base.map { $0 != localTuple } ?? true
      let remoteChanged = base.map { $0 != remoteTuple } ?? true
      if localChanged, remoteChanged {
        // Concurrent connection edits need review; nothing is synthesized.
        snapshot.hostConflicts[id] = HostConflict(
          remote: remote.profile,
          remoteRevision: remote.revision
        )
        return
      }
      if remoteChanged {
        merged.host = remote.profile.host
        merged.port = remote.profile.port
        merged.username = remote.profile.username
        merged.auth = remote.profile.auth
      }
      merged.nickname = remoteNewer ? remote.profile.nickname : local.nickname
    } else {
      // Same tuple: names converge by revision.
      merged.nickname = remoteNewer ? remote.profile.nickname : local.nickname
    }
    snapshot.accounts[account]?.hostBases[id] = remoteTuple
    if merged == remote.profile {
      snapshot.hosts[index] = merged
      snapshot.hostRevisions[id] = remote.revision
      snapshot.accounts[account]?.outbox[name] = nil
    } else {
      snapshot.hosts[index] = merged
      let revision = snapshot.tick()
      snapshot.hostRevisions[id] = revision
      snapshot.enqueue(name, revision: revision)
    }
  }

  package static func merge(
    _ remote: SSHIdentityMetadata,
    name: String,
    account: String,
    into snapshot: inout ConnectionSnapshot
  ) {
    if snapshot.unverifiedKeychainIdentities?.contains(remote.id) == true {
      // Keep this account's delivery without assigning ownership to the
      // older unscoped local identity. Review will reconcile matching data.
      if snapshot.accounts[account]?.cachedRecords == nil {
        snapshot.accounts[account, default: AccountPartition()].cachedRecords =
          [:]
      }
      snapshot.accounts[account]?.cachedRecords?[name] = .identity(
        metadata: remote,
        conflict: nil
      )
      snapshot.accounts[account]?.synced[name] = remote.revision
      snapshot.observe(remote.revision)
      return
    }
    snapshot.activateRecord(name, for: account)
    snapshot.observe(remote.revision)
    snapshot.scopes[name] = account
    snapshot.accounts[account]?.synced[name] = remote.revision
    guard
      let index = snapshot.identities.firstIndex(where: { $0.id == remote.id })
    else {
      guard
        remote.isDeleted
          || snapshot.identities.count(where: { !$0.isDeleted })
            < ConnectionStore.maxIdentities
      else {
        quarantine(
          CloudRecord(
            name: name,
            type: ConnectionRecords.identity,
            fields: [:]
          ),
          "key limit reached",
          account: account,
          in: &snapshot
        )
        return
      }
      snapshot.identities.append(remote)
      return
    }
    let local = snapshot.identities[index]
    // One UUID names one immutable key pair and storage policy.
    guard local.publicKey == remote.publicKey, local.storage == remote.storage,
      local.algorithm == remote.algorithm,
      local.fingerprint == remote.fingerprint
    else {
      snapshot.identityConflicts[remote.id] = remote
      return
    }
    if local.isDeleted {
      if !remote.isDeleted { snapshot.enqueue(name, revision: local.revision) }
      return
    }
    if remote.isDeleted {
      // Blocks new use. Keychain items are not deleted here: the deleting
      // device removes a synchronizable item, and device-only items are
      // never touched by remote changes.
      snapshot.identities[index].deletedAt = remote.deletedAt
      snapshot.identities[index].revision = max(local.revision, remote.revision)
      snapshot.accounts[account]?.outbox[name] = nil
      return
    }
    if remote.revision > local.revision {
      snapshot.identities[index].name = remote.name
      snapshot.identities[index].revision = remote.revision
      if let entry = snapshot.accounts[account]?.outbox[name],
        entry.revision <= remote.revision
      {
        snapshot.accounts[account]?.outbox[name] = nil
      }
    } else if remote.revision < local.revision {
      snapshot.enqueue(name, revision: local.revision)
    }
  }

  // MARK: Known hosts

  /// Applies received trust records to the local trust store. Never
  /// replaces a pinned key: conflicts and remote removals become review
  /// markers that block nothing silently (§8.3).
  private func applyTrustInbox(generation: Int) async {
    guard let app, !snapshot.trustInbox.isEmpty else { return }
    let store = app.trustFile
    // Applied to the trust file one by one, committed to the snapshot once.
    var settled:
      [(
        name: String, remote: KnownHostRecord, adopt: Bool, review: TrustReview?
      )] = []
    defer {
      if !settled.isEmpty {
        commit(generation: generation) { snapshot in
          for outcome in settled {
            let name = outcome.name
            snapshot.trustInbox[name] = nil
            if outcome.adopt,
              snapshot.knownHosts[name]?.revision ?? outcome.remote.revision
                <= outcome.remote.revision
            {
              snapshot.knownHosts[name] = outcome.remote
            }
            if let review = outcome.review {
              snapshot.trustReviews[name] = review
            }
          }
        }
      }
    }
    for (name, remote) in snapshot.trustInbox {
      guard generation == self.generation, !Task.isCancelled, trustSyncEnabled
      else { return }
      // Received trust remains quarantined with its originating account.
      guard snapshot.isVisible(name) else { continue }
      guard let endpoint = HostIdentity(host: remote.host, port: remote.port)
      else {
        settled.append((name, remote, false, nil))
        continue
      }
      let local = try? await store.trustedKey(for: endpoint)
      guard generation == self.generation, !Task.isCancelled, trustSyncEnabled
      else { return }
      var review: TrustReview?
      var adopt = false
      if remote.deletedAt != nil {
        if let local, local == remote.publicKey {
          review = TrustReview(
            recordName: name,
            host: remote.host,
            port: remote.port,
            kind: .removedElsewhere,
            localFingerprint: remote.fingerprint
          )
        }
      } else if let local {
        if local != remote.publicKey {
          review = TrustReview(
            recordName: name,
            host: remote.host,
            port: remote.port,
            kind: .conflictingKey(
              remoteKey: remote.publicKey,
              remoteFingerprint: remote.fingerprint
            ),
            localFingerprint: SSHPublicKeyFormat.fingerprint(
              openSSHPublicKey: local
            )
          )
        } else {
          adopt = true
        }
      } else {
        // Explicitly delegated trust from another of the user's devices.
        let stored = try? await store.trustKeyIfAbsent(
          remote.publicKey,
          for: endpoint
        )
        guard generation == self.generation, !Task.isCancelled, trustSyncEnabled
        else { return }
        adopt = stored == remote.publicKey
        if let stored, stored != remote.publicKey {
          review = TrustReview(
            recordName: name,
            host: remote.host,
            port: remote.port,
            kind: .conflictingKey(
              remoteKey: remote.publicKey,
              remoteFingerprint: remote.fingerprint
            ),
            localFingerprint: SSHPublicKeyFormat.fingerprint(
              openSSHPublicKey: stored
            )
          )
        } else if stored == nil {
          continue
        }
      }
      settled.append((name, remote, adopt, review))
    }
  }

  /// Resolves a review. `trustRemote` adopts another device's key only
  /// after the user verified its fingerprint; otherwise the local pin is
  /// kept (and, for a remote removal, `remove` drops it).
  public func resolve(
    _ review: TrustReview,
    trustRemote: Bool = false,
    remove: Bool = false
  ) async {
    let generation = generation
    guard let app, !Task.isCancelled, snapshot.isVisible(review.recordName),
      snapshot.trustReviews[review.recordName] == review,
      let endpoint = HostIdentity(host: review.host, port: review.port)
    else { return }
    let store = app.trustFile
    if trustRemote, case .conflictingKey(let key, let fingerprint) = review.kind
    {
      guard (try? await store.setTrustedKey(key, for: endpoint)) != nil else {
        return
      }
      commit(generation: generation) { snapshot in
        snapshot.trustReviews[review.recordName] = nil
        snapshot.recordLocalTrust(
          host: review.host,
          port: review.port,
          publicKey: key,
          fingerprint: fingerprint
        )
      }
    } else if remove {
      guard (try? await store.removeTrustedKey(for: endpoint)) != nil else {
        return
      }
      commit(generation: generation) { snapshot in
        snapshot.trustReviews[review.recordName] = nil
        snapshot.recordLocalTrustRemoval(host: review.host, port: review.port)
      }
    } else {
      commit(generation: generation) {
        $0.trustReviews[review.recordName] = nil
      }
    }
    refresh()
  }

  /// Resolves a connection-tuple conflict by keeping this device's version
  /// (re-sent with a newer revision) or adopting the other device's.
  public func resolveConflict(host id: UUID, keepLocal: Bool) {
    guard snapshot.isVisible(ConnectionSnapshot.hostRecord(id)) else { return }
    commit(generation: generation) { snapshot in
      guard let conflict = snapshot.hostConflicts[id] else { return }
      snapshot.hostConflicts[id] = nil
      let name = ConnectionSnapshot.hostRecord(id)
      if let account = snapshot.scopes[name] {
        snapshot.accounts[account]?.hostBases[id] = ConnectionTuple(
          conflict.remote
        )
      }
      if keepLocal {
        let revision = snapshot.tick()
        snapshot.hostRevisions[id] = revision
        snapshot.enqueue(name, revision: revision)
      } else if let index = snapshot.hosts.firstIndex(where: { $0.id == id }) {
        snapshot.hosts[index] = conflict.remote
        snapshot.hostRevisions[id] = conflict.remoteRevision
        if let account = snapshot.scopes[name] {
          snapshot.accounts[account]?.outbox[name] = nil
        }
      }
    }
    refresh()
  }
}
