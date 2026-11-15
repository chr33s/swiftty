import Foundation
import SwiftMuxProtocol

/// How every inbox presents an attention item (spec.inbox.md §3): the
/// native macOS window and the direct clients share this wording, the
/// sanitizing of untrusted program text and the snooze rules, and differ
/// only in the views that host them. Foundation only.
public enum AttentionPresentation {
  // MARK: Membership and order

  /// Whether an inbox lists `item`: a waiting request, or a failure or
  /// result that has not been reviewed.
  public static func shows(_ item: AttentionItem) -> Bool {
    switch item.category {
    case .needsYou: item.resolution == .open
    case .failure, .result:
      item.resolution == .open || item.resolution == .paneExited
    }
  }

  /// Requests, then failures, then results, then snoozed requests; newest
  /// first within each.
  public static func precedes(
    _ first: AttentionItem,
    _ second: AttentionItem,
    at now: Date
  ) -> Bool {
    let a = rank(first.category) + (first.isSnoozed(at: now) ? 3 : 0)
    let b = rank(second.category) + (second.isSnoozed(at: now) ? 3 : 0)
    return a != b ? a < b : first.createdAt > second.createdAt
  }

  private static func rank(_ category: AttentionCategory) -> Int {
    switch category {
    case .needsYou: 0
    case .failure: 1
    case .result: 2
    }
  }

  // MARK: Text

  /// What the item asks for or reports. Never program text.
  public static func label(_ item: AttentionItem) -> LocalizedStringResource {
    switch item.category {
    case .needsYou:
      switch item.status.kind {
      case .permission?:
        LocalizedStringResource("Needs permission", bundle: #bundle)
      case .auth?:
        LocalizedStringResource("Needs authentication", bundle: #bundle)
      case .question?, nil:
        LocalizedStringResource("Needs an answer", bundle: #bundle)
      }
    case .failure: LocalizedStringResource("Failed", bundle: #bundle)
    case .result: LocalizedStringResource("Done", bundle: #bundle)
    }
  }

  /// Untrusted program text as one bounded plain line, or nil when nothing
  /// visible remains. Controls, bidi overrides and other invisible scalars
  /// are dropped; the result is never markup or a link.
  public static func plain(_ text: String?, limit: Int = 200) -> String? {
    guard let text else { return nil }
    let cleaned = DisplayText.sanitize(text, limit: limit)
    return cleaned.isEmpty ? nil : cleaned
  }

  // MARK: Actions

  /// Only a waiting request can be snoozed: snoozing hides it from the
  /// badge until the time passes or the program moves on.
  public static func canSnooze(_ item: AttentionItem) -> Bool {
    item.category == .needsYou && item.resolution == .open
  }

  /// A failure or result is dismissed by reviewing it; a request is
  /// resolved only by the program.
  public static func canMarkReviewed(_ item: AttentionItem) -> Bool {
    item.category != .needsYou
  }

  public enum SnoozeOption: CaseIterable, Sendable {
    case fifteenMinutes, oneHour, tomorrowMorning

    public var title: LocalizedStringResource {
      switch self {
      case .fifteenMinutes:
        LocalizedStringResource("15 Minutes", bundle: #bundle)
      case .oneHour: LocalizedStringResource("1 Hour", bundle: #bundle)
      case .tomorrowMorning:
        LocalizedStringResource("Tomorrow at 9:00", bundle: #bundle)
      }
    }

    public func until(at now: Date, calendar: Calendar = .current) -> Date? {
      switch self {
      case .fifteenMinutes: return now.addingTimeInterval(15 * 60)
      case .oneHour: return now.addingTimeInterval(60 * 60)
      case .tomorrowMorning:
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)
        else { return nil }
        return calendar.date(
          bySettingHour: 9,
          minute: 0,
          second: 0,
          of: tomorrow
        )
      }
    }
  }

  /// The snooze choices offered at `now`: 15 minutes, an hour and 9:00
  /// tomorrow (in `calendar`'s time zone).
  public static func snoozeChoices(
    at now: Date,
    calendar: Calendar = .current
  ) -> [(title: String, until: Date)] {
    SnoozeOption.allCases.compactMap { option in
      option.until(at: now, calendar: calendar)
        .map { (String(localized: option.title), $0) }
    }
  }

  /// "Snoozed until …" for a snoozed item, else nil.
  public static func snoozeText(
    _ item: AttentionItem,
    at now: Date,
    calendar: Calendar = .current
  ) -> String? {
    guard let until = item.snoozedUntil, until > now else { return nil }
    var style = Date.FormatStyle(date: .omitted, time: .shortened)
    if !calendar.isDate(until, inSameDayAs: now) {
      style = Date.FormatStyle(date: .abbreviated, time: .shortened)
    }
    style.timeZone = calendar.timeZone
    return String(
      localized: "Snoozed until \(until.formatted(style))",
      bundle: #bundle
    )
  }
}

// MARK: Attention links

extension AttentionPresentation {
  /// App copy for one navigator outcome: a title and one explanatory line.
  public struct Message: Sendable {
    public let title: LocalizedStringResource
    public let detail: LocalizedStringResource
  }

  /// A link that failed validation; no host was contacted.
  public static let rejectedLink = Message(
    title: LocalizedStringResource(
      "This link can't be opened",
      bundle: #bundle
    ),
    detail: LocalizedStringResource(
      "It is not a valid Swiftty attention link. Nothing was contacted.",
      bundle: #bundle
    )
  )

  /// The pane ended; its last screen may still be shown.
  public static let paneExited = Message(
    title: LocalizedStringResource(
      "The program's pane has exited",
      bundle: #bundle
    ),
    detail: LocalizedStringResource(
      "Its final output may still be retained.",
      bundle: #bundle
    )
  )

  /// The occurrence a link named cannot be found.
  public static func missing(serviceRestarted: Bool) -> Message {
    Message(
      title: LocalizedStringResource(
        "Attention item no longer exists",
        bundle: #bundle
      ),
      detail: serviceRestarted
        ? LocalizedStringResource(
          "The SwiftMux service restarted since this link was made, so the pane it named is gone.",
          bundle: #bundle
        )
        : LocalizedStringResource(
          "The request, pane or terminal this link named was replaced or removed.",
          bundle: #bundle
        )
    )
  }

  /// Opening needs the writer lease another client holds. `controllerChanged`
  /// is true when the holder changed while the user was deciding.
  public static func takeover(controllerChanged: Bool) -> Message {
    Message(
      title: controllerChanged
        ? LocalizedStringResource(
          "Another client took control first",
          bundle: #bundle
        )
        : LocalizedStringResource(
          "Another client controls this workspace",
          bundle: #bundle
        ),
      detail: LocalizedStringResource(
        "Taking over disconnects it from the workspace. Its shells keep running.",
        bundle: #bundle
      )
    )
  }

  /// Why a linked occurrence is no longer the current one.
  public static func staleHeadline(
    _ resolution: AttentionResolution
  ) -> LocalizedStringResource {
    switch resolution {
    case .superseded:
      LocalizedStringResource(
        "This request was replaced by a newer one",
        bundle: #bundle
      )
    case .resolved:
      LocalizedStringResource(
        "This request was already resolved",
        bundle: #bundle
      )
    case .reviewed:
      LocalizedStringResource("This item was already reviewed", bundle: #bundle)
    case .paneExited: paneExited.title
    case .open:
      LocalizedStringResource("This item is no longer current", bundle: #bundle)
    }
  }

  /// A one-line, non-secret category name: never program text.
  public static func categoryLabel(
    _ category: AttentionCategory
  ) -> LocalizedStringResource {
    switch category {
    case .needsYou: LocalizedStringResource("Needs you", bundle: #bundle)
    case .failure: LocalizedStringResource("Failed", bundle: #bundle)
    case .result: LocalizedStringResource("Result", bundle: #bundle)
    }
  }
}
