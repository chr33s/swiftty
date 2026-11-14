import Foundation
import MuxNavigation
import SwiftMuxProtocol
import Testing

@Suite("Shared attention presentation")
struct AttentionPresentationTests {
  private let now = Date(timeIntervalSince1970: 2_000)

  private func item(
    _ category: AttentionCategory,
    _ resolution: AttentionResolution = .open,
    snoozedUntil: Date? = nil,
    created: TimeInterval = 1_000
  ) -> AttentionItem {
    var item = sampleItem(for: sampleDestination(), resolution: resolution)
    item.category = category
    item.snoozedUntil = snoozedUntil
    item.createdAt = Date(timeIntervalSince1970: created)
    return item
  }

  @Test
  func listsWaitingRequestsAndUnreviewedOutcomes() {
    #expect(AttentionPresentation.shows(item(.needsYou)))
    #expect(!AttentionPresentation.shows(item(.needsYou, .resolved)))
    #expect(!AttentionPresentation.shows(item(.needsYou, .paneExited)))
    #expect(AttentionPresentation.shows(item(.failure, .paneExited)))
    #expect(AttentionPresentation.shows(item(.result)))
    #expect(!AttentionPresentation.shows(item(.result, .reviewed)))
  }

  @Test
  func ordersRequestsFailuresResultsThenSnoozed() {
    let later = now.addingTimeInterval(60)
    let ordered = [
      item(.needsYou, snoozedUntil: later), item(.result),
      item(.failure), item(.needsYou, created: 900),
      item(.needsYou, created: 1_500),
    ]
    .sorted { AttentionPresentation.precedes($0, $1, at: now) }
    #expect(
      ordered.map(\.category) == [
        .needsYou, .needsYou, .failure, .result, .needsYou,
      ]
    )
    #expect(ordered[0].createdAt > ordered[1].createdAt)
    #expect(ordered[4].snoozedUntil == later)
  }

  @Test
  func labelsNeverContainProgramText() {
    #expect(
      String(localized: AttentionPresentation.label(item(.needsYou)))
        == "Needs permission"
    )
    #expect(
      String(localized: AttentionPresentation.label(item(.failure))) == "Failed"
    )
    #expect(
      String(localized: AttentionPresentation.label(item(.result))) == "Done"
    )
  }

  @Test
  func programTextIsOnePlainBoundedLine() {
    #expect(AttentionPresentation.plain(nil) == nil)
    #expect(AttentionPresentation.plain(" \u{1B}\n ") == nil)
    // A right-to-left override cannot reorder what follows it.
    #expect(AttentionPresentation.plain("safe\u{202E}txt.exe") == "safetxt.exe")
    #expect(AttentionPresentation.plain("a\nb\tc") == "a b c")
    let long = String(repeating: "x", count: 500)
    #expect(AttentionPresentation.plain(long)?.count == 200)
    #expect(AttentionPresentation.plain(long, limit: 300)?.count == 300)
  }

  @Test
  func onlyWaitingRequestsSnoozeAndOnlyOutcomesAreReviewed() {
    #expect(AttentionPresentation.canSnooze(item(.needsYou)))
    #expect(!AttentionPresentation.canSnooze(item(.needsYou, .resolved)))
    #expect(!AttentionPresentation.canSnooze(item(.result)))
    #expect(!AttentionPresentation.canMarkReviewed(item(.needsYou)))
    #expect(AttentionPresentation.canMarkReviewed(item(.failure)))
    #expect(AttentionPresentation.snoozeText(item(.needsYou), at: now) == nil)
    let snoozed = item(.needsYou, snoozedUntil: now.addingTimeInterval(60))
    #expect(
      AttentionPresentation.snoozeText(snoozed, at: now)?
        .hasPrefix("Snoozed until ") == true
    )
    #expect(
      AttentionPresentation.snoozeText(
        snoozed,
        at: now.addingTimeInterval(120)
      ) == nil
    )
    #expect(AttentionPresentation.snoozeChoices(at: now).count == 3)
  }

  @Test
  func linkCopyDistinguishesARestartAndAChangedController() {
    let restarted = AttentionPresentation.missing(serviceRestarted: true)
    let gone = AttentionPresentation.missing(serviceRestarted: false)
    #expect(String(localized: restarted.detail).contains("restarted"))
    #expect(!String(localized: gone.detail).contains("restarted"))
    #expect(
      String(
        localized: AttentionPresentation.takeover(controllerChanged: true)
          .title
      ) == "Another client took control first"
    )
    #expect(
      String(localized: AttentionPresentation.staleHeadline(.paneExited))
        == String(localized: AttentionPresentation.paneExited.title)
    )
  }
}
