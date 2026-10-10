import Foundation
import SwifttyCore

// UIKit key-layout translation; shared behavior lives in SwifttyCore.

// MARK: - US layout

extension KeyTranslator {
  /// The character of a key on the US (PC-101) layout by HID usage, for
  /// the kitty protocol's base-layout key.
  public static func usLayoutKey(usage: Int) -> Unicode.Scalar? {
    switch usage {
    case 0x04 ... 0x1D: Unicode.Scalar(UInt32(0x61 + usage - 0x04))
    case 0x1E ... 0x26: Unicode.Scalar(UInt32(0x31 + usage - 0x1E))
    case 0x27: "0"
    case 0x2C: " "
    case 0x2D: "-"
    case 0x2E: "="
    case 0x2F: "["
    case 0x30: "]"
    case 0x31: "\\"
    case 0x33: ";"
    case 0x34: "'"
    case 0x35: "`"
    case 0x36: ","
    case 0x37: "."
    case 0x38: "/"
    default: nil
    }
  }
}
