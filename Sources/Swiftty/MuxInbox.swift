import AppKit
import MuxNavigation
import SwiftMuxProtocol

/// The window's mirror of the service attention inbox (spec.inbox.md §3):
/// current requests, unreviewed failures and results. The service owns
/// the reduction; this only applies its pages and coalesced updates.
struct MuxInboxModel: Equatable {
  private(set) var items: [OccurrenceID: AttentionItem] = [:]
  private(set) var counts = InboxCounts()
  private(set) var revision: UInt64 = 0
  /// Cursor for the next page of each section; nil when fully read.
  private(set) var cursors: [InboxQuery.Section: String] = [:]
  private var pageRevisions: [InboxQuery.Section: UInt64] = [:]
  /// Inbox revision at which each recently removed occurrence left the
  /// inbox, so a page read before the removal cannot resurrect it.
  private var removedAt: [OccurrenceID: UInt64] = [:]
  /// Pages and deltas through this revision are unsafe once their
  /// individual removal records have been evicted.
  private var removalHistoryFloor: UInt64?
  /// Bound on `removedAt`; the oldest removals are forgotten first.
  static let tombstoneLimit = 512

  /// The sections the inbox reads (the service's `all` includes
  /// resolved history, which the window never lists).
  static let sections: [InboxQuery.Section] = [.needsYou, .results]

  var hasMore: Bool { !cursors.isEmpty }

  /// Whether the inbox shows `item`; the rule every inbox shares.
  static func shows(_ item: AttentionItem) -> Bool {
    AttentionPresentation.shows(item)
  }

  /// Adopts freshly read first pages, keeping items a newer update
  /// already delivered. Rows past the first page are dropped until read
  /// again with `append`.
  mutating func reset(_ pages: [InboxQuery.Section: InboxPage]) {
    guard let read = pages.values.map(\.revision).min() else { return }
    if let floor = removalHistoryFloor, read <= floor { return }
    guard
      pages.allSatisfy({ section, page in
        page.revision >= (pageRevisions[section] ?? 0)
      })
    else { return }
    let listed = Set(pages.values.flatMap(\.items).map(\.occurrence))
    items = items.filter { listed.contains($0.key) || $0.value.revision > read }
    cursors = pages.compactMapValues(\.nextCursor)
    pageRevisions = pages.mapValues(\.revision)
    for page in pages.values { adopt(page) }
  }

  /// Adds a further page of `section` (read with its cursor).
  mutating func append(_ page: InboxPage, section: InboxQuery.Section) {
    if let floor = removalHistoryFloor, page.revision <= floor { return }
    guard page.revision >= (pageRevisions[section] ?? 0) else { return }
    pageRevisions[section] = page.revision
    cursors[section] = page.nextCursor
    adopt(page)
  }

  private mutating func adopt(_ page: InboxPage) {
    for item in page.items {
      // Removed by an update newer than this page: stay removed.
      if let removed = removedAt[item.occurrence], removed >= page.revision {
        continue
      }
      merge(item)
    }
    if page.revision >= revision {
      counts = page.counts
      revision = page.revision
    }
  }

  /// Forgets an item the service reported stale or missing; the caller
  /// rereads the inbox.
  mutating func forget(_ occurrence: OccurrenceID) { items[occurrence] = nil }

  /// Applies one update; true when the caller must refetch (`resync`).
  mutating func apply(_ update: InboxUpdate) -> Bool {
    if let floor = removalHistoryFloor, update.revision <= floor {
      return update.resync
    }
    for id in update.removed {
      if let known = items[id], known.revision > update.revision { continue }
      items[id] = nil
      tombstone(id, at: update.revision)
    }
    for item in update.changed {
      if let removed = removedAt[item.occurrence], removed >= update.revision {
        continue  // removed by a newer update
      }
      merge(item)
      if items[item.occurrence] == nil {
        tombstone(item.occurrence, at: update.revision)
      } else {
        removedAt[item.occurrence] = nil
      }
    }
    if update.revision >= revision {
      counts = update.counts
      revision = update.revision
    }
    return update.resync
  }

  private mutating func tombstone(_ id: OccurrenceID, at revision: UInt64) {
    removedAt[id] = max(removedAt[id] ?? 0, revision)
    guard removedAt.count > Self.tombstoneLimit else { return }
    let oldest = removedAt.sorted { $0.value < $1.value }
      .prefix(removedAt.count - Self.tombstoneLimit)
    for (old, removed) in oldest {
      removalHistoryFloor = max(removalHistoryFloor ?? 0, removed)
      removedAt[old] = nil
    }
  }

  private mutating func merge(_ item: AttentionItem) {
    if let known = items[item.occurrence], known.revision > item.revision {
      return  // a stale delta
    }
    items[item.occurrence] = Self.shows(item) ? item : nil
  }

  /// Requests, then failures, then results, then snoozed requests;
  /// newest first within each.
  var sorted: [AttentionItem] { sorted(at: Date()) }

  func sorted(at now: Date) -> [AttentionItem] {
    items.values.sorted { AttentionPresentation.precedes($0, $1, at: now) }
  }

  /// Plain-text heading and detail. Program text is untrusted: it is
  /// sanitized and never rendered as markup or links.
  static func text(_ item: AttentionItem) -> (heading: String, detail: String) {
    let s = item.status
    let what = String(localized: AttentionPresentation.label(item))
    let program = [s.app, s.title].compactMap { $0 }
      .map { DisplayText.sanitize($0) }.filter { !$0.isEmpty }
      .joined(separator: " — ")
    let heading = program.isEmpty ? what : "\(what): \(program)"
    var detail = s.message.map { DisplayText.sanitize($0, limit: 300) } ?? ""
    if item.resolution == .paneExited {
      detail += detail.isEmpty ? "Pane exited" : " (pane exited)"
    }
    return (heading, detail)
  }

  // MARK: Snooze

  typealias SnoozeOption = AttentionPresentation.SnoozeOption

  static func canSnooze(_ item: AttentionItem) -> Bool {
    AttentionPresentation.canSnooze(item)
  }

  static func snoozeChoices(
    at now: Date,
    calendar: Calendar = .current
  ) -> [(title: String, until: Date)] {
    AttentionPresentation.snoozeChoices(at: now, calendar: calendar)
  }

  static func snoozeText(
    _ item: AttentionItem,
    at now: Date,
    calendar: Calendar = .current
  ) -> String? {
    AttentionPresentation.snoozeText(item, at: now, calendar: calendar)
  }

  // MARK: Failures

  /// Plain wording for a failed inbox or navigation command.
  static func describe(_ error: any Error) -> String {
    guard let error = error as? MuxError else {
      return "SwiftMux could not complete the request: \(error)"
    }
    switch error.code {
    case .leaseHeld:
      return
        "Another window or device controls this workspace. Open the item again to take over."
    case .staleRevision:
      return
        "Control of the workspace changed while you were deciding. Nothing was taken over."
    case .connectionLost, .quiescing:
      return "The SwiftMux service is not reachable."
    case .serverInstanceChanged:
      return "The SwiftMux service restarted; the inbox was reloaded."
    case .notFound: return "That workspace or pane no longer exists."
    case .resourceLimit:
      return "SwiftMux is at a limit: \(DisplayText.sanitize(error.message))"
    default:
      let detail = DisplayText.sanitize(error.message)
      return detail.isEmpty
        ? "SwiftMux refused the request (\(error.code.rawValue))."
        : "SwiftMux refused the request: \(detail)"
    }
  }

  /// Wording for an occurrence the service no longer offers, or nil when
  /// it is still available.
  static func describe(
    _ availability: AttentionLocation.Availability
  ) -> String? {
    switch availability {
    case .available, .paneExited: nil
    case .stale: "The program has already moved on from this request."
    case .missing: "This item is no longer available."
    }
  }
}

/// The inbox popover: one row per item with "Open in Pane", a Snooze
/// menu for waiting requests and, for failures and results, "Mark
/// Reviewed"; an inline message line reports failed commands.
@MainActor
final class MuxInboxViewController: NSViewController {
  var onOpen: ((AttentionItem) -> Void)?
  var onReview: ((AttentionItem) -> Void)?
  /// Snoozes until the date, or clears the snooze with nil.
  var onSnooze: ((AttentionItem, Date?) -> Void)?
  var onLoadMore: (() -> Void)?
  /// Items shown since the popover opened (marked seen once).
  var onShown: (([AttentionItem]) -> Void)?
  private let stack = NSStackView()
  private(set) var shown: [AttentionItem] = []
  /// The inline failure line, empty when there is none.
  let messageLabel = NSTextField(wrappingLabelWithString: "")
  private(set) var loadMoreButton: ActionButton?
  /// Wall clock used when displaying or activating a snooze choice.
  var snoozeNow: () -> Date = Date.init

  override func loadView() {
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    stack.translatesAutoresizingMaskIntoConstraints = false
    let document = FlippedView()
    document.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(stack)
    let scroll = NSScrollView(
      frame: NSRect(x: 0, y: 0, width: 380, height: 320)
    )
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    scroll.documentView = document
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: document.topAnchor),
      stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
      document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
    ])
    messageLabel.textColor = .systemRed
    messageLabel.isSelectable = false
    messageLabel.allowsEditingTextAttributes = false
    messageLabel.preferredMaxLayoutWidth = 340
    messageLabel.setAccessibilityRole(.staticText)
    view = scroll
    preferredContentSize = scroll.frame.size
  }

  /// Shows (or with nil, clears) the inline failure line. Only the line
  /// changes: rows are not rebuilt, so `onShown` does not fire again and
  /// a failing `markSeen` cannot retry itself in a loop.
  func show(message: String?) {
    _ = view
    let message = message.flatMap { $0.isEmpty ? nil : $0 }
    messageLabel.stringValue = message ?? ""
    let placed = messageLabel.superview === stack
    if let message {
      if !placed { stack.insertArrangedSubview(messageLabel, at: 0) }
      NSAccessibility.post(
        element: messageLabel,
        notification: .announcementRequested,
        userInfo: [.announcement: message]
      )
    } else if placed {
      messageLabel.removeFromSuperview()
    }
  }

  func update(_ model: MuxInboxModel) {
    _ = view
    let now = snoozeNow()
    let items = model.sorted(at: now)
    shown = items
    for row in stack.arrangedSubviews { row.removeFromSuperview() }
    if !messageLabel.stringValue.isEmpty {
      stack.addArrangedSubview(messageLabel)
    }
    if items.isEmpty {
      stack.addArrangedSubview(
        NSTextField(labelWithString: "Nothing needs you.")
      )
    }
    for item in items { stack.addArrangedSubview(row(item, at: now)) }
    loadMoreButton = nil
    if model.hasMore {
      let more = ActionButton(title: "Load More") { [weak self] in
        self?.onLoadMore?()
      }
      loadMoreButton = more
      stack.addArrangedSubview(more)
    }
    onShown?(items)
  }

  private func row(_ item: AttentionItem, at now: Date) -> NSView {
    let text = MuxInboxModel.text(item)
    let snoozed = MuxInboxModel.snoozeText(item, at: now)
    let heading = NSTextField(labelWithString: text.heading)
    heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
    heading.lineBreakMode = .byTruncatingTail
    if snoozed != nil { heading.textColor = .secondaryLabelColor }
    // Plain labels: no link detection, rich text or editing.
    let detail = NSTextField(wrappingLabelWithString: text.detail)
    detail.allowsEditingTextAttributes = false
    detail.isSelectable = false
    detail.textColor = .secondaryLabelColor
    detail.preferredMaxLayoutWidth = 340
    detail.isHidden = text.detail.isEmpty
    let status = NSTextField(labelWithString: snoozed ?? "")
    status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    status.textColor = .tertiaryLabelColor
    status.isHidden = snoozed == nil
    let open = ActionButton(title: "Open in Pane") { [weak self] in
      self?.onOpen?(item)
    }
    var buttons: [NSView] = [open]
    if MuxInboxModel.canSnooze(item) {
      buttons.append(snoozeMenu(item, snoozed: snoozed != nil))
    }
    if item.category != .needsYou {
      buttons.append(
        ActionButton(title: "Mark Reviewed") { [weak self] in
          self?.onReview?(item)
        }
      )
    }
    let actions = NSStackView(views: buttons)
    actions.orientation = .horizontal
    let row = NSStackView(views: [heading, detail, status, actions])
    row.orientation = .vertical
    row.alignment = .leading
    row.spacing = 4
    row.setAccessibilityElement(true)
    row.setAccessibilityLabel(
      [text.heading, text.detail, snoozed ?? ""].filter { !$0.isEmpty }
        .joined(separator: ". ")
    )
    return row
  }

  /// A pull-down: the snooze choices, plus "Unsnooze" while snoozed.
  private func snoozeMenu(_ item: AttentionItem, snoozed: Bool) -> NSPopUpButton
  {
    let button = NSPopUpButton(frame: .zero, pullsDown: true)
    button.controlSize = .small
    button.bezelStyle = .glass
    button.addItem(withTitle: snoozed ? "Snoozed" : "Snooze")
    for option in MuxInboxModel.SnoozeOption.allCases {
      button.menu?
        .addItem(
          ActionMenuItem(title: String(localized: option.title)) {
            [weak self] in
            guard let self, let until = option.until(at: self.snoozeNow())
            else { return }
            self.onSnooze?(item, until)
          }
        )
    }
    if snoozed {
      button.menu?.addItem(.separator())
      button.menu?
        .addItem(
          ActionMenuItem(title: "Unsnooze") { [weak self] in
            self?.onSnooze?(item, nil)
          }
        )
    }
    button.setAccessibilityLabel(snoozed ? "Change snooze" : "Snooze")
    return button
  }

  private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
  }

  final class ActionButton: NSButton {
    private var handler: () -> Void = {}

    convenience init(title: String, _ handler: @escaping () -> Void) {
      self.init(frame: .zero)
      self.title = title
      bezelStyle = .glass
      controlSize = .small
      self.handler = handler
      target = self
      action = #selector(run)
    }

    @objc
    private func run() { handler() }
  }

  final class ActionMenuItem: NSMenuItem {
    private var handler: () -> Void = {}

    convenience init(title: String, _ handler: @escaping () -> Void) {
      self.init(title: title, action: #selector(run), keyEquivalent: "")
      self.handler = handler
      target = self
    }

    @objc
    private func run() { handler() }
  }
}
