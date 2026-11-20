import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
import SwiftMuxXPC
import SwiftMuxService
import Testing
import TestSupport

/// The launcher built alongside the tests (`swift build` builds it).
func launcherPath() throws -> String { try NativeTestProducts.launcherPath() }

struct Harness {
  let service: MuxService
  let endpoint: SMXEndpoint

  init(limits: MuxLimits = .standard) throws {
    var config = MuxServiceConfiguration(launcherPath: try launcherPath())
    config.limits = limits
    try self.init(configuration: config)
  }

  init(configuration: MuxServiceConfiguration) throws {
    service = try MuxService(configuration: configuration)
    endpoint = service.listenAnonymously()
  }

  func connect(_ kind: FrontendKind = .native) async throws -> MuxConnection {
    try await MuxConnection.connect(
      endpoint: endpoint,
      frontend: kind,
      terminalProfile: kind == .terminal ? SMX.terminalProfile : nil
    )
  }
}

/// A shell with a predictable prompt and no user startup files.
func shellLaunch(_ extra: [String: String] = [:]) -> LaunchSpec {
  var env = [
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "PS1": "$ ",
    "HOME": NSTemporaryDirectory(),
  ]
  for (k, v) in extra { env[k] = v }
  return LaunchSpec(
    command: ["/bin/sh"],
    workingDirectory: "/tmp",
    environment: env
  )
}

extension MuxConnection {
  func frame(
    of pane: PaneID,
    timeout: Duration = .seconds(10),
    label: String = "",
    where predicate: (PaneFrame) -> Bool
  ) async throws -> PaneFrame {
    let deadline = ContinuousClock.now + timeout
    var last = "no frame"
    while ContinuousClock.now < deadline {
      let remaining = deadline - ContinuousClock.now
      if remaining <= .zero { break }
      let event: MuxEvent?
      do {
        event = try await withTimeout(remaining) { try await self.nextEvent() }
      } catch is TimeoutError { break }
      guard let event else { continue }
      if case let .frameUnavailable(id, error) = event, id == pane {
        last = "unavailable \(error.code) \(error.message)"
      }
      if case let .frame(f) = event, f.identity.pane == pane {
        let tail = f.lines.joined(separator: " | ")
        last =
          "rev=\(f.identity.revision) gen=\(f.history.generation) "
          + "top=\(f.history.viewportTop) first=\(f.history.firstRow) "
          + "off=\(f.history.viewportOffset) sb=\(f.history.scrollbackRows) "
          + "grid=\(f.grid.columns)x\(f.grid.rows) [\(tail)]"
        if predicate(f) { return f }
      }
    }
    let prefix = label.isEmpty ? "" : "\(label): "
    throw MuxError(
      .notFound,
      "\(prefix)timed out waiting for frame; last \(last)"
    )
  }

  /// Attach, size and subscribe the active tab's panes.
  @discardableResult
  func attachAndShow(
    _ selector: WorkspaceSelector,
    columns: Int = 80,
    rows: Int = 24,
    generation: UInt64 = 1
  ) async throws -> WorkspaceSnapshot {
    guard
      case let .attached(_, ws) = try await execute(
        .attach(AttachRequest(selector))
      )
    else { throw MuxError(.invalidRequest, "attach reply") }
    let panes = ws.activeTabSnapshot!.layout.panes
    try await execute(
      .setGeometry(
        GeometryBatch(
          layoutRevision: ws.layoutRevision,
          generation: generation,
          entries: panes.map { .init(pane: $0, columns: columns, rows: rows) }
        )
      )
    )
    try await execute(.setSubscriptions(panes))
    return ws
  }
}

struct TimeoutError: Error {}

func withTimeout<T: Sendable>(
  _ duration: Duration,
  _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await body() }
    group.addTask {
      try await Task.sleep(for: duration)
      throw TimeoutError()
    }
    let value = try await group.next()!
    group.cancelAll()
    return value
  }
}
