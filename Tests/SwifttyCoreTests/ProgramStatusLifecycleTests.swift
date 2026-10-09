@testable import SwifttyCore
import Testing
import TestSupport

/// OSC 7501 across prompts, resets and exits, in stream order.
struct ProgramStatusLifecycleTests {
    let promptA = "\u{1B}]133;A\u{07}", inputB = "\u{1B}]133;B\u{07}", outputC = "\u{1B}]133;C\u{07}", doneD = "\u{1B}]133;D;0\u{07}"

    func vt() -> VT {
        var vt = VT(20, 5)
        vt.state.programStatusEnabled = true
        return vt
    }

    func status(_ body: String) -> String {
        "\u{1B}]7501;\(body)\u{1B}\\"
    }

    func states(_ vt: borrowing VT) -> [String: ProgramStatusState] {
        Dictionary(uniqueKeysWithValues: vt.state.programStatus.records.map { ($0.id, $0.state) })
    }

    @Test func `stream order within one write`() {
        var vt = vt()
        // working → prompt start → done, all in one chunk: the prompt clears
        // only what came before it.
        vt.feed(status("state=working") + promptA + status("state=done"))
        #expect(states(vt) == ["": .done])
    }

    @Test func `prompt start removes transient state and keeps done and error`() {
        var vt = vt()
        vt.feed("\(promptA)$ \(inputB)run\r\n\(outputC)")
        vt.feed(status("state=working:id=a") + status("state=blocked:id=b") + status("state=idle:id=c"))
        vt.feed(status("state=done:id=d") + status("state=error:id=e"))
        vt.feed("\(doneD)\(promptA)$ ")
        #expect(states(vt) == ["d": .done, "e": .error])
    }

    @Test func `prompt redraw and continuation are not command boundaries`() {
        var vt = vt()
        vt.feed("\(promptA)$ \(inputB)")
        vt.feed(status("state=working"))
        // Redraw of the prompt being edited (e.g. after SIGWINCH).
        vt.feed("\u{1B}]133;A;redraw=1\u{07}$ \(inputB)")
        #expect(states(vt) == ["": .working])
        // A continuation prompt after output.
        vt.feed("\(outputC)\u{1B}]133;A;k=s\u{07}> ")
        #expect(states(vt) == ["": .working])
        // A genuine new prompt.
        vt.feed("\(doneD)\(promptA)")
        #expect(states(vt).isEmpty)
    }

    @Test func `prompt after output without D still ends the command`() {
        var vt = vt()
        vt.feed("\(promptA)\(inputB)\(outputC)")
        vt.feed(status("state=working"))
        vt.feed(promptA)
        #expect(states(vt).isEmpty)
    }

    @Test func `full reset clears everything`() {
        var vt = vt()
        vt.feed(status("state=done") + status("state=working:id=x"))
        _ = vt.state.takeProgramStatusChange()
        vt.feed("\u{1B}c")
        #expect(states(vt).isEmpty)
        #expect(vt.state.takeProgramStatusChange()?.records == [])
        // Still enabled afterwards.
        vt.feed(status("state=idle"))
        #expect(states(vt) == ["": .idle])
        vt.state.reset()
        #expect(states(vt).isEmpty)
    }

    @Test func `soft reset keeps status`() {
        var vt = vt()
        vt.feed(status("state=working"))
        vt.feed("\u{1B}[!p")
        #expect(states(vt) == ["": .working])
    }

    @Test func `program exit removes transient state only`() {
        var vt = vt()
        vt.feed(status("state=working:id=a") + status("state=blocked:id=b") + status("state=done:id=c") + status("state=error:id=d"))
        vt.state.programExited()
        #expect(states(vt) == ["c": .done, "d": .error])
        // Nothing invented on a second exit.
        _ = vt.state.takeProgramStatusChange()
        vt.state.programExited()
        #expect(vt.state.takeProgramStatusChange() == nil)
    }

    @Test func `osc 9 progress stays separate`() {
        var vt = vt()
        vt.feed("\u{1B}]9;4;1;42\u{07}")
        #expect(vt.state.programStatus.records.isEmpty)
        vt.feed(status("state=working:progress=10"))
        #expect(vt.state.takeEvents() == [.progress(state: 1, percent: 42)])
    }

    @Test func `reconstruction reset keeps status and clears the screen`() {
        var vt = vt()
        vt.feed("abc" + status("state=working:id=a") + status("state=done:id=b"))
        let before = vt.state.programStatus.snapshot
        _ = vt.state.takeProgramStatusChange()
        vt.state.resetPreservingProgramStatus()
        #expect(vt.state.programStatus.snapshot == before)
        #expect(vt.state.takeProgramStatusChange() == nil)
        #expect(TestFixture(vt.lines.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }) == TestFixture(true))
    }

    @Test func `replacing status adopts records and keeps revisions monotonic`() {
        var stand = vt(), pane = vt()
        pane.feed(status("state=working:id=a") + status("state=working:id=b") + status("state=working:id=c"))
        _ = pane.state.takeProgramStatusChange()
        // A stand-in seeded from the pane, then fed what the pane missed.
        stand.state.replaceProgramStatus(with: pane.state.programStatus.snapshot)
        #expect(stand.state.programStatus.snapshot == pane.state.programStatus.snapshot)
        stand.feed(status("state=done:id=a"))
        pane.state.replaceProgramStatus(with: stand.state.programStatus.snapshot)
        #expect(states(pane) == ["a": .done, "b": .working, "c": .working])
        #expect(pane.state.programStatus.revision == 4)
        #expect(pane.state.programStatus.records.last?.revision == 4)
        #expect(pane.state.takeProgramStatusChange() != nil)
        // Unchanged: no notification.
        pane.state.replaceProgramStatus(with: stand.state.programStatus.snapshot)
        #expect(pane.state.takeProgramStatusChange() == nil)
        // Never backwards, even from an older snapshot.
        pane.state.replaceProgramStatus(with: .empty)
        #expect(states(pane).isEmpty)
        #expect(pane.state.programStatus.revision == 5)
    }

    @Test func `replacing status is ignored while disabled`() {
        var vt = VT(20, 5)
        vt.state.replaceProgramStatus(with: ProgramStatusSnapshot(records: [ProgramStatusRecord(id: "", state: .working)], revision: 1))
        #expect(vt.state.programStatus.records.isEmpty)
    }

    @Test func `imported status keeps the newest record per id before applying capacity`() {
        var vt = vt()
        let older = ProgramStatusRecord(id: "a", state: .working, revision: 1)
        let other = ProgramStatusRecord(id: "b", state: .blocked, revision: 2)
        let newer = ProgramStatusRecord(id: "a", state: .done, revision: 3)
        let records = [older, other] + Array(repeating: newer, count: ProgramStatusStore.capacity + 1)
        vt.state.replaceProgramStatus(with: ProgramStatusSnapshot(records: records, revision: 3))
        let imported = vt.state.takeProgramStatusChange()
        let recordsMatch = imported?.records == [other, newer]
        #expect(recordsMatch)
        #expect(imported?["a"] == newer)
        vt.state.replaceProgramStatus(with: ProgramStatusSnapshot(records: records, revision: 3))
        #expect(vt.state.takeProgramStatusChange() == nil)
        vt.feed(status("state=error:id=a"))
        #expect(vt.state.programStatus.records.map(\.id) == ["b", "a"])
        #expect(vt.state.programStatus.snapshot["a"]?.state == .error)
        let canonical = vt.state.programStatus.snapshot
        _ = vt.state.takeProgramStatusChange()
        vt.state.replaceProgramStatus(with: canonical)
        #expect(vt.state.takeProgramStatusChange() == nil)
    }

    @Test(arguments: [0, 255, 256, 257, 300])
    func `imported status bounds distinct ids in update order`(_ count: Int) {
        var vt = vt()
        let latest = (0 ..< count).map { ProgramStatusRecord(id: "r\($0)", state: .done, revision: UInt64($0)) }
        let records = latest.flatMap { record in
            [ProgramStatusRecord(id: record.id, state: .working, revision: 1000), record]
        }
        vt.state.replaceProgramStatus(with: ProgramStatusSnapshot(records: records, revision: 1000))
        let expected = Array(latest.suffix(ProgramStatusStore.capacity))
        let recordsMatch = vt.state.programStatus.records == expected
        #expect(recordsMatch)
        #expect(vt.state.takeProgramStatusChange()?.revision == 1000)
    }

    @Test(arguments: ["report", "clear", "exit", "replace"])
    func `maximum imported revisions still allow status changes`(_ action: String) {
        var vt = vt()
        let record = ProgramStatusRecord(id: "a", state: .working, revision: .max)
        vt.state.replaceProgramStatus(with: ProgramStatusSnapshot(records: [record], revision: .max))
        #expect(vt.state.takeProgramStatusChange()?.revision == .max)
        switch action {
        case "report": vt.feed(status("state=done:id=a"))
        case "clear": vt.feed(status("state=clear:id=a"))
        case "exit": vt.state.programExited()
        default: vt.state.replaceProgramStatus(with: .empty)
        }
        let change = vt.state.takeProgramStatusChange()
        #expect(change?.revision == .max)
        if action == "report" {
            #expect(change?["a"]?.state == .done)
            #expect(change?["a"]?.revision == .max)
        } else {
            #expect(change?.records.isEmpty == true)
        }
        #expect(vt.state.takeProgramStatusChange() == nil)
    }
}
