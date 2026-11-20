import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
import SwiftMuxXPC
import SwiftMuxService
@testable import Swiftty
import Testing

@MainActor
struct MuxUpdateUITests {
  @Test
  func cancellingAnInstallCancelsItsPendingDetach() async throws {
    let registration = try UIUpdateRegistration()
    let coordinator = UpdateCoordinator(
      connect: { try await registration.connect() },
      registration: registration,
      replace: { _ in
        Issue.record("cancelled update must not replace the bundle")
      }
    )
    var reports: [String] = []
    let controller = MuxUpdateController(
      coordinator: coordinator,
      selectBundle: { URL(fileURLWithPath: "/tmp/Cancelled.app") },
      confirmInstall: { false },
      report: { title, _ in reports.append(title) },
      validateBundle: { _ in }
    )
    let gate = AsyncStream<Void>.makeStream()
    defer { gate.continuation.finish() }
    var detaching = false
    var detachCancelled = false
    controller.stage()
    controller.install {
      detaching = true
      for await _ in gate.stream { break }
      detachCancelled = Task.isCancelled
    }
    try #require(await until { detaching })
    controller.cancel()
    #expect(
      await until { !controller.installing },
      "cancel must release a cooperative pending detach"
    )
    #expect(detachCancelled)
    #expect(reports == ["Update cancelled."])
    #expect(registration.log.isEmpty)
    // Retire the old implementation's waiter after observing the failure.
    gate.continuation.finish()
    #expect(await until { !controller.installing })
  }

  @Test(arguments: ["repeat", "stage", "cancel"])
  func anInstallOwnsItsStagedBundleAndDetach(_ action: String) async throws {
    let registration = try UIUpdateRegistration()
    var replacements: [URL] = []
    let coordinator = UpdateCoordinator(
      connect: { try await registration.connect() },
      registration: registration,
      replace: { url in await MainActor.run { replacements.append(url) } }
    )
    let first = URL(fileURLWithPath: "/tmp/First.app")
    let second = URL(fileURLWithPath: "/tmp/Second.app")
    var selection = first
    var selections = 0
    var confirmations = 0
    var reports: [String] = []
    let controller = MuxUpdateController(
      coordinator: coordinator,
      selectBundle: {
        selections += 1
        return selection
      },
      confirmInstall: {
        confirmations += 1
        return false
      },
      report: { title, _ in reports.append(title) },
      validateBundle: { _ in }
    )
    controller.stage()
    let gate = AsyncStream<Void>.makeStream()
    var detaches = 0
    let detach: @MainActor () async -> Void = {
      detaches += 1
      for await _ in gate.stream { break }
    }
    controller.install(detachFirst: detach)
    #expect(await until { detaches == 1 })
    switch action {
    case "repeat": controller.install(detachFirst: detach)
    case "stage":
      selection = second
      controller.stage()
    default: controller.cancel()
    }
    // Let the old async stage/cancel operations run while detach is held.
    try await Task.sleep(for: .milliseconds(20))
    #expect(detaches == 1)
    #expect(confirmations == 1)
    #expect(selections == 1)
    #expect(controller.staged == first)
    gate.continuation.finish()
    #expect(await until { !reports.isEmpty })
    if action == "cancel" {
      #expect(replacements.isEmpty)
      #expect(registration.log.isEmpty)
      #expect(reports == ["Update cancelled."])
      #expect(await until { !controller.installing })
      selection = second
      controller.stage()
      controller.install { detaches += 1 }
      #expect(await until { reports.count == 2 })
      #expect(replacements == [second])
      #expect(registration.log == ["unregister", "register"])
      #expect(reports.last == "Swiftty was updated.")
    } else {
      #expect(replacements == [first])
      #expect(registration.log == ["unregister", "register"])
      #expect(reports == ["Swiftty was updated."])
    }
  }

  @Test(arguments: [false, true])
  func confirmationBlocksReentrantStageAndInstall(_ accept: Bool) async throws {
    let registration = try UIUpdateRegistration()
    var replacements: [URL] = []
    let coordinator = UpdateCoordinator(
      connect: { try await registration.connect() },
      registration: registration,
      replace: { url in await MainActor.run { replacements.append(url) } }
    )
    let bundle = URL(fileURLWithPath: "/tmp/Modal.app")
    var selections = 0
    var confirmations = 0
    var detaches = 0
    var reports: [String] = []
    var controller: MuxUpdateController?
    defer { controller = nil }
    controller = MuxUpdateController(
      coordinator: coordinator,
      selectBundle: {
        selections += 1
        return bundle
      },
      confirmInstall: {
        confirmations += 1
        if confirmations == 1 {
          controller?.stage()
          controller?.install { detaches += 1 }
        }
        return accept ? false : nil
      },
      report: { title, _ in reports.append(title) },
      validateBundle: { _ in }
    )
    controller?.stage()
    controller?.install { detaches += 1 }
    #expect(selections == 1)
    #expect(confirmations == 1)
    if accept {
      #expect(await until { reports.count == 1 })
      #expect(replacements == [bundle])
      #expect(registration.log == ["unregister", "register"])
      #expect(detaches == 1)
    } else {
      #expect(replacements.isEmpty)
      #expect(registration.log.isEmpty)
      #expect(detaches == 0)
      #expect(reports.isEmpty)
    }
    #expect(await until { controller?.installing == false })
  }

  private func until(_ predicate: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(2)
    while !predicate(), ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(2))
    }
    return predicate()
  }
}

@MainActor
private final class UIUpdateRegistration: AgentRegistration {
  private var service: MuxService

  init() throws {
    service = try MuxService(
      configuration: .init(launcherPath: "/usr/bin/false")
    )
  }

  private var endpoint: SMXEndpoint?
  private(set) var log: [String] = []

  func connect() async throws -> MuxConnection {
    if endpoint == nil { endpoint = service.listenAnonymously() }
    return try await MuxConnection.connect(
      endpoint: endpoint!,
      frontend: .control
    )
  }

  func unregister() async throws { log.append("unregister") }

  func register() async throws {
    service = try MuxService(
      configuration: .init(launcherPath: "/usr/bin/false")
    )
    endpoint = nil
    log.append("register")
  }
}
