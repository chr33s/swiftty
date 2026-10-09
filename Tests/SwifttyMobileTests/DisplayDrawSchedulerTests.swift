#if canImport(UIKit)
    import Metal
    @testable import SwifttyMobile
    import Testing
    import UIKit

    @MainActor
    @Suite(.serialized) struct DisplayDrawSchedulerTests {
        nonisolated static let hasMetal = MTLCreateSystemDefaultDevice() != nil

        @Test(.enabled(if: hasMetal)) func `display drawing coalesces bursts and stops while idle`() async throws {
            var draws = 0
            let scheduler = DisplayDrawScheduler { draws += 1 }
            scheduler.configure(active: true, framesPerSecond: 120)
            for _ in 0 ..< 50 {
                scheduler.request()
            }
            let deadline = ContinuousClock.now + .seconds(2)
            while draws == 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(draws == 1)
            try await Task.sleep(for: .milliseconds(100))
            #expect(draws == 1)
        }

        @Test(.enabled(if: hasMetal)) func `suspended display drawing preserves the latest update`() async throws {
            var draws = 0
            let scheduler = DisplayDrawScheduler { draws += 1 }
            scheduler.configure(active: false, framesPerSecond: 120)
            for _ in 0 ..< 50 {
                scheduler.request()
            }
            try await Task.sleep(for: .milliseconds(50))
            #expect(draws == 0)
            scheduler.configure(active: true, framesPerSecond: 120)
            var deadline = ContinuousClock.now + .seconds(2)
            while draws == 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(draws == 1)
            scheduler.configure(active: false, framesPerSecond: 120)
            scheduler.request()
            try await Task.sleep(for: .milliseconds(50))
            #expect(draws == 1)
            scheduler.configure(active: true, framesPerSecond: 120)
            deadline = ContinuousClock.now + .seconds(2)
            while draws < 2, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(draws == 2)
        }

        @Test(.enabled(if: hasMetal)) func `a draw can request another frame before the scheduler becomes idle`() async throws {
            var attempts = 0
            weak var retry: DisplayDrawScheduler?
            let scheduler = DisplayDrawScheduler {
                attempts += 1
                if attempts < 3 {
                    retry?.request()
                }
            }
            retry = scheduler
            scheduler.configure(active: true, framesPerSecond: 120)
            scheduler.request()
            let deadline = ContinuousClock.now + .seconds(2)
            while attempts < 3, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(attempts == 3)
            try await Task.sleep(for: .milliseconds(100))
            #expect(attempts == 3)
        }

        @Test(.enabled(if: hasMetal)) func `display drawing does not retain its scheduler`() async throws {
            weak var retained: DisplayDrawScheduler?
            var draws = 0
            do {
                let scheduler = DisplayDrawScheduler { draws += 1 }
                retained = scheduler
                scheduler.configure(active: true, framesPerSecond: 120)
                scheduler.request()
            }
            #expect(retained == nil)
            try await Task.sleep(for: .milliseconds(100))
            #expect(draws == 0)
        }
    }
#endif
