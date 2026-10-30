import AppKit
import Observation
import SwiftUI
import SwifttyCore

/// swiftty › Settings… (Command-Comma): the common preferences and the
/// configuration's problems (spec.apple.md A01). The configuration file
/// stays authoritative: each change rewrites only its own key through
/// `ConfigurationEditor`, then the app reloads the file, so the window and
/// the file share one typed model and one precedence. Everything else is
/// edited in the file (Edit Configuration File…).
@MainActor
@Observable
final class SettingsModel {
  enum Cursor: String, CaseIterable, Identifiable {
    case terminal, block, bar, underline, hollowBlock
    var id: Self { self }

    var title: String {
      switch self {
      case .terminal: "Set by Program"
      case .block: "Block"
      case .bar: "Bar"
      case .underline: "Underline"
      case .hollowBlock: "Hollow Block"
      }
    }

    var value: String? {
      switch self {
      case .terminal: nil
      case .block: "block"
      case .bar: "bar"
      case .underline: "underline"
      case .hollowBlock: "block_hollow"
      }
    }
  }

  enum Blink: String, CaseIterable, Identifiable {
    case terminal, on, off
    var id: Self { self }

    var title: String {
      switch self {
      case .terminal: "Set by Program"
      case .on: "On"
      case .off: "Off"
      }
    }

    var value: String? {
      switch self {
      case .terminal: nil
      case .on: "true"
      case .off: "false"
      }
    }
  }

  let url: URL
  /// As loaded from the file, without display accommodations.
  private(set) var configuration: Configuration
  private(set) var themes: [String]
  /// Why the last change was not saved.
  private(set) var error: String?
  /// Keys whose saved value an included file overrides.
  private(set) var overridden: Set<String> = []
  @ObservationIgnored
  private let reload: @MainActor () -> Configuration

  /// `reload` re-reads the file, applies it to the app and returns it.
  init(
    url: URL,
    configuration: Configuration,
    reload: @escaping @MainActor () -> Configuration
  ) {
    self.url = url
    self.configuration = configuration
    self.reload = reload
    themes = Themes.available(in: configuration.themeDirectories)
  }

  var fontFamily: String { configuration.fontFamily }
  var fontSize: Double { configuration.fontSize }
  var backgroundOpacity: Double { configuration.backgroundOpacity }
  var copyOnSelect: Bool { configuration.copyOnSelect }
  var mouseHideWhileTyping: Bool { configuration.mouseHideWhileTyping }
  /// The `theme` value, or nil for the built-in default.
  var theme: String? { configuration.theme?.configurationValue }

  var cursor: Cursor {
    switch (configuration.cursorStyle, configuration.cursorHollow) {
    case (nil, _): .terminal
    case (.block, true): .hollowBlock
    case (.block, false): .block
    case (.bar, _): .bar
    case (.underline, _): .underline
    }
  }

  var blink: Blink {
    switch configuration.cursorStyleBlink {
    case nil: .terminal
    case true?: .on
    case false?: .off
    }
  }

  var problems: [String] { configuration.problems }

  /// The file was reloaded elsewhere (Reload Configuration, another edit).
  func refresh(_ configuration: Configuration) {
    self.configuration = configuration
    themes = Themes.available(in: configuration.themeDirectories)
  }

  /// Writes `key` (nil restores its default) and reloads.
  func set(_ key: String, _ value: String?) {
    do {
      try ConfigurationEditor.apply([(key, value)], to: url)
      error = nil
    } catch {
      self.error = "\(error)"
      return
    }
    configuration = reload()
    // Parsed as the loader reads a line (quotes removed), alone.
    let expected = Configuration.parse("\(key) = \(value ?? "")")
    if value != nil,
      Self.summary(of: key, in: expected)
        != Self.summary(of: key, in: configuration)
    {
      overridden.insert(key)
    } else {
      overridden.remove(key)
    }
  }

  /// Comparable text for an editable key's effective value.
  static func summary(of key: String, in c: Configuration) -> String {
    switch key {
    case "font-family": c.fontFamily
    case "font-size": "\(c.fontSize)"
    case "theme": c.theme?.configurationValue ?? ""
    case "background-opacity": "\(c.backgroundOpacity)"
    case "cursor-style":
      "\(String(describing: c.cursorStyle)) \(c.cursorHollow)"
    case "cursor-style-blink": String(describing: c.cursorStyleBlink)
    case "copy-on-select": "\(c.copyOnSelect)"
    case "mouse-hide-while-typing": "\(c.mouseHideWhileTyping)"
    default: ""
    }
  }
}

// MARK: - Window

@MainActor
final class SettingsWindowController: NSWindowController {
  let model: SettingsModel

  init(model: SettingsModel, editFile: @escaping @MainActor () -> Void) {
    self.model = model
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: true
    )
    window.title = "Settings"
    window.isReleasedWhenClosed = false
    window.contentViewController = NSHostingController(
      rootView: SettingsView(model: model, editFile: editFile)
    )
    window.setFrameAutosaveName("Settings")
    super.init(window: window)
    if !window.setFrameUsingName("Settings") { window.center() }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  func present() {
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
  }
}

struct SettingsView: View {
  @Bindable
  var model: SettingsModel
  let editFile: @MainActor () -> Void
  @State
  private var family = ""
  @State
  private var opacity = 1.0
  @State
  private var draggingOpacity = false

  var body: some View {
    Form {
      Section("Font") {
        TextField("Family", text: $family)
          .onSubmit { model.set("font-family", nonEmpty(family)) }
          .accessibilityHint("Press Return to apply")
        Stepper(
          value: Binding(
            get: { model.fontSize },
            set: { model.set("font-size", Self.number($0)) }
          ),
          in: Configuration.fontSizeRange,
          step: 1
        ) { LabeledContent("Size", value: "\(Self.number(model.fontSize)) pt") }
        footnote("font-family", "font-size")
      }
      Section("Appearance") {
        Picker(
          "Theme",
          selection: Binding(
            get: { model.theme ?? "" },
            set: { model.set("theme", nonEmpty($0)) }
          )
        ) {
          Text("Default").tag("")
          if let theme = model.theme, !model.themes.contains(theme) {
            Text(theme).tag(theme)
          }
          ForEach(model.themes, id: \.self) { Text($0).tag($0) }
        }
        LabeledContent("Background Opacity") {
          Slider(value: $opacity, in: 0.1 ... 1) { editing in
            draggingOpacity = editing
            if !editing { commitOpacity() }
          }
          // Arrow keys and VoiceOver adjust without an editing phase.
          .onChange(of: opacity) { if !draggingOpacity { commitOpacity() } }
          .accessibilityValue("\(Int((opacity * 100).rounded())) percent")
        }
        footnote("theme", "background-opacity")
      }
      Section("Cursor") {
        Picker(
          "Style",
          selection: Binding(
            get: { model.cursor },
            set: { model.set("cursor-style", $0.value) }
          )
        ) { ForEach(SettingsModel.Cursor.allCases) { Text($0.title).tag($0) } }
        Picker(
          "Blink",
          selection: Binding(
            get: { model.blink },
            set: { model.set("cursor-style-blink", $0.value) }
          )
        ) { ForEach(SettingsModel.Blink.allCases) { Text($0.title).tag($0) } }
        footnote("cursor-style", "cursor-style-blink")
      }
      Section("Mouse and Selection") {
        Toggle(
          "Copy on Select",
          isOn: Binding(
            get: { model.copyOnSelect },
            set: { model.set("copy-on-select", $0 ? "true" : "false") }
          )
        )
        Toggle(
          "Hide Pointer While Typing",
          isOn: Binding(
            get: { model.mouseHideWhileTyping },
            set: { model.set("mouse-hide-while-typing", $0 ? "true" : "false") }
          )
        )
        footnote("copy-on-select", "mouse-hide-while-typing")
      }
      Section {
        LabeledContent("File", value: model.url.path(percentEncoded: false))
          .textSelection(.enabled)
        if let error = model.error {
          Label(error, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
        }
        if model.problems.isEmpty {
          Text("No configuration problems.").foregroundStyle(.secondary)
        } else {
          ForEach(Array(model.problems.prefix(20).enumerated()), id: \.offset) {
            Label($0.element, systemImage: "exclamationmark.circle")
          }
        }
        Button("Edit Configuration File…") { editFile() }
      } header: {
        Text("Configuration")
      } footer: {
        Text(
          "Key bindings and every other option are set in the configuration file (Ghostty syntax). Settings changes rewrite only their own lines."
        )
      }
    }
    .formStyle(.grouped).onAppear(perform: sync)
    .onChange(of: model.configuration) { sync() }
  }

  private func commitOpacity() {
    let value = Self.number(opacity)
    guard value != Self.number(model.backgroundOpacity) else { return }
    model.set("background-opacity", value)
  }

  /// Text field and slider drafts follow the file between edits.
  private func sync() {
    family = model.fontFamily
    opacity = model.backgroundOpacity
  }

  @ViewBuilder
  private func footnote(_ keys: String...) -> some View {
    if keys.contains(where: model.overridden.contains) {
      Label(
        "An included configuration file overrides this setting.",
        systemImage: "info.circle"
      )
      .font(.footnote).foregroundStyle(.secondary)
    }
  }

  private func nonEmpty(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// `13` rather than `13.0`; at most two decimals.
  static func number(_ value: Double) -> String {
    let rounded = (value * 100).rounded() / 100
    return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
  }
}
