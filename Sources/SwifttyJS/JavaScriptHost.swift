import Foundation

/// Values crossing the VM boundary never retain JavaScriptCore objects.
public struct JavaScriptAction: Codable, Sendable, Equatable {
  public enum Kind: String, Codable, Sendable {
    case write, close, split, badge, tabIcon, notification, status, keybinding,
      error
  }
  public var kind: Kind
  public var pane: String?
  public var id: String?
  public var text: String?
  public var title: String?
  public var direction: String?
  public var status: JavaScriptStatusItem?
}

public struct JavaScriptStatusItem: Codable, Sendable, Equatable {
  public var id: String
  public var align: String
  public var text: String
  public var color: JavaScriptColor?
  public var backgroundColor: JavaScriptColor?
}

public enum JavaScriptColor: Codable, Sendable, Equatable {
  case string(String)
  case components(red: Double, green: Double, blue: Double, alpha: Double)

  private struct Components: Codable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double?
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let text = try? container.decode(String.self) {
      self = .string(text)
    } else {
      let value = try container.decode(Components.self)
      let channels = [value.red, value.green, value.blue, value.alpha ?? 1]
      guard channels.allSatisfy({ $0.isFinite && (0 ... 1).contains($0) })
      else {
        throw DecodingError.dataCorruptedError(
          in: container,
          debugDescription: "Color channels must be in 0...1"
        )
      }
      self = .components(
        red: value.red,
        green: value.green,
        blue: value.blue,
        alpha: value.alpha ?? 1
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case let .string(text): try container.encode(text)
    case let .components(red, green, blue, alpha):
      try container.encode(
        Components(red: red, green: green, blue: blue, alpha: alpha)
      )
    }
  }
}
