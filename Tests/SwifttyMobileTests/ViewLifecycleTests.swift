import TestSupport
#if canImport(UIKit)
    import Metal
    import SwifttyCore
    @testable import SwifttyMobile
    import Synchronization
    import Testing
    import UIKit

    @MainActor
    @Suite(.serialized) struct ViewLifecycleTests {
        nonisolated static let hasMetal = MTLCreateSystemDefaultDevice() != nil

        func makeWindow() -> UIWindow {
            let frame = CGRect(x: 0, y: 0, width: 320, height: 480)
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) {
                let window = UIWindow(windowScene: scene)
                window.frame = frame
                return window
            }
            return UIWindow(frame: frame)
        }

        @Test(.enabled(if: hasMetal), arguments: ["detach", "background", "release"], [false, true])
        func `accessory repeats stop when keyboard interaction ends`(_ transition: String, _ repeating: Bool) async throws {
            let view = try TerminalUIView(session: TerminalSession())
            let bar = view.accessoryBar
            let window = makeWindow()
            window.addSubview(view)
            window.addSubview(bar)
            defer { view.removeFromSuperview(); bar.removeFromSuperview() }
            func findButton(in parent: UIView) -> UIButton? {
                if let button = parent as? UIButton, button.accessibilityLabel == AccessoryKey.up.title {
                    return button
                }
                return parent.subviews.lazy.compactMap { findButton(in: $0) }.first
            }
            let button = try #require(findButton(in: bar))
            defer { _ = bar.perform(NSSelectorFromString("keyUp:"), with: button) }
            var keys: [AccessoryKey] = []
            bar.onKey = { keys.append($0) }
            _ = bar.perform(NSSelectorFromString("keyDown:"), with: button)
            #expect(keys == [.up])
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

        @Test(.enabled(if: hasMetal)) func `hardware key repeat stops after its view is released`() throws {
            weak var retainedView: TerminalUIView?
            var repeating: Timer?
            do {
                let view = try TerminalUIView(session: TerminalSession())
                retainedView = view
                try #require(view.keyDown(usage: 82, modifiers: [], base: "\u{F700}", characters: "\u{F700}"))
                let delay = try #require(view.keyRepeat)
                delay.fire() // Advance from the initial delay to the repeating timer.
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

        @Test(.enabled(if: hasMetal)) func `detached blinking text does not start a timer`() async throws {
            let session = TerminalSession(columns: 10, rows: 2)
            let view = try TerminalUIView(session: session)
            defer { view.stopBlinking() }
            session.feed(Array("\u{1B}[5mblink".utf8))
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: 320, height: 200, mipmapped: false,
            )
            descriptor.usage = [.renderTarget, .shaderRead]
            let texture = try #require(view.renderer.device.makeTexture(descriptor: descriptor))
            func renderBlinkingText() throws {
                let command = view.renderer.render(session.snapshot(), to: texture)
                command.waitUntilCompleted()
                try #require(command.status == .completed)
            }
            try renderBlinkingText()
            try #require(view.renderer.hasBlinkingText)
            #expect(view.window == nil)
            view.updateBlinkTimer()
            let deadline = ContinuousClock.now + .seconds(BlinkState.interval * 2 + 0.1)
            var stayedVisible = true
            while ContinuousClock.now < deadline {
                stayedVisible = stayedVisible && view.renderer.options.textBlinkVisible
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(stayedVisible)
        }

        @Test(.enabled(if: hasMetal), arguments: [false, true])
        func `hidden and detached views suspend animated shader frames`(_ animated: Bool) async throws {
            let view = try TerminalUIView(session: TerminalSession())
            if animated {
                try view.renderer.setPostProcessShader("""
                float4 postprocess(float2 position, texture2d<float> source, constant PostUniforms &u) {
                    return float4(sin(u.time), 0, 0, 1);
                }
                """)
            }
            let window = makeWindow()
            view.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
            let container = UIView(frame: view.frame)
            window.addSubview(container)
            container.addSubview(view)
            window.makeKeyAndVisible()
            defer { view.removeFromSuperview(); window.isHidden = true }
            view.sceneDidActivate()
            #expect(view.isPaused == !animated)
            #expect(!view.enableSetNeedsDisplay)

            container.isHidden = true
            try await Task.sleep(for: .milliseconds(50))
            #expect(view.isPaused && !view.enableSetNeedsDisplay)
            container.isHidden = false
            try await Task.sleep(for: .milliseconds(50))
            #expect(view.isPaused == !animated)

            for surface in [view, container, window] {
                surface.alpha = 0
                try await Task.sleep(for: .milliseconds(50))
                #expect(view.isPaused && !view.enableSetNeedsDisplay)
                surface.alpha = 0.25
                try await Task.sleep(for: .milliseconds(50))
                #expect(view.isPaused == !animated)
            }

            let wrapper = UIView(frame: container.frame)
            window.addSubview(wrapper)
            wrapper.addSubview(container)
            wrapper.isHidden = true
            try await Task.sleep(for: .milliseconds(50))
            #expect(view.isPaused && !view.enableSetNeedsDisplay)
            wrapper.isHidden = false
            try await Task.sleep(for: .milliseconds(50))
            #expect(view.isPaused == !animated)

            view.removeFromSuperview()
            #expect(view.isPaused && !view.enableSetNeedsDisplay)

            window.addSubview(view)
            view.sceneDidActivate()
            #expect(view.isPaused == !animated)
            view.sceneDidEnterBackground()
            #expect(view.isPaused && !view.enableSetNeedsDisplay)
            view.sceneWillEnterForeground()
            #expect(view.isPaused == !animated)
        }

        @Test(.enabled(if: hasMetal)) func `hover below a scrolled viewport does not target an invisible URL`() throws {
            let session = TerminalSession(columns: 24, rows: 2)
            let view = try TerminalUIView(session: session)
            session.feed(Array("row0\r\nrow1\r\nrow2\r\nrow3\r\nhttps://example.com".utf8))
            session.scrollViewport(by: 1)
            view.draw(in: view)
            let rect = view.geometry.rect(column: 1, row: 2)
            view.refreshHoveredLink(at: CGPoint(x: rect.midX, y: rect.midY))
            #expect(!view.overLink)
            #expect(view.renderer.options.underlinedSpan == nil)
        }

        @Test(.enabled(if: hasMetal)) func `taps below a scrolled viewport do not move an invisible prompt cursor`() throws {
            let session = TerminalSession(columns: 10, rows: 2)
            let view = try TerminalUIView(session: session)
            session.feed(Array("row0\r\nrow1\r\nrow2\r\nrow3\r\n\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}abc".utf8))
            session.scrollViewport(by: 1)
            view.draw(in: view)
            let writes = Mutex<[[UInt8]]>([])
            session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
            let rect = view.geometry.rect(column: 2, row: 2)
            let tap = ReviewTapGesture()
            tap.point = CGPoint(x: rect.midX, y: rect.midY)
            _ = view.perform(NSSelectorFromString("handleTap:"), with: tap)
            _ = session.snapshot()
            #expect(writes.withLock { $0.isEmpty })
        }

        @Test(.enabled(if: hasMetal), arguments: ["resize", "reset", "evict", "height"])
        func `selection drags reject an origin invalidated before the next frame`(_ change: String) throws {
            var configuration = SessionConfiguration()
            configuration.scrollbackLimitRows = 0
            let session = TerminalSession(columns: 10, rows: 2, configuration: configuration)
            let view = try TerminalUIView(session: session)
            session.feed(Array("abcd".utf8))
            let start = view.geometry.rect(column: 0, row: 0)
            view.beginSelection(at: CGPoint(x: start.midX, y: start.midY), unit: change == "height" ? .word : .cell, rectangle: false)
            if change == "resize" {
                session.resize(columns: 20, rows: 2)
            } else if change == "height" {
                session.resize(columns: 10, rows: 3)
            } else if change == "reset" {
                session.reset()
                session.feed(Array("wxyz".utf8))
            } else {
                session.feed(Array("\r\nrow1\r\nrow2\r\nrow3".utf8))
            }
            let end = view.geometry.rect(column: 2, row: 0)
            view.extendSelection(to: CGPoint(x: end.midX, y: end.midY), rectangle: false)
            #expect(session.withState { $0.selectionText } == (change == "height" ? "abcd" : nil))
            #expect(view.selectionOrigin == nil)
            #expect(view.hasSelection == (change == "height"))
        }

        @Test(.enabled(if: hasMetal), arguments: ["unchanged", "append", "evict", "reset", "resize", "alternate"])
        func `command output menu actions revalidate their captured command`(_ change: String) throws {
            var configuration = SessionConfiguration()
            configuration.scrollbackLimitRows = 0
            let session = TerminalSession(columns: 10, rows: 3, configuration: configuration)
            let view = try TerminalUIView(session: session)
            let prompt = "\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}cmd\r\n\u{1B}]133;C\u{7}"
            session.feed(Array((prompt + "out1").utf8))
            let rect = view.geometry.rect(column: 0, row: 1)
            let config = UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: rect.midX, y: rect.midY))
            let menu = try #require(view.editMenuInteraction(view.editMenu, menuFor: config, suggestedActions: []))
            let action = try #require(menu.children.compactMap { $0 as? UIAction }.first { $0.title == "Select Command Output" })
            if change == "append" {
                session.feed(Array("\r\nout2".utf8))
            } else if change == "evict" {
                session.feed(Array(("\r\n\u{1B}]133;D;0\u{7}" + prompt + "new\r\n\u{1B}]133;D;0\u{7}\u{1B}]133;A\u{7}$ ").utf8))
            } else if change == "reset" {
                session.reset()
                session.feed(Array((prompt + "other").utf8))
            } else if change == "resize" {
                session.resize(columns: 20, rows: 3)
            } else if change == "alternate" {
                session.feed(Array(("\u{1B}[?1049h" + prompt + "other").utf8))
            }
            UIControl().sendAction(action)
            let selected = session.withState { $0.selectionText }
            if change != "unchanged", change != "append" {
                #expect(selected == nil && !view.hasSelection)
            } else {
                #expect(TestFixture(selected) == TestFixture(change == "append" ? "out1\nout2" : "out1"))
                #expect(view.hasSelection)
            }
        }

        @Test(.enabled(if: hasMetal)) func `command output menus below a scrolled grid use its visible boundary`() throws {
            let session = TerminalSession(columns: 10, rows: 2)
            let view = try TerminalUIView(session: session)
            let prompt = "\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}cmd\r\n\u{1B}]133;C\u{7}"
            session.feed(Array((prompt + "out1\r\n\u{1B}]133;D;0\u{7}" + prompt + "out2\r\n\u{1B}]133;D;0\u{7}\u{1B}]133;A\u{7}$ ").utf8))
            session.scrollViewport(by: 1)
            view.draw(in: view)
            let rect = view.geometry.rect(column: 0, row: 2)
            let config = UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: rect.midX, y: rect.midY))
            let menu = view.editMenuInteraction(view.editMenu, menuFor: config, suggestedActions: [])
            #expect(menu?.children.contains { ($0 as? UIAction)?.title == "Select Command Output" } == true)
        }

        @Test(.enabled(if: hasMetal)) func `configured background opacity applies once to terminal cells and padding`() throws {
            let session = TerminalSession(columns: 2, rows: 1)
            let view = try TerminalUIView(session: session, configuration: Configuration.parse("background-opacity=0.5"))
            session.feed(Array("\u{1B}[?25l ".utf8))
            let cw = Int(view.renderer.cellSize.width), ch = Int(view.renderer.cellSize.height)
            let width = cw * 2 + 16, height = ch + 16
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false,
            )
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            let texture = try #require(view.renderer.device.makeTexture(descriptor: descriptor))
            let command = view.renderer.render(session.snapshot(), to: texture)
            command.waitUntilCompleted()
            try #require(command.status == .completed, Comment(rawValue: escapedTestText("\(String(describing: command.error))")))
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            texture.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            let x = Int(view.renderer.options.paddingX) + cw / 2
            let y = Int(view.renderer.options.paddingY) + ch / 2
            let cell = (y * width + x) * 4
            #expect(Array(pixels[cell ..< cell + 4]) == Array(pixels[0 ..< 4]))
            #expect(pixels[cell + 3] == 127)
        }

        @Test(.enabled(if: hasMetal)) func `retaining an accessibility element does not retain its terminal`() throws {
            weak var retainedView: TerminalUIView?
            let element = try autoreleasepool {
                let view = try TerminalUIView(session: TerminalSession(columns: 20, rows: 3))
                retainedView = view
                return view.accessibilityTerminal
            }
            #expect(retainedView == nil)
            #expect(element.accessibilityContainer == nil)
            #expect(element.accessibilityFrame == .zero)
            #expect(element.accessibilityPageContent() == nil)
            #expect(!element.accessibilityActivate())
            #expect(!element.accessibilityScroll(.previous))
        }

        @Test(.enabled(if: hasMetal)) func `activating the terminal accessibility element focuses keyboard input`() throws {
            let session = TerminalSession(columns: 20, rows: 3)
            let view = try TerminalUIView(session: session)
            let window = makeWindow()
            let controller = UIViewController()
            window.rootViewController = controller
            controller.view.addSubview(view)
            let field = UITextField(frame: CGRect(x: 0, y: 0, width: 200, height: 44))
            controller.view.addSubview(field)
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            #expect(field.becomeFirstResponder())
            #expect(!view.isFirstResponder)
            #expect(view.accessibilityTerminal.accessibilityActivate())
            #expect(view.isFirstResponder && !field.isFirstResponder)
        }

        @Test(.enabled(if: hasMetal)) func `accessibility reading page commands navigate scrollback and stop at its bounds`() throws {
            let session = TerminalSession(columns: 20, rows: 3)
            session.feed(Array("0\r\n1\r\n2\r\n3\r\n4\r\n5\r\n6".utf8))
            let view = try TerminalUIView(session: session)
            view.accessibilityScreen = AccessibilityText(session.snapshot())
            let terminal = view.accessibilityTerminal
            #expect(!terminal.accessibilityScroll(.next))
            #expect(terminal.accessibilityScroll(.previous))
            #expect(TestFixture(terminal.accessibilityPageContent()) == TestFixture("2\n3\n4"))
            #expect(terminal.accessibilityScroll(.previous))
            #expect(TestFixture(terminal.accessibilityPageContent()) == TestFixture("0\n1\n2"))
            #expect(!terminal.accessibilityScroll(.previous))
            #expect(terminal.accessibilityScroll(.next))
            #expect(TestFixture(terminal.accessibilityPageContent()) == TestFixture("2\n3\n4"))
            #expect(terminal.accessibilityScroll(.next))
            #expect(TestFixture(terminal.accessibilityPageContent()) == TestFixture("4\n5\n6"))
            #expect(!terminal.accessibilityScroll(.next))
        }

        @Test(.enabled(if: hasMetal)) func `accessibility exposes search controls alongside terminal reading content`() throws {
            let session = TerminalSession(columns: 20, rows: 3)
            session.feed(Array("one\r\ntwo\r\nthree\r\nfour".utf8))
            let view = try TerminalUIView(session: session)
            view.accessibilityScreen = AccessibilityText(session.snapshot())
            view.bounds = CGRect(x: 0, y: 0, width: 320, height: 240)
            #expect(!view.isAccessibilityElement)
            let elements = try #require(view.accessibilityElements)
            #expect(elements.count == 1)
            let terminal = try #require(elements.first as? UIAccessibilityElement)
            let reading = try #require(terminal as? UIAccessibilityReadingContent)
            #expect(terminal.isAccessibilityElement && terminal.accessibilityLabel == "Terminal")
            #expect(terminal.accessibilityValue == "four")
            #expect(terminal.accessibilityFrame == UIAccessibility.convertToScreenCoordinates(view.bounds, in: view))
            #expect(terminal.accessibilityTraits == view.accessibilityTraits)
            #expect(reading.accessibilityPageContent() == view.accessibilityPageContent())
            #expect(reading.accessibilityContent(forLineNumber: 1) == "three")
            #expect(reading.accessibilityFrame(forLineNumber: 1) == view.accessibilityFrame(forLineNumber: 1))
            view.showSearch(text: "three")
            let searching = try #require(view.accessibilityElements)
            #expect(searching.count == 2)
            #expect(searching.first as? UIView === view.searchBar)
            #expect(searching.last as? UIAccessibilityElement === terminal)
            #expect(view.searchBar.field.accessibilityLabel == "Find")
            #expect(reading.accessibilityPageContent() != nil)
            view.hideSearch()
            #expect(view.accessibilityElements?.count == 1)
            #expect(view.accessibilityElements?.first as? UIAccessibilityElement === terminal)
            #expect(terminal.accessibilityScroll(.down))
            #expect(TestFixture(reading.accessibilityPageContent()) == TestFixture("one\ntwo\nthree"))
            #expect(terminal.accessibilityValue == "three")
        }

        @Test(.enabled(if: hasMetal), arguments: [false, true])
        func `configuration reload invalidates previously issued key commands`(_ rebuild: Bool) throws {
            let session = TerminalSession(columns: 10, rows: 2)
            let view = try TerminalUIView(session: session, configuration: Configuration.parse("keybind=ctrl+a=text:X"))
            let stale = try #require(view.keyCommands?.first { $0.input == "a" && $0.modifierFlags == .control })
            view.apply(Configuration.parse("keybind=ctrl+a=text:Y"))
            if rebuild {
                _ = view.keyCommands
            }
            let writes = Mutex<[UInt8]>([])
            session.onWrite = { bytes in writes.withLock { $0.append(contentsOf: bytes) } }
            view.performKeyCommand(stale)
            _ = session.snapshot()
            #expect(writes.withLock { $0.isEmpty })
            let current = try #require(view.keyCommands?.first { $0.input == "a" && $0.modifierFlags == .control })
            let copied = try #require(current.copy() as? UIKeyCommand)
            view.performKeyCommand(copied)
            _ = session.snapshot()
            #expect(writes.withLock { $0 } == Array("Y".utf8))
        }

        @Test(.enabled(if: hasMetal), arguments: [0, 1, 2, 3, 4, 5])
        func `new text bindings and composition stop an older key repeat`(_ transition: Int) throws {
            let session = TerminalSession(columns: 10, rows: 2)
            let view = try TerminalUIView(session: session, configuration: Configuration.parse("keybind=b=ignore\nkeybind=ctrl+b=ignore"))
            defer { view.releaseHardwareKeys() }
            session.feed(Array("\u{1B}[=10u".utf8))
            let writes = Mutex<[[UInt8]]>([])
            session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
            #expect(view.keyDown(usage: KeyTranslator.Usage.left, modifiers: [], base: "", characters: ""))
            let timer = try #require(view.keyRepeat)
            _ = session.snapshot()
            switch transition {
            case 0: #expect(!view.keyDown(usage: 4, modifiers: [], base: "a", characters: "a"))
            case 1: #expect(view.keyDown(usage: 5, modifiers: [], base: "b", characters: "b"))
            case 2: view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0))
            case 3: view.insertText("x")
            case 4: view.accessoryKey(.tab)
            default:
                let command = try #require(view.keyCommands?.first { $0.input == "b" && $0.modifierFlags == .control })
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
            #expect(TestFixture(writes.withLock { $0.last }) == TestFixture(Array("\u{1B}[1;1:3D".utf8)))
        }

        @Test(.enabled(if: hasMetal)) func `activating kitty reporting during a held text key reports a repeat and release`() throws {
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
            #expect(TestFixture(writes.withLock { $0 }) == TestFixture([Array("a".utf8), Array("\u{1B}[97;1:2u".utf8)]))
            view.releaseHardwareKeys()
            _ = session.snapshot()
            #expect(TestFixture(writes.withLock { $0.last }) == TestFixture(Array("\u{1B}[97;1:3u".utf8)))
        }

        @Test(.enabled(if: hasMetal)) func `key commands abandon pending hardware text and consume latched modifiers`() throws {
            let session = TerminalSession(columns: 10, rows: 2)
            let view = try TerminalUIView(session: session, configuration: Configuration.parse("keybind=ctrl+b=ignore"))
            defer { view.releaseHardwareKeys() }
            session.feed(Array("\u{1B}[=10u".utf8))
            view.sticky.tap(.alt)
            #expect(!view.keyDown(usage: 4, modifiers: [], base: "a", characters: "a"))
            let command = try #require(view.keyCommands?.first { $0.input == "b" && $0.modifierFlags == .control })
            view.performKeyCommand(command)
            #expect(view.sticky.active.isEmpty)
            let writes = Mutex<[UInt8]>([])
            session.onWrite = { bytes in writes.withLock { $0.append(contentsOf: bytes) } }
            view.insertText("a")
            _ = session.snapshot()
            #expect(view.heldKeys[4] == nil)
            #expect(writes.withLock { $0 } == Array("a".utf8))
        }

        @Test(.enabled(if: hasMetal), arguments: [false, true])
        func `a second shift key preserves a held text keys repeat report`(_ releaseModifier: Bool) throws {
            let session = TerminalSession(columns: 10, rows: 2)
            let view = try TerminalUIView(session: session)
            defer { view.releaseHardwareKeys() }
            session.feed(Array("\u{1B}[=10u".utf8))
            let writes = Mutex<[[UInt8]]>([])
            session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
            #expect(!view.keyDown(usage: 4, modifiers: .shift, base: "a", characters: "A"))
            view.insertText("A")
            let rightShift = KeyTranslator.Usage.leftControl + 5
            #expect(!view.keyDown(usage: rightShift, modifiers: .shift, base: "", characters: ""))
            if releaseModifier {
                view.pressesEnded([ReviewKeyPress(rightShift)], with: nil)
            }
            view.insertText("A")
            _ = session.snapshot()
            #expect(TestFixture(writes.withLock { $0 }) == TestFixture([Array("\u{1B}[97;2u".utf8), Array("\u{1B}[97;2:2u".utf8)]))
            view.releaseHardwareKeys()
            _ = session.snapshot()
            #expect(TestFixture(writes.withLock { $0.last }) == TestFixture(Array("\u{1B}[97;2:3u".utf8)))
        }

        @Test(.enabled(if: hasMetal)) func `modifier presses preserve hardware repeat`() throws {
            let view = try TerminalUIView(session: TerminalSession(columns: 10, rows: 2))
            defer { view.releaseHardwareKeys() }
            #expect(view.keyDown(usage: KeyTranslator.Usage.left, modifiers: [], base: "", characters: ""))
            let timer = try #require(view.keyRepeat)
            #expect(!view.keyDown(usage: KeyTranslator.Usage.leftControl + 1, modifiers: .shift, base: "", characters: ""))
            #expect(view.keyRepeat === timer && timer.isValid)
        }

        @Test(.enabled(if: hasMetal), arguments: [false, true])
        func `releasing an older hardware key preserves the current repeat`(_ cancelled: Bool) throws {
            let session = TerminalSession(columns: 10, rows: 2)
            let view = try TerminalUIView(session: session)
            defer { view.releaseHardwareKeys() }
            session.feed(Array("\u{1B}[=10u".utf8))
            let writes = Mutex<[[UInt8]]>([])
            session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
            #expect(view.keyDown(usage: KeyTranslator.Usage.left, modifiers: [], base: "", characters: ""))
            #expect(view.keyDown(usage: KeyTranslator.Usage.right, modifiers: [], base: "", characters: ""))
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
            #expect(TestFixture(writes.withLock { $0 }) == TestFixture([Array("\u{1B}[1;1:3D".utf8)]))
            writes.withLock { $0.removeAll() }
            view.keyRepeat?.fire() // Finish the initial delay.
            timer.invalidate()
            view.keyRepeat?.fire() // Repeat the key that is still down.
            _ = session.snapshot()
            #expect(TestFixture(writes.withLock { $0 }) == TestFixture([Array("\u{1B}[1;1:2C".utf8)]))
            release(KeyTranslator.Usage.right)
            #expect(view.keyRepeat == nil && view.heldKeys.isEmpty)
        }

        @Test(.enabled(if: hasMetal), arguments: [
            (CGFloat(-20), CGFloat(1)), (0, 1), (0.5, 1), (201, 200), (1000, 200),
            (.greatestFiniteMagnitude, 200), (.infinity, 200), (-.infinity, 1), (.nan, 13),
        ])
        func `initial font overrides use the same bounds as zoom`(_ input: CGFloat, _ expected: CGFloat) throws {
            let view = try TerminalUIView(session: TerminalSession(columns: 10, rows: 2), fontSize: input)
            #expect(view.fontSize == expected)
            #expect(view.renderer.font.descriptor.size == expected)
            view.apply(Configuration.parse("font-size=20"))
            #expect(view.fontSize == expected && view.renderer.font.descriptor.size == expected)
            view.setFontSize(input)
            #expect(view.fontSize == expected && view.renderer.font.descriptor.size == expected)
            #expect(view.renderer.cellSize.width.isFinite && view.renderer.cellSize.width > 0)
            #expect(view.renderer.cellSize.height.isFinite && view.renderer.cellSize.height > 0)
            view.setFontSize(nil)
            #expect(view.fontSize == 20 && view.renderer.font.descriptor.size == 20)
        }

        @Test(.enabled(if: hasMetal), arguments: [
            (Double(-20), Double(1)), (0, 1), (0.5, 1), (201, 200),
            (.greatestFiniteMagnitude, 200), (.infinity, 200), (-.infinity, 1), (.nan, 13),
        ])
        func `programmatic configuration sizes remain bounded`(_ input: Double, _ expected: Double) throws {
            var configuration = Configuration()
            configuration.fontSize = input
            let view = try TerminalUIView(session: TerminalSession(columns: 10, rows: 2), configuration: configuration)
            #expect(view.fontSize == CGFloat(expected) && view.renderer.font.descriptor.size == CGFloat(expected))
            view.setFontSize(40)
            #expect(view.fontSize == 40)
            view.setFontSize(nil)
            #expect(view.fontSize == CGFloat(expected) && view.renderer.font.descriptor.size == CGFloat(expected))
            view.apply(Configuration.parse("font-size=20"))
            #expect(view.fontSize == 20 && view.renderer.font.descriptor.size == 20)
            view.apply(configuration)
            #expect(view.fontSize == CGFloat(expected) && view.renderer.font.descriptor.size == CGFloat(expected))
        }

        @Test(.enabled(if: hasMetal), arguments: [-1, 2])
        func `selection begins on the nearest visible row outside a scrolled grid`(_ row: Int) throws {
            let session = TerminalSession(columns: 4, rows: 2)
            let view = try TerminalUIView(session: session)
            session.feed(Array("row0\r\nrow1\r\nrow2\r\nrow3\r\nrow4".utf8))
            session.scrollViewport(by: 1)
            view.draw(in: view)
            let expectedRow = session.withState { $0.absoluteRow(viewportRow: row < 0 ? 0 : 1) }
            let rect = view.geometry.rect(column: 0, row: row)
            view.beginSelection(at: CGPoint(x: rect.midX, y: rect.midY), unit: .word, rectangle: false)
            #expect(session.withState { $0.selection?.start.row } == expectedRow)
            #expect(session.withState { $0.selectionText } == "row\(expectedRow)")
            view.endSelection()
        }

        @Test(.enabled(if: hasMetal), arguments: [false, true])
        func `selection release outside the view does not add an automatic scroll step`(_ longPress: Bool) throws {
            let session = TerminalSession(columns: 20, rows: 2)
            let view = try TerminalUIView(session: session)
            defer { view.editMenu.dismissMenu() }
            session.feed(Array("row0\r\nrow1\r\nrow2\r\nrow3\r\nrow4".utf8))
            view.draw(in: view)
            let pan = ReviewScrollGesture()
            let press = ReviewLongPressGesture()
            func select(_ state: UIGestureRecognizer.State, at point: CGPoint) {
                if longPress {
                    press.point = point
                    press.state = state
                    _ = view.perform(NSSelectorFromString("handleLongPress:"), with: press)
                } else {
                    pan.point = point
                    pan.state = state
                    _ = view.perform(NSSelectorFromString("handlePointerDrag:"), with: pan)
                }
            }
            let rect = view.geometry.rect(column: 0, row: 0)
            select(.began, at: CGPoint(x: rect.midX, y: rect.midY))
            let outside = CGPoint(x: rect.midX, y: -view.geometry.lineHeight)
            select(.changed, at: outside)
            let offset = session.snapshot().viewportOffset
            try #require(offset > 0)
            select(.ended, at: outside)
            #expect(session.snapshot().viewportOffset == offset)
        }

        @Test(.enabled(if: hasMetal)) func `stationary hover follows scrollback and link detection settings`() throws {
            let session = TerminalSession(columns: 20, rows: 2)
            let view = try TerminalUIView(session: session)
            session.feed(Array("https://a.test\r\nplain1\r\nplain2\r\nplain3".utf8))
            view.draw(in: view)
            let hover = ReviewHoverGesture()
            let rect = view.geometry.rect(column: 0, row: 0)
            hover.point = CGPoint(x: rect.midX, y: rect.midY)
            hover.state = .began
            _ = view.perform(NSSelectorFromString("handleHover:"), with: hover)
            #expect(!view.overLink)
            session.scrollViewport(by: 2)
            view.draw(in: view)
            #expect(view.overLink && view.renderer.options.underlinedSpan != nil)
            view.apply(Configuration.parse("link-url=false"))
            #expect(!view.overLink && view.renderer.options.underlinedSpan == nil)
            view.apply(Configuration.parse("link-url=true"))
            #expect(view.overLink && view.renderer.options.underlinedSpan != nil)
            session.scrollViewport(by: -2)
            view.draw(in: view)
            #expect(!view.overLink && view.renderer.options.underlinedSpan == nil)
        }

        @Test(.enabled(if: hasMetal)) func `hover follows content tracking modes and modifier changes`() throws {
            let session = TerminalSession(columns: 20, rows: 3)
            let view = try TerminalUIView(session: session)
            session.feed(Array("\u{1B}]8;;https://example.com\u{1B}\\link\u{1B}]8;;\u{1B}\\".utf8))
            view.draw(in: view)
            let hover = ReviewHoverGesture()
            let rect = view.geometry.rect(column: 0, row: 0)
            hover.point = CGPoint(x: rect.midX, y: rect.midY)
            hover.state = .began
            _ = view.perform(NSSelectorFromString("handleHover:"), with: hover)
            #expect(view.overLink && view.renderer.options.hoveredLink != 0)
            session.feed(Array("\u{1B}[?1000h".utf8))
            view.draw(in: view)
            #expect(!view.overLink && view.renderer.options.hoveredLink == 0)
            session.feed(Array("\u{1B}[?1000l".utf8))
            view.draw(in: view)
            #expect(view.overLink && view.renderer.options.hoveredLink != 0)
            session.feed(Array("\r\u{1B}[2Kplain".utf8))
            view.draw(in: view)
            #expect(!view.overLink && view.renderer.options.hoveredLink == 0)

            session.feed(Array("\u{1B}[?1003h\u{1B}[?1006h".utf8))
            view.draw(in: view)
            let writes = Mutex<[[UInt8]]>([])
            session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
            hover.state = .changed
            _ = view.perform(NSSelectorFromString("handleHover:"), with: hover)
            hover.flags = .control
            _ = view.perform(NSSelectorFromString("handleHover:"), with: hover)
            _ = session.snapshot()
            #expect(TestFixture(writes.withLock { $0.map { String(decoding: $0, as: UTF8.self) } }) == TestFixture([
                "\u{1B}[<35;1;1M",
                "\u{1B}[<51;1;1M",
            ]))
            hover.state = .ended
            _ = view.perform(NSSelectorFromString("handleHover:"), with: hover)
            #expect(view.hoverCell == nil && !view.overLink)
        }

        @Test(.enabled(if: hasMetal), arguments: [4, 8, 16, 20])
        func `scroll gestures and momentum preserve keyboard modifiers`(_ bits: Int) throws {
            let flags: UIKeyModifierFlags = switch bits {
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
            defer { view.stopMomentum(); view.removeFromSuperview(); window.isHidden = true }
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
            #expect(TestFixture(writes.withLock { $0.map { String(decoding: $0, as: UTF8.self) } }) == TestFixture(expected))
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
            let sent = writes.withLock { $0.map { String(decoding: $0, as: UTF8.self) } }
            #expect(!sent.isEmpty)
            #expect(sent.allSatisfy { expected.contains($0) })
        }

        @Test(.enabled(if: hasMetal)) func `pinch zoom applies the first and final scale`() throws {
            let view = try TerminalUIView(
                session: TerminalSession(columns: 10, rows: 3), configuration: Configuration.parse("font-size=20"),
            )
            let pinch = ReviewPinchGesture()
            pinch.state = .began
            pinch.scale = 1.2
            _ = view.perform(NSSelectorFromString("handlePinch:"), with: pinch)
            #expect(view.fontSize == 24)
            pinch.state = .changed
            pinch.scale = 1.3
            _ = view.perform(NSSelectorFromString("handlePinch:"), with: pinch)
            #expect(view.fontSize == 26)
            pinch.state = .ended
            pinch.scale = 1.5
            _ = view.perform(NSSelectorFromString("handlePinch:"), with: pinch)
            #expect(view.fontSize == 30)
        }

        @Test(.enabled(if: hasMetal)) func `long press selection includes the release location`() throws {
            let session = TerminalSession(columns: 20, rows: 3)
            let view = try TerminalUIView(session: session)
            session.feed(Array("one two three".utf8))
            view.draw(in: view)
            let press = ReviewLongPressGesture()
            func select(_ state: UIGestureRecognizer.State, at column: Int) {
                let rect = view.geometry.rect(column: column, row: 0)
                press.point = CGPoint(x: rect.midX, y: rect.midY)
                press.state = state
                _ = view.perform(NSSelectorFromString("handleLongPress:"), with: press)
            }
            select(.began, at: 1)
            #expect(session.withState { $0.selectionText } == "one")
            select(.changed, at: 5)
            #expect(session.withState { $0.selectionText } == "one two")
            select(.ended, at: 9)
            #expect(session.withState { $0.selectionText } == "one two three")
            #expect(view.selectionOrigin == nil)
            view.editMenu.dismissMenu()
        }

        @Test(.enabled(if: hasMetal), arguments: [false, true])
        func `pointer selection retains its local gesture after Shift is released or output clears it`(_ clear: Bool) throws {
            let session = TerminalSession(columns: 10, rows: 3)
            let view = try TerminalUIView(session: session)
            session.feed(Array("abcd\u{1B}[?1003h\u{1B}[?1006h".utf8))
            view.draw(in: view)
            let writes = Mutex<[[UInt8]]>([])
            session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
            let pan = ReviewScrollGesture()
            func drag(_ state: UIGestureRecognizer.State, to column: Int) {
                let rect = view.geometry.rect(column: column, row: 0)
                pan.point = CGPoint(x: rect.midX, y: rect.midY)
                pan.state = state
                _ = view.perform(NSSelectorFromString("handlePointerDrag:"), with: pan)
            }
            pan.flags = .shift
            drag(.began, to: 0)
            drag(.changed, to: 1)
            #expect(session.withState { $0.selectionText } == "ab")
            if clear {
                session.feed(Array("\u{1B}[H\u{1B}[2J".utf8))
                view.draw(in: view)
            }
            pan.flags = []
            drag(.changed, to: 2)
            drag(.ended, to: 3)
            _ = session.snapshot()
            #expect(writes.withLock { $0.isEmpty })
            #expect(session.withState { $0.selectionText } == (clear ? nil : "abcd"))
            drag(.began, to: 0)
            drag(.ended, to: 0)
            _ = session.snapshot()
            #expect(TestFixture(writes.withLock { $0.map { String(decoding: $0, as: UTF8.self) } }) == TestFixture([
                "\u{1B}[<0;1;1M",
                "\u{1B}[<0;1;1m",
            ]))
        }

        @Test(
            .enabled(if: hasMetal), arguments: [9, 1000, 1002, 1003],
            [
                (0, 0, UIGestureRecognizer.State.ended),
                (2, 1, .ended),
                (-2, -1, .ended),
                (0, 0, .cancelled),
                (2, 1, .cancelled),
                (-2, -1, .cancelled),
            ],
        )
        func `reported pointer drags include their start and initial motion`(
            _ mode: Int,
            _ fixture: (Int, Int, UIGestureRecognizer.State),
        ) throws {
            let session = TerminalSession(columns: 10, rows: 5)
            let view = try TerminalUIView(session: session)
            session.feed(Array("\u{1B}[?\(mode)h\u{1B}[?1006h".utf8))
            view.draw(in: view)
            let writes = Mutex<[[UInt8]]>([])
            session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
            let pan = ReviewScrollGesture()
            let (dx, dy, ending) = fixture
            let origin = view.geometry.rect(column: 4, row: 2)
            let current = view.geometry.rect(column: 4 + dx, row: 2 + dy)
            pan.point = CGPoint(x: current.midX, y: current.midY)
            pan.distance = CGPoint(x: current.midX - origin.midX, y: current.midY - origin.midY)
            pan.state = .began
            _ = view.perform(NSSelectorFromString("handlePointerDrag:"), with: pan)
            pan.state = ending
            _ = view.perform(NSSelectorFromString("handlePointerDrag:"), with: pan)
            _ = session.snapshot()
            var expected = ["\u{1B}[<0;5;3M"]
            if mode >= 1002, dx != 0 || dy != 0 {
                expected.append("\u{1B}[<32;\(5 + dx);\(3 + dy)M")
            }
            if mode != 9 {
                expected.append("\u{1B}[<0;\(5 + dx);\(3 + dy)m")
            }
            #expect(TestFixture(writes.withLock { $0.map { String(decoding: $0, as: UTF8.self) } }) == TestFixture(expected))
            #expect(!view.reportsPointerMouseGesture && view.selectionOrigin == nil)
        }

        @Test(.enabled(if: hasMetal)) func `pointer selection includes the release location`() throws {
            let session = TerminalSession(columns: 10, rows: 3)
            let view = try TerminalUIView(session: session)
            session.feed(Array("abcdef".utf8))
            view.draw(in: view)
            let pan = ReviewScrollGesture()
            func drag(_ state: UIGestureRecognizer.State, to column: Int) {
                let rect = view.geometry.rect(column: column, row: 0)
                pan.point = CGPoint(x: rect.midX, y: rect.midY)
                pan.state = state
                _ = view.perform(NSSelectorFromString("handlePointerDrag:"), with: pan)
            }
            drag(.began, to: 0)
            drag(.changed, to: 1)
            #expect(session.withState { $0.selectionText } == "ab")
            drag(.ended, to: 4)
            #expect(session.withState { $0.selectionText } == "abcde")
            #expect(view.selectionOrigin == nil)
        }

        @Test(.enabled(if: hasMetal), arguments: [UIGestureRecognizer.State.began, .ended])
        func `scroll gesture boundary events consume their remaining movement`(_ state: UIGestureRecognizer.State) throws {
            let session = TerminalSession(columns: 10, rows: 3)
            let view = try TerminalUIView(session: session)
            session.feed(Array("\u{1B}[?1000h\u{1B}[?1006h".utf8))
            view.draw(in: view)
            let writes = Mutex<[[UInt8]]>([])
            session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
            let pan = ReviewScrollGesture()
            pan.point = view.geometry.rect(column: 0, row: 0).origin
            pan.state = state
            pan.distance = CGPoint(
                x: -2 * view.geometry.cellSize.width / view.geometry.scale,
                y: 2 * view.geometry.lineHeight,
            )
            _ = view.perform(NSSelectorFromString("handleScroll:"), with: pan)
            _ = session.snapshot()
            #expect(TestFixture(writes.withLock { $0.map { String(decoding: $0, as: UTF8.self) } }) == TestFixture([
                "\u{1B}[<64;1;1M",
                "\u{1B}[<64;1;1M",
                "\u{1B}[<67;1;1M",
                "\u{1B}[<67;1;1M",
            ]))
            #expect(pan.distance == .zero)
            #expect(!view.momentum.isActive)
            #expect(!view.horizontalMomentum.isActive)
        }

        @Test(.enabled(if: hasMetal), arguments: [UIGestureRecognizer.State.cancelled, .failed])
        func `cancelled scrolling discards fractional movement without starting momentum`(_ state: UIGestureRecognizer.State) throws {
            let session = TerminalSession(columns: 10, rows: 3)
            let view = try TerminalUIView(session: session)
            session.feed(Array("\u{1B}[?1000h\u{1B}[?1006h".utf8))
            view.draw(in: view)
            let writes = Mutex<[[UInt8]]>([])
            session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
            view.scroll(lines: 0.5, columns: 0.5, at: .zero)
            let pan = ReviewScrollGesture()
            pan.state = state
            pan.distance = CGPoint(x: 100, y: 100)
            pan.speed = CGPoint(x: 100, y: 100)
            _ = view.perform(NSSelectorFromString("handleScroll:"), with: pan)
            #expect(view.scrollAccumulator.remainder == 0)
            #expect(view.horizontalScrollAccumulator.remainder == 0)
            #expect(!view.momentum.isActive)
            #expect(!view.horizontalMomentum.isActive)
            view.scroll(lines: 0.75, columns: 0.75, at: .zero)
            _ = session.snapshot()
            #expect(writes.withLock { $0.isEmpty })
        }

        @Test(.enabled(if: hasMetal), arguments: [-1, 1])
        func `horizontal scroll gestures report both axes and retain fractional movement`(_ direction: Int) throws {
            let session = TerminalSession(columns: 10, rows: 3)
            let view = try TerminalUIView(session: session)
            session.feed(Array("\u{1B}[?1000h\u{1B}[?1006h".utf8))
            view.draw(in: view)
            let writes = Mutex<[[UInt8]]>([])
            session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
            let pan = ReviewScrollGesture()
            let width = view.geometry.cellSize.width / view.geometry.scale
            let point = view.geometry.rect(column: 0, row: 0).origin
            pan.point = point
            pan.state = .began
            _ = view.perform(NSSelectorFromString("handleScroll:"), with: pan)
            pan.state = .changed
            pan.distance = CGPoint(x: CGFloat(direction) * width * 0.75, y: view.geometry.lineHeight * 2)
            _ = view.perform(NSSelectorFromString("handleScroll:"), with: pan)
            _ = session.snapshot()
            #expect(TestFixture(writes.withLock { $0.map { String(decoding: $0, as: UTF8.self) } }) == TestFixture(Array(
                repeating: "\u{1B}[<64;1;1M",
                count: 2,
            )))
            pan.distance = CGPoint(x: CGFloat(direction) * width * 0.75, y: 0)
            _ = view.perform(NSSelectorFromString("handleScroll:"), with: pan)
            _ = session.snapshot()
            #expect(TestFixture(writes.withLock { $0.map { String(decoding: $0, as: UTF8.self) } }) == TestFixture([
                "\u{1B}[<64;1;1M",
                "\u{1B}[<64;1;1M",
                "\u{1B}[<\(direction > 0 ? 66 : 67);1;1M",
            ]))
            #expect(pan.distance == .zero)
            pan.speed = CGPoint(x: CGFloat(direction) * width * 10, y: 0)
            pan.state = .ended
            _ = view.perform(NSSelectorFromString("handleScroll:"), with: pan)
            #expect(!view.momentum.isActive)
            #expect(view.horizontalMomentum.isActive)
            view.stopMomentum()
            #expect(!view.horizontalMomentum.isActive)

            writes.withLock { $0.removeAll() }
            session.feed(Array("\u{1B}[?1000l".utf8))
            view.draw(in: view)
            pan.state = .changed
            pan.distance = CGPoint(x: CGFloat(direction) * width, y: 0)
            _ = view.perform(NSSelectorFromString("handleScroll:"), with: pan)
            #expect(view.horizontalScrollAccumulator.remainder == 0)
            session.feed(Array("\u{1B}[?1000h".utf8))
            view.draw(in: view)
            pan.distance = CGPoint(x: CGFloat(direction) * width * 0.75, y: 0)
            _ = view.perform(NSSelectorFromString("handleScroll:"), with: pan)
            _ = session.snapshot()
            #expect(writes.withLock { $0.isEmpty })
        }

        @Test(.enabled(if: hasMetal), arguments: [1, 3, 100, 200])
        func `zoom actions follow their direction throughout the configured font range`(_ size: Int) throws {
            let view = try TerminalUIView(
                session: TerminalSession(columns: 10, rows: 3), configuration: Configuration.parse("font-size=\(size)"),
            )
            #expect(view.perform(.increaseFontSize(1)))
            #expect(view.fontSize == CGFloat(min(size + 1, 200)))
            #expect(view.perform(.resetFontSize))
            #expect(view.perform(.decreaseFontSize(1)))
            #expect(view.fontSize == CGFloat(max(size - 1, 1)))
        }

        @Test(.enabled(if: hasMetal)) func `reopening search restores the retained query and refocusing preserves navigation`() throws {
            let session = TerminalSession(columns: 10, rows: 3)
            let view = try TerminalUIView(session: session)
            session.feed(Array("needle0\r\nneedle1\r\nneedle2".utf8))
            view.showSearch(text: "needle")
            #expect(session.snapshot().searchMatchCount == 3)
            #expect(session.snapshot().searchSelectedIndex == 2)
            #expect(view.navigateSearch(next: true))
            #expect(session.snapshot().searchSelectedIndex == 1)
            view.showSearch(text: nil)
            #expect(session.snapshot().searchSelectedIndex == 1)
            view.hideSearch()
            #expect(session.snapshot().searchMatchCount == 0)
            #expect(TestFixture(view.searchBar.field.text) == TestFixture("needle"))
            session.feed(Array("\r\nneedle3".utf8))
            view.showSearch(text: nil)
            #expect(session.snapshot().searchMatchCount == 4)
            #expect(session.snapshot().searchSelectedIndex == 3)
            #expect(TestFixture(view.searchBar.count.text) == TestFixture("4/4"))
        }

        @Test(.enabled(if: hasMetal)) func `configuration reloads preserve terminal colors until the configured palette changes`() throws {
            let session = TerminalSession(columns: 10, rows: 3)
            let view = try TerminalUIView(session: session)
            view.traitOverrides.userInterfaceStyle = .dark
            view.updateTraitsIfNeeded()
            #expect(view.traitCollection.userInterfaceStyle == .dark)
            view.applyColorScheme()
            session.feed(Array("\u{1B}]10;#123456\u{7}\u{1B}]4;1;#ABCDEF\u{7}".utf8))
            #expect(session.withState { $0.palette.foreground } == 0x123456)
            view.apply(Configuration.parse("font-size=18"))
            #expect(session.withState { $0.palette.foreground } == 0x123456)
            #expect(session.withState { $0.palette.colors[1] } == 0xABCDEF)
            view.apply(Configuration.parse("font-size=18\nforeground=#654321\npalette=1=#FEDCBA"))
            #expect(session.withState { $0.palette.foreground } == 0x654321)
            #expect(session.withState { $0.palette.colors[1] } == 0xFEDCBA)
            session.feed(Array("\u{1B}]10;#123456\u{7}".utf8))
            view.apply(Configuration.parse("font-size=20\nforeground=#654321\npalette=1=#FEDCBA"))
            #expect(session.withState { $0.palette.foreground } == 0x123456)
        }

        @Test(.enabled(if: hasMetal)) func `appearance changes report the scheme without resetting an identical palette`() throws {
            let session = TerminalSession(columns: 10, rows: 3)
            let view = try TerminalUIView(session: session)
            view.traitOverrides.userInterfaceStyle = .dark
            view.updateTraitsIfNeeded()
            #expect(view.traitCollection.userInterfaceStyle == .dark)
            view.applyColorScheme()
            session.feed(Array("\u{1B}[?2031h\u{1B}]10;#123456\u{7}".utf8))
            let writes = Mutex<[[UInt8]]>([])
            session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
            view.traitOverrides.userInterfaceStyle = .light
            view.updateTraitsIfNeeded()
            #expect(view.traitCollection.userInterfaceStyle == .light)
            view.applyColorScheme()
            #expect(session.withState { $0.palette.foreground } == 0x123456)
            #expect(TestFixture(writes.withLock { $0 }) == TestFixture([Array("\u{1B}[?997;2n".utf8)]))
            let adaptive = Configuration.parse("theme=light:Swiftty Light,dark:Swiftty Dark")
            view.apply(adaptive)
            session.feed(Array("\u{1B}]10;#123456\u{7}".utf8))
            writes.withLock { $0.removeAll() }
            view.traitOverrides.userInterfaceStyle = .dark
            view.updateTraitsIfNeeded()
            view.applyColorScheme()
            #expect(session.withState { $0.palette } == adaptive.palette(for: .dark))
            #expect(TestFixture(writes.withLock { $0 }) == TestFixture([Array("\u{1B}[?997;1n".utf8)]))
        }

        @Test(.enabled(if: hasMetal)) func `accessibility scrolling reports actual movement and updates readable content`() throws {
            let session = TerminalSession(columns: 10, rows: 3)
            let view = try TerminalUIView(session: session)
            #expect(!view.accessibilityScroll(.up))
            #expect(!view.accessibilityScroll(.down))
            session.feed(Array("0\r\n1\r\n2\r\n3\r\n4\r\n5\r\n6".utf8))
            #expect(!view.accessibilityScroll(.up))
            #expect(view.accessibilityScroll(.down))
            #expect(session.withState { $0.viewportOffset } == 2)
            #expect(TestFixture(view.accessibilityPageContent()) == TestFixture("2\n3\n4"))
            #expect(view.accessibilityScroll(.down))
            #expect(session.withState { $0.viewportOffset } == 4)
            #expect(TestFixture(view.accessibilityPageContent()) == TestFixture("0\n1\n2"))
            #expect(!view.accessibilityScroll(.down))
            #expect(!view.accessibilityScroll(.left))
            #expect(view.accessibilityScroll(.up))
            #expect(TestFixture(view.accessibilityPageContent()) == TestFixture("2\n3\n4"))
            #expect(view.accessibilityScroll(.up))
            #expect(TestFixture(view.accessibilityPageContent()) == TestFixture("4\n5\n6"))
            #expect(!view.accessibilityScroll(.up))
            session.feed(Array("\u{1B}[?1049h".utf8))
            #expect(!view.accessibilityScroll(.down))
            #expect(!view.accessibilityScroll(.up))
        }

        @Test(.enabled(if: hasMetal)) func `extreme cell sizes and padding remain safe during layout`() throws {
            let session = TerminalSession(columns: 10, rows: 2)
            let configuration = Configuration.parse("adjust-cell-height = 1e308\nwindow-padding-x = 1e308")
            let view = try TerminalUIView(session: session, configuration: configuration)
            view.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
            view.setNeedsLayout()
            view.layoutIfNeeded()
            let size = session.withState { ($0.columns, $0.rows, $0.cellPixelSize.height) }
            #expect(size.0 == 1 && size.1 == 1 && size.2 == Int.max)
        }

        @Test(.enabled(if: hasMetal)) func `all surface bindings broadcast through presses and key commands`() throws {
            let firstSession = TerminalSession(columns: 10, rows: 2), secondSession = TerminalSession(columns: 10, rows: 2)
            let config = Configuration.parse("keybind = unconsumed:all:ctrl+a=text:X")
            let first = try TerminalUIView(session: firstSession, configuration: config)
            let second = try TerminalUIView(session: secondSession)
            let firstWrites = Mutex<[UInt8]>([]), secondWrites = Mutex<[UInt8]>([])
            firstSession.onWrite = { bytes in firstWrites.withLock { $0.append(contentsOf: bytes) } }
            secondSession.onWrite = { bytes in secondWrites.withLock { $0.append(contentsOf: bytes) } }
            #expect(TestFixture(first.keyDown(usage: 4, modifiers: .control, base: "a", characters: "\u{1}")) == TestFixture(true))
            _ = firstSession.snapshot()
            _ = secondSession.snapshot()
            #expect(firstWrites.withLock { $0 } == [0x58])
            #expect(secondWrites.withLock { $0 } == [0x58])
            #expect(first.heldKeys.isEmpty)
            let command = try #require(first.keyCommands?.first { $0.input == "a" && $0.modifierFlags == .control })
            first.performKeyCommand(command)
            _ = firstSession.snapshot()
            _ = secondSession.snapshot()
            #expect(firstWrites.withLock { $0 } == [0x58, 0x58])
            #expect(secondWrites.withLock { $0 } == [0x58, 0x58])
            withExtendedLifetime(second) {}
        }

        @Test(.enabled(if: hasMetal)) func `performable copy consumes the key when a selection exists`() throws {
            let session = TerminalSession(columns: 10, rows: 2)
            let config = Configuration.parse("keybind = performable:ctrl+c=copy_to_clipboard")
            let view = try TerminalUIView(session: session, configuration: config)
            let clipboard = try #require(UIPasteboard(name: .init(rawValue: UUID().uuidString), create: true))
            view.pasteboard = clipboard
            defer { UIPasteboard.remove(withName: clipboard.name) }
            session.feed(Array("abc".utf8))
            session.mutate {
                $0.setSelection(Selection(anchor: TerminalPoint(row: 0, column: 0), head: TerminalPoint(row: 0, column: 2)))
            }
            let writes = Mutex<[UInt8]>([])
            session.onWrite = { bytes in writes.withLock { $0.append(contentsOf: bytes) } }
            #expect(TestFixture(view.keyDown(usage: 6, modifiers: .control, base: "c", characters: "\u{3}")) == TestFixture(true))
            _ = session.snapshot()
            #expect(clipboard.string == "abc")
            #expect(writes.withLock { $0.isEmpty })
            #expect(session.withState { $0.selection != nil })
        }

        @Test(.enabled(if: hasMetal)) func `navigation actions report whether they can run`() throws {
            let session = TerminalSession(columns: 10, rows: 2)
            let view = try TerminalUIView(session: session)
            #expect(!view.perform(.scrollPageUp))
            #expect(!view.perform(.jumpToPrompt(-1)))
            #expect(!view.perform(.navigateSearch(next: true)))
            #expect(!view.perform(.searchSelection))
            #expect(!view.perform(.endSearch))
            session.feed(Array("one\r\ntwo\r\nthree\r\nfour".utf8))
            #expect(view.perform(.scrollPageUp))
            #expect(view.perform(.scrollToBottom))
            #expect(!view.perform(.scrollToBottom))
        }

        @Test(.enabled(if: hasMetal)) func `unavailable performable copy bindings pass the key through`() throws {
            let config = Configuration.parse("keybind = performable:ctrl+c=copy_to_clipboard")
            let session = TerminalSession(columns: 10, rows: 2)
            let view = try TerminalUIView(session: session, configuration: config)
            defer { view.releaseHardwareKeys() }
            let writes = Mutex<[UInt8]>([])
            session.onWrite = { bytes in writes.withLock { $0.append(contentsOf: bytes) } }
            #expect(TestFixture(view.keyDown(usage: 6, modifiers: .control, base: "c", characters: "\u{3}")) == TestFixture(true))
            _ = session.snapshot()
            #expect(writes.withLock { $0 } == [0x03])
            #expect(view.keyCommands?.contains { $0.input == "c" && $0.modifierFlags == .control } == false)
        }

        @Test(.enabled(if: hasMetal), arguments: [false, true])
        func `bindings send original keys only when unconsumed`(_ unconsumed: Bool) throws {
            let config = Configuration.parse("keybind = \(unconsumed ? "unconsumed:" : "")ctrl+a=text:X")
            let session = TerminalSession(columns: 10, rows: 2)
            let view = try TerminalUIView(session: session, configuration: config)
            defer { view.releaseHardwareKeys() }
            let writes = Mutex<[UInt8]>([])
            session.onWrite = { bytes in writes.withLock { $0.append(contentsOf: bytes) } }
            #expect(TestFixture(view.keyDown(usage: 4, modifiers: .control, base: "a", characters: "\u{1}")) == TestFixture(true))
            _ = session.snapshot()
            #expect(writes.withLock { $0 } == (unconsumed ? [0x58, 0x01] : [0x58]))
            #expect(view.heldKeys.count == (unconsumed ? 1 : 0))
            let command = view.keyCommands?.first { $0.input == "a" && $0.modifierFlags == .control }
            #expect((command == nil) == unconsumed)
        }

        @Test(.enabled(if: hasMetal)) func `unconsumed printable bindings preserve text input`() throws {
            let config = Configuration.parse("keybind = unconsumed:a=text:X")
            let session = TerminalSession(columns: 10, rows: 2)
            let view = try TerminalUIView(session: session, configuration: config)
            let writes = Mutex<[UInt8]>([])
            session.onWrite = { bytes in writes.withLock { $0.append(contentsOf: bytes) } }
            #expect(!view.keyDown(usage: 4, modifiers: [], base: "a", characters: "a"))
            view.insertText("a")
            _ = session.snapshot()
            #expect(writes.withLock { $0 } == Array("Xa".utf8))
        }

        @Test(.enabled(if: hasMetal), arguments: [false, true])
        func `output clearing selection disables copy and ends its drag`(_ extendBeforeFrame: Bool) throws {
            let session = TerminalSession(columns: 10, rows: 2)
            let view = try TerminalUIView(session: session)
            session.feed(Array("abc".utf8))
            view.selectAll(nil)
            let point = TerminalPoint(row: 0, column: 0)
            view.selectionOrigin = (point, point, session.withState { $0.addressingGeneration })
            #expect(view.canPerformAction(#selector(view.copy(_:)), withSender: nil))
            session.feed(Array("\u{1B}[H\u{1B}[2J".utf8))
            _ = session.snapshot()
            // Menu validation can happen before the next frame.
            #expect(!view.canPerformAction(#selector(view.copy(_:)), withSender: nil))
            if extendBeforeFrame {
                view.extendSelection(to: .zero, rectangle: false)
                #expect(session.withState { $0.selection == nil })
            }
            view.draw(in: view)
            #expect(!view.hasSelection)
            #expect(view.selectionOrigin == nil)
            view.selectionOrigin = (point, point, session.withState { $0.addressingGeneration })
            view.draw(in: view)
            #expect(view.selectionOrigin != nil)
        }

        @Test(.enabled(if: hasMetal)) func `key window changes release keys and update terminal focus`() throws {
            let session = TerminalSession(columns: 10, rows: 2)
            let view = try TerminalUIView(session: session)
            let window = makeWindow()
            let controller = UIViewController()
            window.rootViewController = controller
            controller.view.addSubview(view)
            window.makeKeyAndVisible()
            let other = makeWindow()
            other.rootViewController = UIViewController()
            defer { window.isHidden = true; other.isHidden = true }
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
            #expect(TestFixture(writes.withLock { $0 }) == TestFixture([Array("\u{1B}[97;1:3u".utf8), Array("\u{1B}[O".utf8)]))
            writes.withLock { $0.removeAll() }
            window.makeKey()
            #expect(view.becomeFirstResponder())
            _ = session.snapshot()
            #expect(view.renderer.options.isFocused)
            #expect(TestFixture(writes.withLock { $0 }) == TestFixture([Array("\u{1B}[I".utf8)]))
            writes.withLock { $0.removeAll() }
            NotificationCenter.default.post(name: UIWindow.didResignKeyNotification, object: other)
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

        @Test(.enabled(if: hasMetal)) func `search count follows program output`() throws {
            let session = TerminalSession(columns: 10, rows: 2)
            let view = try TerminalUIView(session: session)
            session.feed(Array("foo".utf8))
            view.showSearch(text: "foo")
            #expect(TestFixture(view.searchBar.count.text) == TestFixture("1/1"))
            session.feed(Array(" foo".utf8))
            view.draw(in: view)
            #expect(TestFixture(view.searchBar.count.text) == TestFixture("1/2"))
            session.feed(Array("\u{1B}[2J".utf8))
            view.draw(in: view)
            #expect(TestFixture(view.searchBar.count.text) == TestFixture("0"))
        }

        @Test(.enabled(if: hasMetal)) func `raw text actions preserve every byte`() throws {
            let session = TerminalSession(columns: 10, rows: 2)
            let view = try TerminalUIView(session: session)
            let writes = Mutex<[UInt8]>([])
            session.onWrite = { bytes in writes.withLock { $0.append(contentsOf: bytes) } }
            session.feed(Array("\u{1B}[?2004h\u{1B}[=31u".utf8))
            view.perform(.textBytes([0, 0x80, 0xFF]))
            _ = session.snapshot()
            #expect(writes.withLock { $0 } == [0, 0x80, 0xFF])
        }

        @Test(.enabled(if: hasMetal), arguments: ["focus", "inactive", "background", "detach"])
        func `lost focus releases keys and clears hardware input`(_ transition: String) throws {
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
            view.hardwareTextInput.begin(usage: 5, event: KeyEvent(.character("b"), text: "b"))
            let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in }
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
            let sent = writes.withLock { $0.map { String(decoding: $0, as: UTF8.self) } }
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

        @Test(.enabled(if: hasMetal)) func `scene activation restores focus only for its responder`() throws {
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
            #expect(TestFixture(writes.withLock { $0 }) == TestFixture([Array("\u{1B}[O".utf8), Array("\u{1B}[I".utf8)]))
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
            #expect(TestFixture(writes.withLock { $0 }) == TestFixture([Array("\u{1B}[I".utf8)]))
            #expect(view.resignFirstResponder())
            _ = session.snapshot()
            writes.withLock { $0.removeAll() }
            view.sceneDidActivate()
            _ = session.snapshot()
            #expect(!view.renderer.options.isFocused)
            #expect(writes.withLock { $0.isEmpty })
        }
    }

    @MainActor private final class ReviewHardwareKey: UIKey {
        let usage: Int
        init(_ usage: Int) {
            self.usage = usage
            super.init()
        }

        required init?(coder: NSCoder) {
            return nil
        }

        override var keyCode: UIKeyboardHIDUsage {
            UIKeyboardHIDUsage(rawValue: usage)!
        }
    }

    @MainActor private final class ReviewKeyPress: UIPress {
        let simulatedKey: UIKey
        init(_ usage: Int) {
            simulatedKey = ReviewHardwareKey(usage)
            super.init()
        }

        override var key: UIKey? {
            simulatedKey
        }
    }

    @MainActor private final class ReviewTapGesture: UITapGestureRecognizer {
        var point = CGPoint.zero
        override func location(in view: UIView?) -> CGPoint {
            point
        }
    }

    @MainActor private final class ReviewHoverGesture: UIHoverGestureRecognizer {
        private var simulatedState: UIGestureRecognizer.State = .possible
        var point = CGPoint.zero
        var flags: UIKeyModifierFlags = []
        override var state: UIGestureRecognizer.State {
            get { simulatedState }
            set { simulatedState = newValue }
        }

        override var modifierFlags: UIKeyModifierFlags {
            flags
        }

        override func location(in view: UIView?) -> CGPoint {
            point
        }
    }

    @MainActor final class ReviewPinchGesture: UIPinchGestureRecognizer {
        private var simulatedState: UIGestureRecognizer.State = .possible
        override var state: UIGestureRecognizer.State {
            get { simulatedState }
            set { simulatedState = newValue }
        }
    }

    @MainActor private final class ReviewLongPressGesture: UILongPressGestureRecognizer {
        private var simulatedState: UIGestureRecognizer.State = .possible
        var point = CGPoint.zero
        override var state: UIGestureRecognizer.State {
            get { simulatedState }
            set { simulatedState = newValue }
        }

        override func location(in view: UIView?) -> CGPoint {
            point
        }
    }

#endif
