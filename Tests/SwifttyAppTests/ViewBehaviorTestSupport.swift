import AppKit
import Metal
@testable import Swiftty
@testable import SwifttyMac
import SwifttyCore
import Synchronization
import Testing
import TestSupport

final class ReviewScrollEvent: NSEvent {
  var distance: CGFloat = 0
  override var scrollingDeltaX: CGFloat { distance }

  override var scrollingDeltaY: CGFloat { distance }

  override var hasPreciseScrollingDeltas: Bool { false }

  override var locationInWindow: NSPoint { .zero }

  override var modifierFlags: NSEvent.ModifierFlags { [] }
}
