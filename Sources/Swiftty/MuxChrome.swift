import AppKit
import SwiftMuxProtocol

/// Local presentation of one workspace tab. Icons are chosen here from a
/// fixed local table; nothing a program sends picks an image.
struct MuxTabItem: Equatable {
  var id: TabID
  var title: String
  /// One icon per pane shown, the active pane's first (`MuxIcons`).
  var icons: [MuxIcon] = [.terminal]
  var isActive: Bool
  var hasActivity: Bool
  /// The tab's stored name, which a rename edits; nil for an unnamed tab
  /// (the service's number), which shows its program instead.
  var name: String?
  /// The tab's tooltip: the program for a named tab, and the pane count
  /// when split. Empty shows none.
  var detail: String = ""
}

/// A program's icon. It shows two ways: as a tile (the glyph in white on
/// the brand color, or on a dark neutral square) in tabs, and as the bare
/// glyph, tinted like the text beside it, in pane headers.
struct MuxIcon: Hashable, Sendable {
  /// An SF Symbol: the glyph without a brand, and the fallback when the
  /// brand's file is missing.
  var symbol: String
  /// A logo from developer-icons (`Sources/Swiftty/BrandIcons/<brand>.svg`,
  /// `Scripts/fetch-brand-icons.sh`), drawn by its alpha only.
  var brand: String?
  /// The tile's color as 0xRRGGBB; nil is the neutral tile.
  var tint: UInt32?

  init(symbol: String, brand: String? = nil, tint: UInt32? = nil) {
    self.symbol = symbol
    self.brand = brand
    self.tint = tint
  }

  static let terminal = MuxIcon(symbol: "terminal")
  static let claude = MuxIcon(
    symbol: "asterisk",
    brand: "claude-ai",
    tint: 0xD9_7757
  )
}

enum MuxIcons {
  /// Programs by a word of their title, first match wins.
  static let table: [([String], MuxIcon)] = [
    (["claude"], .claude),
    (
      ["codex", "openai", "chatgpt"],
      MuxIcon(symbol: "asterisk", brand: "openai", tint: 0x10_A37F)
    ),
    (
      ["copilot"],
      MuxIcon(symbol: "asterisk", brand: "github-copilot", tint: 0x83_4EF3)
    ), (["cursor"], MuxIcon(symbol: "asterisk", brand: "cursor-dark")),
    (["assistant", "aider"], MuxIcon(symbol: "asterisk")),
    (
      ["git", "tig", "lazygit", "gitui"],
      MuxIcon(symbol: "arrow.triangle.branch", brand: "git", tint: 0xF0_5032)
    ),
    (
      ["brew", "homebrew"],
      MuxIcon(symbol: "mug", brand: "homebrew", tint: 0xF2_A33A)
    ),
    (
      ["docker"],
      MuxIcon(symbol: "shippingbox", brand: "docker", tint: 0x1D_63ED)
    ),
    (
      ["node", "npm", "npx", "pnpm", "yarn"],
      MuxIcon(symbol: "terminal", brand: "nodejs", tint: 0x5F_A04E)
    ),
    (
      ["python", "python3", "ipython", "pip", "pip3"],
      MuxIcon(symbol: "terminal", brand: "python", tint: 0x37_76AB)
    ), (["go"], MuxIcon(symbol: "terminal", brand: "go", tint: 0x00_ADD8)),
    (
      ["cargo", "rustc", "rustup"],
      MuxIcon(symbol: "terminal", brand: "rust-dark", tint: 0xB7_410E)
    ),
    (["mysql"], MuxIcon(symbol: "cylinder", brand: "mysql", tint: 0x00_758F)),
    (["aws"], MuxIcon(symbol: "cloud", brand: "aws", tint: 0xFF_9900)),
    (
      ["nvim", "neovim"],
      MuxIcon(symbol: "doc.text", brand: "neovim", tint: 0x57_A143)
    ), (["vim", "emacs", "nano", "hx", "helix"], MuxIcon(symbol: "doc.text")),
    (
      ["snake", "game", "tetris", "nethack", "2048"],
      MuxIcon(symbol: "gamecontroller")
    ), (["top", "htop", "btop"], MuxIcon(symbol: "chart.bar")),
    (["ssh", "mosh"], MuxIcon(symbol: "network")),
    (["less", "man", "more"], MuxIcon(symbol: "book")),
  ]

  /// Brands of language runtimes: their process runs many tools, so a
  /// title naming the tool says more (`codex` runs as `node`).
  static let runtimes: Set<String> = ["nodejs", "python"]

  /// A pane's icon, most specific first: the name a script chose
  /// (`ui.setPaneIcon`), Claude Code's status glyph, the foreground
  /// program the service reports, then the title's words.
  static func icon(
    title: String,
    program: String? = nil,
    override: String? = nil
  ) -> MuxIcon {
    if let override, let icon = named(override) { return icon }
    if marker(of: title) != nil { return .claude }
    let fromTitle = match(title)
    if let program, let fromProgram = match(program) {
      if let brand = fromProgram.brand, runtimes.contains(brand), let fromTitle
      {
        return fromTitle
      }
      return fromProgram
    }
    return fromTitle ?? .terminal
  }

  /// The icon for a sanitized title, from the fixed local table.
  static func icon(for title: String) -> MuxIcon { icon(title: title) }

  /// A table icon by one of its keys ("git", "claude"), or "terminal".
  static func named(_ name: String) -> MuxIcon? {
    let key = name.lowercased()
    if key == "terminal" { return .terminal }
    return table.first { $0.0.contains(key) }?.1
  }

  /// The first table entry a word of `text` names.
  private static func match(_ text: String) -> MuxIcon? {
    let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }
      .map(String.init)
    return table.first { $0.0.contains(where: words.contains) }?.1
  }

  /// The SF Symbol for a sanitized title (the icon's fallback glyph).
  static func symbol(for title: String) -> String { icon(for: title).symbol }

  /// The title as shown beside its icon: without the status glyph Claude
  /// Code leads its title with, which the icon now stands for.
  static func displayTitle(_ title: String) -> String {
    guard let marker = marker(of: title) else { return title }
    return String(title[marker...]).trimmingCharacters(in: .whitespaces)
  }

  /// Where the title proper starts after Claude Code's leading status
  /// glyph ("✳ " idle, a braille spinner frame while working), or nil
  /// when it has none.
  private static func marker(of title: String) -> String.Index? {
    guard let first = title.unicodeScalars.first,
      first.value == 0x2733 || (0x2801 ... 0x28FF).contains(first.value)
    else { return nil }
    let scalars = title.unicodeScalars
    var rest = scalars.index(after: scalars.startIndex)
    // "✳️": the emoji presentation selector may follow.
    if rest < scalars.endIndex, scalars[rest].value == 0xFE0F {
      rest = scalars.index(after: rest)
    }
    guard rest < scalars.endIndex, scalars[rest] == " " else { return nil }
    return rest
  }

  static func image(_ symbol: String, _ label: String) -> NSImage? {
    NSImage(systemSymbolName: symbol, accessibilityDescription: label)
  }

  /// The icon's glyph as a template image: the brand's logo when its file
  /// loads, else the SF Symbol.
  static func image(_ icon: MuxIcon) -> NSImage? {
    icon.brand.flatMap(brandImage) ?? image(icon.symbol, "")
  }

  static func brandImage(_ name: String) -> NSImage? {
    if let cached = brandCache[name] { return cached }
    guard
      let url = Bundle.module.url(
        forResource: name,
        withExtension: "svg",
        subdirectory: "BrandIcons"
      ), let image = NSImage(contentsOf: url)
    else { return nil }
    image.isTemplate = true
    brandCache[name] = image
    return image
  }

  nonisolated(unsafe) private static var brandCache: [String: NSImage] = [:]
}

/// A small filled circle marking unseen output.
@MainActor
final class MuxActivityDot: NSView {
  /// A ring around the dot, cutting it out of what it overlaps (a tab's
  /// icon badge); nil draws none.
  var ring: NSColor? { didSet { needsDisplay = true } }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 3
    translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: 6),
      heightAnchor.constraint(equalToConstant: 6),
    ])
    setAccessibilityElement(false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func updateLayer() {
    layer?.backgroundColor = NSColor.controlAccentColor.cgColor
    layer?.borderWidth = ring == nil ? 0 : 1.5
    layer?.borderColor = ring?.cgColor
  }

  override var wantsUpdateLayer: Bool { true }
}

/// One icon as a tile: a rounded square in the brand's color (or dark
/// and neutral) with the glyph in white.
@MainActor
final class MuxIconTile: NSView {
  let glyph = NSImageView()
  private var glyphSize: [NSLayoutConstraint] = []

  var icon: MuxIcon? {
    didSet {
      guard icon != oldValue else { return }
      let brand = icon?.brand.flatMap(MuxIcons.brandImage)
      glyph.image = brand ?? icon.flatMap { MuxIcons.image($0.symbol, "") }
      // A logo fills its share of the tile; a symbol keeps its point size.
      glyph.imageScaling =
        brand == nil ? .scaleProportionallyDown : .scaleProportionallyUpOrDown
      needsDisplay = true
    }
  }

  /// The tile's background for `icon`.
  var fill: NSColor {
    guard let tint = icon?.tint else { return NSColor(white: 0.16, alpha: 1) }
    return NSColor(
      srgbRed: CGFloat(tint >> 16 & 0xFF) / 255,
      green: CGFloat(tint >> 8 & 0xFF) / 255,
      blue: CGFloat(tint & 0xFF) / 255,
      alpha: 1
    )
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    translatesAutoresizingMaskIntoConstraints = false
    glyph.translatesAutoresizingMaskIntoConstraints = false
    glyph.setAccessibilityElement(false)
    glyph.contentTintColor = .white
    glyph.symbolConfiguration = .init(pointSize: 10, weight: .medium)
    addSubview(glyph)
    NSLayoutConstraint.activate([
      glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
      glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
      glyph.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.6),
      glyph.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.6),
      widthAnchor.constraint(equalTo: heightAnchor),
    ])
    setAccessibilityElement(false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    guard let layer else { return }
    layer.cornerCurve = .continuous
    layer.cornerRadius = (bounds.height * 0.28).rounded()
    layer.backgroundColor = fill.cgColor
    layer.borderWidth = 1
    layer.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
  }

  override func layout() {
    super.layout()
    layer?.cornerRadius = (bounds.height * 0.28).rounded()
  }
}

/// A tab's icons as tiles: the active pane's in front and, for a split
/// tab, the next pane's peeking out behind it.
@MainActor
final class MuxTabIconBadge: NSView {
  /// How far a tile behind shows past the one in front.
  static let peek: CGFloat = 7
  private(set) var tiles: [MuxIconTile] = []
  private var width: NSLayoutConstraint!

  var icons: [MuxIcon] = [] {
    didSet {
      guard icons != oldValue else { return }
      let shown = Array(icons.prefix(2))
      while tiles.count < shown.count {
        let tile = MuxIconTile()
        // Each later tile sits behind the ones before it.
        addSubview(tile, positioned: .below, relativeTo: tiles.last)
        NSLayoutConstraint.activate([
          tile.topAnchor.constraint(equalTo: topAnchor),
          tile.bottomAnchor.constraint(equalTo: bottomAnchor),
          tile.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: CGFloat(tiles.count) * Self.peek
          ),
        ])
        tiles.append(tile)
      }
      for (index, tile) in tiles.enumerated() {
        tile.isHidden = index >= shown.count
        tile.icon = index < shown.count ? shown[index] : nil
        tile.alphaValue = index == 0 ? 1 : 0.85
      }
      width.constant = CGFloat(max(shown.count - 1, 0)) * Self.peek
    }
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    translatesAutoresizingMaskIntoConstraints = false
    width = widthAnchor.constraint(equalTo: heightAnchor)
    width.isActive = true
    setAccessibilityElement(false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }
}

// MARK: Tab strip

/// The window-level tab strip: icon, title, activity marker and close
/// button per tab. Double-click renames. In the toolbar (`window.tabs`
/// top) tabs sit in a row and narrow windows scroll horizontally; in the
/// sidebar (left) they stack in a column that scrolls vertically.
@MainActor
final class MuxTabStrip: NSGlassEffectContainerView {
  var onSelect: ((TabID) -> Void)?
  var onClose: ((TabID) -> Void)?
  var onRename: ((TabID, String) -> Void)?
  /// A rename edit ended, however it did (renamed, unchanged, cancelled,
  /// or its field went away).
  var onRenameEnded: (() -> Void)?
  /// Tabs stack in a column (the sidebar) rather than a row (the toolbar).
  var isVertical = false {
    didSet { if isVertical != oldValue { applyOrientation() } }
  }
  private let stack = NSStackView()
  private let scrollView = NSScrollView()
  private(set) var buttons: [MuxTabButton] = []
  private var rowConstraints: [NSLayoutConstraint] = []
  private var columnConstraints: [NSLayoutConstraint] = []
  /// Each button spans the column's width while vertical.
  private var buttonWidths: [NSLayoutConstraint] = []
  static let columnSpacing: CGFloat = 4
  static let rowHeight: CGFloat = 34
  static let rowSpacing: CGFloat = 6

  override init(frame: NSRect) {
    super.init(frame: frame)
    let content = NSView(frame: bounds)
    content.autoresizingMask = [.width, .height]
    contentView = content
    stack.orientation = .horizontal
    stack.spacing = Self.rowSpacing
    stack.alignment = .centerY
    // A flipped clip keeps a short column at the top of the sidebar.
    scrollView.contentView = FlippedClipView()
    scrollView.drawsBackground = false
    scrollView.horizontalScrollElasticity = .none
    scrollView.verticalScrollElasticity = .none
    scrollView.autohidesScrollers = true
    scrollView.automaticallyAdjustsContentInsets = false
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.documentView = stack
    content.addSubview(scrollView)
    rowConstraints = [
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
      scrollView.trailingAnchor.constraint(
        equalTo: trailingAnchor,
        constant: -6
      ), scrollView.centerYAnchor.constraint(equalTo: centerYAnchor),
      scrollView.heightAnchor.constraint(
        equalToConstant: MuxTabButton.rowHeight
      ), widthAnchor.constraint(greaterThanOrEqualToConstant: 102),
      heightAnchor.constraint(equalToConstant: Self.rowHeight),
    ]
    columnConstraints = [
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      scrollView.trailingAnchor.constraint(
        equalTo: trailingAnchor,
        constant: -8
      ), scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
    ]
    NSLayoutConstraint.activate(rowConstraints)
    setContentHuggingPriority(.defaultHigh, for: .horizontal)
    setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    setAccessibilityRole(.tabGroup)
    setAccessibilityLabel("Workspace tabs")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override var intrinsicContentSize: NSSize {
    guard !isVertical else {
      return NSSize(
        width: NSView.noIntrinsicMetric,
        height: NSView.noIntrinsicMetric
      )
    }
    return NSSize(
      width: max(102, stack.fittingSize.width + 12),
      height: Self.rowHeight
    )
  }

  override func layout() {
    super.layout()
    sizeStack()
    stack.layoutSubtreeIfNeeded()
  }

  /// The stack is the scroll view's document, sized by frame: a column of
  /// rows, or a row as wide as its tabs (at least the strip).
  private func sizeStack() {
    if isVertical {
      let rows = CGFloat(buttons.count)
      stack.setFrameSize(
        NSSize(
          width: scrollView.contentSize.width,
          height: max(
            0,
            rows * MuxTabButton.columnHeight + (rows - 1) * Self.columnSpacing
          )
        )
      )
    } else {
      stack.setFrameSize(
        NSSize(
          width: max(stack.fittingSize.width, scrollView.bounds.width),
          height: MuxTabButton.rowHeight
        )
      )
    }
  }

  private func applyOrientation() {
    let (old, new) =
      isVertical
      ? (rowConstraints, columnConstraints)
      : (columnConstraints, rowConstraints)
    NSLayoutConstraint.deactivate(old)
    NSLayoutConstraint.activate(new)
    stack.orientation = isVertical ? .vertical : .horizontal
    stack.alignment = isVertical ? .leading : .centerY
    stack.spacing = isVertical ? Self.columnSpacing : Self.rowSpacing
    scrollView.hasVerticalScroller = isVertical
    scrollView.verticalScrollElasticity = isVertical ? .allowed : .none
    for b in buttons { b.isVertical = isVertical }
    sizeStack()
    fitButtons()
    stack.setFrameOrigin(.zero)
    scrollView.contentView.scroll(to: .zero)
    invalidateIntrinsicContentSize()
    needsLayout = true
  }

  /// Buttons span the column while vertical; in a row they size to fit.
  private func fitButtons() {
    NSLayoutConstraint.deactivate(buttonWidths)
    buttonWidths =
      isVertical
      ? buttons.map {
        $0.widthAnchor.constraint(equalTo: stack.widthAnchor)
          .withPriority(.required - 1)
      } : []
    NSLayoutConstraint.activate(buttonWidths)
  }

  func update(_ items: [MuxTabItem]) {
    // Each tab keeps its button, and so any rename open on it, when other
    // tabs come or go; buttons of tabs gone are reused or removed.
    let shown = Set(items.map(\.id))
    var kept: [TabID: MuxTabButton] = [:]
    var spare: [MuxTabButton] = []
    for b in buttons {
      if let id = b.item?.id, shown.contains(id), kept[id] == nil {
        kept[id] = b
      } else {
        spare.append(b)
      }
    }
    let next = items.map { item in
      // Each button serves one tab, even if a snapshot repeats an id.
      let b =
        kept.removeValue(forKey: item.id) ?? spare.popLast() ?? MuxTabButton()
      b.strip = self
      b.isVertical = isVertical
      b.item = item
      return b
    }
    for b in spare {
      // Showing no tab ends an open rename, so removal cannot commit it.
      b.item = nil
      stack.removeArrangedSubview(b)
      b.removeFromSuperview()
    }
    // Only buttons out of place move.
    for (i, b) in next.enumerated() {
      let arranged = stack.arrangedSubviews
      if i < arranged.count, arranged[i] === b { continue }
      stack.insertArrangedSubview(b, at: i)
    }
    buttons = next
    fitButtons()
    invalidateIntrinsicContentSize()
    needsLayout = true
    // Sized first: rows laid out in a stack of no size cannot fit.
    sizeStack()
    layoutSubtreeIfNeeded()
    if let active = buttons.first(where: { $0.item?.isActive == true }) {
      active.scrollToVisible(active.bounds)
    }
  }
}

extension NSLayoutConstraint {
  fileprivate func withPriority(
    _ priority: NSLayoutConstraint.Priority
  ) -> NSLayoutConstraint {
    self.priority = priority
    return self
  }
}

/// Keeps a document shorter than its scroll view at the top.
private final class FlippedClipView: NSClipView {
  override var isFlipped: Bool { true }
}

/// The column beside the panes that holds the tab strip when
/// `window.tabs` is left. It reaches the window's top edge (the toolbar
/// hides): its top row holds the sidebar controls, after the window
/// controls, and the tabs fill the rest. It draws nothing of its own: the
/// window shows through.
@MainActor
final class MuxTabSidebar: NSView {
  static let width: CGFloat = 220
  /// The top row's least height, and its edge insets.
  static let rowHeight: CGFloat = 40
  static let rowInset: CGFloat = 10
  /// Beside the window controls the row centres on them, at least as tall
  /// as its buttons.
  static let controlsHeight: CGFloat = 28
  private let row = NSView()
  private var rowLeading: NSLayoutConstraint!
  private var rowHeightConstraint: NSLayoutConstraint!

  override init(frame: NSRect) {
    super.init(frame: frame)
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    rowLeading = row.leadingAnchor.constraint(
      equalTo: leadingAnchor,
      constant: Self.rowInset
    )
    rowHeightConstraint = row.heightAnchor.constraint(
      equalToConstant: Self.rowHeight
    )
    NSLayoutConstraint.activate([
      rowLeading, rowHeightConstraint,
      row.topAnchor.constraint(equalTo: topAnchor),
      row.trailingAnchor.constraint(
        equalTo: trailingAnchor,
        constant: -Self.rowInset
      ),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  /// Shows `strip` filling the column below the top row.
  func host(_ strip: NSView) {
    strip.translatesAutoresizingMaskIntoConstraints = false
    addSubview(strip)
    NSLayoutConstraint.activate([
      strip.leadingAnchor.constraint(equalTo: leadingAnchor),
      strip.trailingAnchor.constraint(equalTo: trailingAnchor),
      strip.topAnchor.constraint(equalTo: row.bottomAnchor),
      strip.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  /// Shows the sidebar controls across the top row.
  func showControls(_ controls: NSView) {
    guard controls.superview !== row else { return }
    controls.removeFromSuperview()
    controls.translatesAutoresizingMaskIntoConstraints = false
    row.addSubview(controls)
    NSLayoutConstraint.activate([
      controls.leadingAnchor.constraint(equalTo: row.leadingAnchor),
      controls.trailingAnchor.constraint(equalTo: row.trailingAnchor),
      controls.centerYAnchor.constraint(equalTo: row.centerYAnchor),
    ])
  }

  override var mouseDownCanMoveWindow: Bool { true }

  // The row's constraints change in the constraint pass, not in layout.
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    needsUpdateConstraints = true
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    needsUpdateConstraints = true
  }

  /// The row starts after the window controls and centres on them; in
  /// full screen (they hide) it starts at the edge.
  override func updateConstraints() {
    defer { super.updateConstraints() }
    var leading = Self.rowInset
    var height = Self.rowHeight
    if let window, !window.styleMask.contains(.fullScreen),
      let zoom = window.standardWindowButton(.zoomButton), !zoom.isHidden,
      zoom.window === window
    {
      let buttons = zoom.convert(zoom.bounds, to: self)
      leading = max(leading, buttons.maxX + 12)
      height = max(Self.controlsHeight, 2 * (bounds.maxY - buttons.midY))
    }
    if abs(rowLeading.constant - leading) > 0.5 {
      rowLeading.constant = leading
    }
    if abs(rowHeightConstraint.constant - height) > 0.5 {
      rowHeightConstraint.constant = height
    }
  }
}

/// Calls `action` with each window that becomes key while it lives (its
/// own registration, removed with it).
@MainActor
private final class KeyWindowWatcher: NSObject {
  private let action: (NSWindow) -> Void

  init(_ action: @escaping (NSWindow) -> Void) {
    self.action = action
    super.init()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(changed(_:)),
      name: NSWindow.didBecomeKeyNotification,
      object: nil
    )
  }

  @objc
  private func changed(_ notification: Notification) {
    if let key = notification.object as? NSWindow { action(key) }
  }
}

/// A tab title that reports an abandoned edit, which (unlike one that
/// ends) does not reach the delegate.
@MainActor
final class MuxTabLabel: NSTextField {
  var onAbort: (() -> Void)?

  @discardableResult
  override func abortEditing() -> Bool {
    let aborted = super.abortEditing()
    if aborted { onAbort?() }
    return aborted
  }
}

/// A tab's glass: drawn behind the button's content; clicks on it reach
/// the button.
@MainActor
private final class MuxTabGlass: NSGlassEffectView {
  override var mouseDownCanMoveWindow: Bool { false }
}

/// One tab: its icons as tiles, then its title. In a row (the
/// toolbar) it is a glass capsule; in a column (the sidebar) a full-width
/// row, a glass capsule only when active.
@MainActor
final class MuxTabButton: NSView, NSTextFieldDelegate {
  static let columnHeight: CGFloat = 30
  static let rowHeight: CGFloat = 28
  weak var strip: MuxTabStrip?
  private let glass = MuxTabGlass()
  /// The tab's icon, titles and actions. Glass draws over its siblings, so
  /// while it shows, this lives in its content view; otherwise in the
  /// button. Its subviews' constraints are all within it, so moving it
  /// keeps them.
  private let content = NSView()
  private let badge = MuxTabIconBadge()
  let label = MuxTabLabel(labelWithString: "")
  private let dot = MuxActivityDot()
  let closeButton = NSButton()
  /// A rename is open. It renames `item`: setting `item` to another tab
  /// cancels it.
  private var renaming = false
  /// The person changed the rename's text since it opened; only then does
  /// ending it rename.
  private var edited = false
  /// While a rename is open: ends it when another window takes the keys.
  private var keyWatcher: KeyWindowWatcher?
  private var hovered = false {
    didSet { if hovered != oldValue { refreshAppearance() } }
  }
  private var rowConstraints: [NSLayoutConstraint] = []
  private var columnConstraints: [NSLayoutConstraint] = []
  private var badgeLeading: NSLayoutConstraint!
  private var badgeSize: NSLayoutConstraint!
  private var labelLeading: NSLayoutConstraint!
  private var closeTrailing: NSLayoutConstraint!

  /// Laid out as a sidebar row rather than a toolbar pill.
  var isVertical = false {
    didSet {
      guard isVertical != oldValue else { return }
      NSLayoutConstraint.deactivate(
        isVertical ? rowConstraints : columnConstraints
      )
      NSLayoutConstraint.activate(
        isVertical ? columnConstraints : rowConstraints
      )
      applyMetrics()
      updateTrackingAreas()
      refreshAppearance()
    }
  }

  var item: MuxTabItem? {
    didSet {
      // An open rename belongs to the tab it began on: serving another
      // tab, or none, ends it without renaming.
      if oldValue?.id != item?.id { cancelRename() }
      guard let item, item != oldValue else { return }
      badge.icons = item.icons
      toolTip = item.detail.isEmpty ? nil : item.detail
      dot.isHidden = !item.hasActivity
      showTitle()
      refreshAppearance()
    }
  }

  /// The second line a column used to show: the program (for a named
  /// tab) and the pane count, now the row's tooltip (tests).
  var detailText: String { toolTip ?? "" }

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.cornerCurve = .continuous
    glass.style = .regular
    glass.effectIsInteractive = true
    glass.frame = bounds
    glass.autoresizingMask = [.width, .height]
    addSubview(glass)
    content.translatesAutoresizingMaskIntoConstraints = false
    label.translatesAutoresizingMaskIntoConstraints = false
    label.lineBreakMode = .byTruncatingTail
    label.delegate = self
    label.onAbort = { [weak self] in self?.cancelRename() }
    label.setAccessibilityElement(false)
    dot.ring = .windowBackgroundColor
    closeButton.image = MuxIcons.image("xmark", "End tab")
    closeButton.toolTip = "End Tab (terminates its processes)"
    closeButton.isBordered = false
    closeButton.bezelStyle = .accessoryBarAction
    closeButton.target = self
    closeButton.action = #selector(closeClicked)
    closeButton.translatesAutoresizingMaskIntoConstraints = false
    for v in [badge, label, dot, closeButton] as [NSView] {
      content.addSubview(v)
    }
    badgeLeading = badge.leadingAnchor.constraint(
      equalTo: content.leadingAnchor
    )
    badgeSize = badge.heightAnchor.constraint(equalToConstant: 18)
    labelLeading = label.leadingAnchor.constraint(equalTo: badge.trailingAnchor)
    closeTrailing = closeButton.trailingAnchor.constraint(
      equalTo: content.trailingAnchor
    )
    NSLayoutConstraint.activate([
      badgeLeading, badgeSize, labelLeading, closeTrailing,
      badge.centerYAnchor.constraint(equalTo: content.centerYAnchor),
      label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
      // Unseen output marks the badge's lower trailing corner.
      dot.centerXAnchor.constraint(equalTo: badge.trailingAnchor, constant: -2),
      dot.centerYAnchor.constraint(equalTo: badge.bottomAnchor, constant: -2),
      closeButton.centerYAnchor.constraint(equalTo: content.centerYAnchor),
    ])
    // Widths yield to a stack not yet sized (zero wide before its first
    // layout): a required width there is unsatisfiable, and AppKit throws.
    rowConstraints = [
      heightAnchor.constraint(equalToConstant: Self.rowHeight),
      widthAnchor.constraint(lessThanOrEqualToConstant: 260)
        .withPriority(.required - 1),
      widthAnchor.constraint(greaterThanOrEqualToConstant: 110)
        .withPriority(.required - 1),
      closeButton.leadingAnchor.constraint(
        equalTo: label.trailingAnchor,
        constant: 4
      ),
    ]
    columnConstraints = [
      heightAnchor.constraint(equalToConstant: Self.columnHeight),
      label.trailingAnchor.constraint(
        lessThanOrEqualTo: closeButton.leadingAnchor,
        constant: -4
      ),
    ]
    NSLayoutConstraint.activate(rowConstraints)
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    setAccessibilityElement(true)
    setAccessibilityRole(.radioButton)
    applyMetrics()
    refreshAppearance()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  /// Sizes for the current orientation: a capsule either way.
  private func applyMetrics() {
    let height = isVertical ? Self.columnHeight : Self.rowHeight
    badgeLeading.constant = isVertical ? 5 : 4
    badgeSize.constant = 20
    labelLeading.constant = isVertical ? 9 : 8
    closeTrailing.constant = isVertical ? -8 : -8
    glass.cornerRadius = height / 2
    layer?.cornerRadius = height / 2
    closeButton.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
  }

  /// Fonts, glass and hover for the current tab and orientation.
  private func refreshAppearance() {
    let active = item?.isActive == true
    label.font =
      active
      ? .systemFont(ofSize: 13, weight: .medium) : .systemFont(ofSize: 13)
    label.textColor = active ? .labelColor : .secondaryLabelColor
    // The active pill reads lighter, edged by a hairline.
    glass.tintColor = NSColor.white.withAlphaComponent(active ? 0.14 : 0.03)
    layer?.borderWidth = active ? 1 : 0
    layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
    // A row always reads as a pill; a column shows glass on its active row.
    glass.isHidden = isVertical && !active
    if glass.isHidden, content.superview !== self {
      glass.contentView = nil
      addSubview(content)
      pinContent()
    } else if !glass.isHidden, glass.contentView !== content {
      content.removeFromSuperview()
      glass.contentView = content
      pinContent()
    }
    // A column offers End Tab on the row under the pointer or the active
    // one, so a click on a row's empty edge never ends it.
    closeButton.isHidden = isVertical && !active && !hovered
    // A row keeps its close button's place (tabs keep their widths) and
    // shows it only on the active tab or the one under the pointer.
    closeButton.alphaValue = isVertical || active || hovered ? 1 : 0
    closeButton.contentTintColor = .secondaryLabelColor
    needsDisplay = true
  }

  /// The content fills the button wherever it lives; moving it dropped
  /// its edges, and the button's size follows from its content.
  private func pinContent() {
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: leadingAnchor),
      content.trailingAnchor.constraint(equalTo: trailingAnchor),
      content.topAnchor.constraint(equalTo: topAnchor),
      content.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  /// Whether the title draws inside the glass, above it (tests).
  var titleIsInGlass: Bool { !glass.isHidden && label.isDescendant(of: glass) }

  /// Whether the glass shows (tests).
  var showsGlass: Bool { !glass.isHidden }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    let highlight = isVertical && hovered && item?.isActive != true
    layer?.backgroundColor =
      highlight ? NSColor.labelColor.withAlphaComponent(0.06).cgColor : nil
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas where area.owner === self {
      removeTrackingArea(area)
    }
    addTrackingArea(
      NSTrackingArea(
        rect: .zero,
        options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
        owner: self
      )
    )
  }

  override func mouseEntered(with event: NSEvent) { hovered = true }

  override func mouseExited(with event: NSEvent) { hovered = false }

  override var mouseDownCanMoveWindow: Bool { false }

  override func mouseDown(with event: NSEvent) {
    guard let item else { return }
    if event.clickCount == 2 {
      beginRename()
    } else {
      strip?.onSelect?(item.id)
    }
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    // A fallback for an edit still open as its field changes window (a
    // toolbar moving for full screen): it cannot follow, so it ends as
    // losing focus does (typed text renames). Removing or hiding the field
    // ends an edit through the delegate before this runs.
    guard renaming, newWindow !== window else { return }
    endAsFocusLoss()
  }

  /// Ends the edit as losing focus does (typed text renames) when its
  /// field editor still holds the window's keys; otherwise, or if it would
  /// not end, drops it.
  private func endAsFocusLoss() {
    if let window, let editor = label.currentEditor(),
      window.firstResponder === editor
    {
      window.makeFirstResponder(nil)
    }
    cancelRename()
  }

  /// Ends an open edit without renaming: Escape, the label could not take
  /// focus, the button now serves another tab (or none), or (as a last
  /// resort) the field moved window, or another window took the keys,
  /// without its edit ending.
  /// AppKit abandoning the edit reports here too.
  private func cancelRename() {
    guard renaming else { return }
    // Closed first: however ending the field editor reports back, it finds
    // no rename open (and an editor AppKit already abandoned stays ended).
    renaming = false
    label.abortEditing()
    endEditing()
    strip?.onRenameEnded?()
  }

  func beginRename() {
    // A strip out of sight (a full-screen toolbar auto-hidden) has no field
    // to type in; a minimized window comes back below.
    guard !renaming, let item, let window,
      window.isVisible || window.isMiniaturized
    else { return }
    renaming = true
    edited = false
    label.isEditable = true
    label.isBezeled = false
    label.drawsBackground = false
    // Edit the whole stored name, not the shortened label. An unnamed tab
    // starts empty, its program's title (perhaps cut) a placeholder.
    label.stringValue = item.name ?? ""
    label.placeholderString = item.title
    guard window.makeFirstResponder(label) else { return cancelRename() }
    // The field's window must hold the keys for typing to reach it: a
    // rename from the menu may come while another window is in front, and
    // in full screen the strip lives in AppKit's toolbar window.
    window.makeKeyAndOrderFront(nil)
    label.currentEditor()?.selectAll(nil)
    // Any window: the keys may come back to the app in another one.
    keyWatcher = KeyWindowWatcher { [weak self] key in
      self?.keyWindowChanged(key)
    }
  }

  /// The keys moved to another of the app's windows (in full screen,
  /// from the toolbar window to the workspace; or back from another app
  /// into a different window): the edit ends as losing focus does. The app
  /// merely going inactive leaves it open.
  private func keyWindowChanged(_ key: NSWindow) {
    // Floating panels (a picker, an inspector) serve the edit rather than
    // end it; other panels, popovers among them, take the person elsewhere.
    guard renaming, key !== window, (key as? NSPanel)?.isFloatingPanel != true
    else { return }
    endAsFocusLoss()
  }

  /// Escape cancels the rename.
  func control(
    _ control: NSControl,
    textView: NSTextView,
    doCommandBy selector: Selector
  ) -> Bool {
    guard selector == #selector(NSResponder.cancelOperation(_:)) else {
      return false
    }
    cancelRename()
    return true
  }

  func controlTextDidChange(_ obj: Notification) { edited = true }

  func controlTextDidEndEditing(_ obj: Notification) {
    guard renaming else { return }
    renaming = false
    let typed = label.stringValue
    endEditing()
    defer { strip?.onRenameEnded?() }
    // Only typing renames, and only to a name the tab does not hold now
    // (another client may have renamed it meanwhile). A cancel movement
    // (an input method, accessibility; Escape cancels before this) renames
    // nothing. The label shows the stored title until a rename lands.
    let movement = obj.userInfo?[NSText.movementUserInfoKey] as? Int
    guard edited, movement != NSTextMovement.cancel.rawValue, let item,
      let name = DisplayText.plainName(typed), name != item.name
    else { return }
    strip?.onRename?(item.id, name)
  }

  private func endEditing() {
    keyWatcher = nil
    label.isEditable = false
    label.isSelectable = false
    label.placeholderString = nil
    showTitle()
  }

  /// Shows the tab's title, or while a name is being typed, its
  /// placeholder.
  private func showTitle() {
    guard let item else { return }
    if renaming {
      label.placeholderString = item.title
    } else {
      label.stringValue = item.title
    }
    closeButton.setAccessibilityLabel("End tab \(item.title)")
    setAccessibilityLabel(item.title + (item.hasActivity ? ", new output" : ""))
  }

  @objc
  private func closeClicked() { if let item { strip?.onClose?(item.id) } }

  override func accessibilityValue() -> Any? { item?.isActive == true }

  override func accessibilityPerformPress() -> Bool {
    guard let item else { return false }
    strip?.onSelect?(item.id)
    return true
  }
}

// MARK: Pane chrome

/// What the header shows for one pane.
struct MuxPaneHeaderState: Equatable {
  var title: String
  var isActive: Bool
  var hasActivity: Bool
  var isZoomed: Bool
  var hasExited: Bool
  /// The pane's program icon (`MuxWorkspaceController.icon(of:)`).
  var icon: MuxIcon = .terminal
}

/// A pane's header (icon, title, actions) above its Metal view.
/// In a split tab the pane is a rounded card: header on top, the terminal
/// inset below it. A single pane fills its area with no header.
@MainActor
final class MuxPaneContainer: NSView {
  static let headerHeight: CGFloat = 34
  static let cornerRadius: CGFloat = 10
  /// Space between the card's edge and its terminal (sides and bottom).
  static let cardInset: CGFloat = 8
  let paneView: MuxPaneView
  let header = MuxPaneHeader()
  /// The terminal's background, which a card shows around its terminal so
  /// the whole pane reads as one surface.
  var terminalBackground: NSColor? { didSet { needsDisplay = true } }
  /// What the card wears: the terminal's drawn default background (a
  /// program may set its own) at the theme background's opacity.
  var cardBackground: NSColor? {
    guard let base = terminalBackground else { return nil }
    guard let bg = paneView.drawnBackground else { return base }
    return NSColor(
      srgbRed: CGFloat(bg >> 16 & 0xFF) / 255,
      green: CGFloat(bg >> 8 & 0xFF) / 255,
      blue: CGFloat(bg & 0xFF) / 255,
      alpha: base.alphaComponent
    )
  }
  var showsHeader = true {
    didSet {
      header.isHidden = !showsHeader
      paneView.inCard = showsHeader
      if oldValue != showsHeader {
        needsLayout = true
        needsDisplay = true
      }
    }
  }

  init(paneView: MuxPaneView) {
    self.paneView = paneView
    super.init(frame: .zero)
    paneView.inCard = showsHeader
    paneView.onBackgroundChange = { [weak self] in self?.needsDisplay = true }
    wantsLayer = true
    layer?.cornerCurve = .continuous
    addSubview(header)
    addSubview(paneView)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
  }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    guard let layer else { return }
    layer.cornerRadius = showsHeader ? Self.cornerRadius : 0
    layer.masksToBounds = showsHeader
    layer.borderWidth = showsHeader ? 1 : 0
    layer.borderColor = NSColor.white.withAlphaComponent(0.06).cgColor
    layer.backgroundColor =
      showsHeader
      ? (cardBackground ?? NSColor.labelColor.withAlphaComponent(0.04)).cgColor
      : nil
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func layout() {
    super.layout()
    let h = showsHeader ? min(Self.headerHeight, bounds.height) : 0
    let inset = showsHeader ? Self.cardInset : 0
    header.frame = NSRect(
      x: 0,
      y: bounds.height - h,
      width: bounds.width,
      height: h
    )
    // Re-adding a removed pane view (tests) must restore its frame.
    if paneView.superview === self {
      paneView.frame = NSRect(
        x: inset,
        y: inset,
        width: max(0, bounds.width - 2 * inset),
        height: max(0, bounds.height - h - inset)
      )
    }
  }

  override func didAddSubview(_ subview: NSView) {
    super.didAddSubview(subview)
    needsLayout = true
  }

  /// The whole card, terminal included, reveals the header's actions.
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas where area.owner === self {
      removeTrackingArea(area)
    }
    addTrackingArea(
      NSTrackingArea(
        rect: .zero,
        options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
        owner: self
      )
    )
  }

  // Only the card's own area counts: a terminal's tracking events may
  // come up the responder chain.
  override func mouseEntered(with event: NSEvent) {
    guard event.trackingArea?.owner === self else {
      return super.mouseEntered(with: event)
    }
    header.isHovered = true
  }

  override func mouseExited(with event: NSEvent) {
    guard event.trackingArea?.owner === self else {
      return super.mouseExited(with: event)
    }
    header.isHovered = false
  }

  func update(_ state: MuxPaneHeaderState) {
    header.state = state
    setAccessibilityLabel(
      "Pane \(state.title)" + (state.isActive ? ", active" : "")
        + (state.hasExited ? ", exited" : "")
    )
    paneView.setAccessibilityLabel("Terminal: \(state.title)")
  }
}

@MainActor
final class MuxPaneHeader: NSView {
  enum Action { case splitRight, splitDown, zoom, close }
  var onAction: ((Action) -> Void)?
  /// The program's icon, chosen locally from its title (`MuxIcons`).
  private let icon = NSImageView()
  private let label = NSTextField(labelWithString: "")
  private let dot = MuxActivityDot()
  private let buttons = NSStackView()
  private(set) var actionButtons: [Action: NSButton] = [:]
  private var iconLeading: NSLayoutConstraint!
  private var accessoryConstraints: [NSLayoutConstraint] = []
  /// Shown before the icon: the sidebar controls while the sidebar is
  /// collapsed, on the top-left pane.
  private(set) weak var accessory: NSView?
  /// Room left before the accessory (the window controls over this pane).
  private(set) var accessoryInset: CGFloat = 0
  /// The pointer is over the pane; its card tracks this for the header.
  var isHovered = false {
    didSet { if isHovered != oldValue { refreshActions() } }
  }

  var state = MuxPaneHeaderState(
    title: "",
    isActive: false,
    hasActivity: false,
    isZoomed: false,
    hasExited: false
  ) {
    didSet {
      guard state != oldValue else { return }
      let title = MuxIcons.displayTitle(state.title)
      label.stringValue = state.hasExited ? "\(title) (exited)" : title
      // The active pane reads at full strength, the others dimmed.
      label.textColor = state.isActive ? .labelColor : .secondaryLabelColor
      icon.contentTintColor = label.textColor
      let program = state.icon
      let brand = program.brand.flatMap(MuxIcons.brandImage)
      icon.image = brand ?? MuxIcons.image(program.symbol, "")
      icon.imageScaling =
        brand == nil ? .scaleProportionallyDown : .scaleProportionallyUpOrDown
      dot.isHidden = !state.hasActivity
      actionButtons[.zoom]?.image = MuxIcons.image(
        state.isZoomed
          ? "arrow.down.right.and.arrow.up.left"
          : "arrow.up.left.and.arrow.down.right",
        "Zoom"
      )
      actionButtons[.zoom]?
        .setAccessibilityLabel(state.isZoomed ? "Unzoom pane" : "Zoom pane")
    }
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    // Part of the card: no band or separator of its own.
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
    icon.setAccessibilityElement(false)
    label.font = .systemFont(ofSize: 13)
    label.lineBreakMode = .byTruncatingTail
    label.translatesAutoresizingMaskIntoConstraints = false
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    buttons.orientation = .horizontal
    buttons.spacing = 6
    buttons.translatesAutoresizingMaskIntoConstraints = false
    for (action, symbol, title) in [
      (Action.splitRight, "square.split.2x1", "Split right"),
      (.splitDown, "square.split.1x2", "Split down"),
      (.zoom, "arrow.up.left.and.arrow.down.right", "Zoom pane"),
      (.close, "xmark", "End pane"),
    ] {
      let b = NSButton()
      b.image = MuxIcons.image(symbol, title)
      b.symbolConfiguration = .init(pointSize: 12, weight: .light)
      b.contentTintColor = .tertiaryLabelColor
      b.isBordered = false
      b.bezelStyle = .accessoryBarAction
      b.toolTip = title
      b.setAccessibilityLabel(title)
      b.target = self
      b.action = #selector(clicked(_:))
      b.tag = [.splitRight, .splitDown, .zoom, .close].firstIndex(of: action)!
      actionButtons[action] = b
      buttons.addArrangedSubview(b)
    }
    for v in [icon, label, dot, buttons] as [NSView] { addSubview(v) }
    iconLeading = icon.leadingAnchor.constraint(
      equalTo: leadingAnchor,
      constant: 12
    )
    NSLayoutConstraint.activate([
      iconLeading, icon.centerYAnchor.constraint(equalTo: centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: 16),
      icon.heightAnchor.constraint(equalToConstant: 15),
      label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
      dot.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4),
      dot.centerYAnchor.constraint(equalTo: centerYAnchor),
      // Yields while the header has no width yet (its frame is set by
      // the card's layout): AppKit throws on an unsatisfiable constraint.
      buttons.leadingAnchor
        .constraint(greaterThanOrEqualTo: dot.trailingAnchor, constant: 6)
        .withPriority(.required - 1),
      buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    dot.isHidden = true
    refreshActions()
    setAccessibilityElement(false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  /// Shows `view` before the icon, `inset` points in; nil removes the
  /// accessory this header shows.
  func setAccessory(_ view: NSView?, inset: CGFloat = 0) {
    guard view !== accessory || inset != accessoryInset else { return }
    NSLayoutConstraint.deactivate(accessoryConstraints)
    accessoryConstraints = []
    if let old = accessory, old !== view, old.superview === self {
      old.removeFromSuperview()
    }
    accessory = view
    accessoryInset = inset
    iconLeading.isActive = false
    if let view {
      if view.superview !== self {
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
      }
      iconLeading = icon.leadingAnchor.constraint(
        equalTo: view.trailingAnchor,
        constant: 8
      )
      accessoryConstraints = [
        view.leadingAnchor.constraint(
          equalTo: leadingAnchor,
          constant: 6 + inset
        ), view.centerYAnchor.constraint(equalTo: centerYAnchor),
      ]
      NSLayoutConstraint.activate(accessoryConstraints)
    } else {
      iconLeading = icon.leadingAnchor.constraint(
        equalTo: leadingAnchor,
        constant: 12
      )
    }
    iconLeading.isActive = true
  }

  /// The actions show only on the pane under the pointer; elsewhere they
  /// keep their place (and stay reachable by accessibility) but draw
  /// nothing.
  private func refreshActions() { buttons.alphaValue = isHovered ? 1 : 0 }

  /// Whether the actions draw (tests).
  var showsActions: Bool { buttons.alphaValue > 0 }

  @objc
  private func clicked(_ sender: NSButton) {
    let actions: [Action] = [.splitRight, .splitDown, .zoom, .close]
    onAction?(actions[sender.tag])
  }
}
