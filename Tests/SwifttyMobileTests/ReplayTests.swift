import Foundation
import SwifttyCore
import Testing

/// Recorded `sh`, `vim`, `less`, `tmux` and `top` sessions (see
/// `SessionRecorder` in the core tests) replayed through `receive`, the
/// path iOS uses with no PTY: each must draw the screen it drew live.
struct ReplayTests {
    static let names = ["shell", "vim", "less", "tmux", "top"]

    @Test(arguments: names) func `replay matches the recorded screen`(_ name: String) throws {
        let bytes = try #require(Bundle.module.url(forResource: name, withExtension: "bin", subdirectory: "Fixtures"))
        let screen = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"))
        let expected = try String(contentsOf: screen, encoding: .utf8)
        let session = TerminalSession(columns: 80, rows: 24)
        session.onWrite = { _ in } // replies have no one to go to
        // Fed in uneven chunks, as a transport would deliver it.
        let data = try [UInt8](Data(contentsOf: bytes))
        var offset = 0
        var size = 1
        while offset < data.count {
            let end = min(offset + size, data.count)
            session.receive(Array(data[offset ..< end]))
            offset = end
            size = size * 3 % 997 + 1
        }
        let replayed = session.withState { state in
            (0 ..< state.rows).map { state.text(row: $0) }.joined(separator: "\n")
        }
        #expect(replayed == expected)
    }
}
