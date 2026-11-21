import Foundation
import SSHClient

/// How ordinary SSH connections survive network trouble
/// (spec.roaming.md §9.1). Non-sensitive; stored per device.
public struct ConnectionResilienceSettings: Hashable, Sendable, Codable {
  public static let attemptRange = 1 ... 10
  public static let probeIntervalRange = 15 ... 300
  /// Interval choices offered in Settings (Pickers work on every platform,
  /// including tvOS, which has no Stepper).
  public static let probeIntervals = [15, 30, 60, 120, 300]

  /// Open a new shell automatically after an ordinary SSH connection drops.
  public var autoReconnect: Bool
  /// Attempts in each recovery burst before slowing to `cooldown`.
  public var attemptsPerBurst: Int
  /// TCP keepalive on every SSH connection.
  public var keepAlive: Bool
  /// Periodic connection health checks while a shell is shown.
  public var healthChecks: Bool
  /// Seconds between health checks.
  public var probeInterval: Int
  /// Connect over IPv4 only.
  public var forceIPv4: Bool

  public init(
    autoReconnect: Bool = true,
    attemptsPerBurst: Int = 3,
    keepAlive: Bool = true,
    healthChecks: Bool = true,
    probeInterval: Int = 30,
    forceIPv4: Bool = false
  ) {
    self.autoReconnect = autoReconnect
    self.attemptsPerBurst = attemptsPerBurst.clamped(to: Self.attemptRange)
    self.keepAlive = keepAlive
    self.healthChecks = healthChecks
    self.probeInterval = probeInterval.clamped(to: Self.probeIntervalRange)
    self.forceIPv4 = forceIPv4
  }

  public static let `default` = ConnectionResilienceSettings()

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = Self.default
    self.init(
      autoReconnect: try c.decodeIfPresent(Bool.self, forKey: .autoReconnect)
        ?? d.autoReconnect,
      attemptsPerBurst: try c.decodeIfPresent(
        Int.self,
        forKey: .attemptsPerBurst
      ) ?? d.attemptsPerBurst,
      keepAlive: try c.decodeIfPresent(Bool.self, forKey: .keepAlive)
        ?? d.keepAlive,
      healthChecks: try c.decodeIfPresent(Bool.self, forKey: .healthChecks)
        ?? d.healthChecks,
      probeInterval: try c.decodeIfPresent(Int.self, forKey: .probeInterval)
        ?? d.probeInterval,
      forceIPv4: try c.decodeIfPresent(Bool.self, forKey: .forceIPv4)
        ?? d.forceIPv4
    )
  }

  /// TCP keepalive for new connections, or `nil` when off.
  public var keepalive: SSHKeepalive? { keepAlive ? .standard : nil }

  // MARK: Persistence

  static let defaultsKey = "connection.resilience.v1"

  static func load(from defaults: UserDefaults) -> Self {
    guard let data = defaults.data(forKey: defaultsKey),
      let settings = try? JSONDecoder().decode(Self.self, from: data)
    else { return .default }
    return settings
  }

  func save(to defaults: UserDefaults) {
    if let data = try? JSONEncoder().encode(self) {
      defaults.set(data, forKey: Self.defaultsKey)
    }
  }
}

/// When the next automatic reconnect runs (spec.roaming.md §9.1). A burst
/// tries `attemptsPerBurst` times with growing delays; once exhausted the
/// intent survives and attempts continue every `cooldown`. A trigger (the
/// app returning to the foreground or a network path change) starts a
/// fresh burst at once. Pure, so it is tested without a network.
struct RecoverySchedule: Equatable, Sendable {
  static let burstDelays: [Duration] = [
    .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15),
  ]
  static let cooldown: Duration = .seconds(60)

  let attemptsPerBurst: Int
  /// Attempts made in the current burst.
  private(set) var attempt = 0
  /// Total attempts since the connection was lost.
  private(set) var total = 0
  /// A trigger asked for the next attempt without delay.
  private var immediate = false

  init(attemptsPerBurst: Int) {
    self.attemptsPerBurst = max(1, attemptsPerBurst)
  }

  /// Whether the current burst has no attempts left.
  var isCoolingDown: Bool { attempt >= attemptsPerBurst }

  /// The delay before the next attempt, and records that attempt.
  mutating func next() -> Duration {
    defer {
      attempt += 1
      total += 1
    }
    if immediate {
      immediate = false
      return .zero
    }
    guard attempt < attemptsPerBurst else { return Self.cooldown }
    return Self.burstDelays[min(attempt, Self.burstDelays.count - 1)]
  }

  /// A recovery trigger: the next attempt starts a fresh burst immediately.
  mutating func trigger() {
    attempt = 0
    immediate = true
  }
}

extension Comparable {
  fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
    min(max(self, range.lowerBound), range.upperBound)
  }
}

#if canImport(SwiftUI)
import SwiftUI

/// Settings → Connection: ordinary SSH recovery and transport options
/// (spec.roaming.md §9.1).
struct ConnectionSettingsView: View {
  @Bindable
  var model: RoamingAppModel

  var body: some View {
    Form {
      Section {
        Toggle(
          .localized("Reconnect Automatically"),
          isOn: $model.resilience.autoReconnect
        )
        .accessibilityIdentifier("connection.autoReconnect")
        Picker(
          .localized("Attempts per Recovery Burst"),
          selection: $model.resilience.attemptsPerBurst
        ) {
          ForEach(Array(ConnectionResilienceSettings.attemptRange), id: \.self) {
            Text(verbatim: "\($0)").tag($0)
          }
        }
        .disabled(!model.resilience.autoReconnect)
        .accessibilityIdentifier("connection.attempts")
      } header: {
        Text("Ordinary SSH", bundle: #bundle)
      } footer: {
        Text(
          """
          When an ordinary SSH connection drops, Swiftty opens a new shell in the \
          same screen and tells you so. The previous shell is not resumed and \
          nothing you typed is sent again. After a burst of attempts, Swiftty \
          keeps trying once a minute; returning to the app or a network change \
          tries again at once.
          """,
          bundle: #bundle
        )
      }
      .listRowBackground(Color.clear)
      Section {
        Toggle(
          .localized("Periodic Connection Health Checks"),
          isOn: $model.resilience.healthChecks
        )
        .accessibilityIdentifier("connection.healthChecks")
        Picker(
          .localized("Probe Interval"),
          selection: $model.resilience.probeInterval
        ) {
          ForEach(ConnectionResilienceSettings.probeIntervals, id: \.self) {
            Text("\($0) seconds", bundle: #bundle).tag($0)
          }
        }
        .disabled(!model.resilience.healthChecks)
        .accessibilityIdentifier("connection.probeInterval")
        Toggle(
          .localized("Keep Connections Alive"),
          isOn: $model.resilience.keepAlive
        )
        .accessibilityIdentifier("connection.keepAlive")
        Toggle(.localized("Force IPv4"), isOn: $model.resilience.forceIPv4)
          .accessibilityIdentifier("connection.forceIPv4")
      } header: {
        Text("Transport", bundle: #bundle)
      } footer: {
        Text(
          """
          Health checks ask the Mac to answer while a shell is open; turning them \
          off still checks once when you return to the app or the network \
          changes. Keepalive lets the network detect a silent connection. \
          Neither keeps a shell running while the app is in the background. \
          Changes apply to new connections.
          """,
          bundle: #bundle
        )
      }
      .listRowBackground(Color.clear)
    }
    .glassListBackground().navigationTitle(.localized("Connection"))
  }
}
#endif
