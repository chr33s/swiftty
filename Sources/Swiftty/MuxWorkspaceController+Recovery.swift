import AppKit
import SwiftMuxClient
import SwiftMuxProtocol

extension MuxWorkspaceController {
  /// Only transport loss of a live attachment starts this operation. Lease
  /// revocation and explicit detach never automatically seek a new lease.
  func recoverGatewayAttachment() {
    guard gatewayRecovery == nil, !isClosed, let workspace = attachedWorkspace,
      let reconnect = reconnectGateway
    else { return }
    gatewayRecovery = Task { [weak self] in
      guard let self else { return }
      defer { gatewayRecovery = nil }
      window?.subtitle = "Reconnecting…"
      do {
        let gateway = try await MuxGatewayRecovery.waitForWorkspace(
          workspace,
          reconnect: reconnect
        )
        try Task.checkCancellation()
        guard !isClosed else { return }
        let frame = window?.frame
        let visible = window?.isVisible == true
        let replaced = onReplaced
        // The normal replacement path owns candidate disposal and checks that
        // this window is still open before committing. Its successful detach
        // must not cancel the very task publishing the replacement.
        gatewayRecovery = nil
        let replacement = try await Self.replace(
          self,
          with: .id(workspace),
          configuration: config,
          gateway: gateway
        )
        replacement.reconnectGateway = reconnect
        if let frame { replacement.window?.setFrame(frame, display: false) }
        replaced?(replacement)
        if visible { replacement.window?.orderFront(nil) }
      } catch is CancellationError {
        // Closing or quitting cancels recovery without an error prompt.
      } catch {
        guard !isClosed else { return }
        window?.subtitle = DisplayText.sanitize("Reconnect failed: \(error)")
      }
    }
  }

}
