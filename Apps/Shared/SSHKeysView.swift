import SSHIdentity
import SwiftUI
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Settings → SSH Keys (spec.ssh-identity.md §4.1): every identity with
/// its algorithm, fingerprint, storage and local availability.
public struct SSHKeysView: View {
  @Bindable
  var model: RoamingAppModel
  @State
  private var creating: KeyCreationMode?
  @State
  private var deletionReview: LegacyKeyDeletionReview?
  @State
  private var availability: [UUID: IdentityAvailability] = [:]
  @State
  private var orphans: [Orphan] = []

  struct Orphan: Identifiable, Hashable {
    let id: UUID
    let policy: IdentityStoragePolicy
  }

  public init(model: RoamingAppModel) { self.model = model }

  public var body: some View {
    List {
      if model.identities.isEmpty {
        ContentUnavailableView(
          .localized("No SSH Keys"),
          systemImage: "key",
          description: Text(
            """
            Generate a key here, then add its public key to ~/.ssh/authorized_keys \
            on the Mac.
            """,
            bundle: #bundle
          )
        )
        .listRowBackground(Color.clear)
      }
      ForEach(model.identities) { identity in
        NavigationLink {
          SSHKeyDetailView(model: model, id: identity.id)
        } label: {
          IdentityRow(
            identity: identity,
            availability: availability[identity.id]
          )
        }
      }
      .listRowBackground(Color.clear)
      if !model.keyAccountReviews.isEmpty {
        Section {
          ForEach(model.keyAccountReviews) { identity in
            IdentityAccountReviewRow(model: model, identity: identity)
          }
        } header: {
          Text("Keys Needing Account Review", bundle: #bundle)
        } footer: {
          Text(
            """
            These older keys have no saved iCloud account. Restore a matching key \
            in the current account to use it again. Metadata sync remains a \
            separate choice.
            """,
            bundle: #bundle
          )
        }
        .listRowBackground(Color.clear)
      }
      if !model.keyDeletionReviews.isEmpty {
        Section {
          ForEach(model.keyDeletionReviews) { intent in
            LegacyKeyDeletionRow(model: model, intent: intent) {
              deletionReview = $0
            }
          }
        } header: {
          Text("Key Removals Needing Review", bundle: #bundle)
        } footer: {
          Text(
            "An interrupted removal has no saved account information. Review the matching key before authorizing removal from the current account.",
            bundle: #bundle
          )
        }
        .listRowBackground(Color.clear)
      }
      if !orphans.isEmpty {
        Section {
          ForEach(orphans) { orphan in
            OrphanRow(model: model, orphan: orphan) { Task { await reload() } }
          }
        } header: {
          Text("Unrecognized Keychain Keys", bundle: #bundle)
        } footer: {
          Text(
            """
            Swiftty keys with no saved description, for example after an interrupted \
            operation. Nothing uses them until you restore them.
            """,
            bundle: #bundle
          )
        }
        .listRowBackground(Color.clear)
      }
    }
    .glassListBackground().navigationTitle(.localized("SSH Keys"))
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Menu {
          Button(.localized("Generate Key…"), systemImage: "key") {
            creating = .generate
          }
          .accessibilityIdentifier("keys.generate")
          if model.profile.keyImport {
            Button(
              .localized("Import Key…"),
              systemImage: "square.and.arrow.down"
            ) { creating = .importKey }
            .accessibilityIdentifier("keys.import")
          }
        } label: {
          Label(.localized("Add Key"), systemImage: "plus")
        }
        .accessibilityIdentifier("keys.add")
      }
    }
    .adaptiveSheet(item: $creating) { mode in
      KeyCreationView(model: model, mode: mode) { _ in creating = nil }
        .macSheetFrame(width: 480, height: 460)
    }
    .adaptiveSheet(item: $deletionReview) { review in
      LegacyKeyDeletionView(model: model, review: review)
        .macSheetFrame(width: 540, height: 420)
    }
    .task(id: model.identities) { await reload() }
  }

  private func reload() async {
    var next: [UUID: IdentityAvailability] = [:]
    for identity in model.identities {
      next[identity.id] = await model.identityStore.availability(identity.id)
    }
    availability = next
    orphans = await model.identityStore.orphans()
      .map { Orphan(id: $0.id, policy: $0.policy) }
  }
}

struct IdentityRow: View {
  let identity: SSHIdentityMetadata
  let availability: IdentityAvailability?

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(identity.name).font(.headline)
      Text(identity.fingerprint).font(.caption.monospaced())
        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
      HStack(spacing: 6) {
        Text(verbatim: "Ed25519")
        Text(verbatim: "·")
        Label(
          identity.storage.displayName,
          systemImage: identity.storage == .iCloudKeychain ? "icloud" : "iphone"
        )
        if let availability, availability != .available {
          Text(verbatim: "·")
          Text(availability.summary).foregroundStyle(.orange)
        }
      }
      .font(.caption).foregroundStyle(.secondary)
    }
  }
}

private struct OrphanRow: View {
  let model: RoamingAppModel
  let orphan: SSHKeysView.Orphan
  let changed: () -> Void
  @State
  private var name = "Recovered key"
  @State
  private var confirmingDelete = false
  @State
  private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      TextField(.localized("Name"), text: $name)
      Text(orphan.policy.displayName).font(.caption).foregroundStyle(.secondary)
      HStack {
        Button(.localized("Restore")) {
          Task {
            do throws(IdentityOperationError) {
              try await model.identityStore.adoptOrphan(
                orphan.id,
                policy: orphan.policy,
                name: name
              )
              changed()
            } catch { self.error = error.message }
          }
        }
        // Only a device-only item can be deleted here; an iCloud item may
        // be another device's key whose details have not arrived.
        if orphan.policy == .deviceOnly {
          Button(.localized("Delete"), role: .destructive) {
            confirmingDelete = true
          }
        }
      }
      .glassButtonStyle()
      .confirmationDialog(
        .localized("Delete this unrecognized key?"),
        isPresented: $confirmingDelete,
        titleVisibility: .visible
      ) {
        Button(.localized("Delete"), role: .destructive) {
          Task {
            do throws(IdentityOperationError) {
              try await model.identityStore.deleteOrphan(
                orphan.id,
                policy: orphan.policy
              )
              changed()
            } catch { self.error = error.message }
          }
        }
      } message: {
        Text(
          """
          The private key is removed from this device's Keychain and can't be \
          recovered. Restore it instead if a server still trusts it.
          """,
          bundle: #bundle
        )
      }
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
    }
  }
}

/// One identity: rename, public-key copy and export, referencing hosts,
/// storage changes and deletion.
struct SSHKeyDetailView: View {
  @Bindable
  var model: RoamingAppModel
  let id: UUID
  private struct Selection: Equatable {
    var identity: SSHIdentityMetadata?
    let accountGeneration: Int
  }
  @State
  private var selection: Selection
  @State
  private var name = ""
  @State
  private var availability: IdentityAvailability?
  @State
  private var confirmingDelete = false
  @State
  private var confirmingCopy = false
  @State
  private var confirmingWithdraw = false
  @State
  private var repairing = false
  /// A chosen repair file that needs its passphrase.
  @State
  private var repairData: Data?
  @State
  private var repairPassphrase = ""
  @State
  private var error: String?
  @State
  private var working = false
  /// Hosts that use this key, cached so typing a name does not refilter
  /// every host on each redraw.
  @State
  private var referencing: [HostProfile] = []
  @Environment(\.dismiss)
  private var dismiss

  init(model: RoamingAppModel, id: UUID) {
    self.model = model
    self.id = id
    let identity = model.identities.first { $0.id == id }
    _selection = State(
      initialValue: Selection(
        identity: identity,
        accountGeneration: model.accountGeneration
      )
    )
    _name = State(initialValue: identity?.name ?? "")
  }

  private var selectionIsCurrent: Bool {
    selection.identity != nil
      && selection.accountGeneration == model.accountGeneration
      && model.identities.first { $0.id == id } == selection.identity
  }

  private var identity: SSHIdentityMetadata? {
    selectionIsCurrent ? selection.identity : nil
  }

  private func currentReferencing() -> [HostProfile] {
    model.hosts.filter { $0.auth.identityID == id }
  }

  var body: some View {
    dialogs(
      form.glassListBackground()
        .navigationTitle(
          identity.map { Text($0.name) } ?? Text("Key", bundle: #bundle)
        )
        .disabled(working)
        .task(id: identity) {
          guard selectionIsCurrent else { return }
          let value = await model.identityStore.availability(id)
          guard selectionIsCurrent, !Task.isCancelled else { return }
          availability = value
        }
        .onChange(of: selectionIsCurrent) {
          guard !selectionIsCurrent else { return }
          selection.identity = nil
          confirmingDelete = false
          confirmingCopy = false
          confirmingWithdraw = false
          repairing = false
          repairData = nil
          repairPassphrase = ""
          name = ""
          availability = nil
          error = nil
        }
        .onChange(of: model.hosts, initial: true) {
          let hosts = currentReferencing()
          if hosts != referencing { referencing = hosts }
        }
    )
  }

  private var form: some View {
    Form {
      if let identity {
        if let error {
          Text(error).foregroundStyle(.red).listRowBackground(Color.clear)
        }
        Section(.localized("Name")) {
          TextField(.localized("Name"), text: $name).onSubmit(rename)
            .accessibilityIdentifier("key.name")
        }
        .listRowBackground(Color.clear)
        KeyDetailsSection(identity: identity, availability: availability)
        PublicKeySection(identity: identity)
        KeyUsedBySection(hosts: referencing)
        KeyActionsSection(
          identity: identity,
          availability: availability,
          profile: model.profile,
          repairing: $repairing,
          confirmingCopy: $confirmingCopy,
          confirmingWithdraw: $confirmingWithdraw,
          confirmingDelete: $confirmingDelete
        )
      } else {
        ContentUnavailableView(
          .localized("Key Changed"),
          systemImage: "key.slash",
          description: Text(
            "Return to SSH Keys and open the key again to review its current details.",
            bundle: #bundle
          )
        )
        .accessibilityIdentifier("key.detailUnavailable")
        .listRowBackground(Color.clear)
      }
    }
  }

  private func dialogs(_ content: some View) -> some View {
    deletion(storageChanges(content))
  }

  private func deletion(_ content: some View) -> some View {
    content.confirmationDialog(
      deleteTitle,
      isPresented: $confirmingDelete,
      titleVisibility: .visible
    ) {
      Button(.localized("Delete"), role: .destructive) {
        run { try await model.identityStore.delete(id) }
      }
      .accessibilityIdentifier("key.confirmDelete")
    } message: {
      deleteMessage
    }
    .keyFileImporter(isPresented: $repairing) { data in
      guard let data else { return }
      repair(data, passphrase: nil)
    }
    .alert(
      .localized("Key Passphrase"),
      isPresented: Binding(
        get: { repairData != nil },
        set: {
          if !$0 {
            repairData = nil
            repairPassphrase = ""
          }
        }
      )
    ) {
      SecureField(.localized("Passphrase"), text: $repairPassphrase)
      Button(.localized("Repair")) {
        guard let data = repairData else { return }
        let passphrase = repairPassphrase
        repairData = nil
        repairPassphrase = ""
        repair(data, passphrase: passphrase)
      }
      Button(.localized("Cancel"), role: .cancel) {}
    } message: {
      Text(
        "This key file is protected by a passphrase. It is not saved.",
        bundle: #bundle
      )
    }
  }

  private func repair(_ data: Data, passphrase: String?) {
    run {
      do throws(IdentityOperationError) {
        try await model.identityStore.repair(
          id,
          with: data,
          passphrase: passphrase
        )
      } catch .importFailed(.passphraseRequired) {
        if selectionIsCurrent { repairData = data }
      }
    }
  }

  private func storageChanges(_ content: some View) -> some View {
    content.confirmationDialog(
      "Create an iCloud copy?",
      isPresented: $confirmingCopy,
      titleVisibility: .visible
    ) {
      Button(.localized("Create Copy and Use It for These Hosts")) {
        run {
          _ = try await model.identityStore.createICloudCopy(
            of: id,
            name: copyName,
            reassign: currentReferencing().map(\.id)
          )
        }
      }
      Button(.localized("Create Copy Only")) {
        run {
          _ = try await model.identityStore.createICloudCopy(
            of: id,
            name: copyName,
            reassign: []
          )
        }
      }
    } message: {
      Text(
        """
        The same private key is saved again as a new key that syncs with iCloud \
        Keychain to your other devices. This device-only key stays until you \
        delete it.
        """,
        bundle: #bundle
      )
    }
    .confirmationDialog(
      .localized("Withdraw from iCloud?"),
      isPresented: $confirmingWithdraw,
      titleVisibility: .visible
    ) {
      Button(.localized("Keep on This Device Only"), role: .destructive) {
        run {
          _ = try await model.identityStore.withdrawFromICloud(
            id,
            name: identity?.name ?? "Key",
            reassign: currentReferencing().map(\.id)
          )
          dismiss()
        }
      }
    } message: {
      Text(
        """
        A device-only copy is saved first and these hosts move to it. Then the \
        iCloud key is deleted, which removes it from your other devices over \
        time. This does not revoke the key on any server, and copies made \
        elsewhere may remain.
        """,
        bundle: #bundle
      )
    }
  }

  private var copyName: String {
    let base = identity?.name ?? "Key"
    let candidate = base + " (iCloud)"
    return SSHIdentityMetadata.isValidName(candidate) ? candidate : base
  }

  private var deleteTitle: LocalizedStringResource {
    identity?.storage == .iCloudKeychain
      ? .localized("Delete this iCloud key?")
      : .localized("Delete this device-only key?")
  }

  private var deleteMessage: Text {
    let removal =
      switch (identity?.storage, availability) {
      case (.iCloudKeychain, _):
        Text(
          """
          Deletion propagates to your other devices that use iCloud Keychain, \
          which can take time. It is not removed from any server's authorized_keys.
          """,
          bundle: #bundle
        )
      case (_, .unavailableOnThisDevice?):
        // A device-only key held elsewhere: the tombstone still syncs.
        Text(
          """
          This key's private half is on another device. Deleting it here also \
          deletes it there once synced, and hosts there that use it will stop \
          connecting. It is not removed from any server's authorized_keys.
          """,
          bundle: #bundle
        )
      default:
        Text(
          """
          The private key is removed from this device. It is not removed from \
          any server's authorized_keys.
          """,
          bundle: #bundle
        )
      }
    guard !referencing.isEmpty else { return removal }
    let hosts = Text(
      """
      \(referencing.count) hosts keep this key selected and will not connect \
      until you choose another key.
      """,
      bundle: #bundle,
      comment: "Plural: the number of saved hosts that still use the key."
    )
    return Text("\(removal) \(hosts)", bundle: #bundle)
  }

  private func rename() {
    guard let identity, name != identity.name else { return }
    do throws(IdentityOperationError) {
      try model.identityStore.rename(id, to: name)
      selection.identity = model.identity(id)
    } catch {
      self.error = error.message
      name = identity.name
    }
  }

  private func run(_ work: @escaping @MainActor () async throws -> Void) {
    guard selectionIsCurrent else { return }
    working = true
    error = nil
    Task {
      defer { working = false }
      // The task may start after an account switch or metadata delivery.
      guard selectionIsCurrent else { return }
      do { try await work() } catch {
        guard selectionIsCurrent else { return }
        self.error =
          (error as? IdentityOperationError)?.message
          ?? "The key could not be changed."
      }
      guard selectionIsCurrent else { return }
      let value = await model.identityStore.availability(id)
      if selectionIsCurrent { availability = value }
    }
  }
}

private struct KeyDetailsSection: View {
  let identity: SSHIdentityMetadata
  let availability: IdentityAvailability?

  var body: some View {
    Section {
      LabeledContent(.localized("Algorithm"), value: "Ed25519")
      LabeledContent {
        Text(identity.storage.displayName)
      } label: {
        Text("Storage", bundle: #bundle)
      }
      LabeledContent {
        Text(
          availability?.summary
            ?? String(localized: "Checking…", bundle: #bundle)
        )
      } label: {
        Text("Status", bundle: #bundle)
      }
      VStack(alignment: .leading, spacing: 4) {
        Text("Fingerprint", bundle: #bundle).font(.caption)
          .foregroundStyle(.secondary)
        Text(identity.fingerprint).font(.body.monospaced())
          .selectableIfSupported()
      }
    } footer: {
      Text(storageExplanation)
    }
    .listRowBackground(Color.clear)
  }

  private var storageExplanation: LocalizedStringResource {
    switch identity.storage {
    case .deviceOnly:
      .localized("Stored in this device's Keychain and never synchronized.")
    case .iCloudKeychain:
      .localized(
        """
        Synced by iCloud Keychain, which the system manages. Saving it here does \
        not confirm another device has received it.
        """
      )
    }
  }
}

private struct PublicKeySection: View {
  let identity: SSHIdentityMetadata

  var body: some View {
    Section {
      Text(identity.authorizedKeysLine).font(.caption.monospaced())
        .selectableIfSupported().accessibilityIdentifier("key.public")
      #if !os(tvOS)
      Button(.localized("Copy Public Key"), systemImage: "doc.on.doc") {
        Pasteboard.copy(identity.authorizedKeysLine)
      }
      ShareLink(item: identity.authorizedKeysLine) {
        Label(
          .localized("Export Public Key"),
          systemImage: "square.and.arrow.up"
        )
      }
      #endif
    } header: {
      Text("Public Key", bundle: #bundle)
    } footer: {
      Text(
        """
        Add this line to ~/.ssh/authorized_keys on each Mac. Swiftty never \
        installs it for you.
        """,
        bundle: #bundle
      )
    }
    .listRowBackground(Color.clear)
  }
}

private struct KeyUsedBySection: View {
  let hosts: [HostProfile]

  var body: some View {
    Section(.localized("Used By")) {
      if hosts.isEmpty {
        Text("No hosts", bundle: #bundle).foregroundStyle(.secondary)
      }
      ForEach(hosts) { host in
        Text("\(host.nickname) — \(host.endpointSummary)", bundle: #bundle)
      }
    }
    .listRowBackground(Color.clear)
  }
}

private struct KeyActionsSection: View {
  let identity: SSHIdentityMetadata
  let availability: IdentityAvailability?
  let profile: PlatformProfile
  @Binding
  var repairing: Bool
  @Binding
  var confirmingCopy: Bool
  @Binding
  var confirmingWithdraw: Bool
  @Binding
  var confirmingDelete: Bool

  var body: some View {
    Section {
      if availability != .available, availability != nil, profile.keyImport {
        Button(
          .localized("Repair by Importing This Key…"),
          systemImage: "wrench.and.screwdriver"
        ) { repairing = true }
      }
      if profile.cloudSync, availability == .available {
        switch identity.storage {
        case .deviceOnly:
          Button(
            .localized("Create iCloud Copy…"),
            systemImage: "icloud.and.arrow.up"
          ) { confirmingCopy = true }
        case .iCloudKeychain:
          Button(
            .localized("Withdraw from iCloud…"),
            systemImage: "icloud.slash"
          ) { confirmingWithdraw = true }
        }
      }
      Button(
        .localized("Delete Key…"),
        systemImage: "trash",
        role: .destructive
      ) { confirmingDelete = true }
      .accessibilityIdentifier("key.delete")
    }
    .listRowBackground(Color.clear)
  }
}

enum KeyCreationMode: String, Identifiable, Hashable {
  case generate
  case importKey
  var id: String { rawValue }
}

/// Generate: name, storage, confirm; then show the public key. Import: a
/// chosen file or an explicit paste, the parsed algorithm and fingerprint
/// for confirmation, then save. Imported text is only ever parsed as a key.
struct KeyCreationView: View {
  let model: RoamingAppModel
  let mode: KeyCreationMode
  let finish: (SSHIdentityMetadata?) -> Void
  @State
  private var name = ""
  @State
  private var policy: IdentityStoragePolicy = .deviceOnly
  @State
  private var keyData: Data?
  @State
  private var inspection: OpenSSHKeyInspection?
  /// Opens an encrypted key once, on save; never stored.
  @State
  private var passphrase = ""
  @State
  private var choosingFile = false
  @State
  private var error: String?
  @State
  private var working: Task<Void, Never>?
  @State
  private var created: SSHIdentityMetadata?
  @Environment(\.scenePhase)
  private var scenePhase

  var body: some View {
    NavigationStack {
      Form {
        if let error {
          Text(error).foregroundStyle(.red).listRowBackground(Color.clear)
            .accessibilityIdentifier("key.error")
        }
        if let created {
          createdSection(created)
        } else {
          if mode == .importKey { importSection }
          Section(.localized("Name")) {
            TextField(.localized("Name"), text: $name)
              .accessibilityIdentifier("key.new.name")
          }
          .listRowBackground(Color.clear)
          if model.profile.cloudSync {
            Section {
              Picker(.localized("Storage"), selection: $policy) {
                ForEach(IdentityStoragePolicy.allCases, id: \.self) {
                  Text($0.displayName).tag($0)
                }
              }
              .accessibilityIdentifier("key.new.storage")
            } footer: {
              Text(
                policy == .deviceOnly
                  ? "The private key never leaves this device."
                  : """
                  iCloud Keychain syncs the private key, end-to-end encrypted, to \
                  your devices signed in to the same Apple Account. This choice \
                  can't be changed later.
                  """
              )
            }
            .listRowBackground(Color.clear)
          }
        }
      }
      .glassListBackground()
      .navigationTitle(
        mode == .generate
          ? .localized("Generate Key") : .localized("Import Key")
      )
      .toolbar {
        if created == nil {
          ToolbarItem(placement: .cancellationAction) {
            Button(.localized("Cancel")) { close(nil) }
          }
          ToolbarItem(placement: .confirmationAction) {
            Button(
              mode == .generate ? .localized("Generate") : .localized("Save"),
              action: save
            )
            .disabled(
              working != nil || name.isEmpty
                || (mode == .importKey && inspection == nil)
                || (inspection?.isEncrypted == true && passphrase.isEmpty)
            )
            .accessibilityIdentifier("key.new.save")
          }
        } else {
          ToolbarItem(placement: .confirmationAction) {
            Button(.localized("Done")) { close(created) }
              .accessibilityIdentifier("key.new.done")
          }
        }
      }
      .keyFileImporter(isPresented: $choosingFile) { data in
        guard let data else {
          error = OpenSSHImportError.inputTooLarge.message
          return
        }
        load(data)
      }
    }
    .privacyShield(when: scenePhase != .active)
  }

  private var importSection: some View {
    Section {
      Button(.localized("Choose Key File…"), systemImage: "doc") {
        choosingFile = true
      }
      .accessibilityIdentifier("key.import.file")
      #if !os(tvOS)
      PasteButton(payloadType: String.self) { strings in
        guard let first = strings.first else { return }
        load(Data(first.utf8.prefix(OpenSSHKeyImporter.maxInputBytes + 1)))
      }
      #endif
      if let inspection {
        LabeledContent(.localized("Algorithm"), value: "Ed25519")
        VStack(alignment: .leading, spacing: 4) {
          Text("Fingerprint", bundle: #bundle).font(.caption)
            .foregroundStyle(.secondary)
          Text(inspection.fingerprint).font(.body.monospaced())
            .accessibilityIdentifier("key.import.fingerprint")
        }
        let existing = model.identityStore.identities(
          withFingerprint: inspection.fingerprint
        )
        if let first = existing.first {
          Label {
            Text(
              "Same key as \u{201C}\(first.name)\u{201D}. Saving creates a separate entry.",
              bundle: #bundle
            )
          } icon: {
            Image(systemName: "exclamationmark.triangle")
          }
          .foregroundStyle(.orange)
        }
        if inspection.isEncrypted {
          SecureField(.localized("Passphrase"), text: $passphrase)
            .textContentType(.password).onSubmit(save)
            .accessibilityIdentifier("key.import.passphrase")
        }
      }
    } header: {
      Text("Private Key", bundle: #bundle)
    } footer: {
      Text(
        """
        OpenSSH Ed25519 keys, with or without a passphrase. A passphrase only \
        decrypts the key here and is not saved. The key is stored in the \
        Keychain; delete the original file afterwards if you no longer need it.
        """,
        bundle: #bundle
      )
    }
    .listRowBackground(Color.clear)
  }

  private func createdSection(_ identity: SSHIdentityMetadata) -> some View {
    Section {
      Text(identity.authorizedKeysLine).font(.caption.monospaced())
        .selectableIfSupported().accessibilityIdentifier("key.new.public")
      #if !os(tvOS)
      Button(.localized("Copy Public Key"), systemImage: "doc.on.doc") {
        Pasteboard.copy(identity.authorizedKeysLine)
      }
      ShareLink(item: identity.authorizedKeysLine) {
        Label(
          .localized("Export Public Key"),
          systemImage: "square.and.arrow.up"
        )
      }
      #endif
    } header: {
      Text("Key Saved", bundle: #bundle)
    } footer: {
      Text(
        """
        Before you can sign in, add this line to ~/.ssh/authorized_keys on the \
        Mac. Creating a key does not install it anywhere.
        """,
        bundle: #bundle
      )
    }
    .listRowBackground(Color.clear)
  }

  private func load(_ data: Data) {
    error = nil
    inspection = nil
    keyData = nil
    passphrase = ""
    Task {
      do throws(IdentityOperationError) {
        let parsed = try await model.identityStore.inspect(data)
        inspection = parsed
        keyData = data
        if name.isEmpty, let comment = parsed.comment,
          SSHIdentityMetadata.isValidName(comment)
        {
          name = comment
        }
      } catch { self.error = error.message }
    }
  }

  private func save() {
    guard working == nil else { return }
    let name = name.trimmingCharacters(in: .whitespaces)
    error = nil
    working = Task {
      defer { working = nil }
      do throws(IdentityOperationError) {
        let identity: SSHIdentityMetadata
        switch mode {
        case .generate:
          identity = try await model.identityStore.generate(
            name: name,
            policy: policy
          )
        case .importKey:
          guard let keyData else { return }
          identity = try await model.identityStore.importKey(
            keyData,
            passphrase: inspection?.isEncrypted == true ? passphrase : nil,
            name: name,
            policy: policy
          )
          self.keyData = nil
          passphrase = ""
        }
        guard !Task.isCancelled else { return }
        created = identity
      } catch { self.error = error.message }
    }
  }

  private func close(_ identity: SSHIdentityMetadata?) {
    // Cancelling an in-flight save prevents late persistence.
    working?.cancel()
    keyData = nil
    inspection = nil
    passphrase = ""
    finish(identity)
  }
}

extension View {
  /// A user-selected key file, read with a size bound. tvOS has no key
  /// import in the first release (spec.ssh-identity.md §3.2).
  func keyFileImporter(
    isPresented: Binding<Bool>,
    onRead: @escaping (Data?) -> Void
  ) -> some View {
    #if os(tvOS)
    self
    #else
    fileImporter(
      isPresented: isPresented,
      allowedContentTypes: [.item],
      allowsMultipleSelection: false
    ) { result in
      guard case let .success(urls) = result, let url = urls.first else {
        return
      }
      onRead(KeyFile.read(url))
    }
    #endif
  }
}

/// Bounded reads of a user-chosen key file through its security scope.
enum KeyFile {
  static func read(_ url: URL) -> Data? {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    return try? BoundedFile.readIfPresent(
      url,
      limit: OpenSSHKeyImporter.maxInputBytes
    )
  }
}

/// Explicit copy of public text.
enum Pasteboard {
  static func copy(_ text: String) {
    #if os(tvOS)
    #elseif canImport(UIKit)
    UIPasteboard.general.string = text
    #elseif canImport(AppKit)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #endif
  }
}

/// Settings → Sync (§4.3): separate opt-ins and honest status.
public struct SyncSettingsView: View {
  @Bindable
  var model: RoamingAppModel
  @State
  private var error: String?
  @State
  private var working = false

  public init(model: RoamingAppModel) { self.model = model }

  public var body: some View {
    Form {
      if let sync = model.sync {
        if let error {
          Text(error).foregroundStyle(.red).listRowBackground(Color.clear)
        }
        Section {
          Toggle(
            .localized("Sync profiles and key metadata"),
            isOn: metadataBinding(sync)
          )
          .accessibilityIdentifier("sync.metadata")
          LabeledContent(.localized("Status"), value: sync.status.summary)
          Button(.localized("Refresh"), systemImage: "arrow.clockwise") {
            Task { await model.refreshConnections() }
          }
          .disabled(!sync.metadataSyncEnabled)
        } footer: {
          Text(
            """
            Syncs host names, addresses, usernames, key names and public keys to \
            your private iCloud database. These are not private keys, but are \
            still sensitive. Private keys sync only for keys you saved to iCloud \
            Keychain; turning this off does not change that, and does not delete \
            anything from iCloud.
            """,
            bundle: #bundle
          )
        }
        .listRowBackground(Color.clear)
        Section {
          Toggle(.localized("Sync trusted hosts"), isOn: trustBinding(sync))
            .disabled(!sync.metadataSyncEnabled)
            .accessibilityIdentifier("sync.trust")
        } footer: {
          Text(
            """
            Lets your devices accept host keys you trusted on another device. A \
            different key for a trusted host is never accepted automatically.
            """,
            bundle: #bundle
          )
        }
        .listRowBackground(Color.clear)
        accountSection(sync)
        reviews(sync)
      } else {
        Text(
          model.profile.cloudSync
            ? "This build is not configured for iCloud sync."
            : "iCloud sync is not available on this device."
        )
        .foregroundStyle(.secondary).listRowBackground(Color.clear)
      }
    }
    .glassListBackground().navigationTitle(.localized("iCloud Sync"))
    .disabled(working)
  }

  @ViewBuilder
  private func accountSection(_ sync: ConnectionSyncCoordinator) -> some View {
    if sync.status == .accountChanged {
      Section {
        Button(.localized("Sync This Device's Data with the Current Account")) {
          run { try await sync.confirmCurrentAccount() }
        }
      } footer: {
        Text(
          """
          The iCloud account changed. Data synced with the previous account is \
          hidden on this device and is not uploaded to the new one.
          """,
          bundle: #bundle
        )
      }
      .listRowBackground(Color.clear)
    }
    if sync.status == .zoneRecoveryRequired {
      Section {
        Button(.localized("Upload This Device's Data Again")) {
          run { try await sync.recoverZone() }
        }
      } footer: {
        Text("Swiftty's synced data was removed from iCloud.", bundle: #bundle)
      }
      .listRowBackground(Color.clear)
    }
    if model.hiddenCount > 0 {
      Section {
        Text(
          "\(model.hiddenCount) items from another iCloud account are hidden.",
          bundle: #bundle,
          comment:
            "Plural: the number of synced items hidden from this account."
        )
        .foregroundStyle(.secondary)
      }
      .listRowBackground(Color.clear)
    }
  }

  @ViewBuilder
  private func reviews(_ sync: ConnectionSyncCoordinator) -> some View {
    let conflicts = model.hostConflicts
    if !conflicts.isEmpty {
      let localHosts = Dictionary(
        model.hosts.map { ($0.id, $0) },
        uniquingKeysWith: { first, _ in first }
      )
      Section(.localized("Conflicting Host Changes")) {
        ForEach(conflicts) { item in
          let id = item.id
          let conflict = item.conflict
          VStack(alignment: .leading, spacing: 6) {
            let local = localHosts[id]
            Text(local?.nickname ?? conflict.remote.nickname).font(.headline)
            Text(
              "This device: \(local?.endpointSummary ?? "—")",
              bundle: #bundle
            )
            .font(.caption)
            Text(
              "Other device: \(conflict.remote.endpointSummary)",
              bundle: #bundle
            )
            .font(.caption)
            HStack {
              Button(.localized("Keep This Device's")) {
                sync.resolveConflict(host: id, keepLocal: true)
              }
              Button(.localized("Use Other Device's")) {
                sync.resolveConflict(host: id, keepLocal: false)
              }
            }
            .glassButtonStyle()
          }
        }
      }
      .listRowBackground(Color.clear)
    }
    let trust = model.trustReviews
    if !trust.isEmpty {
      Section(.localized("Trusted Host Reviews")) {
        ForEach(trust) { review in
          VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "\(review.host):\(review.port)").font(.headline)
            switch review.kind {
            case .conflictingKey(_, let fingerprint):
              Text("Another device trusts a different key:", bundle: #bundle)
                .font(.caption)
              Text(fingerprint).font(.caption.monospaced())
              Text(
                "This device: \(review.localFingerprint ?? "—")",
                bundle: #bundle
              )
              .font(.caption.monospaced())
              HStack {
                Button(.localized("Keep This Device's Key")) {
                  Task { await sync.resolve(review) }
                }
                Button(.localized("Trust Other Key (Verified)")) {
                  Task { await sync.resolve(review, trustRemote: true) }
                }
              }
              .glassButtonStyle()
            case .removedElsewhere:
              Text(
                "Another device stopped trusting this host's key.",
                bundle: #bundle
              )
              .font(.caption)
              HStack {
                Button(.localized("Keep Trusting")) {
                  Task { await sync.resolve(review) }
                }
                Button(.localized("Remove Trust"), role: .destructive) {
                  Task { await sync.resolve(review, remove: true) }
                }
              }
              .glassButtonStyle()
            }
          }
        }
      }
      .listRowBackground(Color.clear)
    }
  }

  private func metadataBinding(
    _ sync: ConnectionSyncCoordinator
  ) -> Binding<Bool> {
    Binding(
      get: { sync.metadataSyncEnabled },
      set: { enabled in run { try await sync.setMetadataSync(enabled) } }
    )
  }

  private func trustBinding(_ sync: ConnectionSyncCoordinator) -> Binding<Bool>
  {
    Binding(
      get: { sync.trustSyncEnabled },
      set: { enabled in
        run {
          let keys =
            enabled ? ((try? await model.ssh.trustFile.entries()) ?? [:]) : [:]
          guard sync.setTrustSync(enabled, trustedKeys: keys) else {
            throw CloudSyncError.settingsNotSaved
          }
        }
      }
    )
  }

  private func run(_ work: @escaping @MainActor () async throws -> Void) {
    working = true
    error = nil
    Task {
      defer { working = false }
      do { try await work() } catch {
        self.error =
          (error as? CloudSyncError)?.message ?? "iCloud sync failed."
      }
    }
  }
}
