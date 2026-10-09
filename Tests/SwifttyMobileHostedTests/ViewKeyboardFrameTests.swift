#if canImport(UIKit) && !os(visionOS)
    import SwifttyCore
    @testable import SwifttyMobile
    import Testing
    import UIKit

    /// The application host supplies the window scene and its coordinate space.
    extension ViewLifecycleTests {
        @Test(.enabled(if: hasMetal), arguments: [false, true])
        func `keyboard hides while detached restore the viewport on reattachment`(_ includesScreen: Bool) throws {
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
            let session = TerminalSession(columns: 20, rows: 10)
            let view = try TerminalUIView(session: session)
            view.frame = window.bounds
            window.addSubview(view)
            defer { view.removeFromSuperview() }
            view.layoutIfNeeded()
            let fullRows = session.withState { $0.rows }
            let covered = CGRect(x: view.bounds.minX, y: view.bounds.maxY - 120, width: view.bounds.width, height: 120)
            let frame = view.convert(covered, to: scene.screen.coordinateSpace)
            let object: UIScreen? = includesScreen ? scene.screen : nil
            NotificationCenter.default.post(
                name: UIResponder.keyboardWillChangeFrameNotification, object: object,
                userInfo: [UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: frame)],
            )
            #expect(session.withState { $0.rows } < fullRows)
            view.removeFromSuperview()
            #expect(view.window == nil)
            NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: object)
            window.addSubview(view)
            view.layoutIfNeeded()
            #expect(session.withState { $0.rows } == fullRows)
        }

        @Test(.enabled(if: hasMetal)) func `keyboard notifications respect the terminal screen`() throws {
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
            let screen = scene.screen
            let otherScreens = UIScreen.screens.filter { $0 !== screen }
            print("Keyboard screen fixture: \(otherScreens.count) other system screens")
            let session = TerminalSession(columns: 20, rows: 10)
            let view = try TerminalUIView(session: session)
            view.frame = window.bounds
            window.addSubview(view)
            defer { view.removeFromSuperview() }
            view.layoutIfNeeded()
            let fullRows = session.withState { $0.rows }
            let covered = CGRect(x: view.bounds.minX, y: view.bounds.maxY - 120, width: view.bounds.width, height: 120)
            let frame = view.convert(covered, to: screen.coordinateSpace)
            func notify(_ name: Notification.Name, on screen: UIScreen?) {
                let notification = Notification(
                    name: name, object: screen,
                    userInfo: [UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: frame)],
                )
                _ = view.perform(NSSelectorFromString("keyboardFrameChanged:"), with: notification as NSNotification)
            }

            for otherScreen in otherScreens {
                notify(UIResponder.keyboardWillChangeFrameNotification, on: otherScreen)
                #expect(session.withState { $0.rows } == fullRows)
            }
            notify(UIResponder.keyboardWillChangeFrameNotification, on: screen)
            let reducedRows = session.withState { $0.rows }
            #expect(reducedRows < fullRows)
            for otherScreen in otherScreens {
                notify(UIResponder.keyboardWillHideNotification, on: otherScreen)
                #expect(session.withState { $0.rows } == reducedRows)
            }
            notify(UIResponder.keyboardWillHideNotification, on: screen)
            #expect(session.withState { $0.rows } == fullRows)

            // Keep accepting older keyboard notifications without a screen object.
            notify(UIResponder.keyboardWillChangeFrameNotification, on: nil)
            #expect(session.withState { $0.rows } == reducedRows)
            notify(UIResponder.keyboardWillHideNotification, on: nil)
            #expect(session.withState { $0.rows } == fullRows)
        }
    }
#endif
