import AppKit
import SwiftMuxProtocol
import SwifttyCore

/// Read-only view of a pane's saved output (spec.durability.md §12.2.8):
/// styled cells with literal Find and Copy. It never reaches a PTY, parser,
/// history, link handler, automation or the inbox; it opens no links.
@MainActor
final class SavedOutputViewer: NSWindowController {
  init(output: SavedOutput, title: String, font: NSFont) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
      styleMask: [.titled, .closable, .resizable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.title = title
    window.subtitle = "Read-only; earlier processes ended"
    window.isReleasedWhenClosed = false
    let scroll = NSScrollView(frame: window.contentView!.bounds)
    scroll.autoresizingMask = [.width, .height]
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    let text = NSTextView(frame: scroll.bounds)
    text.isEditable = false
    text.isSelectable = true
    text.isRichText = true
    text.usesFindBar = true
    text.isIncrementalSearchingEnabled = true
    text.isAutomaticLinkDetectionEnabled = false
    text.isAutomaticDataDetectionEnabled = false
    text.textContainer?.widthTracksTextView = false
    text.textContainer?.containerSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )
    text.isHorizontallyResizable = true
    text.autoresizingMask = [.width, .height]
    text.backgroundColor = Self.color(output.defaultBackground)
    text.textStorage?.setAttributedString(Self.render(output, font: font))
    scroll.documentView = text
    window.contentView?.addSubview(scroll)
    super.init(window: window)
    text.scrollToEndOfDocument(nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  /// Cells to attributed text. Link attributes are never set.
  static func render(_ output: SavedOutput, font: NSFont) -> NSAttributedString
  {
    let result = NSMutableAttributedString()
    let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    let italic = NSFontManager.shared.convert(
      font,
      toHaveTrait: .italicFontMask
    )
    for row in output.rows {
      for cell in row.cells {
        let style = output.styles[Int(cell.style)]
        let inverse = style.flags & (1 << 6) != 0
        var foreground = resolve(style.foreground, output, foreground: true)
        var background = resolve(style.background, output, foreground: false)
        if inverse { swap(&foreground, &background) }
        var attributes: [NSAttributedString.Key: Any] = [
          .font: style.flags & 1 != 0
            ? bold : style.flags & (1 << 2) != 0 ? italic : font,
          .foregroundColor: color(foreground),
        ]
        if background != output.defaultBackground || inverse {
          attributes[.backgroundColor] = color(background)
        }
        if style.flags & (1 << 3) != 0 {
          attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if style.flags & (1 << 8) != 0 {
          attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        result.append(
          NSAttributedString(
            string: output.graphemes[Int(cell.grapheme)],
            attributes: attributes
          )
        )
      }
      if !row.wrapped {
        result.append(
          NSAttributedString(string: "\n", attributes: [.font: font])
        )
      }
    }
    return result
  }

  /// `TerminalColor` raw values: tag byte 0 default, 1 palette, 2 RGB.
  private static func resolve(
    _ raw: UInt32,
    _ output: SavedOutput,
    foreground: Bool
  ) -> UInt32 {
    switch raw >> 24 {
    case 1: output.palette[Int(raw & 0xFF)]
    case 2: raw & 0xFF_FFFF
    default: foreground ? output.defaultForeground : output.defaultBackground
    }
  }

  private static func color(_ rgb: UInt32) -> NSColor {
    NSColor(
      srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
      green: CGFloat((rgb >> 8) & 0xFF) / 255,
      blue: CGFloat(rgb & 0xFF) / 255,
      alpha: 1
    )
  }
}
