import SwiftMuxGuardian
import SwiftMuxProtocol
import SwiftMuxXPC

/// Bounded owner of native routes. The directory is monitored by its caller.
/// Selections reuse listeners; each accepted connection still validates authority.
package actor GatewayNativeRoutes {
  private struct Route {
    let authority: GuardianAuthority
    let listener: GatewayNativeEndpoint
  }

  private let supervisor: GatewaySupervisor
  private let directory: GatewayWorkspaceDirectory
  private let peerRequirement: String?
  private let capacity: Int
  private let admission: GatewayNativeAdmission
  private var routes: [WorkspaceID: Route] = [:]
  private var busy = false
  private var closed = false

  package init(
    supervisor: GatewaySupervisor,
    directory: GatewayWorkspaceDirectory,
    peerRequirement: String?,
    capacity: Int = 32,
    connectionLimit: Int = 64
  ) throws {
    guard capacity > 0, capacity <= 4096 else {
      throw MuxError(.invalidRequest, "invalid native route capacity")
    }
    self.supervisor = supervisor
    self.directory = directory
    self.peerRequirement = peerRequirement
    self.capacity = capacity
    admission = try GatewayNativeAdmission(limit: connectionLimit)
  }

  package var routeCount: Int { routes.count }
  package var connectionCount: Int { admission.count }

  package func endpoint(
    for selector: WorkspaceSelector,
    expectedAuthority: GuardianAuthority? = nil
  ) async throws -> SMXEndpoint {
    try begin()
    defer { busy = false }
    try await prune()
    let authority = try await directory.nativeAuthority(for: selector)
    try checkOpen()
    guard expectedAuthority == nil || expectedAuthority == authority else {
      throw MuxError(.staleAttachment, "selected workspace authority changed")
    }
    if let route = routes[authority.workspace] {
      guard route.authority == authority else {
        throw MuxError(
          .staleAttachment,
          "workspace authority changed during selection"
        )
      }
      return route.listener.endpoint
    }
    guard routes.count < capacity else {
      throw MuxError(.resourceLimit, "native route capacity exhausted")
    }
    let listener = try GatewayNativeEndpoint(
      supervisor: supervisor,
      authority: authority,
      peerRequirement: peerRequirement,
      capacity: 256,
      admission: admission
    )
    routes[authority.workspace] = Route(
      authority: authority,
      listener: listener
    )
    return listener.endpoint
  }

  /// Call after inventory changes, or before selection (done automatically).
  /// Retirement disconnects frontend transports, never guardian-owned processes.
  package func reconcile() async throws {
    try begin()
    defer { busy = false }
    try await prune()
  }

  package func close() async {
    closed = true
    // Keep entries until cancelled so a concurrent close also drains them.
    for route in Array(routes.values) { await route.listener.close() }
    routes.removeAll()
  }

  private func begin() throws {
    try checkOpen()
    guard !busy else {
      throw MuxError(.quiescing, "native routes are reconciling")
    }
    busy = true
  }

  private func checkOpen() throws {
    try Task.checkCancellation()
    guard !closed else {
      throw MuxError(.connectionLost, "native routes closed")
    }
  }

  private func prune() async throws {
    let records = await directory.records
    try checkOpen()
    let available = records.filter {
      if case .available = $0.state { true } else { false }
    }
    for (id, route) in Array(routes) {
      guard
        !available.contains(where: { $0.inventory.authority == route.authority }
        )
      else { continue }
      await route.listener.close()
      routes.removeValue(forKey: id)
      try checkOpen()
    }
  }
}
