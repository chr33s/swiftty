import Foundation
import ScreenProtocol
import SessionCore
import Synchronization
import SwifttyCore
import Testing

@testable import RoamingKit
@testable import TerminalSurface

/// Client-side history windows (`historyViewport`).
struct RoamingViewportTests {
  @Test
  func `scrolling is sent only to hosts that advertise history windows`()
    async throws
  {
    for advertised in [false, true] {
      let f = try RoamingFixture()
      await f.host.set(features: advertised ? [.historyViewport] : [])
      try #require(try await f.startActive())
      #expect(await f.client.supportsHistoryViewport == advertised)
      await f.client.scrollViewport(by: 12)
      await f.client.scrollViewport(by: 0)
      await f.client.scrollViewport(by: -3)
      await f.client.scrollViewport(by: .max)
      if advertised {
        #expect(await eventually { await f.host.viewports.count == 3 })
        #expect(await f.host.viewports == [12, -3, 1_000_000])
      } else {
        // Give any stray message time to arrive.
        _ = await f.client.submit(.text("x"))
        #expect(await eventually { await f.host.applied.count == 1 })
        #expect(await f.host.viewports.isEmpty)
      }
      await f.client.close()
    }
  }

  @Test
  func `a presentation session forwards scrolling instead of moving its frame`()
  {
    let session = TerminalSession(
      presentationColumns: 20,
      rows: 4,
      configuration: SessionConfiguration()
    )
    let forwarded = Mutex<[Int]>([])
    session.viewportScrollHandler = { lines in
      forwarded.withLock { $0.append(lines) }
    }
    session.scrollViewport(by: 5)
    session.scrollViewport(by: -2)
    #expect(session.withState { $0.viewportOffset } == 0)
    #expect(forwarded.withLock { $0 } == [5, -2])
    session.viewportScrollHandler = nil
    session.scrollViewport(by: 1)
    #expect(session.withState { $0.viewportOffset } == 0)
    #expect(forwarded.withLock { $0 } == [5, -2])
  }
}
