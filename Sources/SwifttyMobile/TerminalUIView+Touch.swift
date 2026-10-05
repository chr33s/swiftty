#if canImport(UIKit)
    import SwifttyCore
    import UIKit

    /// Touch, pointer and scroll handling.
    ///
    /// - tap: focus (shows the keyboard), clears a selection; opens a link;
    ///   moves the shell's cursor on its command line (OSC 133); a mouse
    ///   click when the application tracks the mouse;
    /// - long press, then drag: select words; the edit menu follows;
    /// - one-finger pan, trackpad or wheel: scroll with momentum (wheel
    ///   events or arrow keys when the application asks for them);
    /// - pointer drag: select cells, or report a drag;
    /// - pointer hover: motion reports (mode 1003), link underline, the
    ///   OSC 22 pointer shape; secondary click: menu;
    /// - pinch: font size.
    extension TerminalUIView: UIPointerInteractionDelegate, @MainActor UIEditMenuInteractionDelegate {
        func installGestures() {
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            addGestureRecognizer(tap)

            let secondary = UITapGestureRecognizer(target: self, action: #selector(handleSecondaryClick(_:)))
            secondary.buttonMaskRequired = .secondary
            secondary.allowedTouchTypes = [UITouch.TouchType.indirectPointer.rawValue as NSNumber]
            addGestureRecognizer(secondary)

            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
            longPress.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
            addGestureRecognizer(longPress)

            let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
            scroll.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
            scroll.allowedScrollTypesMask = .all
            scroll.maximumNumberOfTouches = 1
            scroll.require(toFail: longPress)
            addGestureRecognizer(scroll)

            let pointerDrag = UIPanGestureRecognizer(target: self, action: #selector(handlePointerDrag(_:)))
            pointerDrag.allowedTouchTypes = [UITouch.TouchType.indirectPointer.rawValue as NSNumber]
            addGestureRecognizer(pointerDrag)

            addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:))))

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            addGestureRecognizer(pinch)

            let pointer = UIPointerInteraction(delegate: self)
            addInteraction(pointer)
            pointerInteraction = pointer
            addInteraction(editMenu)
        }

        // MARK: Mouse reporting

        var tracking: Bool {
            !lastModes.isDisjoint(with: Modes.mouseTracking)
        }

        /// Grid cell under `point`, clamped to the grid.
        func cell(at point: CGPoint) -> (column: Int, row: Int) {
            let c = geometry.cell(at: point)
            return (max(0, c.column), max(0, c.row))
        }

        func sendMouse(_ action: MouseEvent.Action, _ button: MouseEvent.Button, at point: CGPoint, modifiers: KeyModifiers = []) {
            guard tracking else { return }
            let c = cell(at: point)
            session.send(.mouse(MouseEvent(action, button, column: c.column, row: c.row, modifiers: modifiers)))
        }

        @objc private func handleTap(_ tap: UITapGestureRecognizer) {
            let point = tap.location(in: self)
            let mods = Self.modifiers(tap.modifierFlags)
            if !isFirstResponder {
                becomeFirstResponder()
            }
            editMenu.dismissMenu()
            // Shift selects even while the application tracks the mouse.
            if tracking, !mods.contains(.shift) {
                sendMouse(.press, .left, at: point, modifiers: mods)
                sendMouse(.release, .left, at: point, modifiers: mods)
                return
            }
            if hasSelection {
                clearSelection()
                return
            }
            let c = geometry.cell(at: point)
            let detect = configuration.linkURL
            let (link, moves) = session.withState { state in
                let p = TerminalPoint(row: state.absoluteRow(viewportRow: max(0, c.row)), column: max(0, c.column))
                return (state.link(at: p, detectURLs: detect), state.promptCursorMoves(to: p))
            }
            if let link, let url = LinkPolicy.openableURL(link.url) {
                UIApplication.shared.open(url)
            } else if configuration.cursorClickToMove, let moves, moves != 0 {
                send(ClickToMove.keys(moves).map { .key($0) })
            }
        }

        @objc private func handleSecondaryClick(_ tap: UITapGestureRecognizer) {
            let point = tap.location(in: self)
            let mods = Self.modifiers(tap.modifierFlags)
            if tracking, !mods.contains(.shift) {
                sendMouse(.press, .right, at: point, modifiers: mods)
                sendMouse(.release, .right, at: point, modifiers: mods)
            } else {
                editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
            }
        }

        @objc private func handlePointerDrag(_ pan: UIPanGestureRecognizer) {
            let point = pan.location(in: self)
            let mods = Self.modifiers(pan.modifierFlags)
            if selectionOrigin == nil, tracking, !mods.contains(.shift) {
                switch pan.state {
                case .began: sendMouse(.press, .left, at: point, modifiers: mods)
                case .changed: sendMouse(.motion, .left, at: point, modifiers: mods)
                case .ended, .cancelled: sendMouse(.release, .left, at: point, modifiers: mods)
                default: break
                }
                return
            }
            switch pan.state {
            case .began:
                // The press happened where the drag started.
                let start = CGPoint(x: point.x - pan.translation(in: self).x, y: point.y - pan.translation(in: self).y)
                beginSelection(at: start, unit: .cell, rectangle: mods.contains(.alt))
                extendSelection(to: point, rectangle: mods.contains(.alt))
            case .changed: extendSelection(to: point, rectangle: mods.contains(.alt))
            case .ended, .cancelled: endSelection()
            default: break
            }
        }

        @objc private func handleHover(_ hover: UIHoverGestureRecognizer) {
            guard hover.state == .began || hover.state == .changed else {
                hoverCell = nil
                setHoveredLink(nil)
                return
            }
            let point = hover.location(in: self)
            let c = cell(at: point)
            guard hoverCell.map({ $0 != c }) ?? true else { return }
            hoverCell = c
            if lastModes.contains(.mouseAny) {
                sendMouse(.motion, .none, at: point, modifiers: Self.modifiers(hover.modifierFlags))
            }
            if tracking {
                setHoveredLink(nil)
                return
            }
            let detect = configuration.linkURL
            let hovered = session.withState { state -> (id: UInt8, span: HighlightSpan)? in
                let p = TerminalPoint(row: state.absoluteRow(viewportRow: c.row), column: c.column)
                guard let link = state.link(at: p, detectURLs: detect), LinkPolicy.openableURL(link.url) != nil else { return nil }
                return (link.id, LinkPolicy.span(of: link.range, firstVisibleRow: state.absoluteRow(viewportRow: 0)))
            }
            setHoveredLink(hovered)
        }

        /// Underlines the link under the pointer: OSC 8 links by id (every
        /// cell of the link), detected URLs by their span.
        private func setHoveredLink(_ link: (id: UInt8, span: HighlightSpan)?) {
            let id = link?.id ?? 0
            let span = link.flatMap { $0.id == 0 ? $0.span : nil }
            let isOver = link != nil
            guard renderer.options.hoveredLink != id || renderer.options.underlinedSpan != span || overLink != isOver else { return }
            renderer.options.hoveredLink = id
            renderer.options.underlinedSpan = span
            if overLink != isOver {
                overLink = isOver
                pointerInteraction?.invalidate()
            }
            setNeedsDisplay()
        }

        public func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
            let shape = PointerShape.resolve(applicationShape: pointerShapeName, overLink: overLink, tracking: tracking)
            let line = geometry.lineHeight
            switch shape {
            case .beam:
                return UIPointerStyle(shape: .verticalBeam(length: line), constrainedAxes: [])
            case .link:
                // iPadOS has no hand; a small filled dot with a link badge.
                let style = UIPointerStyle(shape: .roundedRect(CGRect(x: -5, y: -5, width: 10, height: 10), radius: 5))
                style.accessories = [.arrow(.topRight)]
                return style
            case .system:
                return .system()
            case .crosshair:
                let path = UIBezierPath()
                path.append(UIBezierPath(rect: CGRect(x: -8, y: -0.75, width: 16, height: 1.5)))
                path.append(UIBezierPath(rect: CGRect(x: -0.75, y: -8, width: 1.5, height: 16)))
                return UIPointerStyle(shape: .path(path))
            case .resizeHorizontal:
                let style = UIPointerStyle.system()
                style.accessories = [.arrow(.left), .arrow(.right)]
                return style
            case .resizeVertical:
                let style = UIPointerStyle.system()
                style.accessories = [.arrow(.top), .arrow(.bottom)]
                return style
            case .move:
                let style = UIPointerStyle.system()
                style.accessories = [.arrow(.top), .arrow(.bottom), .arrow(.left), .arrow(.right)]
                return style
            case .hidden:
                return .hidden()
            }
        }

        @objc private func handlePinch(_ pinch: UIPinchGestureRecognizer) {
            switch pinch.state {
            case .began: pinchStartSize = fontSize
            case .changed:
                let size = (pinchStartSize * pinch.scale).rounded()
                if size != fontSize {
                    setFontSize(size)
                }
            default: break
            }
        }

        // MARK: Selection

        @objc private func handleLongPress(_ press: UILongPressGestureRecognizer) {
            let point = press.location(in: self)
            switch press.state {
            case .began:
                editMenu.dismissMenu()
                UISelectionFeedbackGenerator(view: self).selectionChanged()
                beginSelection(at: point, unit: .word, rectangle: false)
            case .changed:
                extendSelection(to: point, rectangle: false)
            case .ended:
                endSelection()
                editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
            case .cancelled, .failed:
                endSelection()
            default: break
            }
        }

        func beginSelection(at point: CGPoint, unit: SelectionUnit, rectangle: Bool) {
            let c = geometry.cell(at: point)
            selectionUnit = unit
            selectionOrigin = session.mutate { state in
                let p = state.clamp(TerminalPoint(row: state.absoluteRow(viewportRow: max(0, c.row)), column: c.column))
                let span = switch unit {
                case .cell: (start: p, end: p)
                case .word: state.wordRange(at: p)
                case .line: state.lineRange(at: p)
                }
                state.setSelection(unit == .cell ? nil : Selection(anchor: span.start, head: span.end, rectangle: rectangle))
                return span
            }
            hasSelection = unit != .cell
        }

        func extendSelection(to point: CGPoint, rectangle: Bool) {
            guard let origin = selectionOrigin else { return }
            let c = geometry.cell(at: point)
            let unit = selectionUnit
            session.mutate { state in
                // Dragging past the top or bottom edge scrolls the viewport.
                state.scrollViewport(by: SelectionMath.edgeScroll(row: c.row, rows: state.rows))
                let row = min(max(c.row, 0), state.rows - 1)
                let p = state.clamp(TerminalPoint(row: state.absoluteRow(viewportRow: row), column: c.column))
                let span = switch unit {
                case .cell: (start: p, end: p)
                case .word: state.wordRange(at: p)
                case .line: state.lineRange(at: p)
                }
                state.setSelection(SelectionMath.extend(origin: origin, to: span, rectangle: rectangle))
            }
            hasSelection = true
        }

        func endSelection() {
            selectionOrigin = nil
            if hasSelection, configuration.copyOnSelect {
                copy(nil)
            }
        }

        func clearSelection() {
            guard hasSelection else { return }
            hasSelection = false
            session.mutateAsync { $0.setSelection(nil) }
        }

        public func editMenuInteraction(
            _ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement],
        ) -> UIMenu? {
            var children = suggestedActions
            let c = geometry.cell(at: configuration.sourcePoint)
            let output = session.withState { state in
                state.commandOutputRange(at: TerminalPoint(row: state.absoluteRow(viewportRow: max(0, c.row)), column: max(0, c.column)))
            }
            if let output {
                children
                    .append(UIAction(title: "Select Command Output", image: UIImage(systemName: "text.badge.checkmark")) { [weak self] _ in
                        guard let self else { return }
                        session.mutate { $0.setSelection(Selection(anchor: output.start, head: output.end)) }
                        hasSelection = true
                        editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: configuration.sourcePoint))
                    })
            }
            return UIMenu(children: children)
        }

        // MARK: Scrolling

        @objc private func handleScroll(_ pan: UIPanGestureRecognizer) {
            let point = pan.location(in: self)
            switch pan.state {
            case .began:
                stopMomentum()
                scrollAccumulator.reset()
                editMenu.dismissMenu()
            case .changed:
                let dy = pan.translation(in: self).y
                pan.setTranslation(.zero, in: self)
                scroll(lines: dy / geometry.lineHeight, at: point)
            case .ended:
                startMomentum(velocity: pan.velocity(in: self).y / geometry.lineHeight, at: point)
            default: break
            }
        }

        /// Scrolls by `lines` (positive reveals history, as content follows
        /// the finger down), routed the way the application asked.
        func scroll(lines: CGFloat, at point: CGPoint) {
            let n = scrollAccumulator.add(lines)
            guard n != 0 else { return }
            switch ScrollRouting(modes: lastModes) {
            case .wheel:
                for _ in 0 ..< abs(n) {
                    sendMouse(.press, n > 0 ? .wheelUp : .wheelDown, at: point)
                }
            case .arrows:
                for _ in 0 ..< abs(n) {
                    session.send(.key(KeyEvent(n > 0 ? .up : .down)))
                }
            case .viewport:
                session.scrollViewport(by: n)
            }
        }

        private func startMomentum(velocity: CGFloat, at point: CGPoint) {
            momentum = ScrollMomentum(velocity: velocity)
            guard momentum.isActive, !isRenderingPaused else { return }
            momentumPoint = point
            let link = CADisplayLink(target: self, selector: #selector(momentumFrame(_:)))
            link.add(to: .main, forMode: .common)
            momentumLink = link
        }

        @objc private func momentumFrame(_ link: CADisplayLink) {
            scroll(lines: momentum.step(link.targetTimestamp - link.timestamp), at: momentumPoint)
            if !momentum.isActive {
                stopMomentum()
            }
        }

        func stopMomentum() {
            momentum.stop()
            momentumLink?.invalidate()
            momentumLink = nil
        }
    }
#endif
