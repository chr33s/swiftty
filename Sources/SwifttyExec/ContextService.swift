/// Controls a backend must enforce itself before it may start a context.
enum BackendFeature: String, CaseIterable, Sendable {
  case filesystemIsolation = "filesystem_isolation"
  case networkDisabled = "network_disabled"
  case noAmbientCredentials = "no_ambient_credentials"
  case transitiveConfinement = "transitive_confinement"
  case resourceLimits = "resource_limits"
  case contextTeardown = "context_teardown"
  case controlledExport = "controlled_export"
}

/// Authority for one session. Grants come from trusted controls: nothing in a
/// request, a repository, or a workload's output can create or widen one. A
/// grant is about resources; it names no command.
struct Grant: Sendable {
  let sessionID: String
  var images: Set<String>
  var snapshots: Set<String>
  var maximumWallMilliseconds: Int
  var maximumOutputBytes: Int
  /// Cumulative wall time across every context of the session.
  var sessionWallMilliseconds: Int
  var maximumRequests: Int
  /// Seconds on the service's clock; nil never expires.
  var expiresAt: UInt64?
}

/// A `create` that passed admission, with the limits that actually apply.
struct AdmittedContext: Equatable, Sendable {
  let identity: String
  let sessionID: String
  let requestID: String
  let create: ContextRequest.Create
  let wallMilliseconds: Int
  let outputBytes: Int
}

enum CreateOutcome: Equatable, Sendable {
  /// The backend established that no context exists.
  case notStarted(String)
  /// The backend lost track of the context; it may exist.
  case unknown(String)
}

protocol ContextBackend {
  var name: String { get }
  /// Only controls the backend enforces independently of the workload.
  var features: Set<BackendFeature> { get }
  func create(_ context: AdmittedContext) -> CreateOutcome
}

/// The only backend so far. It enforces nothing, so admission never reaches
/// `create`, and it could not start a context if it did. The service process
/// that would own a `ContextService` does not exist yet.
struct RefusingBackend: ContextBackend {
  let name = "none"
  let features: Set<BackendFeature> = []
  func create(_ context: AdmittedContext) -> CreateOutcome {
    .notStarted("no execution backend is available")
  }
}

package struct ContextResult: Equatable, Sendable {
  enum Effects: String, Sendable { case none, started, unknown }
  enum Cleanup: String, Sendable {
    case notNeeded = "not_needed"
    case complete, incomplete, unknown
  }
  struct Scope: Equatable, Sendable {
    let image: String
    let snapshots: [String]
    let wallMilliseconds: Int
    let outputBytes: Int
  }

  package var requestID: String?
  package var outcome: Outcome
  var reason: String?
  var identity: String?
  var backend: String?
  var effects = Effects.none
  var cleanup = Cleanup.notNeeded
  var replayed = false
  var missingFeatures: [String] = []
  var scope: Scope?

  package init(_ rejected: Rejected) {
    requestID = rejected.requestID
    outcome = rejected.outcome
    reason = rejected.reason
  }

  init(
    requestID: String,
    identity: String,
    _ outcome: Outcome,
    _ reason: String
  ) {
    self.requestID = requestID
    self.identity = identity
    self.outcome = outcome
    self.reason = reason
  }

  /// One line of ASCII JSON. Every field is produced by the service.
  package func encoded() -> [UInt8] {
    func list(_ values: [String]) -> String {
      "[" + values.map { Wire.quote($0) }.joined(separator: ",") + "]"
    }
    var members = [
      "\"protocol\":" + Wire.quote(ContextRequest.version),
      "\"requestId\":" + Wire.quote(requestID),
      "\"outcome\":" + Wire.quote(outcome.rawValue),
      "\"reason\":" + Wire.quote(reason),
      "\"requestIdentity\":" + Wire.quote(identity),
      "\"backend\":" + Wire.quote(backend),
      "\"effects\":" + Wire.quote(effects.rawValue),
      "\"cleanup\":" + Wire.quote(cleanup.rawValue),
      "\"replayed\":" + (replayed ? "true" : "false"),
      "\"missingFeatures\":" + list(missingFeatures),
    ]
    if let scope {
      members.append(
        "\"scope\":{\"image\":" + Wire.quote(scope.image) + ",\"snapshots\":"
          + list(scope.snapshots)
          + ",\"network\":\"none\",\"wallMilliseconds\":"
          + String(scope.wallMilliseconds) + ",\"outputBytes\":"
          + String(scope.outputBytes) + "}"
      )
    } else {
      members.append("\"scope\":null")
    }
    return Array(("{" + members.joined(separator: ",") + "}\n").utf8)
  }
}

/// Admits context requests against grants and a backend's advertised
/// controls. One serial caller owns a service, so each reservation is atomic.
final class ContextService {
  private struct Session {
    var grant: Grant
    var remainingWallMilliseconds: Int
    var records: [String: ContextResult] = [:]
  }
  private var sessions: [String: Session]
  private let backend: any ContextBackend
  private let now: () -> UInt64

  init(
    grants: [Grant],
    backend: any ContextBackend,
    now: @escaping () -> UInt64
  ) {
    sessions = Dictionary(
      grants.map {
        (
          $0.sessionID,
          Session(
            grant: $0,
            remainingWallMilliseconds: $0.sessionWallMilliseconds
          )
        )
      },
      uniquingKeysWith: { first, _ in first }
    )
    self.backend = backend
    self.now = now
  }

  func remainingWallMilliseconds(session: String) -> Int? {
    sessions[session]?.remainingWallMilliseconds
  }

  func handle(_ request: ContextRequest) -> ContextResult {
    let identity = request.identity
    func result(_ outcome: Outcome, _ reason: String) -> ContextResult {
      ContextResult(
        requestID: request.requestID,
        identity: identity,
        outcome,
        reason
      )
    }
    // An unknown session gets no accounting and learns nothing else.
    guard var session = sessions[request.sessionID] else {
      return result(.policyDenied, "no grant for this session")
    }
    // A repeated request ID returns the first decision; it never creates or
    // charges twice.
    if var record = session.records[request.requestID] {
      guard record.identity == identity else {
        return result(
          .requestConflict,
          "this request ID was used for a different request"
        )
      }
      record.replayed = true
      return record
    }
    guard session.records.count < session.grant.maximumRequests else {
      return result(.budgetExhausted, "the session's request budget is spent")
    }
    let decision = admit(request, identity, &session)
    session.records[request.requestID] = decision
    sessions[request.sessionID] = session
    return decision
  }

  private func admit(
    _ request: ContextRequest,
    _ identity: String,
    _ session: inout Session
  ) -> ContextResult {
    func result(_ outcome: Outcome, _ reason: String) -> ContextResult {
      ContextResult(
        requestID: request.requestID,
        identity: identity,
        outcome,
        reason
      )
    }
    let grant = session.grant
    if let expiry = grant.expiresAt, now() >= expiry {
      return result(.policyDenied, "the session's grant has expired")
    }
    guard case .create(let create) = request.operation else {
      // No backend can have created a context yet.
      return result(.unknownContext, "no such context in this session")
    }
    guard grant.images.contains(create.image) else {
      return result(.policyDenied, "the image is outside the session's grant")
    }
    guard create.snapshots.allSatisfy(grant.snapshots.contains) else {
      return result(
        .policyDenied,
        "an input snapshot is outside the session's grant"
      )
    }
    // A request may lower a granted maximum and can never raise it.
    let wall = min(
      create.limits.wallMilliseconds ?? grant.maximumWallMilliseconds,
      grant.maximumWallMilliseconds
    )
    let output = min(
      create.limits.outputBytes ?? grant.maximumOutputBytes,
      grant.maximumOutputBytes
    )
    var decision = result(.unsupportedEnforcement, "")
    decision.scope = ContextResult.Scope(
      image: create.image,
      snapshots: create.snapshots,
      wallMilliseconds: wall,
      outputBytes: output
    )
    decision.backend = backend.name
    // Every context needs every control: what runs inside is arbitrary code.
    let missing = Set(BackendFeature.allCases).subtracting(backend.features)
    guard missing.isEmpty else {
      // There is no weaker backend to fall back to, least of all the host.
      decision.reason = "the backend cannot enforce every required control"
      decision.missingFeatures = missing.map(\.rawValue).sorted()
      return decision
    }
    guard wall <= session.remainingWallMilliseconds else {
      decision.outcome = .budgetExhausted
      decision.reason = "the session's wall-time budget is spent"
      return decision
    }
    // Reserved before the backend is asked, and returned only once the backend
    // has established that no context exists.
    session.remainingWallMilliseconds -= wall
    let context = AdmittedContext(
      identity: identity,
      sessionID: request.sessionID,
      requestID: request.requestID,
      create: create,
      wallMilliseconds: wall,
      outputBytes: output
    )
    switch backend.create(context) {
    case .notStarted(let reason):
      session.remainingWallMilliseconds += wall
      decision.outcome = .runtimeFailure
      decision.reason = reason
    case .unknown(let reason):
      decision.outcome = .executionUnknown
      decision.reason = reason
      decision.effects = .unknown
      decision.cleanup = .unknown
    }
    return decision
  }
}
