import Foundation
import SwiftMuxProtocol

/// What a constrained surface (watchOS, complications, lock screen) may
/// show about an attention item. Defaults to fully redacted program text.
public struct AttentionSummaryPolicy: Sendable, Equatable, Codable {
  /// Show the program's self-reported app name (untrusted, short).
  public var showsAppName: Bool
  /// Show the program's message text. Off unless the user opts in.
  public var showsMessage: Bool

  public init(showsAppName: Bool = true, showsMessage: Bool = false) {
    self.showsAppName = showsAppName
    self.showsMessage = showsMessage
  }

  public static let redacted = AttentionSummaryPolicy(
    showsAppName: false,
    showsMessage: false
  )
}

/// Redacted attention metadata for watchOS (spec.inbox.md §4,
/// scenario 20): a category, optional app name, inbox counts and a time.
/// No title, no message unless the policy allows it, no IDs beyond the
/// opaque handoff locator, never terminal output.
public struct AttentionSummary: Sendable, Equatable, Codable {
  public static let maxAppNameLength = 32
  public static let maxMessageLength = 120

  public var category: AttentionCategory
  public var appName: String?
  public var counts: InboxCounts
  /// When the item last changed, for a relative time display.
  public var updatedAt: Date
  /// Only when `AttentionSummaryPolicy.showsMessage` was set.
  public var message: String?
  /// Opaque, non-secret locator for a handoff to a paired device.
  public var locator: String?

  public init(
    category: AttentionCategory,
    appName: String? = nil,
    counts: InboxCounts,
    updatedAt: Date,
    message: String? = nil,
    locator: String? = nil
  ) {
    self.category = category
    self.appName = appName
    self.counts = counts
    self.updatedAt = updatedAt
    self.message = message
    self.locator = locator
  }

  /// Summarizes `item` under `policy`. Program text is sanitized (no
  /// controls, no newlines) and truncated.
  public init(
    item: AttentionItem,
    counts: InboxCounts,
    policy: AttentionSummaryPolicy = AttentionSummaryPolicy(),
    destination: AttentionDestination? = nil
  ) {
    self.init(
      category: item.category,
      appName: policy.showsAppName
        ? Self.sanitize(item.status.app, limit: Self.maxAppNameLength) : nil,
      counts: counts,
      updatedAt: item.updatedAt,
      message: policy.showsMessage
        ? Self.sanitize(item.status.message, limit: Self.maxMessageLength)
        : nil,
      locator: destination.map(AttentionLocator.encode)
    )
  }

  /// "2 min ago" style text relative to `now`.
  /// A format style rather than a `RelativeDateTimeFormatter`, which
  /// would be allocated again for every row on every redraw.
  public func relativeTime(now: Date) -> String {
    Date.AnchoredRelativeFormatStyle(
      anchor: min(updatedAt, now),
      presentation: .numeric,
      unitsStyle: .abbreviated
    )
    .format(now)
  }

  /// A one-line, non-secret label: never the program title or message.
  public var categoryLabel: LocalizedStringResource {
    AttentionPresentation.categoryLabel(category)
  }

  static func sanitize(_ text: String?, limit: Int) -> String? {
    guard let text else { return nil }
    let cleaned = String(
      String.UnicodeScalarView(
        text.unicodeScalars.map {
          $0.properties.generalCategory == .control
            || $0.properties.generalCategory == .format
            || $0.properties.generalCategory == .lineSeparator
            || $0.properties.generalCategory == .paragraphSeparator ? " " : $0
        }
      )
    )
    .trimmingCharacters(in: .whitespaces)
    guard !cleaned.isEmpty else { return nil }
    return DisplayText.head(cleaned, width: limit)
  }
}

/// A user-confirmed request from a constrained device (watchOS) asking
/// a paired, authorized device to open an attention item. It carries
/// only the opaque locator and an intent: it can never acquire a writer
/// lease, take over, or send terminal input, and the receiving device
/// resolves it through its own configured hosts like any other link.
public struct AttentionHandoffRequest: Sendable, Equatable, Codable {
  /// `NSUserActivity` type for Handoff continuation.
  public static let activityType = "dev.swiftty.attention.open"
  /// `userInfo` key holding `locator`.
  public static let locatorKey = "ref"

  public enum Intent: String, Sendable, Codable { case review, reveal }

  public var locator: String
  public var intent: Intent
  public var requestedAt: Date

  /// Fails unless `locator` decodes; a watch never forwards free text.
  public init?(
    locator: String,
    intent: Intent = .review,
    requestedAt: Date = .now
  ) {
    guard (try? AttentionLocator.decode(locator)) != nil else { return nil }
    self.locator = locator
    self.intent = intent
    self.requestedAt = requestedAt
  }

  /// Handoff never grants these, by construction.
  public var grantsWriterLease: Bool { false }
  public var allowsInput: Bool { false }

  /// The destination for the receiving device; `.reveal` narrows intent.
  public func destination() throws(AttentionLocator.DecodeError)
    -> AttentionDestination
  {
    var destination = try AttentionLocator.decode(locator)
    if intent == .reveal { destination.intent = .reveal }
    return destination
  }

  /// `userInfo` carries the effective intent inside the existing locator.
  public var userInfo: [String: String] {
    guard let destination = try? destination() else { return [:] }
    return [Self.locatorKey: AttentionLocator.encode(destination)]
  }

  /// Parses a continued activity's `userInfo`, strictly.
  public init?(userInfo: [AnyHashable: Any]?) {
    guard let userInfo, userInfo.count == 1,
      let locator = userInfo[Self.locatorKey] as? String
    else { return nil }
    self.init(locator: locator)
  }
}

/// The latest redacted summaries a phone sends its paired watch, as one
/// application-context entry beside the companion status. Bounded in
/// count and size; decoding re-applies the redaction limits so a watch
/// never shows more than the policy allows.
public struct AttentionSummaryBatch: Sendable, Equatable, Codable {
  public static let dictionaryKey = "attention"
  public static let maxSummaries = 20
  public static let maxEncodedBytes = 32 * 1024

  public var summaries: [AttentionSummary]
  public var sentAt: Date

  public init(summaries: [AttentionSummary], sentAt: Date = .now) {
    self.summaries = Array(summaries.prefix(Self.maxSummaries))
    self.sentAt = sentAt
  }

  public enum CodecError: Error, Equatable { case tooLarge, malformed }

  public func encoded() throws(CodecError) -> Data {
    guard let data = try? JSONEncoder().encode(self),
      data.count <= Self.maxEncodedBytes
    else { throw .tooLarge }
    return data
  }

  public static func decode(_ data: Data) throws(CodecError) -> Self {
    guard data.count <= maxEncodedBytes else { throw .tooLarge }
    guard var batch = try? JSONDecoder().decode(Self.self, from: data),
      batch.summaries.count <= maxSummaries
    else { throw .malformed }
    batch.summaries = batch.summaries.map { summary in
      var summary = summary
      summary.appName = AttentionSummary.sanitize(
        summary.appName,
        limit: AttentionSummary.maxAppNameLength
      )
      summary.message = AttentionSummary.sanitize(
        summary.message,
        limit: AttentionSummary.maxMessageLength
      )
      if let locator = summary.locator,
        (try? AttentionLocator.decode(locator)) == nil
      {
        summary.locator = nil
      }
      return summary
    }
    return batch
  }
}
