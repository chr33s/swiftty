import AppKit
import SwiftMuxProtocol
@testable import Swiftty
import Testing

/// The saved-output viewer shows cells only (spec.durability.md §12.2.8,
/// RS12): no link attributes, no data detection, read-only.
@MainActor
@Suite
struct SavedOutputViewerTests {
  @Test
  func renderShowsCellsWithoutLinks() {
    let output = SavedOutput(
      columns: 40,
      palette: (0 ..< 256).map { UInt32($0) },
      defaultForeground: 0xFFFFFF,
      defaultBackground: 0,
      styles: [
        .plain,
        SavedOutputStyle(
          foreground: 0x0200_FF00,
          background: 0,
          underline: 0,
          flags: 1 << 6
        ),
      ],
      graphemes: [" ", "h", "t", "p", "s", ":", "/", ".", "x"],
      rows: [
        SavedOutputRow(
          wrapped: false,
          cells: [1, 2, 2, 3, 4, 5, 6, 6, 8, 7, 8]
            .map {
              SavedOutputCell(grapheme: $0, width: 1, style: $0 == 1 ? 1 : 0)
            }
        )
      ]
    )
    let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    let text = SavedOutputViewer.render(output, font: font)
    #expect(text.string == "https://x.x\n")
    var linked = false
    text.enumerateAttribute(
      .link,
      in: NSRange(location: 0, length: text.length)
    ) { value, _, _ in if value != nil { linked = true } }
    #expect(!linked)
    // Inverse swaps colours for the styled cell.
    let background = text.attribute(
      .backgroundColor,
      at: 0,
      effectiveRange: nil
    )
    #expect(background != nil)
    let viewer = SavedOutputViewer(output: output, title: "t", font: font)
    let view = viewer.window?.contentView?.subviews.first as? NSScrollView
    let textView = view?.documentView as? NSTextView
    #expect(textView?.isEditable == false)
    #expect(textView?.isAutomaticLinkDetectionEnabled == false)
    viewer.close()
  }
}
