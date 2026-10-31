import SwiftUI

/// Saved hosts. Focus-friendly: every row is a single button, and
/// destructive actions live in a context menu (available on tvOS too).
public struct HostListView: View {
  @Bindable
  var model: RoamingAppModel
  @State
  private var editing: HostMutationContext?
  @State
  private var adding = false
  @State
  private var browsing: HostConnectionSelection?
  /// The workspace chooser for a tapped host (pairing lives in Settings).
  @State
  private var connecting: ConnectSheet?

  public init(model: RoamingAppModel) { self.model = model }

  public var body: some View {
    List {
      if let error = model.lastError {
        Label(error, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.orange).listRowBackground(Color.clear)
      }
      if model.hosts.isEmpty {
        ContentUnavailableView(
          .localized("No Hosts"),
          systemImage: "server.rack",
          description: Text(
            "Add a Mac with Remote Login enabled, or pair one in Settings.",
            bundle: #bundle
          )
        )
        .listRowBackground(Color.clear)
      }
      ForEach(model.hosts) { host in
        HostRow(
          host: host,
          context: model.hostMutationContext(for: host),
          authSummary: model.authSummary(for: host),
          isResumable: model.resumableHosts.contains(host.id),
          model: model,
          connecting: $connecting,
          editing: $editing,
          browsing: $browsing
        )
      }
      .listRowBackground(Color.clear)
    }
    .glassListBackground().navigationTitle(.localized("Hosts"))
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          adding = true
        } label: {
          Label(.localized("Add Host"), systemImage: "plus")
        }
        .accessibilityIdentifier("hosts.add").addHostShortcut()
      }
    }
    #if !os(tvOS)
    .adaptiveSheet(item: $browsing) { selection in
      SFTPBrowserView(selection: selection, app: model)
      .macSheetFrame(width: 560, height: 480)
    }
    #endif
    .hostEditorPresentation(adding: $adding, editing: $editing, model: model)
    .background {
      // A separate presentation anchor from the editor sheets.
      Color.clear.adaptiveSheet(item: $connecting) { sheet in
        ConnectSheetView(sheet: sheet, connecting: $connecting, model: model)
          .macSheetFrame(width: 480, height: 460)
      }
    }
  }
}

/// One saved host. Its own view with only the values it shows, so a
/// row redraws only when its host, sign-in summary or resume state
/// changes.
private struct HostRow: View {
  let host: HostProfile
  let context: HostMutationContext
  let authSummary: String
  let isResumable: Bool
  let model: RoamingAppModel
  @Binding
  var connecting: ConnectSheet?
  @Binding
  var editing: HostMutationContext?
  @Binding
  var browsing: HostConnectionSelection?

  var body: some View {
    Button {
      // Mac → Workspace: sign in, then pick or create a workspace.
      guard model.validateHostMutation(context) else { return }
      connecting = .choose(context)
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text(host.nickname).font(.headline)
        Text(host.endpointSummary).font(.subheadline.monospaced())
          .foregroundStyle(.secondary)
        Text(authSummary).font(.caption).foregroundStyle(.secondary)
        if isResumable {
          // Resuming still needs fresh SSH sign-in.
          Label(
            .localized("Detached workspace — open to resume"),
            systemImage: "arrow.uturn.forward"
          )
          .font(.caption).foregroundStyle(.tint)
        }
      }
    }
    .accessibilityIdentifier("host.open.\(host.id)")
    .contextMenu {
      if let last = model.resumableSessionID(for: host) {
        // Names the remembered workspace; never creates one.
        Button {
          guard model.validateHostMutation(context) else { return }
          model.openWorkspace(host, intent: .resume(last, nil))
        } label: {
          Label {
            Text(
              "Resume Last Workspace (\(last.hex.prefix(8)))",
              bundle: #bundle
            )
          } icon: {
            Image(systemName: "arrow.uturn.forward")
          }
        }
      }
      if model.profile.sshShell {
        Button(.localized("Open Ordinary SSH Shell")) {
          guard model.validateHostMutation(context) else { return }
          model.open(host, kind: .ordinarySSH)
        }
      }
      #if !os(tvOS)
      if model.profile.sftp {
        Button(.localized("Browse Files…")) {
          guard model.validateHostMutation(context) else { return }
          browsing = model.connectionSelection(for: host)
        }
      }
      #endif
      Button(.localized("Edit")) {
        guard model.validateHostMutation(context) else { return }
        editing = context
      }
      Button(.localized("Delete"), role: .destructive) {
        model.delete(host, expecting: context)
      }
    }
  }
}

extension View {
  /// A sheet, except on Mac Catalyst, where SwiftUI's programmatic sheet
  /// dismissal (Save, Cancel, Done) did not close the sheet; there the
  /// content is pushed onto the enclosing navigation stack instead, and
  /// the same dismissal pops it.
  @ViewBuilder
  func adaptiveSheet<Content: View>(
    isPresented: Binding<Bool>,
    @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    #if targetEnvironment(macCatalyst)
    navigationDestination(isPresented: isPresented, destination: content)
    #else
    sheet(isPresented: isPresented) { content().presentationBackground(.clear) }
    #endif
  }

  @ViewBuilder
  func adaptiveSheet<Item: Hashable & Identifiable, Content: View>(
    item: Binding<Item?>,
    @ViewBuilder content: @escaping (Item) -> Content
  ) -> some View {
    #if targetEnvironment(macCatalyst)
    navigationDestination(item: item, destination: content)
    #else
    sheet(item: item) { item in content(item).presentationBackground(.clear) }
    #endif
  }

  /// Add/Edit Host forms.
  func hostEditorPresentation(
    adding: Binding<Bool>,
    editing: Binding<HostMutationContext?>,
    model: RoamingAppModel
  ) -> some View {
    self.adaptiveSheet(isPresented: adding) {
      HostEditorView(model: model, host: nil) { adding.wrappedValue = false }
        .macSheetFrame()
    }
    .adaptiveSheet(item: editing) { context in
      HostEditorView(model: model, context: context) {
        editing.wrappedValue = nil
      }
      .macSheetFrame()
    }
  }
}

/// How the editor's sign-in picker is set.
enum AuthSelection: Hashable {
  case password
  case key(UUID)
  /// A reference this editor cannot change into a choice (an unresolved
  /// version-1 label or a newer variant), kept until the user picks one.
  case preserved(AuthMethodReference)

  init(_ auth: AuthMethodReference?) {
    switch auth {
    case .password?, nil: self = .password
    case .key(let id)?: self = .key(id)
    case let other?: self = .preserved(other)
    }
  }

  var reference: AuthMethodReference {
    switch self {
    case .password: .password
    case .key(let id): .key(identityID: id)
    case .preserved(let auth): auth
    }
  }
}

/// Add/edit form for a saved host. Collects no secrets: passwords are
/// prompted at connect time and keys are referenced by identity UUID.
public struct HostEditorView: View {
  let model: RoamingAppModel
  @State
  private var context: HostMutationContext
  /// A discovered or scanned Mac awaiting confirmation; `nil` for
  /// ordinary add/edit.
  let candidate: HostCandidate?
  let onPaired: ((HostProfile) -> Void)?
  let dismiss: () -> Void

  @State
  private var nickname: String
  @State
  private var host: String
  @State
  private var port: String
  @State
  private var username: String
  @State
  private var auth: AuthSelection
  @State
  private var error: String?
  @State
  private var confirmedSource = false
  /// Explicit choice to update this saved host instead of adding one.
  @State
  private var replacement: HostMutationContext?
  /// `currentMatches()`, cached so typing does not refilter the hosts on
  /// every redraw.
  @State
  private var matchingHosts: [HostProfile] = []
  @State
  private var pairing: Task<Void, Never>?
  /// The presenting binding alone does not always close the sheet on Mac
  /// Catalyst; dismiss through the environment as well.
  @Environment(\.dismiss)
  private var dismissSheet

  public init(
    model: RoamingAppModel,
    host: HostProfile?,
    candidate: HostCandidate? = nil,
    onPaired: ((HostProfile) -> Void)? = nil,
    dismiss: @escaping () -> Void
  ) {
    self.init(
      model: model,
      context: model.hostMutationContext(for: host),
      candidate: candidate,
      onPaired: onPaired,
      dismiss: dismiss
    )
  }

  init(
    model: RoamingAppModel,
    context: HostMutationContext,
    candidate: HostCandidate? = nil,
    onPaired: ((HostProfile) -> Void)? = nil,
    dismiss: @escaping () -> Void
  ) {
    self.model = model
    _context = State(initialValue: context)
    let host = context.original
    self.candidate = candidate
    self.onPaired = onPaired
    self.dismiss = dismiss
    _nickname = State(
      initialValue: host?.nickname ?? candidate?.suggestedNickname ?? ""
    )
    _host = State(initialValue: host?.host ?? candidate?.host ?? "")
    _port = State(initialValue: String(host?.port ?? candidate?.port ?? 22))
    _username = State(initialValue: host?.username ?? candidate?.username ?? "")
    _auth = State(initialValue: AuthSelection(host?.auth))
  }

  public var body: some View {
    form.modalConnectionPrompts(model, enabled: candidate != nil)
      .onChange(of: host, initial: true) { refreshMatches() }
      .onChange(of: port) { refreshMatches() }
      .onChange(of: model.hosts) { refreshMatches() }
  }

  private var editorIsCurrent: Bool { model.hostMutationIsCurrent(context) }

  /// Saved hosts at the same address, offered only as an explicit update.
  private func currentMatches() -> [HostProfile] {
    let address = host.trimmingCharacters(in: .whitespaces).lowercased()
    let number = Int(port.trimmingCharacters(in: .whitespaces))
    return model.hosts.filter {
      $0.host.lowercased() == address && $0.port == number
    }
  }

  private func refreshMatches() {
    let matches = currentMatches()
    if matches != matchingHosts { matchingHosts = matches }
  }

  private var form: some View {
    NavigationStack {
      Form {
        // First, so a blocked connection stays visible above the keyboard.
        if pairing != nil {
          HStack {
            ProgressView()
            Text("Verifying the Mac's SSH key and signing in…", bundle: #bundle)
          }
          .listRowBackground(Color.clear)
        }
        if !editorIsCurrent {
          Text(RoamingAppModel.hostChangedMessage).foregroundStyle(.red)
            .listRowBackground(Color.clear)
            .accessibilityIdentifier("host.error")
        } else if let error {
          Text(error).foregroundStyle(.red).listRowBackground(Color.clear)
            .accessibilityIdentifier("host.error")
        }
        if let candidate {
          CandidateSummary(
            candidate: candidate,
            confirmedSource: $confirmedSource
          )
        }
        Section(.localized("Host")) {
          TextField(.localized("Nickname"), text: $nickname)
            .accessibilityIdentifier("host.nickname")
          TextField(.localized("Host name or address"), text: $host)
            .plainEntry().accessibilityIdentifier("host.address")
          TextField(.localized("Port"), text: $port).plainEntry()
            .accessibilityIdentifier("host.port")
          TextField(.localized("Username"), text: $username).plainEntry()
            .accessibilityIdentifier("host.username")
        }
        .disabled(!editorIsCurrent).listRowBackground(Color.clear)
        HostAuthenticationSection(model: model, auth: $auth)
          .disabled(!editorIsCurrent).listRowBackground(Color.clear)
        if candidate != nil, !matchingHosts.isEmpty {
          SaveAsSection(
            matches: matchingHosts.map { model.hostMutationContext(for: $0) },
            replacement: $replacement
          )
          .disabled(!editorIsCurrent)
        }
      }
      .glassListBackground()
      .navigationTitle(
        candidate != nil
          ? "Connect to Mac"
          : context.original == nil ? "Add Host" : "Edit Host"
      )
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(.localized("Cancel"), action: close)
        }
        ToolbarItem(placement: .confirmationAction) {
          if candidate != nil {
            Button(.localized("Connect"), action: connect)
              .disabled(
                !editorIsCurrent || pairing != nil
                  || (candidate?.source == .code && !confirmedSource)
              )
              .accessibilityIdentifier("host.connect")
          } else {
            Button(.localized("Save"), action: save).disabled(!editorIsCurrent)
              .accessibilityIdentifier("host.save")
          }
        }
      }
    }
  }

  private func close() {
    // Cancelling discards the candidate; an in-flight sign-in stops.
    pairing?.cancel()
    pairing = nil
    dismiss()
    dismissSheet()
  }

  private func draft(id: UUID) -> HostProfile {
    HostProfile(
      id: id,
      nickname: nickname.trimmingCharacters(in: .whitespaces),
      host: host.trimmingCharacters(in: .whitespaces),
      port: Int(port.trimmingCharacters(in: .whitespaces)) ?? 0,
      username: username.trimmingCharacters(in: .whitespaces),
      auth: auth.reference
    )
  }

  /// Verify, trust, sign in, save; then the workspace chooser.
  private func connect() {
    guard let candidate, pairing == nil, model.validateHostMutation(context)
    else { return }
    let target = replacement ?? context
    guard model.validateHostMutation(target),
      replacement == nil
        || currentMatches().contains(where: { $0.id == target.id })
    else {
      error = RoamingAppModel.hostChangedMessage
      return
    }
    let profile = draft(id: target.id)
    do { try profile.validate() } catch {
      self.error = error.message
      return
    }
    error = nil
    pairing = Task {
      defer { pairing = nil }
      do throws(PairingFailure) {
        let saved = try await model.pair(
          profile,
          expectedHostKeys: candidate.expectedHostKeys,
          context: target
        )
        guard !Task.isCancelled else { return }
        onPaired?(saved)
      } catch {
        guard !Task.isCancelled else { return }
        self.error = error.message
      }
    }
  }

  private func save() {
    let profile = draft(id: context.id)
    do {
      guard try model.save(profile, expecting: context) else {
        error = model.lastError
        return
      }
      close()
    } catch { self.error = error.message }
  }
}

/// Password or one saved SSH identity, by UUID. An identity that is
/// missing on this device stays selected and explained; it never turns
/// into Password. Its own view, so typing in the host fields does not
/// redraw the identity picker.
private struct HostAuthenticationSection: View {
  let model: RoamingAppModel
  @Binding
  var auth: AuthSelection
  @State
  private var creatingKey: KeyCreationMode?

  var body: some View {
    Section {
      Picker(.localized("Sign in with"), selection: $auth) {
        Text("Password", bundle: #bundle).tag(AuthSelection.password)
        ForEach(model.identities) { identity in
          Text("Key \u{201C}\(identity.name)\u{201D}", bundle: #bundle)
            .tag(AuthSelection.key(identity.id))
        }
        if case .key(let id) = auth,
          !model.identities.contains(where: { $0.id == id })
        {
          Text("Deleted or unavailable key", bundle: #bundle).tag(auth)
        }
        if case .preserved(let reference) = auth {
          Text(reference.summary).tag(auth)
        }
      }
      .accessibilityIdentifier("host.auth")
      Menu(.localized("New Key"), systemImage: "key.badge.plus") {
        Button(.localized("Generate Key…")) { creatingKey = .generate }
          .accessibilityIdentifier("host.key.generate")
        if model.profile.keyImport {
          Button(.localized("Import Key…")) { creatingKey = .importKey }
        }
      }
      .accessibilityIdentifier("host.key.new")
    } header: {
      Text("Authentication", bundle: #bundle)
    } footer: {
      switch auth {
      case .password:
        Text(
          "You will be asked for the password when connecting.",
          bundle: #bundle
        )
      case .key(let id):
        if let identity = model.identity(id), !identity.isDeleted {
          Text(identity.fingerprint).font(.caption.monospaced())
        } else {
          Text(
            "This key was deleted or is not on this device. Choose another key.",
            bundle: #bundle
          )
        }
      case .preserved(.legacyKey):
        Text(
          """
          This key was not found when Swiftty updated its key storage. Choose or \
          import a key.
          """,
          bundle: #bundle
        )
      case .preserved:
        Text("Saved by a newer version of Swiftty.", bundle: #bundle)
      }
    }
    .adaptiveSheet(item: $creatingKey) { mode in
      KeyCreationView(model: model, mode: mode) { created in
        if let created { auth = .key(created.id) }
        creatingKey = nil
      }
      .macSheetFrame(width: 480, height: 460)
    }
  }
}

/// Saved hosts at the candidate's address, offered as explicit updates.
private struct SaveAsSection: View {
  let matches: [HostMutationContext]
  @Binding
  var replacement: HostMutationContext?

  var body: some View {
    Section {
      Picker(.localized("Save as"), selection: $replacement) {
        Text("New host", bundle: #bundle).tag(HostMutationContext?.none)
        if let replacement, !matches.contains(replacement) {
          Text("Selected host changed. Choose again.", bundle: #bundle)
            .tag(HostMutationContext?.some(replacement)).disabled(true)
        }
        ForEach(matches) { context in
          if let saved = context.original {
            Text("Update \u{201C}\(saved.nickname)\u{201D}", bundle: #bundle)
              .tag(HostMutationContext?.some(context))
          }
        }
      }
      .accessibilityIdentifier("host.replacement")
    } footer: {
      Text(
        """
        Updating keeps that host's place in the list. Its trusted key is \
        never replaced: a different key still blocks the connection.
        """,
        bundle: #bundle
      )
    }
    .listRowBackground(Color.clear)
  }
}

extension HostProfile.ValidationError {
  /// Localized; a `String` because it shares the error line with
  /// messages that carry what the Mac or Keychain reported.
  var message: String {
    switch self {
    case .emptyNickname: String(localized: "Enter a nickname.", bundle: #bundle)
    case .invalidHost:
      String(localized: "Enter a valid host name or address.", bundle: #bundle)
    case .invalidPort:
      String(localized: "Port must be between 1 and 65535.", bundle: #bundle)
    case .invalidUsername:
      String(localized: "Enter a valid username.", bundle: #bundle)
    case .invalidKeyLabel:
      String(localized: "Enter a valid key label.", bundle: #bundle)
    }
  }
}

extension View {
  /// ⌘N for Add Host where hardware keyboard shortcuts exist (not tvOS).
  func addHostShortcut() -> some View {
    #if os(tvOS)
    self
    #else
    self.keyboardShortcut("n", modifiers: .command)
    #endif
  }

  /// Text selection where the platform offers it (not tvOS).
  func selectableIfSupported() -> some View {
    #if os(tvOS)
    self
    #else
    self.textSelection(.enabled)
    #endif
  }

  /// macOS sheets size to their content; a `NavigationStack` + `Form`
  /// sheet otherwise collapses to nothing while still making the window
  /// modal. Gives such sheets a usable minimum size there.
  func macSheetFrame(width: CGFloat = 460, height: CGFloat = 380) -> some View {
    #if os(macOS)
    self.frame(minWidth: width, minHeight: height)
    #else
    self
    #endif
  }

  /// Disables autocorrection and capitalization for identifiers.
  func plainEntry() -> some View {
    #if os(macOS)
    self.autocorrectionDisabled()
    #else
    self.autocorrectionDisabled().textInputAutocapitalization(.never)
    #endif
  }
}

/// Host-key trust prompt (spec §5.1). An unknown key needs an
/// explicit decision; a changed key blocks the connection outright.
public struct TrustPromptView: View {
  let prompt: TrustPrompt
  let decide: (TrustDecision) -> Void

  public init(prompt: TrustPrompt, decide: @escaping (TrustDecision) -> Void) {
    self.prompt = prompt
    self.decide = decide
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      switch prompt.kind {
      case .unknownKey:
        Label(
          .localized("Unknown host key"),
          systemImage: "questionmark.diamond"
        )
        .font(.title2)
        if prompt.matchesPairingCode {
          Label(
            .localized("Matches the connection code you confirmed"),
            systemImage: "checkmark.seal"
          )
          .foregroundStyle(.green).accessibilityIdentifier("trust.paired")
          Text(
            """
            Trusting stores this key for \(prompt.host.endpointSummary); \
            a different key will be blocked later.
            """,
            bundle: #bundle
          )
        } else {
          Text(
            """
            The authenticity of \(prompt.host.endpointSummary) can't be established. \
            Verify the fingerprint on the Mac before trusting it.
            """,
            bundle: #bundle
          )
        }
      case .changedKey:
        Label(
          .localized("Host key changed"),
          systemImage: "exclamationmark.octagon"
        )
        .font(.title2).foregroundStyle(.red)
        Text(
          """
          The key for \(prompt.host.endpointSummary) differs from the trusted key. \
          The connection is blocked.
          """,
          bundle: #bundle
        )
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(prompt.keyAlgorithm).font(.caption).foregroundStyle(.secondary)
        Text(prompt.fingerprint).font(.body.monospaced())
          .selectableIfSupported().accessibilityIdentifier("trust.fingerprint")
      }
      HStack {
        Button(
          prompt.kind == .changedKey
            ? .localized("Close") : .localized("Don't Trust"),
          role: .cancel
        ) { decide(.reject) }
        .accessibilityIdentifier("trust.reject")
        if prompt.kind == .unknownKey {
          Button(.localized("Trust")) { decide(.trust) }
            .glassButtonStyle(prominent: true)
            .accessibilityIdentifier("trust.accept")
        }
      }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .glassSurface().glassButtonStyle()
  }
}

/// Password prompt for one connection. The password stays in memory for
/// this app session only; it is never saved or logged.
public struct PasswordPromptView: View {
  let prompt: PasswordPrompt
  let answer: (String?) -> Void
  @State
  private var password = ""

  public init(prompt: PasswordPrompt, answer: @escaping (String?) -> Void) {
    self.prompt = prompt
    self.answer = answer
  }

  public var body: some View {
    NavigationStack {
      Form {
        Section {
          SecureField(.localized("Password"), text: $password)
            .textContentType(.password).onSubmit(submit)
            .accessibilityIdentifier("password.field")
        } header: {
          Text(prompt.host.endpointSummary)
        } footer: {
          if prompt.isRetry {
            Text("The password was not accepted. Try again.", bundle: #bundle)
              .foregroundStyle(.red)
          } else {
            Text(
              "Kept in memory until the app quits; never saved.",
              bundle: #bundle
            )
          }
        }
        .listRowBackground(Color.clear)
      }
      .glassListBackground().navigationTitle(.localized("Sign In"))
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(.localized("Cancel")) { answer(nil) }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(.localized("Sign In"), action: submit)
            .disabled(password.isEmpty)
            .accessibilityIdentifier("password.submit")
        }
      }
    }
  }

  private func submit() {
    guard !password.isEmpty else { return }
    let value = password
    password = ""
    answer(value)
  }
}
