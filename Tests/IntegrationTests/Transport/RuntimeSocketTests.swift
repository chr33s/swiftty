#if os(macOS)
import Darwin
import Foundation
import ScreenProtocol
import SessionCore
import Synchronization
import Testing
import TestSupport

@Suite(.timeLimit(.minutes(1)))
struct RuntimeSocketTests {
  private let request: [UInt8] = [0, 0, 0, 1, 42]

  private func withPeer(
    _ peer: @escaping @Sendable (Int32) async throws -> Void,
    client: @escaping @Sendable (String) async throws -> Void,
  ) async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("socket").path
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    try #require(fd >= 0)
    defer { close(fd) }
    try #require(fcntl(fd, F_SETFD, FD_CLOEXEC) == 0)
    try #require(fcntl(fd, F_SETFL, O_NONBLOCK) == 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    try #require(path.utf8.count < MemoryLayout.size(ofValue: address.sun_path))
    withUnsafeMutableBytes(of: &address.sun_path) {
      $0.copyBytes(from: path.utf8)
    }
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    try #require(bound == 0 && listen(fd, 1) == 0)
    try await withThrowingTaskGroup(of: Void.self) { group in
      defer { group.cancelAll() }
      group.addTask {
        let deadline = ContinuousClock.now + .seconds(5)
        var accepted: Int32 = -1
        while accepted < 0 {
          try Task.checkCancellation()
          try #require(ContinuousClock.now < deadline)
          accepted = accept(fd, nil, nil)
          if accepted < 0 {
            try #require(errno == EAGAIN || errno == EINTR)
            try await Task.sleep(for: .milliseconds(1))
          }
        }
        defer { close(accepted) }
        try #require(fcntl(accepted, F_SETFD, FD_CLOEXEC) == 0)
        try #require(fcntl(accepted, F_SETFL, O_NONBLOCK) == 0)
        var noSignal: Int32 = 1
        try #require(
          setsockopt(
            accepted,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size),
          ) == 0
        )
        try await peer(accepted)
      }
      group.addTask { try await client(path) }
      try await group.waitForAll()
    }
  }

  private static func read(_ fd: Int32, count: Int) async throws -> [UInt8] {
    var bytes = [UInt8]()
    let deadline = ContinuousClock.now + .seconds(5)
    while bytes.count < count {
      try Task.checkCancellation()
      try #require(ContinuousClock.now < deadline)
      var buffer = [UInt8](repeating: 0, count: min(512, count - bytes.count))
      let size = buffer.count
      let n = recv(fd, &buffer, size, 0)
      if n > 0 {
        bytes.append(contentsOf: buffer.prefix(n));
        continue
      }
      try #require(n < 0 && (errno == EAGAIN || errno == EINTR))
      try await Task.sleep(for: .milliseconds(1))
    }
    return bytes
  }

  private static func send(_ fd: Int32, _ bytes: [UInt8]) async throws {
    var offset = 0
    let deadline = ContinuousClock.now + .seconds(5)
    while offset < bytes.count {
      try Task.checkCancellation()
      try #require(ContinuousClock.now < deadline)
      let n = bytes.withUnsafeBytes {
        Darwin.send(fd, $0.baseAddress! + offset, bytes.count - offset, 0)
      }
      if n > 0 {
        offset += n;
        continue
      }
      try #require(n < 0 && (errno == EAGAIN || errno == EINTR))
      try await Task.sleep(for: .milliseconds(1))
    }
  }

  private static func waitForClose(_ fd: Int32) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while true {
      try Task.checkCancellation()
      try #require(ContinuousClock.now < deadline)
      var byte: UInt8 = 0
      let n = recv(fd, &byte, 1, 0)
      if n == 0 || (n < 0 && errno == ECONNRESET) { return }
      try #require(n < 0 && (errno == EAGAIN || errno == EINTR))
      try await Task.sleep(for: .milliseconds(1))
    }
  }

  @Test
  func fragmentedResponseAndFullSizeRequestRemainExact() async throws {
    let body = [UInt8](
      repeating: 42,
      count: RSTLimits.maxBootstrapEnvelopeBytes,
    )
    let large = [UInt8](arrayLiteral: 0, 1, 0, 0) + body
    let reply = try BootstrapEnvelope.encode(
      BootstrapResponse.failure(.malformed)
    )
    try await withPeer { fd in
      #expect(try await Self.read(fd, count: large.count) == large)
      for byte in reply {
        try await Self.send(fd, [byte])
        try await Task.sleep(for: .milliseconds(1))
      }
    } client: { path in
      let actual = try await RuntimeSocket.exchange(
        path: path,
        request: large,
        maximumBodyBytes: RSTLimits.maxBootstrapEnvelopeBytes,
      )
      #expect(actual == reply)
      #expect(
        try BootstrapEnvelope.decode(BootstrapResponse.self, from: actual)
          == .failure(.malformed)
      )
    }
  }

  @Test(arguments: [0, 1, 2])
  func deadlineCoversPrefixBodyAndEOF(_ phase: Int) async throws {
    let request = request
    try await withPeer { fd in
      _ = try await Self.read(fd, count: request.count)
      if phase >= 1 { try await Self.send(fd, [0, 0, 0, 2]) }
      if phase == 2 { try await Self.send(fd, [1, 2]) }
      try await Self.waitForClose(fd)
    } client: { path in
      await #expect(throws: RuntimeSocketError.timedOut) {
        _ = try await RuntimeSocket.exchange(
          path: path,
          request: request,
          maximumBodyBytes: 2,
          timeout: .seconds(1),
        )
      }
    }
  }

  @Test(arguments: [0, 1, 2])
  func cancellationClosesPeerInEveryReadPhase(_ phase: Int) async throws {
    let ready = Mutex(false)
    let request = request
    try await withPeer { fd in
      _ = try await Self.read(fd, count: request.count)
      if phase >= 1 { try await Self.send(fd, [0, 0, 0, 2]) }
      if phase == 2 { try await Self.send(fd, [1, 2]) }
      ready.withLock { $0 = true }
      try await Self.waitForClose(fd)
    } client: { path in
      let task = Task {
        try await RuntimeSocket.exchange(
          path: path,
          request: request,
          maximumBodyBytes: 2,
          timeout: .seconds(30),
        )
      }
      defer { task.cancel() }
      try await RuntimeFixture.wait("peer phase", timeout: .seconds(5)) {
        ready.withLock { $0 }
      }
      task.cancel()
      await #expect(throws: CancellationError.self) { try await task.value }
    }
  }

  @Test(arguments: [false, true])
  func oversizedPrefixIsRejectedBeforeReadingABody(_ flood: Bool) async throws {
    let request = request
    try await withPeer { fd in
      _ = try await Self.read(fd, count: request.count)
      try await Self.send(fd, [0, 0, 1, 0])
      if flood {
        _ = [UInt8](repeating: 0, count: 4096)
          .withUnsafeBytes { Darwin.send(fd, $0.baseAddress!, $0.count, 0) }
      }
      try await Self.waitForClose(fd)
    } client: { path in
      await #expect(throws: RuntimeSocketError.recordTooLarge(256)) {
        _ = try await RuntimeSocket.exchange(
          path: path,
          request: request,
          maximumBodyBytes: 2,
        )
      }
    }
  }

  @Test
  func continuingBodyProgressDoesNotExtendTheDeadline() async throws {
    let request = request
    let sent = Mutex(0)
    try await withPeer { fd in
      _ = try await Self.read(fd, count: request.count)
      try await Self.send(fd, [0, 0, 1, 0])
      for _ in 0 ..< 256 {
        var byte: UInt8 = 42
        let n = Darwin.send(fd, &byte, 1, 0)
        let failure = n < 0 ? errno : 0
        // The client closes at its deadline; Darwin reports that to a
        // later send as EPIPE, ECONNRESET or ENOTCONN depending on timing.
        if n < 0, [EPIPE, ECONNRESET, ENOTCONN].contains(failure) { return }
        try #require(n == 1, "drip-body send result \(n), errno \(failure)")
        sent.withLock { $0 += 1 }
        try await Task.sleep(for: .milliseconds(20))
      }
    } client: { path in
      await #expect(throws: RuntimeSocketError.timedOut) {
        _ = try await RuntimeSocket.exchange(
          path: path,
          request: request,
          maximumBodyBytes: 256,
          timeout: .seconds(1),
        )
      }
      #expect(sent.withLock { $0 } > 1)
    }
  }

  @Test(arguments: [0, 1, 2, 3, 4])
  func truncatedAndTrailingResponsesAreRefused(_ variant: Int) async throws {
    let replies: [[UInt8]] = [
      [], [0, 0], [0, 0, 0, 2, 1], [0, 0, 0, 1, 42, 99], [0, 0, 0, 1, 42],
    ]
    let request = request
    try await withPeer { fd in
      _ = try await Self.read(fd, count: request.count)
      try await Self.send(fd, replies[variant])
      if variant == 4 {
        try await Task.sleep(for: .milliseconds(10))
        try await Self.send(fd, [99])
      }
    } client: { path in
      let expected: RuntimeSocketError =
        variant >= 3 ? .trailingData : .truncated
      await #expect(throws: expected) {
        _ = try await RuntimeSocket.exchange(
          path: path,
          request: request,
          maximumBodyBytes: 2,
        )
      }
    }
  }

  @Test
  func badPathsLimitsAndRequestsFailBeforeOpeningASocket() async {
    for path in [
      "", String(repeating: "x", count: 108), "socket\0alias",
      String(repeating: "漢", count: 36),
    ] {
      await #expect(throws: RuntimeSocketError.invalidPath) {
        _ = try await RuntimeSocket.exchange(
          path: path,
          request: request,
          maximumBodyBytes: 2,
        )
      }
    }
    for maximum in [-1, Int(UInt32.max) + 1] {
      await #expect(throws: RuntimeSocketError.invalidLimits) {
        _ = try await RuntimeSocket.exchange(
          path: "/unused",
          request: request,
          maximumBodyBytes: maximum,
        )
      }
    }
    await #expect(throws: RuntimeSocketError.invalidLimits) {
      _ = try await RuntimeSocket.exchange(
        path: "/unused",
        request: request,
        maximumBodyBytes: 2,
        timeout: .zero,
      )
    }
    for bytes: [UInt8] in [
      [], [0, 0], [0, 0, 0, 2, 1], [0, 0, 0, 0, 1], [0, 0, 0, 3, 1, 2, 3],
    ] {
      await #expect(throws: RuntimeSocketError.invalidEnvelope) {
        _ = try await RuntimeSocket.exchange(
          path: "/unused",
          request: bytes,
          maximumBodyBytes: 2,
        )
      }
    }
  }

  @Test
  func preCanceledAndMissingSocketDoNotWait() async {
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await RuntimeSocket.exchange(
        path: "/unused",
        request: request,
        maximumBodyBytes: 2,
      )
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    do {
      _ = try await RuntimeSocket.exchange(
        path: "/missing-" + UUID().uuidString,
        request: request,
        maximumBodyBytes: 2,
      )
      Issue.record("missing socket connected")
    } catch {
      #expect(error as? RuntimeSocketError == .system("connect", ENOENT))
    }
  }
}
#endif
