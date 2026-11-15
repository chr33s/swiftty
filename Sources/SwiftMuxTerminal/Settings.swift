import TTYKit
import Foundation
import SwiftMuxProtocol

/// The small validated settings model (no scripting language).
/// Stored at ~/.config/swmux/settings.json.
public struct Settings: Codable, Equatable, Sendable {
  /// Prefix key as `C-x` (control + letter).
  public var prefix = "C-b"
  public var escapeDelayMilliseconds = InputDecoder
    .defaultEscapeDelayMilliseconds
  /// Keep a pane's final screen after its process exits.
  public var remainOnExit = false

  public init() {}

  public static var defaultURL: URL {
    let base =
      ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
      .map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.homeDirectoryForCurrentUser.appending(
        path: ".config"
      )
    return base.appending(path: "swmux/settings.json")
  }

  /// Loads and validates. A missing file keeps defaults. An existing
  /// file that cannot be read, is a directory, or exceeds 64 KiB fails
  /// before the whole file is loaded. Missing keys keep defaults.
  public static func load(from url: URL = defaultURL) throws -> Settings {
    guard let data = try readBounded(url, limit: 64 << 10) else {
      return Settings()
    }
    let raw: [String: Any]
    do {
      guard
        let object = try JSONSerialization.jsonObject(with: data)
          as? [String: Any]
      else { throw SettingsError("settings must be a JSON object") }
      raw = object
    } catch let e as SettingsError { throw e } catch {
      throw SettingsError("invalid JSON in \(url.path)")
    }
    var s = Settings()
    for (key, value) in raw {
      switch key {
      case "prefix":
        guard let v = value as? String, Settings.prefixByte(v) != nil else {
          throw SettingsError("prefix must look like \"C-b\"")
        }
        s.prefix = v
      case "escapeDelayMilliseconds":
        guard let v = value as? Int, (0 ... 1000).contains(v) else {
          throw SettingsError("escapeDelayMilliseconds must be 0...1000")
        }
        s.escapeDelayMilliseconds = v
      case "remainOnExit":
        guard let v = value as? Bool else {
          throw SettingsError("remainOnExit must be a boolean")
        }
        s.remainOnExit = v
      default: throw SettingsError("unknown setting \"\(key)\"")
      }
    }
    return s
  }

  /// Reads at most `limit` bytes. A missing file is `nil`.
  private static func readBounded(_ url: URL, limit: Int) throws -> Data? {
    var isDirectory: ObjCBool = false
    guard
      FileManager.default.fileExists(
        atPath: url.path,
        isDirectory: &isDirectory
      )
    else { return nil }
    guard !isDirectory.boolValue else {
      throw SettingsError("settings path is a directory")
    }
    do {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      let data = try handle.read(upToCount: limit + 1) ?? Data()
      guard data.count <= limit else {
        throw SettingsError("settings file too large")
      }
      return data
    } catch let error as SettingsError { throw error } catch {
      throw SettingsError("settings could not be read")
    }
  }

  /// The control character for `C-<letter>`.
  public static func prefixByte(_ spec: String) -> UInt8? {
    let lower = spec.lowercased()
    guard lower.hasPrefix("c-"), lower.count == 3,
      let ch = lower.last?.asciiValue,
      (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains(ch)
    else { return nil }
    return ch - 0x60
  }

  public var prefixKey: (MuxKey, MuxKeyModifiers) {
    let byte = Settings.prefixByte(prefix) ?? 0x02
    return (.character(UInt32(byte) + 0x60), .control)
  }
}

public struct SettingsError: Error, CustomStringConvertible {
  public let description: String
  init(_ description: String) { self.description = description }
}
