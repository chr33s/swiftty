import Foundation
@testable import RoamingApp
import SSHClient
import Testing

/// spec.roaming.md §9.1: ordinary SSH recovery bursts and settings.
@Suite
struct ConnectionResilienceTests {
  @Test
  func burstsBackOffThenCoolDown() {
    var schedule = RecoverySchedule(attemptsPerBurst: 3)
    #expect(schedule.next() == .seconds(1))
    #expect(schedule.next() == .seconds(2))
    #expect(schedule.next() == .seconds(4))
    #expect(schedule.isCoolingDown)
    // The intent survives the burst, at a slower pace.
    #expect(schedule.next() == RecoverySchedule.cooldown)
    #expect(schedule.next() == RecoverySchedule.cooldown)
    #expect(schedule.total == 5)
  }

  @Test
  func aTriggerStartsAFreshBurstAtOnce() {
    var schedule = RecoverySchedule(attemptsPerBurst: 2)
    _ = schedule.next()
    _ = schedule.next()
    #expect(schedule.isCoolingDown)
    schedule.trigger()
    #expect(!schedule.isCoolingDown)
    #expect(schedule.next() == .zero)
    #expect(schedule.next() == .seconds(2))
    #expect(schedule.isCoolingDown)
    #expect(schedule.next() == RecoverySchedule.cooldown)
  }

  @Test
  func longBurstsCapTheirDelay() {
    var schedule = RecoverySchedule(attemptsPerBurst: 10)
    let delays = (0 ..< 10).map { _ in schedule.next() }
    #expect(delays.last == .seconds(15))
    #expect(delays.allSatisfy { $0 <= .seconds(15) })
  }

  @Test
  func settingsClampAndDecodeOlderPayloads() throws {
    let clamped = ConnectionResilienceSettings(
      attemptsPerBurst: 99,
      probeInterval: 1
    )
    #expect(clamped.attemptsPerBurst == 10)
    #expect(clamped.probeInterval == 15)
    let partial = try JSONDecoder()
      .decode(
        ConnectionResilienceSettings.self,
        from: Data(#"{"forceIPv4":true}"#.utf8)
      )
    #expect(partial.forceIPv4)
    #expect(partial.autoReconnect)
    #expect(partial.keepalive == .standard)
    #expect(ConnectionResilienceSettings(keepAlive: false).keepalive == nil)
  }

  @Test
  func settingsPersistPerDevice() throws {
    let suite = "resilience-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(ConnectionResilienceSettings.load(from: defaults) == .default)
    let custom = ConnectionResilienceSettings(
      autoReconnect: false,
      attemptsPerBurst: 5,
      forceIPv4: true
    )
    custom.save(to: defaults)
    #expect(ConnectionResilienceSettings.load(from: defaults) == custom)
  }
}
