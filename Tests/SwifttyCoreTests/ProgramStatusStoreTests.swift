@testable import SwifttyCore
import Testing

/// OSC 7501 record semantics.
struct ProgramStatusStoreTests {
    func vt() -> VT {
        var vt = VT(20, 3)
        vt.state.programStatusEnabled = true
        return vt
    }

    func report(_ vt: inout VT, _ body: String) {
        vt.feed("\u{1B}]7501;\(body)\u{07}")
    }

    func ids(_ vt: borrowing VT) -> [String] {
        vt.state.programStatus.records.map(\.id)
    }

    @Test func `root and child records, child without parent`() {
        var vt = vt()
        report(&vt, "state=working:id=a/b/c")
        report(&vt, "state=idle")
        #expect(ids(vt) == ["a/b/c", ""])
        #expect(vt.state.programStatus.snapshot[""]?.state == .idle)
    }

    @Test func `reports replace whole records`() {
        var vt = vt()
        report(&vt, "state=working:id=build:app=cargo:progress=20")
        report(&vt, "state=working:id=build:progress=30")
        let r = vt.state.programStatus.records
        #expect(r.count == 1)
        #expect(r[0].progress == 30 && r[0].app == nil)
        report(&vt, "state=done:id=build")
        #expect(vt.state.programStatus.records[0].progress == nil)
    }

    @Test func `app inherits from the nearest ancestor`() {
        var vt = vt()
        report(&vt, "state=idle:app=shell")
        report(&vt, "state=working:id=build:app=cargo")
        report(&vt, "state=working:id=build/test/unit")
        report(&vt, "state=working:id=other/x")
        let s = vt.state.programStatus.snapshot
        #expect(s["build/test/unit"]?.app == nil) // stored as reported
        #expect(s.app(for: "build/test/unit") == "cargo") // build/test absent: skipped
        #expect(s.app(for: "build") == "cargo")
        #expect(s.app(for: "other/x") == "shell") // the root last
        #expect(s.app(for: "") == "shell")
        report(&vt, "state=idle")
        #expect(vt.state.programStatus.snapshot.app(for: "other/x") == nil)
    }

    @Test func `exact and descendant clear`() {
        var vt = vt()
        for id in ["build", "build/test", "build/test/unit", "builder", "other/build", "buil"] {
            report(&vt, "state=working:id=\(id)")
        }
        report(&vt, "state=clear:id=build")
        #expect(ids(vt) == ["builder", "other/build", "buil"])
        report(&vt, "state=clear:id=other")
        #expect(ids(vt) == ["builder", "buil"])
    }

    @Test func `clear of a descendant leaves the parent`() {
        var vt = vt()
        report(&vt, "state=working:id=a")
        report(&vt, "state=working:id=a/b")
        report(&vt, "state=clear:id=a/b")
        #expect(ids(vt) == ["a"])
    }

    @Test func `root clear removes everything`() {
        var vt = vt()
        report(&vt, "state=working")
        report(&vt, "state=done:id=x")
        report(&vt, "state=clear")
        #expect(ids(vt).isEmpty)
    }

    @Test func `invalid clear id never clears the root`() {
        var vt = vt()
        report(&vt, "state=working")
        report(&vt, "state=working:id=a")
        report(&vt, "state=clear:id=a//")
        report(&vt, "state=clear:id=")
        #expect(ids(vt) == ["", "a"])
    }

    @Test func `ordering follows updates`() {
        var vt = vt()
        report(&vt, "state=working:id=a")
        report(&vt, "state=working:id=b")
        report(&vt, "state=working:id=c")
        report(&vt, "state=done:id=a")
        #expect(ids(vt) == ["b", "c", "a"])
    }

    @Test func `capacity evicts the least recently updated`() {
        var vt = vt()
        for i in 0 ..< ProgramStatusStore.capacity {
            report(&vt, "state=working:id=r\(i)")
        }
        report(&vt, "state=working:id=r0") // refreshed: now newest, count unchanged
        #expect(vt.state.programStatus.records.count == ProgramStatusStore.capacity)
        report(&vt, "state=working:id=new")
        #expect(vt.state.programStatus.records.count == ProgramStatusStore.capacity)
        #expect(!ids(vt).contains("r1"))
        #expect(ids(vt).contains("r0"))
        #expect(ids(vt).first == "r2" && ids(vt).last == "new")
    }

    @Test func `revisions`() {
        var vt = vt()
        #expect(vt.state.programStatus.revision == 0)
        report(&vt, "state=working:id=a")
        #expect(vt.state.programStatus.revision == 1)
        #expect(vt.state.programStatus.records[0].revision == 1)
        report(&vt, "state=nope")
        report(&vt, "state=clear:id=missing")
        report(&vt, "state=working:id=a//")
        #expect(vt.state.programStatus.revision == 1) // no observable change
        report(&vt, "state=working:id=b")
        report(&vt, "state=done:id=a")
        #expect(vt.state.programStatus.revision == 3)
        #expect(vt.state.programStatus.snapshot["a"]?.revision == 3)
        #expect(vt.state.programStatus.snapshot["b"]?.revision == 2)
        report(&vt, "state=clear")
        #expect(vt.state.programStatus.revision == 4)
    }

    @Test func `change flag only on mutation`() {
        var vt = vt()
        report(&vt, "state=clear")
        #expect(vt.state.takeProgramStatusChange() == nil)
        report(&vt, "state=working")
        report(&vt, "state=done")
        let snapshot = vt.state.takeProgramStatusChange()
        #expect(snapshot?.revision == 2 && snapshot?.records.count == 1)
        #expect(vt.state.takeProgramStatusChange() == nil)
    }

    @Test func `disabling clears records`() {
        var vt = vt()
        report(&vt, "state=done")
        _ = vt.state.takeProgramStatusChange()
        vt.state.programStatusEnabled = false
        #expect(vt.state.programStatus.records.isEmpty)
        #expect(vt.state.takeProgramStatusChange() != nil)
    }
}
