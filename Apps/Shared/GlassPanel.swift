import SwiftUI

extension View {
  @ViewBuilder
  func glassPanel(cornerRadius: CGFloat = 12, tint: Color? = nil) -> some View {
    #if os(visionOS)
    background(tint ?? .clear)
      .glassBackgroundEffect(in: .rect(cornerRadius: cornerRadius))
    #else
    glassEffect(.regular.tint(tint), in: .rect(cornerRadius: cornerRadius))
    #endif
  }

  /// Glass behind the view, reaching into the safe areas unless
  /// `fillsSafeArea` is false: a terminal leaves its insets to
  /// `TerminalChromeBackground`, which the glass would cover.
  @ViewBuilder
  func glassSurface(fillsSafeArea: Bool = true) -> some View {
    if fillsSafeArea {
      background { Color.clear.glassPanel(cornerRadius: 0).ignoresSafeArea() }
    } else {
      background { Color.clear.glassPanel(cornerRadius: 0) }
    }
  }

  @ViewBuilder
  func glassListBackground() -> some View {
    #if os(tvOS)
    glassSurface()
    #else
    scrollContentBackground(.hidden).glassSurface()
    #endif
  }

  @ViewBuilder
  func glassButtonStyle(prominent: Bool = false) -> some View {
    #if os(visionOS)
    if prominent {
      buttonStyle(.borderedProminent)
    } else {
      buttonStyle(.bordered)
    }
    #else
    if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
    #endif
  }

  @ViewBuilder
  func glassWindowBackground() -> some View {
    #if os(macOS)
    containerBackground(.clear, for: .window)
    #else
    self
    #endif
  }
}
