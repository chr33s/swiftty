import TestSupport
#if canImport(UIKit)
import Metal
import SwifttyCore
@testable import SwifttyMobile
import Synchronization
import Testing
import UIKit

extension ViewLifecycleTests {
  @Test(
    .enabled(if: hasMetal),
    arguments: ["detach", "background", "release"],
    [false, true]
  )
  func `accessory repeats stop when keyboard interaction ends`(
    _ transition: String,
    _ repeating: Bool
  ) async throws {
    let view = try TerminalUIView(session: TerminalSession())
    let bar = view.accessoryBar
    let window = makeWindow()
    window.addSubview(view)
    window.addSubview(bar)
    defer {
      view.removeFromSuperview();
      bar.removeFromSuperview()
    }
    func findButton(in parent: UIView) -> UIButton? {
      if let button = parent as? UIButton, button.accessibilityLabel == "Escape"
      {
        return button
      }
      return parent.subviews.lazy.compactMap { findButton(in: $0) }.first
    }
    let button = try #require(findButton(in: bar))
    defer { _ = bar.perform(NSSelectorFromString("keyUp:"), with: button) }
    var keys: [AccessoryKey] = []
    bar.onKey = { keys.append($0) }
    _ = bar.perform(NSSelectorFromString("keyDown:"), with: button)
    #expect(keys == [.escape])
    if repeating {
      let deadline = ContinuousClock.now + .seconds(2)
      while keys.count < 2, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
      }
      try #require(keys.count >= 2)
    }
    switch transition {
    case "detach": bar.removeFromSuperview()
    case "background": view.sceneDidEnterBackground()
    default: view.releaseHardwareKeys()
    }
    let stoppedCount = keys.count
    try await Task.sleep(for: .milliseconds(repeating ? 200 : 650))
    #expect(keys.count == stoppedCount)
  }

  @Test(.enabled(if: hasMetal))
  func `hardware key repeat stops after its view is released`() throws {
    weak var retainedView: TerminalUIView?
    var repeating: Timer?
    do {
      let view = try TerminalUIView(session: TerminalSession())
      retainedView = view
      try #require(
        view.keyDown(
          usage: 82,
          modifiers: [],
          base: "\u{F700}",
          characters: "\u{F700}"
        )
      )
      let delay = try #require(view.keyRepeat)
      delay.fire()  // Advance from the initial delay to the repeating timer.
      delay.invalidate()
      repeating = try #require(view.keyRepeat)
    }
    let timer = try #require(repeating)
    defer { timer.invalidate() }
    #expect(retainedView == nil)
    try #require(timer.isValid)
    timer.fire()
    #expect(!timer.isValid)
  }

  @Test(.enabled(if: hasMetal), arguments: [false, true])
  func `configuration reload invalidates previously issued key commands`(
    _ rebuild: Bool
  ) throws {
    let session = TerminalSession(columns: 10, rows: 2)
    let view = try TerminalUIView(
      session: session,
      configuration: Configuration.parse("keybind=ctrl+a=text:X")
    )
    let stale = try #require(
      view.keyCommands?
        .first { $0.input == "a" && $0.modifierFlags == .control }
    )
    view.apply(Configuration.parse("keybind=ctrl+a=text:Y"))
    if rebuild { _ = view.keyCommands }
    let writes = Mutex<[UInt8]>([])
    session.onWrite = { bytes in
      writes.withLock { $0.append(contentsOf: bytes) }
    }
    view.performKeyCommand(stale)
    _ = session.snapshot()
    #expect(writes.withLock { $0.isEmpty })
    let current = try #require(
      view.keyCommands?
        .first { $0.input == "a" && $0.modifierFlags == .control }
    )
    let copied = try #require(current.copy() as? UIKeyCommand)
    view.performKeyCommand(copied)
    _ = session.snapshot()
    #expect(writes.withLock { $0 } == Array("Y".utf8))
  }

  // An accessory key no longer interrupts a held physical key: it is
  // refused (DirectionPadEventTests).
  @Test(.enabled(if: hasMetal), arguments: [0, 1, 2, 3, 5])
  func `new text bindings and composition stop an older key repeat`(
    _ transition: Int
  ) throws {
    let session = TerminalSession(columns: 10, rows: 2)
    let view = try TerminalUIView(
      session: session,
      configuration: Configuration.parse(
        "keybind=b=ignore\nkeybind=ctrl+b=ignore"
      )
    )
    defer { view.releaseHardwareKeys() }
    session.feed(Array("\u{1B}[=10u".utf8))
    let writes = Mutex<[[UInt8]]>([])
    session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
    #expect(
      view.keyDown(
        usage: KeyTranslator.Usage.left,
        modifiers: [],
        base: "",
        characters: ""
      )
    )
    let timer = try #require(view.keyRepeat)
    _ = session.snapshot()
    switch transition {
    case 0:
      #expect(
        !view.keyDown(usage: 4, modifiers: [], base: "a", characters: "a")
      )
    case 1:
      #expect(view.keyDown(usage: 5, modifiers: [], base: "b", characters: "b"))
    case 2:
      view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0))
    case 3: view.insertText("x")
    default:
      let command = try #require(
        view.keyCommands?
          .first { $0.input == "b" && $0.modifierFlags == .control }
      )
      view.performKeyCommand(command)
    }
    #expect(view.keyRepeat == nil && !timer.isValid)
    #expect(view.heldKeys[KeyTranslator.Usage.left] != nil)
    _ = session.snapshot()
    let sent = writes.withLock { $0 }
    timer.fire()
    timer.invalidate()
    view.keyRepeat?.fire()
    _ = session.snapshot()
    #expect(writes.withLock { $0 } == sent)
    view.releaseHardwareKeys()
    _ = session.snapshot()
    #expect(
      TestFixture(writes.withLock { $0.last })
        == TestFixture(Array("\u{1B}[1;1:3D".utf8))
    )
  }

  @Test(.enabled(if: hasMetal))
  func
    `activating kitty reporting during a held text key reports a repeat and release`()
    throws
  {
    let session = TerminalSession(columns: 10, rows: 2)
    let view = try TerminalUIView(session: session)
    defer { view.releaseHardwareKeys() }
    let writes = Mutex<[[UInt8]]>([])
    session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
    #expect(!view.keyDown(usage: 4, modifiers: [], base: "a", characters: "a"))
    view.insertText("a")
    session.feed(Array("\u{1B}[=10u".utf8))
    view.insertText("a")
    _ = session.snapshot()
    #expect(
      TestFixture(writes.withLock { $0 })
        == TestFixture([Array("a".utf8), Array("\u{1B}[97;1:2u".utf8)])
    )
    view.releaseHardwareKeys()
    _ = session.snapshot()
    #expect(
      TestFixture(writes.withLock { $0.last })
        == TestFixture(Array("\u{1B}[97;1:3u".utf8))
    )
  }

  @Test(.enabled(if: hasMetal))
  func
    `key commands abandon pending hardware text and consume latched modifiers`()
    throws
  {
    let session = TerminalSession(columns: 10, rows: 2)
    let view = try TerminalUIView(
      session: session,
      configuration: Configuration.parse("keybind=ctrl+b=ignore")
    )
    defer { view.releaseHardwareKeys() }
    session.feed(Array("\u{1B}[=10u".utf8))
    view.sticky.tap(.alt)
    #expect(!view.keyDown(usage: 4, modifiers: [], base: "a", characters: "a"))
    let command = try #require(
      view.keyCommands?
        .first { $0.input == "b" && $0.modifierFlags == .control }
    )
    view.performKeyCommand(command)
    #expect(view.sticky.active.isEmpty)
    let writes = Mutex<[UInt8]>([])
    session.onWrite = { bytes in
      writes.withLock { $0.append(contentsOf: bytes) }
    }
    view.insertText("a")
    _ = session.snapshot()
    #expect(view.heldKeys[4] == nil)
    // Unassociated text under all-key reporting reports key zero, not the press.
    #expect(writes.withLock { $0 } == Array("\u{1B}[0u".utf8))
  }

  @Test(.enabled(if: hasMetal), arguments: [false, true])
  func `a second shift key preserves a held text keys repeat report`(
    _ releaseModifier: Bool
  ) throws {
    let session = TerminalSession(columns: 10, rows: 2)
    let view = try TerminalUIView(session: session)
    defer { view.releaseHardwareKeys() }
    session.feed(Array("\u{1B}[=10u".utf8))
    let writes = Mutex<[[UInt8]]>([])
    session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
    #expect(
      !view.keyDown(usage: 4, modifiers: .shift, base: "a", characters: "A")
    )
    view.insertText("A")
    let rightShift = KeyTranslator.Usage.leftControl + 5
    #expect(
      !view.keyDown(
        usage: rightShift,
        modifiers: .shift,
        base: "",
        characters: ""
      )
    )
    if releaseModifier {
      view.pressesEnded([ReviewKeyPress(rightShift)], with: nil)
    }
    view.insertText("A")
    _ = session.snapshot()
    #expect(
      TestFixture(writes.withLock { $0 })
        == TestFixture([
          Array("\u{1B}[97;2u".utf8), Array("\u{1B}[97;2:2u".utf8),
        ])
    )
    view.releaseHardwareKeys()
    _ = session.snapshot()
    #expect(
      TestFixture(writes.withLock { $0.last })
        == TestFixture(Array("\u{1B}[97;2:3u".utf8))
    )
  }

  @Test(.enabled(if: hasMetal))
  func `modifier presses preserve hardware repeat`() throws {
    let view = try TerminalUIView(
      session: TerminalSession(columns: 10, rows: 2)
    )
    defer { view.releaseHardwareKeys() }
    #expect(
      view.keyDown(
        usage: KeyTranslator.Usage.left,
        modifiers: [],
        base: "",
        characters: ""
      )
    )
    let timer = try #require(view.keyRepeat)
    #expect(
      !view.keyDown(
        usage: KeyTranslator.Usage.leftControl + 1,
        modifiers: .shift,
        base: "",
        characters: ""
      )
    )
    #expect(view.keyRepeat === timer && timer.isValid)
  }

  @Test(.enabled(if: hasMetal), arguments: [false, true])
  func `releasing an older hardware key preserves the current repeat`(
    _ cancelled: Bool
  ) throws {
    let session = TerminalSession(columns: 10, rows: 2)
    let view = try TerminalUIView(session: session)
    defer { view.releaseHardwareKeys() }
    session.feed(Array("\u{1B}[=10u".utf8))
    let writes = Mutex<[[UInt8]]>([])
    session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
    #expect(
      view.keyDown(
        usage: KeyTranslator.Usage.left,
        modifiers: [],
        base: "",
        characters: ""
      )
    )
    #expect(
      view.keyDown(
        usage: KeyTranslator.Usage.right,
        modifiers: [],
        base: "",
        characters: ""
      )
    )
    let timer = try #require(view.keyRepeat)
    _ = session.snapshot()
    writes.withLock { $0.removeAll() }
    func release(_ usage: Int) {
      let press = ReviewKeyPress(usage)
      if cancelled {
        view.pressesCancelled([press], with: nil)
      } else {
        view.pressesEnded([press], with: nil)
      }
    }
    release(KeyTranslator.Usage.left)
    #expect(view.keyRepeat === timer && timer.isValid)
    _ = session.snapshot()
    #expect(
      TestFixture(writes.withLock { $0 })
        == TestFixture([Array("\u{1B}[1;1:3D".utf8)])
    )
    writes.withLock { $0.removeAll() }
    view.keyRepeat?.fire()  // Finish the initial delay.
    timer.invalidate()
    view.keyRepeat?.fire()  // Repeat the key that is still down.
    _ = session.snapshot()
    #expect(
      TestFixture(writes.withLock { $0 })
        == TestFixture([Array("\u{1B}[1;1:2C".utf8)])
    )
    release(KeyTranslator.Usage.right)
    #expect(view.keyRepeat == nil && view.heldKeys.isEmpty)
  }

  @Test(.enabled(if: hasMetal), arguments: [4, 8, 16, 20])
  func `scroll gestures and momentum preserve keyboard modifiers`(
    _ bits: Int
  ) throws {
    let flags: UIKeyModifierFlags =
      switch bits {
      case 4: .shift
      case 8: .alternate
      case 16: .control
      default: [.shift, .control]
      }
    let session = TerminalSession(columns: 10, rows: 3)
    let view = try TerminalUIView(session: session)
    let window = makeWindow()
    view.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
    window.addSubview(view)
    window.makeKeyAndVisible()
    defer {
      view.stopMomentum();
      view.removeFromSuperview();
      window.isHidden = true
    }
    session.feed(Array("\u{1B}[?1000h\u{1B}[?1006h".utf8))
    view.draw(in: view)
    let writes = Mutex<[[UInt8]]>([])
    session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
    let pan = ReviewScrollGesture()
    pan.flags = flags
    pan.point = view.geometry.rect(column: 0, row: 0).origin
    pan.state = .began
    _ = view.perform(NSSelectorFromString("handleScroll:"), with: pan)
    pan.state = .changed
    let width = view.geometry.cellSize.width / view.geometry.scale
    pan.distance = CGPoint(x: width, y: view.geometry.lineHeight)
    _ = view.perform(NSSelectorFromString("handleScroll:"), with: pan)
    _ = session.snapshot()
    let expected = ["\u{1B}[<\(64 + bits);1;1M", "\u{1B}[<\(66 + bits);1;1M"]
    #expect(
      TestFixture(
        writes.withLock { $0.map { String(decoding: $0, as: UTF8.self) } }
      ) == TestFixture(expected)
    )
    writes.withLock { $0.removeAll() }
    pan.state = .ended
    pan.speed = CGPoint(x: width * 20, y: view.geometry.lineHeight * 20)
    _ = view.perform(NSSelectorFromString("handleScroll:"), with: pan)
    let deadline = Date().addingTimeInterval(2)
    while writes.withLock({ $0.isEmpty }), Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
      _ = session.snapshot()
    }
    view.stopMomentum()
    _ = session.snapshot()
    let sent = writes.withLock {
      $0.map { String(decoding: $0, as: UTF8.self) }
    }
    #expect(!sent.isEmpty)
    #expect(sent.allSatisfy { expected.contains($0) })
  }

  @Test(.enabled(if: hasMetal))
  func `all surface bindings broadcast through presses and key commands`()
    throws
  {
    let firstSession = TerminalSession(columns: 10, rows: 2)
    let secondSession = TerminalSession(columns: 10, rows: 2)
    let config = Configuration.parse("keybind = unconsumed:all:ctrl+a=text:X")
    let first = try TerminalUIView(session: firstSession, configuration: config)
    let second = try TerminalUIView(session: secondSession)
    let firstWrites = Mutex<[UInt8]>([])
    let secondWrites = Mutex<[UInt8]>([])
    firstSession.onWrite = { bytes in
      firstWrites.withLock { $0.append(contentsOf: bytes) }
    }
    secondSession.onWrite = { bytes in
      secondWrites.withLock { $0.append(contentsOf: bytes) }
    }
    #expect(
      TestFixture(
        first.keyDown(
          usage: 4,
          modifiers: .control,
          base: "a",
          characters: "\u{1}"
        )
      ) == TestFixture(true)
    )
    _ = firstSession.snapshot()
    _ = secondSession.snapshot()
    #expect(firstWrites.withLock { $0 } == [0x58])
    #expect(secondWrites.withLock { $0 } == [0x58])
    #expect(first.heldKeys.isEmpty)
    let command = try #require(
      first.keyCommands?
        .first { $0.input == "a" && $0.modifierFlags == .control }
    )
    first.performKeyCommand(command)
    _ = firstSession.snapshot()
    _ = secondSession.snapshot()
    #expect(firstWrites.withLock { $0 } == [0x58, 0x58])
    #expect(secondWrites.withLock { $0 } == [0x58, 0x58])
    withExtendedLifetime(second) {}
  }

  @Test(.enabled(if: hasMetal))
  func `performable copy consumes the key when a selection exists`() throws {
    let session = TerminalSession(columns: 10, rows: 2)
    let config = Configuration.parse(
      "keybind = performable:ctrl+c=copy_to_clipboard"
    )
    let view = try TerminalUIView(session: session, configuration: config)
    let clipboard = try #require(
      UIPasteboard(name: .init(rawValue: UUID().uuidString), create: true)
    )
    view.pasteboard = clipboard
    defer { UIPasteboard.remove(withName: clipboard.name) }
    session.feed(Array("abc".utf8))
    session.mutate {
      $0.setSelection(
        Selection(
          anchor: TerminalPoint(row: 0, column: 0),
          head: TerminalPoint(row: 0, column: 2)
        )
      )
    }
    let writes = Mutex<[UInt8]>([])
    session.onWrite = { bytes in
      writes.withLock { $0.append(contentsOf: bytes) }
    }
    #expect(
      TestFixture(
        view.keyDown(
          usage: 6,
          modifiers: .control,
          base: "c",
          characters: "\u{3}"
        )
      ) == TestFixture(true)
    )
    _ = session.snapshot()
    #expect(clipboard.string == "abc")
    #expect(writes.withLock { $0.isEmpty })
    #expect(session.withState { $0.selection != nil })
  }

  @Test(.enabled(if: hasMetal))
  func `unavailable performable copy bindings pass the key through`() throws {
    let config = Configuration.parse(
      "keybind = performable:ctrl+c=copy_to_clipboard"
    )
    let session = TerminalSession(columns: 10, rows: 2)
    let view = try TerminalUIView(session: session, configuration: config)
    defer { view.releaseHardwareKeys() }
    let writes = Mutex<[UInt8]>([])
    session.onWrite = { bytes in
      writes.withLock { $0.append(contentsOf: bytes) }
    }
    #expect(
      TestFixture(
        view.keyDown(
          usage: 6,
          modifiers: .control,
          base: "c",
          characters: "\u{3}"
        )
      ) == TestFixture(true)
    )
    _ = session.snapshot()
    #expect(writes.withLock { $0 } == [0x03])
    #expect(
      view.keyCommands?
        .contains { $0.input == "c" && $0.modifierFlags == .control } == false
    )
  }

  @Test(.enabled(if: hasMetal), arguments: [false, true])
  func `bindings send original keys only when unconsumed`(
    _ unconsumed: Bool
  ) throws {
    let config = Configuration.parse(
      "keybind = \(unconsumed ? "unconsumed:" : "")ctrl+a=text:X"
    )
    let session = TerminalSession(columns: 10, rows: 2)
    let view = try TerminalUIView(session: session, configuration: config)
    defer { view.releaseHardwareKeys() }
    let writes = Mutex<[UInt8]>([])
    session.onWrite = { bytes in
      writes.withLock { $0.append(contentsOf: bytes) }
    }
    #expect(
      TestFixture(
        view.keyDown(
          usage: 4,
          modifiers: .control,
          base: "a",
          characters: "\u{1}"
        )
      ) == TestFixture(true)
    )
    _ = session.snapshot()
    #expect(writes.withLock { $0 } == (unconsumed ? [0x58, 0x01] : [0x58]))
    #expect(view.heldKeys.count == (unconsumed ? 1 : 0))
    let command = view.keyCommands?
      .first { $0.input == "a" && $0.modifierFlags == .control }
    #expect((command == nil) == unconsumed)
  }

  @Test(.enabled(if: hasMetal))
  func `unconsumed printable bindings preserve text input`() throws {
    let config = Configuration.parse("keybind = unconsumed:a=text:X")
    let session = TerminalSession(columns: 10, rows: 2)
    let view = try TerminalUIView(session: session, configuration: config)
    let writes = Mutex<[UInt8]>([])
    session.onWrite = { bytes in
      writes.withLock { $0.append(contentsOf: bytes) }
    }
    #expect(!view.keyDown(usage: 4, modifiers: [], base: "a", characters: "a"))
    view.insertText("a")
    _ = session.snapshot()
    #expect(writes.withLock { $0 } == Array("Xa".utf8))
  }

  @Test(.enabled(if: hasMetal))
  func `key window changes release keys and update terminal focus`() throws {
    let session = TerminalSession(columns: 10, rows: 2)
    let view = try TerminalUIView(session: session)
    let window = makeWindow()
    let controller = UIViewController()
    window.rootViewController = controller
    controller.view.addSubview(view)
    window.makeKeyAndVisible()
    let other = makeWindow()
    other.rootViewController = UIViewController()
    defer {
      window.isHidden = true;
      other.isHidden = true
    }
    #expect(view.becomeFirstResponder())
    session.feed(Array("\u{1B}[=10u\u{1B}[?1004h".utf8))
    let writes = Mutex<[[UInt8]]>([])
    session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
    view.heldKeys[4] = KeyEvent(.character("a"), action: .release)
    other.makeKeyAndVisible()
    #expect(!window.isKeyWindow && other.isKeyWindow)
    _ = session.snapshot()
    #expect(!view.renderer.options.isFocused)
    #expect(view.heldKeys.isEmpty)
    #expect(
      TestFixture(writes.withLock { $0 })
        == TestFixture([Array("\u{1B}[97;1:3u".utf8), Array("\u{1B}[O".utf8)])
    )
    writes.withLock { $0.removeAll() }
    window.makeKey()
    #expect(view.becomeFirstResponder())
    _ = session.snapshot()
    #expect(view.renderer.options.isFocused)
    #expect(
      TestFixture(writes.withLock { $0 })
        == TestFixture([Array("\u{1B}[I".utf8)])
    )
    writes.withLock { $0.removeAll() }
    NotificationCenter.default.post(
      name: UIWindow.didResignKeyNotification,
      object: other
    )
    _ = session.snapshot()
    #expect(view.renderer.options.isFocused)
    #expect(writes.withLock { $0.isEmpty })
    view.removeFromSuperview()
    _ = session.snapshot()
    writes.withLock { $0.removeAll() }
    other.makeKey()
    window.makeKey()
    _ = session.snapshot()
    #expect(!view.renderer.options.isFocused)
    #expect(writes.withLock { $0.isEmpty })
  }

  @Test(.enabled(if: hasMetal))
  func `raw text actions preserve every byte`() throws {
    let session = TerminalSession(columns: 10, rows: 2)
    let view = try TerminalUIView(session: session)
    let writes = Mutex<[UInt8]>([])
    session.onWrite = { bytes in
      writes.withLock { $0.append(contentsOf: bytes) }
    }
    session.feed(Array("\u{1B}[?2004h\u{1B}[=31u".utf8))
    view.perform(.textBytes([0, 0x80, 0xFF]))
    _ = session.snapshot()
    #expect(writes.withLock { $0 } == [0, 0x80, 0xFF])
  }

  @Test(
    .enabled(if: hasMetal),
    arguments: ["focus", "inactive", "background", "detach"]
  )
  func `lost focus releases keys and clears hardware input`(
    _ transition: String
  ) throws {
    let session = TerminalSession(columns: 10, rows: 2)
    let view = try TerminalUIView(session: session)
    let window = makeWindow()
    let controller = UIViewController()
    window.rootViewController = controller
    controller.view.addSubview(view)
    window.makeKeyAndVisible()
    #expect(view.becomeFirstResponder())
    defer { window.isHidden = true }
    _ = session.snapshot()
    let writes = Mutex<[[UInt8]]>([])
    session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
    session.feed(Array("\u{1B}[=10u\u{1B}[?1004h".utf8))
    view.heldKeys = [
      4: KeyEvent(.character("a"), modifiers: .shift, action: .release),
      82: KeyEvent(.up, action: .release),
    ]
    view.handledPresses = [4, 82]
    view.hardwareTextInput.begin(
      usage: 5,
      event: KeyEvent(.character("b"), text: "b")
    )
    let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
    }
    view.keyRepeat = timer
    func loseFocus() {
      switch transition {
      case "focus": #expect(view.resignFirstResponder())
      case "inactive": view.sceneWillDeactivate()
      case "background": view.sceneDidEnterBackground()
      default: view.removeFromSuperview()
      }
    }
    loseFocus()
    _ = session.snapshot()
    let sent = writes.withLock {
      $0.map { String(decoding: $0, as: UTF8.self) }
    }
    let releases = ["\u{1B}[97;2:3u", "\u{1B}[1;1:3A"]
    #expect(TestFixture(sent.last) == TestFixture("\u{1B}[O"))
    #expect(sent.dropLast().sorted() == releases.sorted())
    #expect(!view.renderer.options.isFocused)
    #expect(view.heldKeys.isEmpty)
    #expect(view.handledPresses.isEmpty)
    #expect(view.keyRepeat == nil)
    #expect(!timer.isValid)
    #expect(view.hardwareTextInput.commit("b", keyboardFlags: 10) == nil)
    writes.withLock { $0.removeAll() }
    if transition == "focus" {
      _ = view.resignFirstResponder()
    } else {
      loseFocus()
    }
    _ = session.snapshot()
    #expect(writes.withLock { $0.isEmpty })
  }

  @Test(.enabled(if: hasMetal))
  func `scene activation restores focus only for its responder`() throws {
    let session = TerminalSession(columns: 10, rows: 2)
    let view = try TerminalUIView(session: session)
    let window = makeWindow()
    let controller = UIViewController()
    window.rootViewController = controller
    controller.view.addSubview(view)
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    #expect(view.becomeFirstResponder())
    session.feed(Array("\u{1B}[?1004h".utf8))
    let writes = Mutex<[[UInt8]]>([])
    session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
    view.sceneWillDeactivate()
    view.sceneDidEnterBackground()
    view.sceneWillEnterForeground()
    #expect(!view.renderer.options.isFocused)
    view.sceneDidActivate()
    view.sceneDidActivate()
    #expect(view.renderer.options.isFocused)
    _ = session.snapshot()
    #expect(
      TestFixture(writes.withLock { $0 })
        == TestFixture([Array("\u{1B}[O".utf8), Array("\u{1B}[I".utf8)])
    )
    view.sceneWillDeactivate()
    #expect(view.resignFirstResponder())
    _ = session.snapshot()
    writes.withLock { $0.removeAll() }
    #expect(view.becomeFirstResponder())
    _ = session.snapshot()
    #expect(!view.renderer.options.isFocused)
    #expect(writes.withLock { $0.isEmpty })
    view.sceneDidActivate()
    _ = session.snapshot()
    #expect(
      TestFixture(writes.withLock { $0 })
        == TestFixture([Array("\u{1B}[I".utf8)])
    )
    #expect(view.resignFirstResponder())
    _ = session.snapshot()
    writes.withLock { $0.removeAll() }
    view.sceneDidActivate()
    _ = session.snapshot()
    #expect(!view.renderer.options.isFocused)
    #expect(writes.withLock { $0.isEmpty })
  }
}

#endif
