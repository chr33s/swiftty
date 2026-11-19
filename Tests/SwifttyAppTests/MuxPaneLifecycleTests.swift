import AppKit
import SwiftMuxProtocol
@testable import Swiftty
import SwifttyCore
import Testing

extension MuxNativeTests {
  @Test(.enabled(if: hasMetal), arguments: [false, true])
  func selectionClampsEndpointsBeforeOrderingThem(reverse: Bool) async throws {
    let f = try await open()
    defer { f.controller.close() }
    let view = try #require(activeView(f.controller))
    let frame = try #require(await waitPresented(view) { _ in true })
    let outside = (row: -1, column: 5)
    let inside = (row: 0, column: 3)
    let selection = FrozenSelection(
      anchor: reverse ? inside : outside,
      head: reverse ? outside : inside,
      unit: .cell
    )
    // An end above the frame starts at its first cell, whatever column
    // the pointer was in.
    #expect(
      selection.span(in: frame)
        == HighlightSpan(startRow: 0, startColumn: 0, endRow: 0, endColumn: 3)
    )
  }

  @Test(.enabled(if: hasMetal), arguments: [false, true])
  func endingSelectionDiscardsThePendingDrag(reset: Bool) async throws {
    let f = try await open()
    defer { f.controller.close() }
    let view = try #require(activeView(f.controller))
    let baseline = try #require(await waitPresented(view) { _ in true })
    let location = view.convert(NSPoint(x: 20, y: 20), to: nil)
    func event(_ type: NSEvent.EventType) throws -> NSEvent {
      try #require(
        NSEvent.mouseEvent(
          with: type,
          location: location,
          modifierFlags: [],
          timestamp: 0,
          windowNumber: view.window?.windowNumber ?? 0,
          context: nil,
          eventNumber: 0,
          clickCount: 1,
          pressure: 1
        )
      )
    }
    view.mouseDown(with: try event(.leftMouseDown))
    #expect(view.selection == nil)
    if reset { view.reset() } else { view.clearSelection() }
    view.mouseDragged(with: try event(.leftMouseDragged))
    #expect(view.selection == nil)
    #expect(view.accessibilitySelectedText() == nil)
    if reset {
      #expect(view.presented == nil)
      #expect(view.accessibilityValue() == nil)
    } else {
      #expect(view.presented?.frame.identity == baseline.identity)
    }
    view.mouseUp(with: try event(.leftMouseUp))
  }
}
