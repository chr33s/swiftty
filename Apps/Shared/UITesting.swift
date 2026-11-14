import Foundation
import SwiftUI

extension View {
  /// Under `-ui-testing`, overlays an invisible accessibility element
  /// `terminal.screen` whose value is the visible terminal text. UIKit's
  /// terminal only builds screen text for VoiceOver, which UI tests don't
  /// run.
  func uiTestingScreenProbe(_ model: TerminalScreenModel) -> some View {
    overlay(alignment: .topLeading) {
      if UITesting.isEnabled { ScreenTextProbe(model: model) }
    }
  }
}

private struct ScreenTextProbe: View {
  let model: TerminalScreenModel

  var body: some View {
    TimelineView(.periodic(from: .now, by: 0.25)) { _ in
      let text = (model.previewLines?() ?? []).joined(separator: "\n")
      Color.clear
        .frame(width: 2, height: 2)
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel(Text("Terminal screen", bundle: #bundle))
        .accessibilityValue(text).accessibilityIdentifier("terminal.screen")
    }
  }
}
