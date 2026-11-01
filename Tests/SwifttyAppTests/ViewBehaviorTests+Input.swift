import AppKit
import Metal
@testable import Swiftty
@testable import SwifttyMac
import SwifttyCore
import Synchronization
import Testing
import TestSupport

/// VoiceOver throttling and text caching, and render options surviving a
/// configuration reload, in the macOS view.
extension ViewBehaviorTests {
  @Test(.enabled(if: hasMetal), arguments: [false, true], [false, true])
  func
    `clipboard paste clears selection and filters controls through both actions`(
      _ binding: Bool,
      _ bracketed: Bool
    ) throws
  {
    let view = try makeView()
    let clipboard = NSPasteboard.withUniqueName()
    view.pasteboard = clipboard
    defer { clipboard.releaseGlobally() }
    clipboard.setString("漢\u{15}text\u{03}end", forType: .string)
    view.session.feed(Array(("abc" + (bracketed ? "\u{1B}[?2004h" : "")).utf8))
    view.selectAll(nil)
    #expect(view.hasSelection)
    #expect(view.session.withState { $0.selection != nil })
    let writes = Mutex<[UInt8]>([])
    view.session.onWrite = { bytes in
      writes.withLock { $0.append(contentsOf: bytes) }
    }
    if binding {
      #expect(view.perform(.pasteFromClipboard))
    } else {
      view.paste(nil)
    }
    _ = view.session.snapshot()
    #expect(!view.hasSelection)
    #expect(view.session.withState { $0.selection == nil })
    let expected = bracketed ? "\u{1B}[200~漢 text end\u{1B}[201~" : "漢 text end"
    #expect(
      TestFixture(writes.withLock { String(decoding: $0, as: UTF8.self) })
        == TestFixture(expected)
    )
  }

  @Test(.enabled(if: hasMetal), arguments: [false, true])
  func `an unavailable clipboard paste retains selection`(
    _ binding: Bool
  ) throws {
    let view = try makeView()
    let clipboard = NSPasteboard.withUniqueName()
    view.pasteboard = clipboard
    defer { clipboard.releaseGlobally() }
    view.session.feed(Array("abc".utf8))
    view.selectAll(nil)
    let writes = Mutex<[UInt8]>([])
    view.session.onWrite = { bytes in
      writes.withLock { $0.append(contentsOf: bytes) }
    }
    if binding {
      #expect(!view.perform(.pasteFromClipboard))
    } else {
      view.paste(nil)
    }
    _ = view.session.snapshot()
    #expect(view.hasSelection)
    #expect(view.session.withState { $0.selection != nil })
    #expect(writes.withLock { $0.isEmpty })
  }

  @Test(.enabled(if: hasMetal))
  func
    `unavailable performable prompt navigation sends the key to the application`()
    throws
  {
    let configuration = Configuration.configured([
      ("keybind", "performable:ctrl+arrow_down=jump_to_prompt:1")
    ])
    let view = try makeView(configuration: configuration)
    let writes = Mutex<[UInt8]>([])
    view.session.onWrite = { bytes in
      writes.withLock { $0.append(contentsOf: bytes) }
    }
    view.session.feed(
      Array("\u{1B}]133;A\u{7}first\r\n\u{1B}]133;A\u{7}second".utf8)
    )
    let event = try #require(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: .control,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "\u{F701}",
        charactersIgnoringModifiers: "\u{F701}",
        isARepeat: false,
        keyCode: 125,
      )
    )
    view.keyDown(with: event)
    _ = view.session.snapshot()
    #expect(
      TestFixture(writes.withLock { $0 })
        == TestFixture(Array("\u{1B}[1;5B".utf8))
    )
    #expect(view.session.withState { $0.viewportOffset } == 0)
  }

  @Test(
    .enabled(if: hasMetal),
    arguments: ["plain", "attributed", "composition"],
    [UInt8(0), 8, 24, 31]
  )
  func `text system commits clear terminal selection`(
    _ route: String,
    _ flags: UInt8
  ) throws {
    let view = try makeView()
    let writes = Mutex<[UInt8]>([])
    view.session.onWrite = { bytes in
      writes.withLock { $0.append(contentsOf: bytes) }
    }
    view.session.feed(Array("selected output".utf8))
    view.session.feed(Array("\u{1B}[=\(flags)u".utf8))
    view.selectAll(nil)
    let replacement = NSRange(location: NSNotFound, length: 0)
    view.insertText("", replacementRange: replacement)
    #expect(view.hasSelection)
    #expect(view.session.withState { $0.selection != nil })
    #expect(writes.withLock { $0.isEmpty })
    let text = "漢e\u{301}"
    switch route {
    case "composition":
      view.setMarkedText(
        text,
        selectedRange: NSRange(location: 0, length: 0),
        replacementRange: replacement
      )
      view.unmarkText()
    case "attributed":
      view.insertText(
        NSAttributedString(string: text),
        replacementRange: replacement
      )
    default: view.insertText(text, replacementRange: replacement)
    }
    _ = view.session.snapshot()
    #expect(!view.hasSelection)
    #expect(view.session.withState { $0.selection == nil })
    let expected =
      flags & 8 == 0
      ? text : flags & 16 == 0 ? "\u{1B}[0u" : "\u{1B}[0;1;28450:101:769u"
    #expect(writes.withLock { $0 } == Array(expected.utf8))
  }

  @Test(.enabled(if: hasMetal))
  func `IME selection follows marked text updates and clears on commit`() throws
  {
    let view = try makeView()
    let writes = Mutex<[UInt8]>([])
    view.session.onWrite = { bytes in
      writes.withLock { $0.append(contentsOf: bytes) }
    }
    let replacement = NSRange(location: NSNotFound, length: 0)
    view.setMarkedText(
      "😀ab",
      selectedRange: NSRange(location: 2, length: 1),
      replacementRange: replacement
    )
    #expect(view.markedRange() == NSRange(location: 0, length: 4))
    #expect(view.selectedRange() == NSRange(location: 2, length: 1))
    #expect(
      view.renderer.options.preeditSelection == NSRange(location: 2, length: 1)
    )
    // IMEs can move the selection without changing the composition.
    view.setMarkedText(
      "😀ab",
      selectedRange: NSRange(location: 3, length: 0),
      replacementRange: replacement
    )
    #expect(view.selectedRange() == NSRange(location: 3, length: 0))
    #expect(
      view.renderer.options.preeditSelection == NSRange(location: 3, length: 0)
    )
    view.unmarkText()
    _ = view.session.snapshot()
    #expect(writes.withLock { $0 } == Array("😀ab".utf8))
    #expect(!view.hasMarkedText() && view.renderer.options.preedit.isEmpty)
    #expect(view.renderer.options.preeditSelection == nil)
    #expect(view.selectedRange() == replacement)
    #expect(view.markedRange() == replacement)
    view.unmarkText()
    _ = view.session.snapshot()
    #expect(writes.withLock { $0 } == Array("😀ab".utf8))
  }

  @Test(
    .enabled(if: hasMetal),
    arguments: [
      ("e\u{301}", 1), ("中", 2), ("👩‍💻", 2), ("🇻🇳", 2), ("❤\u{FE0F}", 2),
      ("⌚\u{FE0E}", 1),
    ],
    [false, true]
  )
  func `IME candidate rectangles follow composition ranges`(
    _ sample: (String, Int),
    _ mux: Bool
  ) throws {
    let (prefix, columns) = sample
    let direct = try makeView()
    let pane = try MuxPaneView(pane: .init(), configuration: Configuration())
    let view: any NSTextInputClient = mux ? pane : direct
    let renderer = mux ? pane.renderer : direct.renderer
    let surface: NSView = mux ? pane : direct
    surface.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
    view.setMarkedText(
      prefix + "X",
      selectedRange: NSRange(location: prefix.utf16.count, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0),
    )
    let cellWidth = renderer.cellSize.width / renderer.font.descriptor.scale
    let origin = view.firstRect(
      forCharacterRange: NSRange(location: 0, length: 0),
      actualRange: nil
    )
    #expect(origin.width == 0)
    var actual = NSRange(location: NSNotFound, length: 0)
    let suffixRange = NSRange(location: prefix.utf16.count, length: 1)
    let suffix = view.firstRect(
      forCharacterRange: suffixRange,
      actualRange: &actual
    )
    #expect(
      abs(suffix.minX - (origin.minX + CGFloat(columns) * cellWidth)) < 0.001
    )
    #expect(abs(suffix.width - cellWidth) < 0.001 && suffix.minY == origin.minY)
    #expect(actual == suffixRange)
    let partial = view.firstRect(
      forCharacterRange: NSRange(location: 0, length: 1),
      actualRange: &actual
    )
    #expect(abs(partial.width - CGFloat(columns) * cellWidth) < 0.001)
    #expect(actual == NSRange(location: 0, length: prefix.utf16.count))
    let caretRange = NSRange(location: prefix.utf16.count, length: 0)
    let caret = view.firstRect(
      forCharacterRange: caretRange,
      actualRange: &actual
    )
    #expect(caret.minX == suffix.minX && caret.width == 0)
    #expect(actual == caretRange)
    let whole = view.firstRect(
      forCharacterRange: NSRange(location: 0, length: .max),
      actualRange: &actual
    )
    #expect(abs(whole.width - CGFloat(columns + 1) * cellWidth) < 0.001)
    #expect(actual == NSRange(location: 0, length: prefix.utf16.count + 1))
  }

  @Test(.enabled(if: hasMetal))
  func `IME candidate rectangles convert nested view coordinates to screen`()
    throws
  {
    let view = try makeView()
    let window = NSWindow(
      contentRect: NSRect(x: 100, y: 120, width: 640, height: 480),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false,
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
    window.contentView = container
    view.frame = NSRect(x: 40, y: 50, width: 500, height: 300)
    container.addSubview(view)
    view.session.feed(Array("\u{1B}[2;4H".utf8))
    view.lastSnapshot = view.session.snapshot()
    view.setMarkedText(
      "👩‍💻X",
      selectedRange: NSRange(location: 5, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0),
    )
    let scale = window.backingScaleFactor
    let cell = view.renderer.cellSize
    let expected = window.convertToScreen(
      NSRect(
        x: 40 + (view.renderer.options.paddingX + 5 * cell.width) / scale,
        y: 50 + view.bounds.height
          - (view.renderer.options.paddingY + 2 * cell.height) / scale,
        width: cell.width / scale,
        height: cell.height / scale,
      )
    )
    let actual = view.firstRect(
      forCharacterRange: NSRange(location: 5, length: 1),
      actualRange: nil
    )
    #expect(actual == expected)
  }

  @Test(.enabled(if: hasMetal))
  func `all surface bindings reach other terminals and exclude stopped views`()
    throws
  {
    let first = try makeView(
      configuration: Configuration.configured([
        ("keybind", "all:unconsumed:ctrl+a=text:X")
      ])
    )
    let second = try makeView()
    let firstWrites = Mutex<[UInt8]>([])
    let secondWrites = Mutex<[UInt8]>([])
    first.session.onWrite = { bytes in
      firstWrites.withLock { $0.append(contentsOf: bytes) }
    }
    second.session.onWrite = { bytes in
      secondWrites.withLock { $0.append(contentsOf: bytes) }
    }
    let event = try #require(
      TestFixture(
        NSEvent.keyEvent(
          with: .keyDown,
          location: .zero,
          modifierFlags: .control,
          timestamp: 0,
          windowNumber: 0,
          context: nil,
          characters: "\u{1}",
          charactersIgnoringModifiers: "a",
          isARepeat: false,
          keyCode: 0,
        )
      )
      .value
    )
    first.keyDown(with: event)
    _ = first.session.snapshot()
    _ = second.session.snapshot()
    #expect(firstWrites.withLock { $0 } == [0x58])
    #expect(secondWrites.withLock { $0 } == [0x58])
    #expect(first.heldKeys.isEmpty)
    second.stop()
    secondWrites.withLock { $0.removeAll() }
    first.keyDown(with: event)
    _ = first.session.snapshot()
    _ = second.session.snapshot()
    #expect(firstWrites.withLock { $0 } == [0x58, 0x58])
    #expect(secondWrites.withLock { $0.isEmpty })
  }

  @Test(.enabled(if: hasMetal))
  func `performable copy consumes the key when a selection exists`() throws {
    let view = try makeView(
      configuration: Configuration.configured([
        ("keybind", "performable:ctrl+c=copy_to_clipboard")
      ])
    )
    let clipboard = NSPasteboard.withUniqueName()
    view.pasteboard = clipboard
    defer { clipboard.releaseGlobally() }
    view.session.feed(Array("abc".utf8))
    view.session.mutate {
      $0.setSelection(
        Selection(
          anchor: TerminalPoint(row: 0, column: 0),
          head: TerminalPoint(row: 0, column: 2)
        )
      )
    }
    let writes = Mutex<[UInt8]>([])
    view.session.onWrite = { bytes in
      writes.withLock { $0.append(contentsOf: bytes) }
    }
    let event = try #require(
      TestFixture(
        NSEvent.keyEvent(
          with: .keyDown,
          location: .zero,
          modifierFlags: .control,
          timestamp: 0,
          windowNumber: 0,
          context: nil,
          characters: "\u{3}",
          charactersIgnoringModifiers: "c",
          isARepeat: false,
          keyCode: 8,
        )
      )
      .value
    )
    view.keyDown(with: event)
    _ = view.session.snapshot()
    #expect(clipboard.string(forType: .string) == "abc")
    #expect(writes.withLock { $0.isEmpty })
    #expect(view.session.withState { $0.selection != nil })
  }

  @Test(.enabled(if: hasMetal), arguments: [false, true])
  func `unavailable performable copy bindings pass the key through`(
    _ keyEquivalent: Bool
  ) throws {
    let config = Configuration.configured([
      ("keybind", "performable:ctrl+c=copy_to_clipboard")
    ])
    let view = try makeView(configuration: config)
    let window = NSWindow(
      contentRect: .zero,
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = view
    #expect(window.makeFirstResponder(view))
    let writes = Mutex<[UInt8]>([])
    view.session.onWrite = { bytes in
      writes.withLock { $0.append(contentsOf: bytes) }
    }
    let event = try #require(
      TestFixture(
        NSEvent.keyEvent(
          with: .keyDown,
          location: .zero,
          modifierFlags: .control,
          timestamp: 0,
          windowNumber: window.windowNumber,
          context: nil,
          characters: "\u{3}",
          charactersIgnoringModifiers: "c",
          isARepeat: false,
          keyCode: 8,
        )
      )
      .value
    )
    if keyEquivalent { #expect(!view.performKeyEquivalent(with: event)) }
    view.keyDown(with: event)
    _ = view.session.snapshot()
    #expect(writes.withLock { $0 } == [0x03])
  }

  @Test(.enabled(if: hasMetal), arguments: [false, true], [false, true])
  func `unconsumed bindings send the action and original key once`(
    _ keyEquivalent: Bool,
    _ control: Bool
  ) throws {
    let config = Configuration.configured([
      ("keybind", "unconsumed:\(control ? "ctrl+" : "")a=text:X")
    ])
    let view = try makeView(configuration: config)
    let window = NSWindow(
      contentRect: .zero,
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = view
    #expect(window.makeFirstResponder(view))
    let writes = Mutex<[UInt8]>([])
    view.session.onWrite = { bytes in
      writes.withLock { $0.append(contentsOf: bytes) }
    }
    let event = try #require(
      TestFixture(
        NSEvent.keyEvent(
          with: .keyDown,
          location: .zero,
          modifierFlags: control ? .control : [],
          timestamp: 0,
          windowNumber: window.windowNumber,
          context: nil,
          characters: control ? "\u{1}" : "a",
          charactersIgnoringModifiers: "a",
          isARepeat: false,
          keyCode: 0,
        )
      )
      .value
    )
    if keyEquivalent {
      #expect(view.performKeyEquivalent(with: event))
    } else {
      view.keyDown(with: event)
    }
    _ = view.session.snapshot()
    #expect(writes.withLock { $0 } == [0x58, control ? 0x01 : 0x61])
    #expect(view.heldKeys.count == (control ? 1 : 0))
  }

  @Test(.enabled(if: hasMetal))
  func `window key notifications release keys while retaining the responder`()
    throws
  {
    let view = try makeView()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
      styleMask: [.titled],
      backing: .buffered,
      defer: false,
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = view
    #expect(window.makeFirstResponder(view))
    let writes = Mutex<[[UInt8]]>([])
    view.session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
    view.session.feed(Array("\u{1B}[=10u\u{1B}[?1004h".utf8))
    _ = view.session.snapshot()
    view.heldKeys = [0: KeyEvent(.character("a"), modifiers: .shift)]
    NotificationCenter.default.post(
      name: NSWindow.didResignKeyNotification,
      object: window
    )
    #expect(window.firstResponder === view)
    #expect(view.heldKeys.isEmpty)
    _ = view.session.snapshot()
    #expect(
      TestFixture(
        writes.withLock { $0.map { String(decoding: $0, as: UTF8.self) } }
      ) == TestFixture(["\u{1B}[97;2:3u", "\u{1B}[O"])
    )
    writes.withLock { $0.removeAll() }
    NotificationCenter.default.post(
      name: NSWindow.didBecomeKeyNotification,
      object: window
    )
    _ = view.session.snapshot()
    #expect(
      TestFixture(
        writes.withLock { $0.map { String(decoding: $0, as: UTF8.self) } }
      ) == TestFixture(["\u{1B}[I"])
    )
  }

  @Test(.enabled(if: hasMetal))
  func `moving a view releases keys and removes old window observers`() throws {
    let view = try makeView()
    let first = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
      styleMask: [.titled],
      backing: .buffered,
      defer: false,
    )
    let second = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
      styleMask: [.titled],
      backing: .buffered,
      defer: false,
    )
    first.isReleasedWhenClosed = false
    second.isReleasedWhenClosed = false
    defer {
      first.close();
      second.close()
    }
    first.contentView = view
    #expect(first.makeFirstResponder(view))
    let writes = Mutex<[[UInt8]]>([])
    view.session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
    view.session.feed(Array("\u{1B}[=10u\u{1B}[?1004h".utf8))
    _ = view.session.snapshot()
    view.heldKeys = [0: KeyEvent(.character("a"))]
    view.removeFromSuperview()
    _ = view.session.snapshot()
    #expect(view.heldKeys.isEmpty)
    let releases = writes.withLock {
      $0.filter { $0 == Array("\u{1B}[97;1:3u".utf8) }
    }
    #expect(releases.count == 1)
    second.contentView = view
    #expect(second.makeFirstResponder(view))
    _ = view.session.snapshot()
    writes.withLock { $0.removeAll() }
    view.heldKeys = [0: KeyEvent(.character("a"))]
    NotificationCenter.default.post(
      name: NSWindow.didResignKeyNotification,
      object: first
    )
    NotificationCenter.default.post(
      name: NSWindow.didBecomeKeyNotification,
      object: first
    )
    _ = view.session.snapshot()
    #expect(writes.withLock { $0.isEmpty })
    #expect(view.heldKeys.count == 1)
    NotificationCenter.default.post(
      name: NSWindow.didResignKeyNotification,
      object: second
    )
    _ = view.session.snapshot()
    #expect(view.heldKeys.isEmpty)
    #expect(
      TestFixture(writes.withLock { $0.last })
        == TestFixture(Array("\u{1B}[O".utf8))
    )
  }

  @Test(.enabled(if: hasMetal))
  func `raw text actions preserve every byte`() throws {
    let view = try makeView()
    let writes = Mutex<[UInt8]>([])
    view.session.onWrite = { bytes in
      writes.withLock { $0.append(contentsOf: bytes) }
    }
    view.session.feed(Array("\u{1B}[?2004h\u{1B}[=31u".utf8))
    view.perform(.textBytes([0, 0x80, 0xFF]))
    _ = view.session.snapshot()
    #expect(writes.withLock { $0 } == [0, 0x80, 0xFF])
  }

  @Test(.enabled(if: hasMetal))
  func `refinement flags keep hardware commits as text`() throws {
    let view = try makeView()
    let writes = Mutex<[UInt8]>([])
    view.session.onWrite = { bytes in
      writes.withLock { $0.append(contentsOf: bytes) }
    }
    view.interpretingEvent = try #require(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: .option,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "å",
        charactersIgnoringModifiers: "a",
        isARepeat: false,
        keyCode: 0,
      )
    )
    for flags in [0, 2, 4, 16, 6, 18, 20, 22] {
      view.session.feed(Array("\u{1B}[=\(flags)u".utf8))
      writes.withLock { $0.removeAll() }
      view.insertText(
        "å",
        replacementRange: NSRange(location: NSNotFound, length: 0)
      )
      _ = view.session.snapshot()  // Drain the queued send.
      #expect(writes.withLock { $0 } == Array("å".utf8))
    }
  }

  @Test(.enabled(if: hasMetal), arguments: [UInt8(0), 10])
  func `focus loss releases held hardware keys once`(_ flags: UInt8) throws {
    let view = try makeView()
    let writes = Mutex<[[UInt8]]>([])
    view.session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
    view.session.feed(Array("\u{1B}[=\(flags)u\u{1B}[?1004h".utf8))
    let press = try #require(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: .shift,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "A",
        charactersIgnoringModifiers: "a",
        isARepeat: false,
        keyCode: 0,
      )
    )
    let repeated = try #require(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: .shift,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "A",
        charactersIgnoringModifiers: "a",
        isARepeat: true,
        keyCode: 0,
      )
    )
    let up = try #require(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "\u{F700}",
        charactersIgnoringModifiers: "\u{F700}",
        isARepeat: false,
        keyCode: 126,
      )
    )
    let letter = KeyEvent(.character("a"), modifiers: .shift)
    view.sendHardwareKey(letter, event: press)
    view.sendHardwareKey(letter, event: repeated)
    view.sendHardwareKey(KeyEvent(.up), event: up)
    // Drain the queued presses before measuring releases.
    _ = view.session.snapshot()
    #expect(view.heldKeys.count == 2)
    writes.withLock { $0.removeAll() }

    #expect(view.resignFirstResponder())
    #expect(view.heldKeys.isEmpty)
    _ = view.session.snapshot()
    let sent = writes.withLock {
      $0.map { String(decoding: $0, as: UTF8.self) }
    }
    // Releases precede the focus report.
    #expect(TestFixture(sent.last) == TestFixture("\u{1B}[O"))
    if flags == 10 {
      #expect(
        TestFixture(sent.dropLast().sorted())
          == TestFixture(["\u{1B}[97;2:3u", "\u{1B}[1;1:3A"].sorted())
      )
    } else {
      #expect(TestFixture(sent) == TestFixture(["\u{1B}[O"]))
    }

    #expect(view.becomeFirstResponder())
    _ = view.session.snapshot()
    writes.withLock { $0.removeAll() }
    // A delayed key-up after focus returns must not release a stale press.
    for (code, characters) in [(UInt16(0), "a"), (126, "\u{F700}")] {
      let release = try #require(
        NSEvent.keyEvent(
          with: .keyUp,
          location: .zero,
          modifierFlags: [],
          timestamp: 0,
          windowNumber: 0,
          context: nil,
          characters: characters,
          charactersIgnoringModifiers: characters,
          isARepeat: false,
          keyCode: code,
        )
      )
      view.keyUp(with: release)
    }
    _ = view.session.snapshot()
    #expect(writes.withLock { $0.isEmpty })
  }
}
