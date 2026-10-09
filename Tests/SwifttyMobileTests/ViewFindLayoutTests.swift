import TestSupport
#if canImport(UIKit)
    import SwifttyCore
    @testable import SwifttyMobile
    import Testing
    import UIKit

    extension ViewLifecycleTests {
        @Test(.enabled(if: hasMetal), arguments: [CGFloat(160), 240, 280, 320, 420, 640])
        func `find controls stay usable when resizing and match counts change`(_ width: CGFloat) throws {
            let view = try TerminalUIView(session: TerminalSession())
            let window = makeWindow()
            let controller = UIViewController()
            window.rootViewController = controller
            view.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
            controller.view.addSubview(view)
            window.makeKeyAndVisible()
            defer { view.removeFromSuperview(); window.isHidden = true }
            view.showSearch(text: "retained query")
            let bar = view.searchBar
            try #require(bar.field.isFirstResponder)
            var buttons: [UIButton] = []
            func collectButtons(in parent: UIView) {
                for child in parent.subviews {
                    if let button = child as? UIButton,
                       ["Previous match", "Next match", "Done"].contains(button.accessibilityLabel) {
                        buttons.append(button)
                    }
                    collectButtons(in: child)
                }
            }
            collectButtons(in: bar)
            try #require(buttons.count == 3)
            for size in [CGSize(width: width, height: 240), CGSize(width: 640, height: 240)] {
                view.frame.size = size
                view.setNeedsLayout()
                view.layoutIfNeeded()
                for total in [1, 1234, 1] {
                    bar.showCount(selected: total - 1, total: total)
                    #expect(view.bounds.contains(bar.frame))
                    #expect(bar.field.bounds.width >= 40)
                    #expect(bar.count.bounds.width >= bar.count.intrinsicContentSize.width)
                    for control in [bar.field, bar.count] + buttons {
                        #expect(bar.bounds.contains(bar.convert(control.bounds, from: control)))
                    }
                    for button in buttons {
                        #expect(button.bounds.width >= 44 && button.bounds.height > 0)
                    }
                    #expect(bar.field.isFirstResponder)
                    #expect(TestFixture(bar.field.text) == TestFixture("retained query"))
                }
            }
        }
    }
#endif
