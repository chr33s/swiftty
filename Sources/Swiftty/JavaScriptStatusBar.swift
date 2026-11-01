import AppKit
import SwifttyJS

@MainActor
final class JavaScriptStatusBar: NSView {
  private let left = NSStackView()
  private let right = NSStackView()
  private var entries: [String: (JavaScriptStatusItem, NSTextField)] = [:]
  private var barHeight: NSLayoutConstraint!

  override init(frame: NSRect) {
    super.init(frame: frame)
    translatesAutoresizingMaskIntoConstraints = false
    for stack in [left, right] {
      stack.translatesAutoresizingMaskIntoConstraints = false
      stack.orientation = .horizontal
      stack.spacing = 12
      addSubview(stack)
    }
    barHeight = heightAnchor.constraint(equalToConstant: 0)
    NSLayoutConstraint.activate([
      barHeight,
      left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      left.centerYAnchor.constraint(equalTo: centerYAnchor),
      right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      right.centerYAnchor.constraint(equalTo: centerYAnchor),
      left.trailingAnchor.constraint(
        lessThanOrEqualTo: right.leadingAnchor,
        constant: -12
      ),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(_ item: JavaScriptStatusItem) {
    guard item.align == "left" || item.align == "right" else { return }
    let label = entries[item.id]?.1 ?? NSTextField(labelWithString: "")
    label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    label.lineBreakMode = .byTruncatingTail
    label.stringValue = item.text
    label.setAccessibilityLabel(item.text)
    label.textColor = item.color.flatMap(Self.color) ?? .secondaryLabelColor
    label.backgroundColor = item.backgroundColor.flatMap(Self.color) ?? .clear
    label.drawsBackground = item.backgroundColor != nil
    if entries[item.id]?.0.align != item.align {
      if let previous = entries[item.id] {
        (previous.0.align == "left" ? left : right).removeArrangedSubview(label)
        label.removeFromSuperview()
      }
      (item.align == "left" ? left : right).addArrangedSubview(label)
    }
    entries[item.id] = (item, label)
    barHeight.constant = 24
  }

  static func color(_ value: JavaScriptColor) -> NSColor? {
    switch value {
    case let .components(red, green, blue, alpha):
      return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    case let .string(raw):
      let text = raw.lowercased()
      let names: [String: NSColor] = [
        "black": .black, "white": .white, "red": .red, "green": .green,
        "blue": .blue, "yellow": .yellow, "orange": .orange, "purple": .purple,
        "gray": .gray, "grey": .gray, "cyan": .cyan, "magenta": .magenta,
        "transparent": .clear,
      ]
      if let named = names[text] { return named }
      guard text.first == "#" else { return nil }
      var hex = String(text.dropFirst())
      if hex.count == 3 || hex.count == 4 {
        hex = hex.map { "\($0)\($0)" }.joined()
      }
      guard hex.count == 6 || hex.count == 8, let bits = UInt32(hex, radix: 16)
      else { return nil }
      let rgba = hex.count == 6 ? (bits << 8) | 255 : bits
      return NSColor(
        srgbRed: Double((rgba >> 24) & 255) / 255,
        green: Double((rgba >> 16) & 255) / 255,
        blue: Double((rgba >> 8) & 255) / 255,
        alpha: Double(rgba & 255) / 255
      )
    }
  }
}
