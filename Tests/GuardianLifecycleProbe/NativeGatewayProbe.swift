import Darwin
import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
import SwiftMuxService

extension GuardianLifecycleProbe {
  /// Runs in a separate signed process with no guardian connection or runtime.
  static func nativeGatewayClient(_ args: [String]) async throws {
    guard (4 ... 5).contains(args.count),
      args[1].hasPrefix("com.chr33s.swiftty.durability-probe."),
      let workspace = WorkspaceID(args[2]),
      ["create", "inspect", "end", "list"].contains(args[3])
    else {
      throw MuxError(.invalidRequest, "invalid native client fixture arguments")
    }
    let control = try await MuxGatewayConnection.connect(
      peerRequirement: PeerSigningPolicy.requirementForCurrentProcess(),
      channel: { .connect(machService: args[1], queue: $0) }
    )
    do {
      if args[3] == "list" {
        print(
          String(
            decoding: try JSONEncoder()
              .encode(try await control.listWorkspaces()),
            as: UTF8.self
          )
        )
      } else if args[3] == "end" {
        try await control.endWorkspace(.id(workspace))
        let deadline = ContinuousClock.now + .seconds(5)
        while try await control.listWorkspaces()
          .contains(where: { $0.workspace == workspace })
        {
          guard ContinuousClock.now < deadline else {
            throw MuxError(.quiescing, "retired workspace still listed")
          }
          try await Task.sleep(for: .milliseconds(25))
        }
        print("retired")
      } else {
        if args[3] == "create" {
          try await control.createWorkspace(
            workspace,
            request: NewWorkspaceRequest(
              name: "independent-frontend",
              launch: LaunchSpec(
                command: ["/bin/sh", "-i"],
                environment: ["PATH": "/usr/bin:/bin", "PS1": "$ "]
              )
            )
          )
        }
        let deadline = ContinuousClock.now + .seconds(15)
        while try await !control.listWorkspaces()
          .contains(where: {
            $0.workspace == workspace && $0.state == .available
          })
        {
          guard ContinuousClock.now < deadline else {
            throw MuxError(.notAttached, "native workspace not ready")
          }
          try await Task.sleep(for: .milliseconds(25))
        }
        let session = MuxGatewaySession(gateway: control)
        let selected = try await session.select(.id(workspace))
        let client = selected.connection
        do {
          let graph = selected.workspace
          let server = selected.welcome.server
          guard let tab = graph.activeTabSnapshot else {
            throw MuxError(.notAttached, "missing native attachment")
          }
          let pane = tab.activePane
          _ = try await client.execute(
            .setGeometry(
              GeometryBatch(
                layoutRevision: graph.layoutRevision,
                generation: 1,
                entries: [.init(pane: pane, columns: 120, rows: 24)]
              )
            )
          )
          _ = try await client.execute(.setSubscriptions([pane]))
          if args[3] == "create" {
            try await client.send(.text("set +H\r"), to: pane)
          }
          let marker =
            "proof_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
          let setup =
            args[3] == "create"
            ? "SWMUX_PROBE=durable; set -m; sleep 300 & SWMUX_JOB=$!; " : ""
          try await client.send(
            .text(
              setup
                + "printf '\(marker)=%s:%s:%s:%s\\n' \"$SWMUX_PROBE\" \"$$\" \"$SWMUX_JOB\" \"$-\"\r"
            ),
            to: pane
          )
          let deadline = ContinuousClock.now + .seconds(10)
          var proof: String?
          while proof == nil, ContinuousClock.now < deadline {
            if case let .frame(frame) = try await client.nextEvent(
              timeout: .seconds(2)
            ),
              let line = frame.lines.first(where: {
                $0.hasPrefix(marker + "=durable:")
              })
            {
              if args.count == 5, !frame.lines.contains(args[4]) {
                throw MuxError(
                  .invalidRequest,
                  "previous terminal output was lost"
                )
              }
              proof = line
            }
          }
          guard let proof else {
            throw MuxError(.connectionLost, "native terminal proof timed out")
          }
          let result = [
            "frontend": String(getpid()),
            "workspace": String(describing: workspace),
            "server": String(describing: server),
            "tab": String(describing: tab.id), "pane": String(describing: pane),
            "proof": proof,
          ]
          print(
            String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
          )
          await session.close()
        } catch {
          await session.close();
          throw error
        }
      }
      await control.close()
    } catch {
      await control.close();
      throw error
    }
  }
}
