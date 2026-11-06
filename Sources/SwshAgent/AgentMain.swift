#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import SwifttyExec

/// `swsh --agent`: swsh's headless interface for tools. Newline-delimited JSON
/// requests arrive on standard input and one result line each leaves on
/// standard output. The loop starts no shell session and reads no
/// configuration, history, or environment.
///
/// swsh makes a request precise and reports exactly what happened; it does not
/// decide whether a request is allowed or where it runs. Those belong to the
/// execution service, which starts swsh inside an execution context. A
/// preview is pure and needs no context. Without a context, `run` is answered
/// `no_context` and nothing is run: there is no fallback to the host. That
/// refusal prevents an accident; it is not a security boundary.
public enum AgentMain {
  public static func run() -> Int32 {
    var pending: [UInt8] = []
    var discarding = false
    var chunk = [UInt8](repeating: 0, count: 65536)
    while true {
      let count = chunk.withUnsafeMutableBytes {
        read(STDIN_FILENO, $0.baseAddress, $0.count)
      }
      if count < 0 {
        if errno == EINTR { continue }
        return 1
      }
      if count == 0 { break }
      var bytes = chunk[..<count]
      while !bytes.isEmpty {
        let newline = bytes.firstIndex(of: 10)
        let line = bytes[..<(newline ?? bytes.endIndex)]
        bytes = bytes[(newline.map { $0 + 1 } ?? bytes.endIndex)...]
        if !discarding {
          pending.append(contentsOf: line)
          if pending.count > WireLimits.frameBytes {
            // Answer once, then drop the rest of the frame without keeping it.
            pending = []
            discarding = true
            guard write(oversized) else { return 1 }
          }
        }
        guard newline != nil else { break }
        if discarding {
          discarding = false
        } else {
          let frame = pending
          pending = []
          if let result = respond(frame) {
            guard write(result) else { return 1 }
          }
        }
      }
    }
    // Input that ends inside a frame is not a request.
    return 0
  }

  private static var oversized: RunnerResult {
    RunnerResult(
      Rejected(
        requestID: nil,
        outcome: .invalidRequest,
        reason: "frame exceeds \(WireLimits.frameBytes) bytes"
      )
    )
  }

  /// nil for a blank line.
  static func respond(_ frame: [UInt8]) -> RunnerResult? {
    guard frame.contains(where: { ![32, 9, 13].contains($0) }) else {
      return nil
    }
    do {
      let request = try RunnerRequest.decode(frame)
      switch (request.operation, request.work) {
      case (.preview, .pipeline(let stages)):
        // Typed stages are literal, so every value is known exactly.
        var result = RunnerResult(request, .previewed, nil)
        result.stages = stages
        return result
      case (.preview, .source):
        return RunnerResult(
          request,
          .unsupportedOperation,
          "previews of shell source are not implemented; nothing was run"
        )
      case (.run, _):
        return RunnerResult(
          request,
          .noContext,
          "no execution context was supplied; nothing was run"
        )
      }
    } catch let rejected as Rejected { return RunnerResult(rejected) } catch {
      return RunnerResult(
        Rejected(requestID: nil, outcome: .invalidRequest, reason: "\(error)")
      )
    }
  }

  private static func output(
    _ fd: Int32,
    _ bytes: UnsafeRawPointer?,
    _ count: Int
  ) -> Int {
    #if canImport(Darwin)
    Darwin.write(fd, bytes, count)
    #else
    Glibc.write(fd, bytes, count)
    #endif
  }

  private static func write(_ result: RunnerResult) -> Bool {
    let bytes = result.encoded()
    var offset = 0
    while offset < bytes.count {
      let written = bytes[offset...]
        .withUnsafeBytes { output(STDOUT_FILENO, $0.baseAddress, $0.count) }
      if written < 0 {
        if errno == EINTR { continue }
        return false
      }
      offset += written
    }
    return true
  }
}
