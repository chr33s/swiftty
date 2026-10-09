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
            arguments: ["view", "window", "size", "parent", "reparent", "detach", "viewAlpha", "parentAlpha", "windowAlpha"],
        )
        func `invisible surfaces suspend blinking and resume when shown`(_ transition: String) async throws {
            let surface = try makeAnimationSurface()
            let view = surface.view
            defer { view.stopBlinking(); view.removeFromSuperview(); surface.window.isHidden = true }
            view.session.feed(Array("\u{1B}[?25l\u{1B}[5mblink".utf8))
            try primeBlinkingText(view)
            view.updateBlinkTimer()
            var deadline = ContinuousClock.now + .seconds(2)
            while view.renderer.options.textBlinkVisible, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(!view.renderer.options.textBlinkVisible)

            surface.hide(transition)
            try await Task.sleep(for: .milliseconds(50))
            #expect(view.renderer.options.textBlinkVisible)
            deadline = ContinuousClock.now + .seconds(BlinkState.interval * 2 + 0.1)
            var stayedVisible = true
            while ContinuousClock.now < deadline {
                stayedVisible = stayedVisible && view.renderer.options.textBlinkVisible
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(stayedVisible)

            surface.show(transition)
            deadline = ContinuousClock.now + .seconds(2)
            while view.renderer.options.textBlinkVisible, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(!view.renderer.options.textBlinkVisible)
        }

        @Test(
            .enabled(if: hasMetal),
            arguments: ["view", "window", "size", "parent", "reparent", "detach", "viewAlpha", "parentAlpha", "windowAlpha", "fade"],
        )
        func `invisible surfaces stop wheel momentum on both axes`(_ transition: String) async throws {
            let surface = try makeAnimationSurface()
            let view = surface.view
            defer { view.stopMomentum(); view.removeFromSuperview(); surface.window.isHidden = true }
            if transition == "fade" {
                let deadline = ContinuousClock.now + .seconds(2)
                while surface.container.layer.presentation() == nil, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                try #require(surface.container.layer.presentation()?.opacity == 1)
            }
            view.session.feed(Array("\u{1B}[?1002h\u{1B}[?1006h".utf8))
            view.draw(in: view)
            let writes = Mutex<[[UInt8]]>([])
            view.session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
            let pan = ReviewScrollGesture()
            pan.state = .ended
            let velocity: CGFloat = transition == "fade" ? 1000 : 100
            pan.speed = CGPoint(
                x: view.geometry.cellSize.width / view.geometry.scale * velocity,
                y: view.geometry.lineHeight * velocity,
            )
            _ = view.perform(NSSelectorFromString("handleScroll:"), with: pan)
            try #require(view.momentum.isActive && view.horizontalMomentum.isActive && view.momentumLink != nil)

            surface.hide(transition)
            try await Task.sleep(for: .milliseconds(50))
            if transition == "fade" {
                try #require((surface.container.layer.presentation()?.opacity ?? 0) > 0)
                try #require(view.momentum.isActive && view.horizontalMomentum.isActive && view.momentumLink != nil)
                let deadline = ContinuousClock.now + .seconds(2)
                while (surface.container.layer.presentation()?.opacity ?? 0) > 0, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                try #require((surface.container.layer.presentation()?.opacity ?? 0) == 0)
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(!view.momentum.isActive && !view.horizontalMomentum.isActive && view.momentumLink == nil)
            _ = view.session.snapshot()
            let count = writes.withLock { $0.count }
            try await Task.sleep(for: .milliseconds(150))
            _ = view.session.snapshot()
            #expect(writes.withLock { $0.count } == count)

            surface.show(transition)
            try await Task.sleep(for: .milliseconds(50))
            #expect(!view.momentum.isActive && !view.horizontalMomentum.isActive && view.momentumLink == nil)
        }

        private func makeAnimationSurface() throws -> AnimationSurface {
            var configuration = Configuration()
            configuration.cursorStyleBlink = false
            let view = try TerminalUIView(session: TerminalSession(), configuration: configuration)
            let window = makeWindow()
            view.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
            let container = UIView(frame: view.frame)
            let wrapper = UIView(frame: view.frame)
            window.addSubview(wrapper)
            window.addSubview(container)
            container.addSubview(view)
            window.makeKeyAndVisible()
            view.sceneDidActivate()
            return AnimationSurface(view: view, window: window, container: container, wrapper: wrapper)
        }

        private func primeBlinkingText(_ view: TerminalUIView) throws {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: 320, height: 200, mipmapped: false,
            )
            descriptor.usage = [.renderTarget, .shaderRead]
            let texture = try #require(view.renderer.device.makeTexture(descriptor: descriptor))
            let command = view.renderer.render(view.session.snapshot(), to: texture)
            command.waitUntilCompleted()
            try #require(command.status == .completed && view.renderer.hasBlinkingText)
        }

        @MainActor private struct AnimationSurface {
            let view: TerminalUIView
            let window: UIWindow
            let container: UIView
            let wrapper: UIView

            func hide(_ transition: String) {
                switch transition {
                case "view": view.isHidden = true
                case "window": window.isHidden = true
                case "size": view.frame = .zero; view.layoutIfNeeded()
                case "parent": container.isHidden = true
                case "reparent": wrapper.addSubview(container); wrapper.isHidden = true
                case "viewAlpha": view.alpha = 0
                case "parentAlpha": container.alpha = 0
                case "windowAlpha": window.alpha = 0
                case "fade": UIView.animate(withDuration: 0.2) { container.alpha = 0 }
                default: view.removeFromSuperview()
                }
            }

            func show(_ transition: String) {
                switch transition {
                case "view": view.isHidden = false
                case "window": window.makeKeyAndVisible()
                case "size": view.frame = container.bounds; view.layoutIfNeeded()
                case "parent": container.isHidden = false
                case "reparent": wrapper.isHidden = false
                case "viewAlpha": view.alpha = 0.25
                case "parentAlpha": container.alpha = 0.25
                case "windowAlpha": window.alpha = 0.25
                case "fade": container.alpha = 0.25
                default: container.addSubview(view); view.sceneDidActivate()
                }
            }
        }
    }
#endif
