import Foundation
@testable import SwifttyCore
import Synchronization
import Testing
import TestSupport

/// OSC 7501 through `TerminalSession` with no view attached: support
/// replies, snapshots and change notifications.
struct ProgramStatusSessionTests {
    final class Recorder: Sendable {
        let replies = Mutex<[[UInt8]]>([])
        let writes = Mutex<[[UInt8]]>([])
        let changes = Mutex<[ProgramStatusSnapshot]>([])
    }

    func session(enabled: Bool) -> (TerminalSession, Recorder) {
        var configuration = SessionConfiguration()
        configuration.programStatusEnabled = enabled
        let session = TerminalSession(columns: 20, rows: 5, configuration: configuration)
        let recorder = Recorder()
        session.onTerminalReply = { bytes in recorder.replies.withLock { $0.append(bytes) } }
        session.onWrite = { bytes in recorder.writes.withLock { $0.append(bytes) } }
        session.onProgramStatusChange = { snapshot in recorder.changes.withLock { $0.append(snapshot) } }
        return (session, recorder)
    }

    func replies(_ r: Recorder) -> [String] {
        r.replies.withLock { $0.map { String(decoding: $0, as: UTF8.self) } }
    }

    @Test func `no reply when disabled`() {
        let (session, r) = session(enabled: false)
        session.feed(Array("\u{1B}]7501;?\u{1B}\\\u{1B}]7501;?\u{07}".utf8))
        #expect(replies(r).isEmpty)
        #expect(r.writes.withLock { $0.isEmpty })
    }

    @Test func `ST query gets an ST reply, BEL query a BEL reply`() {
        let (session, r) = session(enabled: true)
        session.feed(Array("\u{1B}]7501;?\u{1B}\\".utf8))
        session.feed(Array("\u{1B}]7501;?\u{07}".utf8))
        #expect(TestFixture(replies(r)) == TestFixture(["\u{1B}]7501;?\u{1B}\\", "\u{1B}]7501;?\u{07}"]))
        // Terminal-reply provenance: nothing went out as input.
        #expect(r.writes.withLock { $0.isEmpty })
    }

    @Test func `reports produce no reply`() {
        let (session, r) = session(enabled: true)
        session.feed(Array("\u{1B}]7501;state=working\u{07}".utf8))
        #expect(replies(r).isEmpty)
    }

    @Test func `other query replies carry the same provenance`() {
        let (session, r) = session(enabled: true)
        session.feed(Array("\u{1B}[c".utf8))
        #expect(replies(r).count == 1)
        session.send(.text("x"))
        session.withState { _ in } // drain the queue
        #expect(r.writes.withLock { $0 } == [Array("x".utf8)])
    }

    @Test func `replies fall back to onWrite without onTerminalReply`() {
        let (session, r) = session(enabled: true)
        session.onTerminalReply = nil
        session.feed(Array("\u{1B}]7501;?\u{07}".utf8))
        #expect(TestFixture(r.writes.withLock { $0 }) == TestFixture([Array("\u{1B}]7501;?\u{07}".utf8)]))
    }

    @Test func `snapshots publish without cell damage`() {
        let (session, r) = session(enabled: true)
        _ = session.snapshot() // consume initial damage
        let updates = Mutex(0)
        session.onUpdate = { updates.withLock { $0 += 1 } }
        session.feed(Array("\u{1B}]7501;state=working:id=build:progress=5\u{07}".utf8))
        let changes = r.changes.withLock { $0 }
        #expect(changes.count == 1)
        #expect(changes.first?.records.first?.id == "build")
        #expect(updates.withLock { $0 } == 0) // no cells changed
    }

    @Test func `one notification per batch, latest state`() {
        let (session, r) = session(enabled: true)
        session.feed(Array("\u{1B}]7501;state=working\u{07}\u{1B}]7501;state=done\u{07}\u{1B}]7501;state=nope\u{07}".utf8))
        let changes = r.changes.withLock { $0 }
        #expect(changes.count == 1)
        #expect(changes.first?.records.map(\.state) == [.done])
        #expect(changes.first?.revision == 2)
        session.feed(Array("\u{1B}]7501;state=nope\u{07}".utf8))
        #expect(r.changes.withLock { $0.count } == 1)
    }

    @Test func `a new consumer reads the current snapshot`() {
        let (session, _) = session(enabled: true)
        session.receive(Array("\u{1B}]7501;state=blocked:kind=auth:id=login\u{07}".utf8))
        let snapshot = session.programStatusSnapshot // ordered after receive
        #expect(snapshot["login"]?.kind == .auth)
        #expect(snapshot.revision == 1)
    }

    @Test func `external transport exit cleans up in order`() {
        let (session, r) = session(enabled: true)
        session.receive(Array("\u{1B}]7501;state=working:id=a\u{07}\u{1B}]7501;state=done:id=b\u{07}".utf8))
        session.programExited()
        #expect(session.programStatusSnapshot.records.map(\.id) == ["b"])
        #expect(r.changes.withLock { $0.last?.records.map(\.id) } == ["b"])
    }

    @Test func `enabling at runtime`() {
        let (session, r) = session(enabled: false)
        session.setProgramStatusEnabled(true)
        session.receive(Array("\u{1B}]7501;state=done\u{07}\u{1B}]7501;?\u{07}".utf8))
        #expect(session.programStatusSnapshot.records.count == 1)
        #expect(replies(r).count == 1)
        session.setProgramStatusEnabled(false)
        #expect(session.programStatusSnapshot.records.isEmpty)
    }

    #if os(macOS)
        @Test func `stopping a PTY drops transient status and publishes it`() throws {
            let (session, r) = session(enabled: true)
            try session.start(SessionConfiguration(command: ["/bin/sleep", "30"]))
            defer { session.stop() }
            session.feed(Array("\u{1B}]7501;state=working:id=a\u{07}\u{1B}]7501;state=done:id=b\u{07}".utf8))
            session.stop()
            #expect(!session.isRunning)
            #expect(session.programStatusSnapshot.records.map(\.id) == ["b"])
            #expect(r.changes.withLock { $0.last?.records.map(\.id) } == ["b"])
            let changes = r.changes.withLock { $0.count }
            session.stop()
            #expect(r.changes.withLock { $0.count } == changes)
        }

        @Test func `PTY child exit drops transient status`() async throws {
            var configuration = SessionConfiguration(command: [
                "/bin/sh", "-c", #"printf '\033]7501;state=working:id=a\033\\\033]7501;state=done:id=b\033\\'"#,
            ])
            configuration.programStatusEnabled = true
            let session = TerminalSession(columns: 20, rows: 5, configuration: configuration)
            let changes = Mutex<[ProgramStatusSnapshot]>([])
            let exited = Mutex(false)
            session.onProgramStatusChange = { s in changes.withLock { $0.append(s) } }
            session.onEvent = { event in
                if case .exited = event {
                    exited.withLock { $0 = true }
                }
            }
            try session.start(configuration)
            for _ in 0 ..< 500 where !exited.withLock({ $0 }) {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(exited.withLock { $0 })
            #expect(session.programStatusSnapshot.records.map(\.id) == ["b"])
            #expect(changes.withLock { $0.last?.records.map(\.id) } == ["b"])
        }
    #endif

    @Test func `support reply survives discarded replies only when asked`() {
        let (session, r) = session(enabled: true)
        session.mutate { $0.discardsReplies = true }
        session.feed(Array("\u{1B}[c\u{1B}]7501;?\u{07}".utf8))
        #expect(replies(r).isEmpty)
        session.mutate { $0.answersProgramStatusWhileDiscarding = true }
        session.feed(Array("\u{1B}[c\u{1B}]7501;?\u{07}\u{1B}[5n".utf8))
        #expect(TestFixture(replies(r)) == TestFixture(["\u{1B}]7501;?\u{07}"]))
    }
}
