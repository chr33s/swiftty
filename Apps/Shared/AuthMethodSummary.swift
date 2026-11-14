import Foundation

extension AuthMethodReference {
  /// Localized plain text: it can name a key the user chose.
  public var summary: String {
    switch self {
    case .password: String(localized: "Password", bundle: #bundle)
    case .key: String(localized: "SSH key", bundle: #bundle)
    case .legacyKey(let label):
      String(
        localized: "Key \u{201C}\(label)\u{201D} (needs repair)",
        bundle: #bundle
      )
    case .unsupported:
      String(localized: "Unsupported sign-in method", bundle: #bundle)
    }
  }
}
