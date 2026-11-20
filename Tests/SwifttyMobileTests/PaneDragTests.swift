#if canImport(UIKit)
@testable import SwifttyMobile
import Testing
import UIKit

/// A mostly sideways one-finger drag pages between panes; on release it
/// turns the page past a third of the width or when flicked onward.
struct PaneDragTests {
  @Test
  func `the axis is decided once the pan has travelled`() {
    #expect(PaneDrag.pages(CGPoint(x: 5, y: 3)) == nil)
    #expect(PaneDrag.pages(CGPoint(x: -20, y: 4)) == true)
    #expect(PaneDrag.pages(CGPoint(x: 15, y: 14)) == false)
    #expect(PaneDrag.pages(CGPoint(x: 0, y: -20)) == false)
    #expect(PaneDrag.pages(CGPoint(x: CGFloat.nan, y: 0)) == false)
  }

  @Test
  func `far enough or flicked onward turns the page`() {
    // A third of 300 pt, slowly: next (moving left) or previous.
    #expect(PaneDrag.commit(travel: -110, velocity: 0, width: 300) == true)
    #expect(PaneDrag.commit(travel: 110, velocity: 0, width: 300) == false)
    // Short but flicked onward.
    #expect(PaneDrag.commit(travel: -30, velocity: -800, width: 300) == true)
  }

  @Test(
    arguments: [
      // Short and slow.
      (CGFloat(-60), CGFloat(-100)),
      // Far, but flicked back.
      (-200, 800), (0, -900), (CGFloat.nan, -900),
    ] as [(CGFloat, CGFloat)]
  )
  func `otherwise the page settles back`(travel: CGFloat, velocity: CGFloat) {
    #expect(
      PaneDrag.commit(travel: travel, velocity: velocity, width: 300) == nil
    )
  }
}
#endif
