import ProgramIcons
import SessionCore
import SwiftUI
import SwifttyCore

/// Builds the terminal surface for a session. Each direct-client app
/// installs `LiveTerminalSurfaceFactory` through
/// `.environment(\.terminalSurfaceFactory, …)`; without one (previews,
/// tests) `TerminalScreen` shows a status card.
///
/// A protocol rather than a closure: SwiftUI cannot compare closures, so a
/// closure-valued environment entry invalidates its readers on every write.
public protocol TerminalSurfaceFactory: Sendable {
  @MainActor
  func makeSurface(for model: TerminalScreenModel) -> AnyView
}

extension EnvironmentValues {
  @Entry
  public var terminalSurfaceFactory: (any TerminalSurfaceFactory)?
}

/// The terminal screen for one session: connection state, pending input
/// and capability chrome around the surface from `TerminalSurfaceFactory`
/// (a Swiftty renderer fed by a roaming, ordinary-SSH or local backend).
public struct TerminalScreen: View {
  @Bindable
  var model: TerminalScreenModel
  @Environment(\.terminalSurfaceFactory)
  private var factory
  /// Pending input that outlived a normal round trip; a keystroke awaiting
  /// its ack is not worth showing.
  @State
  private var pendingVisible = false
  /// The terminal's own background, once the surface reports it.
  @State
  private var terminalBackground: Color?
  let onClose: () -> Void

  public init(model: TerminalScreenModel, onClose: @escaping () -> Void) {
    self.model = model
    self.onClose = onClose
  }

  public var body: some View {
    VStack(spacing: 0) {
      if showsStatusBar {
        TerminalStatusBar(model: model, pendingVisible: pendingVisible)
        Divider()
      }
      if let factory {
        factory.makeSurface(for: model)
          // Native renderers and surface tasks belong to this model's
          // session; a replacement must start with a fresh hierarchy.
          .id(model.id)
      } else {
        TerminalSurfacePlaceholder(model: model)
      }
    }
    // Transient state floats over the terminal: inserting a row would
    // resize the grid, and redraw it, on every keystroke.
    .overlay(alignment: .top) {
      if showsStatusOverlay {
        TerminalStatusBar(model: model, pendingVisible: pendingVisible)
      }
    }
    .modifier(PendingInputDelay(model: model, visible: $pendingVisible))
    .onPreferenceChange(TerminalBackgroundKey.self) { color in
      MainActor.assumeIsolated { terminalBackground = color }
    }
    .modifier(TerminalChromeBackground(color: terminalBackground))
    .navigationTitle(model.host.nickname)
    .alert(
      Text("Unable to open shell", bundle: #bundle),
      isPresented: Binding(
        get: { model.actionError != nil },
        set: { if !$0 { model.actionError = nil } }
      )
    ) {
      Button(.localized("OK"), role: .cancel) { model.actionError = nil }
    } message: {
      Text(model.actionError ?? "")
        .accessibilityIdentifier("terminal.actionError")
    }
    #if os(iOS) && !targetEnvironment(macCatalyst)
    // iPhone and iPad: the host name sits in the top row beside Back, and
    // closing is the surface menu's Detach (or Disconnect), so the
    // terminal starts higher.
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .principal) {
        TerminalTitle(model: model, background: terminalBackground)
      }
    }
    #else
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button(.localized("Close"), action: onClose)
        .accessibilityIdentifier("terminal.close")
      }
    }
    #endif
  }

  /// The bar as a layout row, only where it stays put.
  private var showsStatusBar: Bool {
    !terminalStatusInTitle || model.kind != .roaming
  }

  private var showsStatusOverlay: Bool {
    !showsStatusBar && (pendingVisible || !model.acceptsInput)
  }
}

/// iPhone and iPad show the connection state as a dot beside the title
/// (`TerminalTitle`); the bar then remains only for what the dot cannot
/// say.
private let terminalStatusInTitle: Bool = {
  #if os(iOS) && !targetEnvironment(macCatalyst)
  true
  #else
  false
  #endif
}()

/// Paints the navigation bar and the safe areas with the terminal's
/// background instead of the app's, with bar content legible on it. Only
/// iPhone and iPad: Catalyst and visionOS keep their window chrome.
///
/// The fill is the terminal's color made opaque, behind the whole screen,
/// and the bar's own background is hidden. A translucent terminal
/// (`background-opacity` below 1) then shows its glass over the same color
/// the bars show, instead of over black.
///
/// Zero-height strips grown into the insets by `ignoresSafeArea`, and
/// inset-sized strips from a `GeometryReader`, both render nothing on
/// iOS 27: the bars and the home-indicator area stayed black.
private struct TerminalChromeBackground: ViewModifier {
  let color: Color?

  func body(content: Content) -> some View {
    #if os(iOS) && !targetEnvironment(macCatalyst)
    // One structure with or without a color: branching on it would give
    // `content` a new identity when the color arrives, recreating the
    // terminal, whose fresh state reports no color, and so on.
    content
      // Full bleed, keyboard area included: the terminal lifts itself
      // above the keyboard rather than shrinking.
      .background {
        if let color {
          Color(uiColor: UIColor(color).withAlphaComponent(1)).ignoresSafeArea()
        }
      }
      .toolbarBackgroundVisibility(
        color == nil ? .automatic : .hidden,
        for: .navigationBar
      )
      .toolbarColorScheme(
        color.map { $0.isDark ? .dark : .light },
        for: .navigationBar
      )
    #else
    content
    #endif
  }
}

#if os(iOS) && !targetEnvironment(macCatalyst)
extension Color {
  /// Relative luminance below the midpoint (WCAG weights).
  fileprivate var isDark: Bool {
    var r: CGFloat = 0
    var g: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 0
    guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else {
      return true
    }
    return 0.2126 * r + 0.7152 * g + 0.0722 * b < 0.5
  }
}
#endif

/// Shows pending input only once it outlives a normal round trip. Its own
/// modifier, so the count changing with each keystroke and ack invalidates
/// only this, not the whole screen.
private struct PendingInputDelay: ViewModifier {
  let model: TerminalScreenModel
  @Binding
  var visible: Bool

  func body(content: Content) -> some View {
    content.task(id: model.pendingInputCount > 0) {
      guard model.pendingInputCount > 0 else {
        visible = false
        return
      }
      try? await Task.sleep(for: .milliseconds(750))
      if !Task.isCancelled { visible = true }
    }
  }
}

#if os(iOS) && !targetEnvironment(macCatalyst)
/// The running program's icon and the host name, as the Mac shows a tab:
/// the icon a tile picked from the pane's title (`MuxIcons`), with the
/// connection state as a dot on its bottom-right corner: green connected,
/// orange on the way, red failed. The dot carries the state text for
/// VoiceOver and tests.
private struct TerminalTitle: View {
  let model: TerminalScreenModel
  /// The bar's color (the terminal's), which the dot's ring cuts out of
  /// the tile; nil is the system background.
  let background: Color?

  var body: some View {
    HStack(spacing: 8) {
      ProgramIconTile(icon: MuxIcons.icon(title: model.title))
        .overlay(alignment: .bottomTrailing) {
          Circle().fill(model.connectionState.indicatorColor)
            .frame(width: 9, height: 9)
            .overlay {
              Circle()
                .strokeBorder(
                  background.map(AnyShapeStyle.init)
                    ?? AnyShapeStyle(.background),
                  lineWidth: 1.5
                )
            }
            .offset(x: 3, y: 3).accessibilityElement()
            .accessibilityLabel(Text(model.stateText))
            .accessibilityIdentifier("terminal.status")
        }
      Text(model.host.nickname).font(.headline).lineLimit(1)
    }
  }
}

/// A program's icon as the Mac's tab tile: a rounded square in the
/// brand's color (or dark and neutral) with the glyph in white, or a
/// `colored` logo in its own colors in place of the tile. Logos are the
/// asset catalog's `brand-<name>` image sets; a missing one, or no brand,
/// draws the SF Symbol.
private struct ProgramIconTile: View {
  let icon: MuxIcon
  private let size: CGFloat = 22

  var body: some View {
    Group {
      if let logo, icon.colored {
        Image(uiImage: logo).renderingMode(.original).resizable().scaledToFit()
      } else {
        RoundedRectangle(
          cornerRadius: (size * 0.28).rounded(),
          style: .continuous
        )
        .fill(fill).strokeBorder(.white.opacity(0.16), lineWidth: 1)
        .overlay { glyph.foregroundStyle(.white) }
      }
    }
    .frame(width: size, height: size).accessibilityHidden(true)
  }

  private var logo: UIImage? {
    icon.brand.flatMap { UIImage(named: "brand-\($0)", in: .main, with: nil) }
  }

  @ViewBuilder
  private var glyph: some View {
    if let logo {
      // A logo fills its share of the tile; a symbol keeps its size.
      Image(uiImage: logo).renderingMode(.template).resizable().scaledToFit()
        .frame(width: size * 0.6, height: size * 0.6)
    } else {
      Image(systemName: icon.symbol).font(.system(size: 11, weight: .medium))
    }
  }

  private var fill: Color {
    guard let tint = icon.tint else { return Color(white: 0.16) }
    return Color(
      .sRGB,
      red: Double(tint >> 16 & 0xFF) / 255,
      green: Double(tint >> 8 & 0xFF) / 255,
      blue: Double(tint & 0xFF) / 255
    )
  }
}
#endif

private struct TerminalStatusBar: View {
  let model: TerminalScreenModel
  let pendingVisible: Bool

  var body: some View {
    HStack(spacing: 12) {
      if !terminalStatusInTitle {
        Label(model.stateText, systemImage: model.connectionState.symbol)
          .foregroundStyle(
            model.connectionState.acceptsInput ? .primary : .secondary
          )
      }
      if model.kind != .roaming {
        Text(model.kind.displayName).foregroundStyle(.secondary)
      }
      Spacer()
      if pendingVisible, model.pendingInputCount > 0 {
        // Previously submitted input may still apply later (spec §8).
        Label(
          .localized("\(model.pendingInputCount) pending"),
          systemImage: "hourglass"
        )
        .foregroundStyle(.orange)
      }
      if !model.acceptsInput {
        Label(
          .localized("Input paused"),
          systemImage: "keyboard.badge.ellipsis"
        )
        .foregroundStyle(.secondary)
      }
    }
    .font(.footnote).padding(.horizontal).padding(.vertical, 8)
    .glassPanel(cornerRadius: 0).accessibilityElement(children: .combine)
    .accessibilityIdentifier(
      terminalStatusInTitle ? "terminal.details" : "terminal.status"
    )
  }
}

extension TerminalScreenModel {
  /// Honest state text: a reconnect attempt is not a lost session, and an
  /// exited shell is not a lost one.
  fileprivate var stateText: LocalizedStringResource {
    switch connectionState {
    case .reconnecting where reconnectAttempt > 0:
      .localized("Reconnecting (attempt \(reconnectAttempt))")
    case .sessionExited:
      exitStatus.map { .localized("Session exited (status \($0))") }
        ?? .localized("Session exited")
    default: connectionState.displayName
    }
  }
}

/// Shown only when no `TerminalSurfaceFactory` is installed.
struct TerminalSurfacePlaceholder: View {
  let model: TerminalScreenModel

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "apple.terminal").font(.largeTitle)
        .foregroundStyle(.secondary)
      Text("Terminal unavailable", bundle: #bundle).font(.headline)
      Text(model.host.endpointSummary).font(.subheadline.monospaced())
        .foregroundStyle(.secondary)
      capabilityList
    }
    .padding().frame(maxWidth: .infinity, maxHeight: .infinity).glassSurface()
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("Terminal unavailable", bundle: #bundle))
  }

  private var capabilityList: some View {
    let caps = model.capabilities
    let entries: [(id: String, name: LocalizedStringResource, enabled: Bool)] =
      [
        ("text", .localized("Text input"), caps.textInput),
        ("copy", .localized("Local copy"), caps.localCopy),
        ("paste", .localized("Paste"), caps.paste),
        ("scrollback", .localized("Scrollback"), caps.scrollback),
        ("search", .localized("Search"), caps.search),
        ("sftp", .localized("SFTP"), model.profile.sftp),
      ]
    return VStack(alignment: .leading, spacing: 4) {
      ForEach(entries, id: \.id) { _, name, enabled in
        Label(name, systemImage: enabled ? "checkmark.circle" : "minus.circle")
          .foregroundStyle(enabled ? .primary : .secondary)
      }
    }
    .font(.caption)
  }
}

extension ClientConnectionState {
  public var displayName: LocalizedStringResource {
    switch self {
    case .idle: .localized("Not connected")
    case .sshBootstrap: .localized("Signing in")
    case .attaching: .localized("Attaching")
    case .active: .localized("Connected")
    case .suspect: .localized("Connection uncertain")
    case .reconnecting: .localized("Reconnecting")
    case .backgroundDetached: .localized("Detached")
    case .sessionExited: .localized("Session exited")
    case .sessionLost: .localized("Workspace lost")
    case .userClosed: .localized("Closed")
    }
  }

  /// The title dot: green connected, orange connecting, red failed, grey
  /// when not connected by choice.
  var indicatorColor: Color {
    switch self {
    case .active: .green
    case .sshBootstrap, .attaching, .reconnecting, .suspect: .orange
    case .sessionLost, .sessionExited: .red
    case .idle, .backgroundDetached, .userClosed: .secondary
    }
  }

  var symbol: String {
    switch self {
    case .active: "bolt.horizontal.circle"
    case .suspect, .reconnecting, .attaching, .sshBootstrap:
      "arrow.triangle.2.circlepath"
    case .sessionLost, .sessionExited: "exclamationmark.triangle"
    default: "circle.dashed"
    }
  }
}
