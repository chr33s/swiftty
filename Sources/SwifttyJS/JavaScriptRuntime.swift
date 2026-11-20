import Foundation
import JavaScriptCore

/// All JavaScript values, including callbacks, stay on one private queue.
/// Hosts exchange only strings and bytes with the VM.
///
/// Sendable: context, failure, and timer operations are serialized on `queue`.
/// Teardown cancels the timer and releases the VM context on that same queue;
/// JavaScript values never escape into callers.
///
/// Every entry into the VM is bounded by `executionTimeLimit`: callers block
/// on `queue`, so a script that never returns would otherwise stall its host
/// (the workspace service and every pane's output path). A terminated entry
/// reports one `.error` action and leaves the VM usable for the next entry.
public final class JavaScriptRuntime: @unchecked Sendable {
  /// The default bound on one entry into the VM.
  public static let defaultExecutionTimeLimit: TimeInterval = 2

  private let queue = DispatchQueue(label: "com.chr33s.swiftty.javascript")
  private var context: JSContext!
  private var failure: String?
  /// Set on `queue` by the watchdog callback when it terminates an entry.
  private var timedOut = false
  private let executionTimeLimit: TimeInterval
  private let onAction: @Sendable (JavaScriptAction) -> Void
  private let queueKey = DispatchSpecificKey<Bool>()
  private var timer: DispatchSourceTimer?

  public struct ScriptError: Error, Sendable, CustomStringConvertible {
    public let description: String
  }

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    configurationDirectory: URL = JavaScriptConfiguration.defaultDirectory,
    executionTimeLimit: TimeInterval = JavaScriptRuntime
      .defaultExecutionTimeLimit,
    onAction: @escaping @Sendable (JavaScriptAction) -> Void = { _ in }
  ) {
    self.executionTimeLimit = executionTimeLimit
    self.onAction = onAction
    queue.setSpecific(key: queueKey, value: true)
    queue.sync {
      context = JSContext(virtualMachine: JSVirtualMachine())
      installExecutionTimeLimit()
      context.exceptionHandler = { [weak self] _, exception in
        // A terminated entry is reported once, by `bounded`.
        if self?.timedOut == true { return }
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
      installJSONCBridge(in: context, directory: configurationDirectory)
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
        bounded {
          _ = context.objectForKeyedSubscript("__tick")?
            .call(withArguments: [Date().timeIntervalSince1970 * 1000])
        }
      }
      timer = source
      source.resume()
    }
  }

  public func setActivePane(_ id: String?) {
    _ = queue.sync {
      bounded {
        _ = context.objectForKeyedSubscript("__activePane")?
          .call(withArguments: [id as Any? ?? NSNull()])
      }
    }
  }

  public func refreshStatusItems(at date: Date = Date()) {
    _ = queue.sync {
      bounded {
        _ = context.objectForKeyedSubscript("__tick")?
          .call(withArguments: [date.timeIntervalSince1970 * 1000])
      }
    }
  }

  public func evaluate(_ script: String, sourceURL: URL? = nil) throws {
    try queue.sync {
      failure = nil
      let completed = bounded {
        context.evaluateScript(script, withSourceURL: sourceURL)
      }
      if !completed { throw ScriptError(description: timeLimitMessage) }
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
      var result: JSValue?
      let completed = bounded {
        result = context.objectForKeyedSubscript("__filter")?
          .call(withArguments: [
            stream.rawValue, text, pane as Any? ?? NSNull(),
          ])
      }
      guard completed, failure == nil, let result, result.isString,
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
    _ = queue.sync {
      bounded {
        _ = context.objectForKeyedSubscript("__emit")?
          .call(withArguments: [
            "command", [command, exitCode], pane as Any? ?? NSNull(),
          ])
      }
    }
  }

  public func directoryChanged(_ path: String, pane: String? = nil) {
    _ = queue.sync {
      bounded {
        _ = context.objectForKeyedSubscript("__emit")?
          .call(withArguments: ["directory", [path], pane as Any? ?? NSNull()])
      }
    }
  }

  public func statusChanged(_ change: JavaScriptStatusChange) {
    guard let data = try? JSONEncoder().encode(change),
      let json = String(data: data, encoding: .utf8)
    else { return }
    _ = queue.sync {
      bounded {
        _ = context.objectForKeyedSubscript("__status")?
          .call(withArguments: [json, change.paneId])
      }
    }
  }

  public func handleKey(_ shortcut: String, pane: String? = nil) -> Bool {
    queue.sync {
      var handled = false
      let completed = bounded {
        handled =
          context.objectForKeyedSubscript("__key")?
          .call(withArguments: [shortcut, pane as Any? ?? NSNull()])?
          .toBool() ?? false
      }
      return completed && handled
    }
  }

  // MARK: Execution time limit

  private var timeLimitMessage: String {
    "Script exceeded the \(executionTimeLimit)-second execution time limit"
  }

  /// Runs one entry into the VM on `queue`. Returns false, after reporting
  /// one error action, when the watchdog terminated it.
  @discardableResult
  private func bounded(_ body: () -> Void) -> Bool {
    timedOut = false
    body()
    guard timedOut else { return true }
    _ = context.objectForKeyedSubscript("__recover")?.call(withArguments: [])
    timedOut = false
    failure = timeLimitMessage
    onAction(JavaScriptAction(kind: .error, text: timeLimitMessage))
    return false
  }

  /// JavaScriptCore exports its watchdog only as SPI, so it is resolved at
  /// run time; `JavaScriptRuntimeTests.runawayScriptsAreTerminated` fails if
  /// an OS release drops it. The callback runs on `queue`, inside the entry
  /// it terminates. `self` outlives the context that holds the pointer:
  /// `deinit` releases the context on `queue`.
  private func installExecutionTimeLimit() {
    typealias ShouldTerminate =
      @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
    typealias SetLimit =
      @convention(c) (
        JSContextGroupRef?, Double, ShouldTerminate?, UnsafeMutableRawPointer?
      ) -> Void
    guard executionTimeLimit > 0, executionTimeLimit.isFinite,
      let symbol = dlsym(
        UnsafeMutableRawPointer(bitPattern: -2),  // RTLD_DEFAULT
        "JSContextGroupSetExecutionTimeLimit"
      )
    else {
      NSLog("Swiftty JavaScript: execution time limit unavailable")
      return
    }
    let setLimit = unsafeBitCast(symbol, to: SetLimit.self)
    setLimit(
      JSContextGetGroup(context.jsGlobalContextRef),
      executionTimeLimit,
      { _, pointer in
        guard let pointer else { return true }
        Unmanaged<JavaScriptRuntime>.fromOpaque(pointer).takeUnretainedValue()
          .timedOut = true
        return true
      },
      Unmanaged.passUnretained(self).toOpaque()
    )
  }
}
