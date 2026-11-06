#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
import Testing
@testable import Swsh

/// Child tests never mutate the test runner's cwd, environment, signal policy or group.
@Suite
struct SpawnTests {
  @Test
  func suspendedGroupAssemblyAndRelease() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appendingPathComponent("executed")
    let spawn = DarwinSpawn()
    var owned: Set<pid_t> = []
    defer { cleanup(owned) }
    let leader = try spawn.launch(
      path: bytes("/bin/sh"),
      arguments: [
        bytes("sh"), bytes("-c"), bytes("echo released > \"$1\""),
        bytes("probe"), bytes(marker.path),
      ],
      environment: [],
      group: .suspendedLeader
    )
    owned.insert(leader)
    // A fast first command must remain alive while a later stage is delayed.
    usleep(30_000)
    #expect(kill(leader, 0) == 0)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    #expect(getpgid(leader) == leader)
    let follower = try spawn.launch(
      path: bytes("/usr/bin/true"),
      arguments: [bytes("true")],
      environment: [],
      group: .suspendedMember(leader)
    )
    owned.insert(follower)
    #expect(getpgid(follower) == leader)
    #expect(kill(-leader, SIGCONT) == 0)
    #expect(try reap(leader, owned: &owned) == 0)
    #expect(try reap(follower, owned: &owned) == 0)
    #expect(try String(contentsOf: marker, encoding: .utf8) == "released\n")
  }

  @Test
  func abortDoesNotExecuteSuspendedChild() throws {
    let spawn = DarwinSpawn()
    var owned: Set<pid_t> = []
    defer { cleanup(owned) }
    let child = try spawn.launch(
      path: bytes("/usr/bin/true"),
      arguments: [bytes("true")],
      environment: [],
      group: .suspendedLeader
    )
    owned.insert(child)
    #expect(kill(child, SIGKILL) == 0)
    #expect(try reap(child, owned: &owned) == SIGKILL)
  }

  @Test
  func inheritedModeKeepsParentGroup() throws {
    let spawn = DarwinSpawn()
    var owned: Set<pid_t> = []
    defer { cleanup(owned) }
    let child = try spawn.launch(
      path: bytes("/bin/sleep"),
      arguments: [bytes("sleep"), bytes("10")],
      environment: [],
      group: .inherited
    )
    owned.insert(child)
    #expect(getpgid(child) == getpgrp())
    #expect(kill(child, SIGKILL) == 0)
    #expect(try reap(child, owned: &owned) == SIGKILL)
  }

  @Test
  func missingExecutableReportsSpawnError() {
    #expect(throws: SystemFailure.self) {
      try DarwinSpawn()
        .launch(
          path: bytes("/swsh-nonexistent-executable"),
          arguments: [bytes("missing")],
          environment: [],
          group: .inherited
        )
    }
  }

  private func bytes(_ string: String) -> [UInt8] { Array(string.utf8) }

  private func reap(_ pid: pid_t, owned: inout Set<pid_t>) throws -> Int32 {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while ContinuousClock.now < deadline {
      var status: Int32 = 0
      let result = waitpid(pid, &status, WNOHANG)
      if result == pid {
        owned.remove(pid)
        return status
      }
      if result < 0 && errno != EINTR { throw SystemFailure("waitpid") }
      usleep(1_000)
    }
    throw SystemFailure(
      "child failed to terminate before deadline",
      code: ETIMEDOUT
    )
  }

  private func cleanup(_ owned: Set<pid_t>) {
    for pid in owned { _ = kill(pid, SIGKILL) }
    for pid in owned {
      var status: Int32 = 0
      while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    }
  }
}
