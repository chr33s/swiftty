import ScreenProtocol
import SessionCore
import SwifttyEngine

// Small seams bridged to concrete modules at integration time: the
// frame display, the SSH exec bootstrap, the QUIC connector and the
// ordinary SSH shell channel.

/// Displays complete presentation frames (spec §A.4.3). A GUI frontend's
/// presentation-mode session or a TTY renderer conforms at integration.
///
/// Called from the client's serialized owner, never from the UI executor;
/// implementations hop to their own executor as needed.
public protocol PresentationSink: AnyObject, Sendable {
  /// Replaces the visible state atomically. Returns false when the frame
  /// was refused (for example, the sink is closed).
  @discardableResult
  func install(_ frame: PresentationFrame) -> Bool
}

/// Failures to obtain an authenticated bootstrap response. An
/// authenticated refusal is a `BootstrapResponse.failure` instead, so the
/// client can tell "temporarily unreachable" from "session no longer
/// exists" (spec §9).
public enum RemoteBootstrapError: Error, Hashable, Sendable {
  /// No SSH connection, or the exec channel failed before a response.
  case unreachable
  /// The SSH host key is unknown or changed: automatic reconnection is
  /// blocked until the user decides (spec §5.1).
  case hostKeyRejected
  case authenticationFailed
  /// The selected client key could not be read (deleted, not on this
  /// device, or the device is locked). No credential was offered.
  case credentialUnavailable
  /// The helper answered with malformed or unexpected output.
  case protocolViolation
}

/// Runs `swifttyd bootstrap --stdio` over a no-PTY SSH exec channel
/// (spec §5.1). Implemented by SSHClient at integration.
public protocol RemoteBootstrapper: Sendable {
  /// Sends one request and returns the helper's authenticated response.
  /// Throws `RemoteBootstrapError` only when no authenticated response
  /// was obtained.
  func bootstrap(_ request: BootstrapRequest) async throws -> BootstrapResponse
}

/// Opens an RST/1 connection to a granted endpoint (spec §5.3). The
/// connector verifies the exact SSH-delivered certificate before
/// returning; pinning is its job, not the client's.
public protocol RSTConnector: Sendable {
  /// Returns a connection whose TLS handshake has completed against the
  /// grant's pinned certificate. Throws when unreachable or pinning fails.
  func connect(to grant: BootstrapGrant) async throws -> any RSTConnection
}

/// How an ordinary SSH shell channel ended.
public enum TerminalChannelExit: Hashable, Sendable {
  /// The remote program exited with this status.
  case exited(Int32)
  /// The remote program was killed by a signal.
  case signaled(String)
  /// The channel or connection closed without an exit status.
  case disconnected
}

/// Events from an ordinary SSH shell channel.
public struct TerminalChannelHandler: Sendable {
  /// Program output (stdout of the PTY). Calls are serialized and stop
  /// once the granted credit is used up.
  public var onOutput: @Sendable ([UInt8]) -> Void
  /// Delivered once, after all output.
  public var onExit: @Sendable (TerminalChannelExit) -> Void

  public init(
    onOutput: @escaping @Sendable ([UInt8]) -> Void,
    onExit: @escaping @Sendable (TerminalChannelExit) -> Void
  ) {
    self.onOutput = onOutput
    self.onExit = onExit
  }
}

/// An ordinary SSH session channel with a remote PTY (spec §A.3.B).
/// Only terminal-session bytes travel here; SFTP and exec use their own
/// channels.
///
/// Output is credit-based: the channel delivers output only while it holds
/// credit, consuming credit by the number of bytes delivered. A single
/// delivery may exceed the remaining credit by at most one transport read,
/// and stops further reads (and the SSH window) until more credit arrives.
public protocol TerminalByteChannel: AnyObject, Sendable {
  /// Starts delivery with no credit. Call once.
  func start(_ handler: TerminalChannelHandler)
  /// Allows `bytes` more output to be delivered.
  func grantCredit(_ bytes: Int)
  /// Writes to the remote PTY; returns once the channel accepted the
  /// bytes under its flow control.
  func write(_ bytes: [UInt8]) async throws
  /// Sends an SSH window-change request.
  func resize(columns: Int, rows: Int) async throws
  /// Sends an SSH window-change request carrying the pixel size too, for
  /// programs that size images by it (`kitten icat`, spec.graphics.md §16).
  func resize(
    columns: Int,
    rows: Int,
    pixelWidth: Int,
    pixelHeight: Int
  ) async throws
  /// Closes the channel. Idempotent.
  func close() async
}

extension TerminalByteChannel {
  /// Channels without pixel sizes send the character grid only.
  public func resize(
    columns: Int,
    rows: Int,
    pixelWidth: Int,
    pixelHeight: Int
  ) async throws { try await resize(columns: columns, rows: rows) }
}
