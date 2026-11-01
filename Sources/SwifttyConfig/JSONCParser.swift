import Foundation

/// Schema-independent JSONC parsing shared by terminal settings and automation.
/// Returned bytes are validated, strict JSON; strings are never executed.
public enum JSONCParser {
  public static let maxFileBytes = 1024 * 1024

  public static func parse(
    _ source: String,
    from url: URL = URL(fileURLWithPath: "config.jsonc")
  ) throws -> Data { try JSONCDocument(source, from: url).data }

  public static func load(from url: URL) throws -> Data {
    try parse(readSource(from: url), from: url)
  }

  static func readSource(from url: URL) throws -> String {
    guard url.isFileURL,
      try url.resolvingSymlinksInPath()
        .resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
    else {
      throw ConfigError(
        url: url,
        source: "",
        offset: 0,
        detail: "Configuration must be a regular file"
      )
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: maxFileBytes + 1) ?? Data()
    guard data.count <= maxFileBytes else {
      throw ConfigError(
        url: url,
        source: "",
        offset: 0,
        detail: "Configuration exceeds \(maxFileBytes) bytes"
      )
    }
    guard let source = String(data: data, encoding: .utf8) else {
      throw ConfigError(
        url: url,
        source: "",
        offset: 0,
        detail: "Configuration must be UTF-8"
      )
    }
    return source
  }
}

struct JSONCDocument {
  let data: Data
  let index: JSONSourceIndex

  init(_ source: String, from url: URL) throws {
    do {
      data = try JSONCSanitizer.sanitizeChecked(source)
      index = try JSONSourceIndex(data)
    } catch let error as SourceFailure {
      throw ConfigError(
        url: url,
        source: source,
        offset: error.offset,
        detail: error.message
      )
    }
  }
}
