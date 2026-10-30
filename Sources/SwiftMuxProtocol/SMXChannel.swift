// Local XPC transport: macOS only. The message types in this module are
// Foundation-only, so attention links (MuxNavigation) build everywhere.
#if os(macOS)
import Darwin
import Dispatch
import Foundation
import Synchronization
import XPC

/// One XPC connection carrying SMX records as `Data` payloads. XPC supplies
/// message boundaries and ordering; this type only frames bytes.
/// Handlers run on `queue`.
///
/// Sendable: `handler`, `closed`, and `recordLimit` are written once by
/// `activate` (enforced by `activated`) before `xpc_connection_activate`
/// and thereafter only on `queue`, the connection's target queue. The retained `xpc_connection_t` lives as
/// long as the channel; `send` and `cancel` are thread-safe XPC calls.
public final class SMXChannel: @unchecked Sendable {
  public enum Event: Sendable {
    case message(Data)
    /// The connection ended; no further events follow.
    case closed(String)
  }

  public let queue: DispatchQueue
  private let connection: xpc_connection_t
  /// `activate` runs once: its writes precede every event.
  private let activated = Atomic(false)
  private var handler: (@Sendable (Event) -> Void)?
  private var closed = false
  private var recordLimit: @Sendable () -> Int = {
    SMXCodec.serverRecordLimit(.standard)
  }

  init(connection: xpc_connection_t, queue: DispatchQueue) {
    self.connection = connection
    self.queue = queue
    xpc_connection_set_target_queue(connection, queue)
  }

  /// Connects to a launchd Mach service.
  public static func connect(
    machService name: String,
    queue: DispatchQueue
  ) -> SMXChannel {
    SMXChannel(
      connection: xpc_connection_create_mach_service(name, queue, 0),
      queue: queue
    )
  }

  /// Connects to an anonymous listener's endpoint (tests, in-process use).
  public static func connect(
    endpoint: SMXEndpoint,
    queue: DispatchQueue
  ) -> SMXChannel {
    SMXChannel(
      connection: xpc_connection_create_from_endpoint(endpoint.endpoint),
      queue: queue
    )
  }

  /// Peer effective user id (OS-provided, not claimed in a message).
  public var peerEUID: uid_t { xpc_connection_get_euid(connection) }
  public var peerPID: pid_t { xpc_connection_get_pid(connection) }

  /// Requires the peer to satisfy a code-signing requirement string.
  public func requirePeer(codeSigning requirement: String) -> Bool {
    xpc_connection_set_peer_code_signing_requirement(connection, requirement)
      == 0
  }

  /// Checks the current receive limit before copying an XPC payload into Data.
  /// The limit closure runs on `queue`, allowing negotiated limits to change.
  public func activate(
    recordLimit: @escaping @Sendable () -> Int = {
      SMXCodec.serverRecordLimit(.standard)
    },
    _ handler: @escaping @Sendable (Event) -> Void
  ) {
    let (first, _) = activated.compareExchange(
      expected: false,
      desired: true,
      ordering: .acquiringAndReleasing
    )
    precondition(first, "an SMXChannel is activated once")
    self.recordLimit = recordLimit
    self.handler = handler
    xpc_connection_set_event_handler(connection) { [weak self] object in
      self?.receive(object)
    }
    xpc_connection_activate(connection)
  }

  private func receive(_ object: xpc_object_t) {
    guard !closed else { return }
    if xpc_get_type(object) == XPC_TYPE_DICTIONARY {
      var length = 0
      guard let bytes = xpc_dictionary_get_data(object, "d", &length) else {
        return
      }
      let limit = recordLimit()
      guard length <= limit else {
        finish("record exceeds \(limit) bytes")
        return
      }
      handler?(.message(Data(bytes: bytes, count: length)))
      return
    }
    let reason =
      xpc_dictionary_get_string(object, XPC_ERROR_KEY_DESCRIPTION)
      .map { String(cString: $0) } ?? "connection closed"
    finish(reason)
  }

  private func finish(_ reason: String) {
    guard !closed else { return }
    closed = true
    // Interruption leaves native XPC live and able to reconnect on send.
    // Our closed event is terminal, including sends from its callback.
    xpc_connection_cancel(connection)
    let h = handler
    handler = nil
    h?(.closed(reason))
  }

  public func send(_ data: Data) {
    let message = xpc_dictionary_create_empty()
    data.withUnsafeBytes { buffer in
      xpc_dictionary_set_data(message, "d", buffer.baseAddress!, buffer.count)
    }
    xpc_connection_send_message(connection, message)
  }

  public func cancel() { xpc_connection_cancel(connection) }
}

/// An endpoint for connecting to an anonymous listener.
///
/// Sendable: none: immutable after init. The retained `xpc_endpoint_t` is an
/// immutable, thread-safe XPC object that lives as long as any copy.
public struct SMXEndpoint: @unchecked Sendable { let endpoint: xpc_endpoint_t }

/// Accepts XPC connections on a Mach service name, or anonymously.
///
/// Sendable: none: immutable after init. Events arrive on `queue`; the
/// retained listener `xpc_connection_t` lives as long as the listener and is
/// used only through thread-safe XPC calls.
public final class SMXListener: @unchecked Sendable {
  private let listener: xpc_connection_t
  private let queue: DispatchQueue

  /// A launchd-registered Mach service listener.
  public init(machService name: String, queue: DispatchQueue) {
    self.queue = queue
    listener = xpc_connection_create_mach_service(
      name,
      queue,
      UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER)
    )
  }

  /// An anonymous listener reachable through `endpoint`.
  public init(anonymousOn queue: DispatchQueue) {
    self.queue = queue
    listener = xpc_connection_create(nil, queue)
  }

  public var endpoint: SMXEndpoint {
    SMXEndpoint(endpoint: xpc_endpoint_create(listener))
  }

  /// Each accepted connection gets its own channel on `connectionQueue`.
  public func activate(
    connectionQueue: DispatchQueue,
    _ accept: @escaping @Sendable (SMXChannel) -> Void
  ) {
    xpc_connection_set_event_handler(listener) { object in
      guard xpc_get_type(object) == XPC_TYPE_CONNECTION else { return }
      accept(SMXChannel(connection: object, queue: connectionQueue))
    }
    xpc_connection_activate(listener)
  }

  public func cancel() { xpc_connection_cancel(listener) }
}
#endif
