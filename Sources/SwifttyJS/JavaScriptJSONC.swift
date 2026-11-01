import Foundation
import JavaScriptCore
import SwifttyConfig

/// Returns plain bridge values. Throwing happens in JavaScript, so scripts can
/// catch a parse error without triggering the runtime's uncaught-error handler.
func installJSONCBridge(in context: JSContext, directory: URL) {
  let bridge: @convention(block) (String, String) -> NSDictionary = {
    operation,
    input in
    do {
      let data: Data
      switch operation {
      case "parse":
        guard input.utf8.count <= JSONCParser.maxFileBytes else {
          return ["error": "JSONC input exceeds 1 MiB", "syntax": false]
        }
        data = try JSONCParser.parse(
          input,
          from: directory.appendingPathComponent("<jsonc>")
        )
      case "read":
        guard !input.isEmpty, !input.contains("\0") else {
          return [
            "error": "JSONC path must be nonempty and contain no NUL",
            "syntax": false,
          ]
        }
        let expanded = (input as NSString).expandingTildeInPath
        let url =
          expanded.hasPrefix("/")
          ? URL(fileURLWithPath: expanded)
          : directory.appendingPathComponent(expanded)
        data = try JSONCParser.load(from: url)
      default: return ["error": "Unknown JSONC operation", "syntax": false]
      }
      return ["json": String(decoding: data, as: UTF8.self)]
    } catch let error as ConfigError {
      return [
        "error": error.message, "syntax": true, "line": error.line,
        "column": error.column,
      ]
    } catch { return ["error": error.localizedDescription, "syntax": false] }
  }
  context.setObject(bridge, forKeyedSubscript: "__jsonc" as NSString)
}
