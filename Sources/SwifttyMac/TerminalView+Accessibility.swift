import AppKit
import SwifttyCore

/// VoiceOver: the view is a read-only text area holding the visible
/// screen, with the insertion point at the terminal cursor.
extension TerminalView {
  public override func isAccessibilityElement() -> Bool { true }

  public override func accessibilityRole() -> NSAccessibility.Role? {
    .textArea
  }

  public override func accessibilityRoleDescription() -> String? { "terminal" }

  public override func accessibilityLabel() -> String? {
    window?.title ?? "Terminal"
  }

  public override func accessibilityValue() -> Any? {
    accessibilityText?.string ?? ""
  }

  private var accessibilityPresenter: TerminalAccessibility {
    TerminalAccessibility(
      snapshot: lastSnapshot,
      text: accessibilityText,
      selection: lastSnapshot?.selection
    )
  }

  public override func accessibilityNumberOfCharacters() -> Int {
    accessibilityPresenter.accessibilityNumberOfCharacters()
  }
  public override func accessibilityVisibleCharacterRange() -> NSRange {
    accessibilityPresenter.accessibilityVisibleCharacterRange()
  }
  public override func accessibilitySelectedTextRange() -> NSRange {
    accessibilityPresenter.accessibilitySelectedTextRange()
  }
  public override func accessibilitySelectedTextRanges() -> [NSValue]? {
    accessibilityPresenter.accessibilitySelectedTextRanges()
  }
  public override func accessibilitySelectedText() -> String? {
    accessibilityPresenter.accessibilitySelectedText()
  }
  public override func accessibilityInsertionPointLineNumber() -> Int {
    accessibilityPresenter.accessibilityInsertionPointLineNumber()
  }
  public override func accessibilityLine(for index: Int) -> Int {
    accessibilityPresenter.accessibilityLine(for: index)
  }
  public override func accessibilityRange(forLine line: Int) -> NSRange {
    accessibilityPresenter.accessibilityRange(forLine: line)
  }
  public override func accessibilityRange(for index: Int) -> NSRange {
    accessibilityPresenter.accessibilityRange(for: index)
  }
  public override func accessibilityRange(for point: NSPoint) -> NSRange {
    accessibilityPresenter.accessibilityRange(
      for: point,
      view: self,
      renderer: renderer,
      contains: containsTerminalPoint
    )
  }
  public override func accessibilityString(for range: NSRange) -> String? {
    accessibilityPresenter.accessibilityString(for: range)
  }
  public override func accessibilityFrame(for range: NSRange) -> NSRect {
    accessibilityPresenter.accessibilityFrame(
      for: range,
      view: self,
      renderer: renderer
    )
  }
}
