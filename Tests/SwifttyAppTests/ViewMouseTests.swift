import AppKit
@testable import Swiftty
import SwifttyCore
import Synchronization
import Testing
import TestSupport

extension ViewBehaviorTests {
    @Test(.enabled(if: hasMetal), arguments: ["resize", "reset", "evict", "height"])
    func `selection drags reject an origin invalidated before the next frame`(_ change: String) throws {
        let view = try makeView(configuration: Configuration.parse("scrollback-limit=0"))
        view.setFrameSize(NSSize(width: 320, height: 200))
        view.session.resize(columns: 10, rows: 2)
        view.session.feed(Array("abcd".utf8))
        func event(_ type: NSEvent.EventType, column: Int) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type,
                location: NSPoint(
                    x: (view.renderer.options.paddingX + (CGFloat(column) + 0.5) * view.renderer.cellSize.width) / 2,
                    y: view.bounds.height - (view.renderer.options.paddingY + view.renderer.cellSize.height / 2) / 2,
                ),
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                clickCount: change == "height" ? 2 : 1, pressure: 0,
            ))
        }
        try view.mouseDown(with: event(.leftMouseDown, column: 0))
        if change == "resize" {
            view.session.resize(columns: 20, rows: 2)
        } else if change == "height" {
            view.session.resize(columns: 10, rows: 3)
        } else if change == "reset" {
            view.session.reset()
            view.session.feed(Array("wxyz".utf8))
        } else {
            view.session.feed(Array("\r\nrow1\r\nrow2\r\nrow3".utf8))
        }
        try view.mouseDragged(with: event(.leftMouseDragged, column: 2))
        try view.mouseUp(with: event(.leftMouseUp, column: 2))
        #expect(view.session.withState { $0.selectionText } == (change == "height" ? "abcd" : nil))
        #expect(view.selectionOrigin == nil)
        #expect(view.hasSelection == (change == "height"))
    }

    @Test(.enabled(if: hasMetal), arguments: [-1, 2])
    func `selection clicks outside the visible grid use its nearest visible row`(_ row: Int) throws {
        let view = try makeView()
        view.setFrameSize(NSSize(width: 320, height: 200))
        view.session.resize(columns: 4, rows: 2)
        view.session.feed(Array("row0\r\nrow1\r\nrow2\r\nrow3\r\nrow4".utf8))
        view.session.scrollViewport(by: 1)
        view.draw(in: view)
        let expectedRow = view.session.withState { $0.absoluteRow(viewportRow: row < 0 ? 0 : 1) }
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(
                x: (view.renderer.options.paddingX + view.renderer.cellSize.width / 2) / 2,
                y: row < 0 ? view.bounds.height - view.renderer.options.paddingY / 4
                    : view.bounds.height - (view.renderer.options.paddingY + (CGFloat(row) + 0.5) * view.renderer.cellSize.height) / 2,
            ),
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 2, pressure: 0,
        ))
        view.mouseDown(with: event)
        #expect(view.session.withState { $0.selection?.start.row } == expectedRow)
        #expect(view.session.withState { $0.selectionText } == "row\(expectedRow)")
    }

    @Test(.enabled(if: hasMetal), arguments: [false, true])
    func `an invalidated local selection drag does not become a terminal mouse gesture`(_ drawBeforeDrag: Bool) throws {
        let view = try makeView()
        view.setFrameSize(NSSize(width: 320, height: 200))
        view.session.feed(Array("abcd\u{1B}[?1003h\u{1B}[?1006h".utf8))
        view.draw(in: view)
        let writes = Mutex<[[UInt8]]>([])
        view.session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
        func event(_ type: NSEvent.EventType, column: Int, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type,
                location: NSPoint(
                    x: (view.renderer.options.paddingX + (CGFloat(column) + 0.5) * view.renderer.cellSize.width) / 2,
                    y: view.bounds.height - (view.renderer.options.paddingY + view.renderer.cellSize.height / 2) / 2,
                ),
                modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 0,
            ))
        }
        try view.mouseDown(with: event(.leftMouseDown, column: 0, modifiers: .shift))
        try view.mouseDragged(with: event(.leftMouseDragged, column: 1, modifiers: .shift))
        #expect(view.session.withState { $0.selectionText } == "ab")
        view.session.feed(Array("\u{1B}[H\u{1B}[2J".utf8))
        if drawBeforeDrag {
            view.draw(in: view)
        }
        try view.mouseDragged(with: event(.leftMouseDragged, column: 2))
        try view.mouseDragged(with: event(.leftMouseDragged, column: 3))
        try view.mouseUp(with: event(.leftMouseUp, column: 3))
        _ = view.session.snapshot()
        #expect(writes.withLock { $0.isEmpty })
        #expect(view.session.withState { $0.selection == nil })
    }

    @Test(.enabled(if: hasMetal), arguments: [false, true])
    func `command link clicks consume their drag and release reports`(_ released: Bool) throws {
        let view = try makeView()
        view.setFrameSize(NSSize(width: 320, height: 200))
        // A blocked scheme exercises the consumed link click without opening
        // another application during the test.
        view.session.feed(Array("\u{1B}]8;;file:///tmp/swiftty-review\u{7}link\u{1B}]8;;\u{7}\u{1B}[?1003h\u{1B}[?1006h".utf8))
        view.draw(in: view)
        let writes = Mutex<[[UInt8]]>([])
        view.session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
        func event(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type,
                location: NSPoint(
                    x: (view.renderer.options.paddingX + view.renderer.cellSize.width / 2) / 2,
                    y: view.bounds.height - (view.renderer.options.paddingY + view.renderer.cellSize.height / 2) / 2,
                ),
                modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 0,
            ))
        }
        let down = try event(.leftMouseDown, modifiers: .command)
        #expect(view.link(for: down) != nil)
        view.mouseDown(with: down)
        try view.mouseDragged(with: event(.leftMouseDragged))
        if released {
            try view.mouseUp(with: event(.leftMouseUp))
        }
        _ = view.session.snapshot()
        #expect(writes.withLock { $0.isEmpty })

        try view.mouseDown(with: event(.leftMouseDown))
        try view.mouseUp(with: event(.leftMouseUp))
        _ = view.session.snapshot()
        #expect(TestFixture(writes.withLock { $0.map { String(decoding: $0, as: UTF8.self) } }) == TestFixture([
            "\u{1B}[<0;1;1M",
            "\u{1B}[<0;1;1m",
        ]))
    }
}
