import AppKit
import SwifttyCore
import SwifttyMac

extension MuxPaneView {
  private var accessibilityPresenter: TerminalAccessibility {
    let presentation = frozen ?? presented
    let snapshot = presentation?.snapshot
    return TerminalAccessibility(
      snapshot: snapshot,
      text: snapshot.map { accessibilityCache.text(for: $0) },
      selection: presentation.flatMap { p in
        selection.map { $0.span(in: p.frame) }
      }
    )
  }

  override func isAccessibilityElement() -> Bool { true }
  override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
  override func accessibilityRoleDescription() -> String? { "terminal" }
  override func accessibilityLabel() -> String? { "Terminal pane" }
  override func accessibilityValue() -> Any? {
    (frozen ?? presented)
      .map { accessibilityCache.text(for: $0.snapshot).string }
  }

  override func accessibilityNumberOfCharacters() -> Int {
    accessibilityPresenter.accessibilityNumberOfCharacters()
  }
  override func accessibilityVisibleCharacterRange() -> NSRange {
    accessibilityPresenter.accessibilityVisibleCharacterRange()
  }
  override func accessibilitySelectedTextRange() -> NSRange {
    accessibilityPresenter.accessibilitySelectedTextRange()
  }
  override func accessibilitySelectedTextRanges() -> [NSValue]? {
    accessibilityPresenter.accessibilitySelectedTextRanges()
  }
  override func accessibilitySelectedText() -> String? { selectedText }
  override func accessibilityInsertionPointLineNumber() -> Int {
    accessibilityPresenter.accessibilityInsertionPointLineNumber()
  }
  override func accessibilityLine(for index: Int) -> Int {
    accessibilityPresenter.accessibilityLine(for: index)
  }
  override func accessibilityRange(forLine line: Int) -> NSRange {
    accessibilityPresenter.accessibilityRange(forLine: line)
  }
  override func accessibilityRange(for index: Int) -> NSRange {
    accessibilityPresenter.accessibilityRange(for: index)
  }
  override func accessibilityRange(for point: NSPoint) -> NSRange {
    accessibilityPresenter.accessibilityRange(
      for: point,
      view: self,
      renderer: renderer,
      contains: { self.bounds.contains($0) }
    )
  }
  override func accessibilityString(for range: NSRange) -> String? {
    accessibilityPresenter.accessibilityString(for: range)
  }
  override func accessibilityFrame(for range: NSRange) -> NSRect {
    accessibilityPresenter.accessibilityFrame(
      for: range,
      view: self,
      renderer: renderer
    )
  }
}
