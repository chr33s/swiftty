import Dispatch
import Network
import Synchronization

/// A summary of the device's network path. A reachability hint only
/// (spec §9): it never proves the peer is alive or that a working
/// connection must be replaced.
public struct NetworkPathStatus: Equatable, Sendable {
  public enum Interface: String, Sendable, CaseIterable {
    case wifi, cellular, wiredEthernet, loopback, other
  }

  public var isSatisfied: Bool
  public var isExpensive: Bool
  public var isConstrained: Bool
  public var interfaces: Set<Interface>

  public init(
    isSatisfied: Bool,
    isExpensive: Bool = false,
    isConstrained: Bool = false,
    interfaces: Set<Interface> = []
  ) {
    self.isSatisfied = isSatisfied
    self.isExpensive = isExpensive
    self.isConstrained = isConstrained
    self.interfaces = interfaces
  }

  init(_ path: NWPath) {
    var interfaces: Set<Interface> = []
    for kind in [
      (NWInterface.InterfaceType.wifi, Interface.wifi), (.cellular, .cellular),
      (.wiredEthernet, .wiredEthernet), (.loopback, .loopback),
      (.other, .other),
    ] where path.usesInterfaceType(kind.0) { interfaces.insert(kind.1) }
    self.init(
      isSatisfied: path.status == .satisfied,
      isExpensive: path.isExpensive,
      isConstrained: path.isConstrained,
      interfaces: interfaces
    )
  }
}

/// A small `NWPathMonitor` wrapper that reports distinct path summaries.
public final class PathMonitor: Sendable {
  private let monitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "rst.path.monitor")
  private let last = LastStatus()

  public init() {}

  public var current: NetworkPathStatus? { last.value }

  /// Starts monitoring; `onChange` runs on a private serial queue for
  /// each distinct status. Call once.
  public func start(onChange: @escaping @Sendable (NetworkPathStatus) -> Void) {
    monitor.pathUpdateHandler = { [last] path in
      let status = NetworkPathStatus(path)
      if last.update(status) { onChange(status) }
    }
    monitor.start(queue: queue)
  }

  public func cancel() { monitor.cancel() }
}

private final class LastStatus: Sendable {
  private let status = Mutex<NetworkPathStatus?>(nil)

  var value: NetworkPathStatus? { status.withLock { $0 } }

  /// Records `new`; returns whether it differs from the previous value.
  func update(_ new: NetworkPathStatus) -> Bool {
    status.withLock { previous in
      defer { previous = new }
      return previous != new
    }
  }
}
