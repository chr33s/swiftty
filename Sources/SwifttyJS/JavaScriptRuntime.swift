import Foundation
import JavaScriptCore

/// All JavaScript values, including callbacks, stay on one private queue.
/// Hosts exchange only strings and bytes with the VM.
public final class JavaScriptRuntime: @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.chr33s.swiftty.javascript")
  private var context: JSContext!
  private var failure: String?
  private let queueKey = DispatchSpecificKey<Bool>()
  private var timer: DispatchSourceTimer?

  public struct ScriptError: Error, Sendable, CustomStringConvertible {
    public let description: String
  }

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    onAction: @escaping @Sendable (JavaScriptAction) -> Void = { _ in }
  ) {
    queue.setSpecific(key: queueKey, value: true)
    queue.sync {
      context = JSContext(virtualMachine: JSVirtualMachine())
      context.exceptionHandler = { [weak self] _, exception in
        let line = exception?.forProperty("line")?.toString() ?? "unknown"
        self?.failure =
          "Line \(line): \(exception?.toString() ?? "JavaScript error")"
        onAction(JavaScriptAction(kind: .error, text: self?.failure))
      }
      context.setObject(
        environment,
        forKeyedSubscript: "__environment" as NSString
      )
      // The host must enqueue actions, never synchronously re-enter this VM.
      let host: @convention(block) (String) -> Void = { json in
        guard
          let action = try? JSONDecoder()
            .decode(JavaScriptAction.self, from: Data(json.utf8))
        else { return }
        onAction(action)
      }
      let identifier: @convention(block) () -> String = { UUID().uuidString }
      context.setObject(host, forKeyedSubscript: "__host" as NSString)
      context.setObject(
        identifier,
        forKeyedSubscript: "__identifier" as NSString
      )
      context.evaluateScript(
        try! String(
          contentsOf: Bundle.module.resourceURL!
            .appendingPathComponent("Resources/runtime.js"),
          encoding: .utf8
        )
      )
    }
  }

  deinit {
    timer?.cancel()
    if DispatchQueue.getSpecific(key: queueKey) == true {
      context = nil
    } else {
      queue.sync { context = nil }
    }
  }

  /// Polling can be disabled by hosts that only need the data plane.
  public func startPolling() {
    queue.sync {
      guard timer == nil else { return }
      let source = DispatchSource.makeTimerSource(queue: queue)
      source.schedule(
        deadline: .now() + .milliseconds(100),
        repeating: .milliseconds(100)
      )
      source.setEventHandler { [weak self] in
        guard let self else { return }
        _ = context.objectForKeyedSubscript("__tick")?
          .call(withArguments: [Date().timeIntervalSince1970 * 1000])
      }
      timer = source
      source.resume()
    }
  }

  public func setActivePane(_ id: String?) {
    queue.sync {
      _ = context.objectForKeyedSubscript("__activePane")?
        .call(withArguments: [id as Any? ?? NSNull()])
    }
  }

  public func refreshStatusItems(at date: Date = Date()) {
    queue.sync {
      _ = context.objectForKeyedSubscript("__tick")?
        .call(withArguments: [date.timeIntervalSince1970 * 1000])
    }
  }

  public func evaluate(_ script: String, sourceURL: URL? = nil) throws {
    try queue.sync {
      failure = nil
      context.evaluateScript(script, withSourceURL: sourceURL)
      if let failure { throw ScriptError(description: failure) }
    }
  }

  public enum Stream: String, Sendable { case stdin, stdout }

  /// Invalid UTF-8 is preserved byte-for-byte. String filters must never
  /// silently replace binary data or incomplete UTF-8 with replacement glyphs.
  public func filter(
    _ data: Data,
    stream: Stream,
    pane: String? = nil,
    maximumBytes: Int = Int.max
  ) -> Data {
    guard let text = String(data: data, encoding: .utf8) else { return data }
    return queue.sync {
      failure = nil
      let result = context.objectForKeyedSubscript("__filter")?
        .call(withArguments: [stream.rawValue, text, pane as Any? ?? NSNull()])
      guard failure == nil, let result, result.isString,
        let output = result.toString()
      else { return data }
      guard output.utf8.count <= maximumBytes else { return data }
      return Data(output.utf8)
    }
  }

  public func commandFinished(
    command: String,
    exitCode: Int,
    pane: String? = nil
  ) {
    queue.sync {
      _ = context.objectForKeyedSubscript("__emit")?
        .call(withArguments: [
          "command", [command, exitCode], pane as Any? ?? NSNull(),
        ])
    }
  }

  public func directoryChanged(_ path: String, pane: String? = nil) {
    queue.sync {
      _ = context.objectForKeyedSubscript("__emit")?
        .call(withArguments: ["directory", [path], pane as Any? ?? NSNull()])
    }
  }

  public func statusChanged(_ change: JavaScriptStatusChange) {
    guard let data = try? JSONEncoder().encode(change),
      let json = String(data: data, encoding: .utf8)
    else { return }
    queue.sync {
      _ = context.objectForKeyedSubscript("__status")?
        .call(withArguments: [json, change.paneId])
    }
  }

  public func handleKey(_ shortcut: String, pane: String? = nil) -> Bool {
    queue.sync {
      context.objectForKeyedSubscript("__key")?
        .call(withArguments: [shortcut, pane as Any? ?? NSNull()])?
        .toBool() ?? false
    }
  }

}
