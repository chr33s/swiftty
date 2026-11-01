import SwifttyCore

extension Configuration {
  /// Programmatic settings for renderer/input fixtures; no document parsing.
  public static func configured(_ settings: [(String, String)]) -> Configuration
  {
    var config = Configuration()
    config.configure(settings)
    return config
  }

  public mutating func configure(_ settings: [(String, String)]) {
    for (key, value) in settings {
      if let error = set(key, value) { diagnostics.append("\(key): \(error)") }
    }
  }
}
