#if canImport(UIKit)
@testable import SwifttyMobile
import Testing
import UIKit

/// A docked keyboard lifts the terminal instead of shrinking its grid.
struct KeyboardLiftTests {
  // 2× scale, 4 pt padding, 10×20 pt cells.
  let geometry = GridGeometry(
    scale: 2,
    padding: CGPoint(x: 8, y: 8),
    cellSize: CGSize(width: 20, height: 40)
  )

  @Test
  func `the accessory above the reported keyboard is covered`() {
    let keyboard = CGRect(x: 0, y: 500, width: 400, height: 374)
    // Mid-animation the accessory's position is stale; its height counts.
    let moving = TerminalUIView.keyboardCovering(
      keyboard: keyboard,
      accessory: CGRect(x: 0, y: 874, width: 400, height: 60),
      settled: false
    )
    #expect(moving.minY == 440)
    #expect(moving.maxY == 874)
    // Settled, the measured frame counts.
    let settled = TerminalUIView.keyboardCovering(
      keyboard: keyboard,
      accessory: CGRect(x: 0, y: 440, width: 400, height: 60),
      settled: true
    )
    #expect(settled.minY == 440)
  }

  @Test
  func `a hardware keyboard covers only the accessory`() {
    let covering = TerminalUIView.keyboardCovering(
      keyboard: CGRect(x: 0, y: 874, width: 400, height: 0),
      accessory: CGRect(x: 0, y: 814, width: 400, height: 60),
      settled: true
    )
    #expect(covering == CGRect(x: 0, y: 814, width: 400, height: 60))
  }

  @Test
  func `a settled frame that includes the accessory is not doubled`() {
    let keyboard = CGRect(x: 0, y: 440, width: 400, height: 434)
    let covering = TerminalUIView.keyboardCovering(
      keyboard: keyboard,
      accessory: CGRect(x: 0, y: 440, width: 400, height: 60),
      settled: true
    )
    #expect(covering == keyboard)
    #expect(
      TerminalUIView.keyboardCovering(
        keyboard: keyboard,
        accessory: nil,
        settled: false
      ) == keyboard
    )
  }

  @Test
  func `no keyboard means no lift`() {
    #expect(
      TerminalUIView.keyboardLift(
        covered: 0,
        height: 800,
        cursorRow: 38,
        geometry: geometry
      ) == 0
    )
  }

  @Test
  func `a cursor above the keyboard stays put`() {
    // Row 5 ends at 4 + 6 × 20 = 124 pt, well above 800 − 300.
    #expect(
      TerminalUIView.keyboardLift(
        covered: 300,
        height: 800,
        cursorRow: 5,
        geometry: geometry
      ) == 0
    )
  }

  @Test
  func `a covered cursor lifts just above the keyboard`() {
    // Row 29 ends at 604 pt, plus 4 pt padding: 108 pt past 500.
    #expect(
      TerminalUIView.keyboardLift(
        covered: 300,
        height: 800,
        cursorRow: 29,
        geometry: geometry
      ) == 108
    )
  }

  @Test
  func `the lift never exceeds the covered height`() {
    #expect(
      TerminalUIView.keyboardLift(
        covered: 300,
        height: 800,
        cursorRow: 39,
        geometry: geometry
      ) == 300
    )
    #expect(
      TerminalUIView.keyboardLift(
        covered: 300,
        height: 800,
        cursorRow: nil,
        geometry: geometry
      ) == 300
    )
  }
}
#endif

#if canImport(UIKit)
/// Scrolling back with the keyboard up reveals the lifted top first.
struct KeyboardRevealTests {
  @Test
  func `scrolling back lowers the view before history`() {
    var r = KeyboardReveal()
    // 100 pt lift: the first 60 pt only lower the view.
    #expect(r.consume(60, lift: 100, atLive: true) == 0)
    #expect(r.revealed == 60)
    // The rest of the lift, then 30 pt into history.
    #expect(r.consume(70, lift: 100, atLive: true) == 30)
    #expect(r.revealed == 100)
    #expect(r.consume(50, lift: 100, atLive: false) == 50)
  }

  @Test
  func `scrolling forward restores the lift only at live output`() {
    var r = KeyboardReveal()
    _ = r.consume(100, lift: 100, atLive: true)
    // Still in history: the viewport moves, the view stays lowered.
    #expect(r.consume(-40, lift: 100, atLive: false) == -40)
    #expect(r.revealed == 100)
    // Live again: the lift comes back before anything else.
    #expect(r.consume(-40, lift: 100, atLive: true) == 0)
    #expect(r.revealed == 60)
    #expect(r.consume(-80, lift: 100, atLive: true) == -20)
    #expect(r.revealed == 0)
  }

  @Test
  func `a smaller lift clamps what was revealed`() {
    var r = KeyboardReveal()
    _ = r.consume(100, lift: 100, atLive: true)
    #expect(r.consume(10, lift: 40, atLive: true) == 10)
    #expect(r.revealed == 40)
    #expect(r.consume(.nan, lift: 40, atLive: true).isNaN)
    r.reset()
    #expect(r.revealed == 0)
  }
}
#endif
