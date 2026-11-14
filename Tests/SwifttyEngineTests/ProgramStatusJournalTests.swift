@testable import SwifttyEngine
import Testing

/// The OSC 7501 change journal: every transition in stream order, for
/// consumers (the attention inbox) that must not lose rapid changes.
struct ProgramStatusJournalTests {
  @Test(arguments: [-1, 0, 1, 2, 5, 6], [false, true])
  func `lowering the journal limit immediately bounds pending changes`(
    _ limit: Int,
    _ reset: Bool
  ) throws {
    var vt = vt(journal: 8)
    report(&vt, "state=working:id=before")
    if reset { vt.feed("\u{1B}c") }
    for id in ["a", "b", "c", "d"] { report(&vt, "state=working:id=\(id)") }
    vt.state.programStatusJournalLimit = limit
    let taken = vt.state.takeProgramStatusJournal()
    let journal = try #require(taken)
    #expect(
      journal.snapshot.records.map(\.id) == (reset ? [] : ["before"]) + [
        "a", "b", "c", "d",
      ]
    )
    if limit <= 0 {
      #expect(journal.changes.isEmpty && !journal.truncated)
    } else if limit < (reset ? 6 : 5) {
      #expect(journal.changes == (reset ? [.reset] : []) && journal.truncated)
    } else {
      #expect(journal.changes.count == (reset ? 6 : 5) && !journal.truncated)
    }
  }

  func vt(journal: Int = 64) -> VT {
    var vt = VT(20, 3)
    vt.state.programStatusEnabled = true
    vt.state.programStatusJournalLimit = journal
    return vt
  }

  func report(_ vt: inout VT, _ body: String) {
    vt.feed("\u{1B}]7501;\(body)\u{07}")
  }

  func states(_ changes: [ProgramStatusChange]) -> [String] {
    changes.map {
      switch $0 {
      case let .report(r): "\(r.id):\(r.state)"
      case let .removed(ids): "-\(ids.joined(separator: ","))"
      case .reset: "reset"
      }
    }
  }

  @Test
  func `rapid transitions are journaled in order`() throws {
    var vt = vt()
    report(&vt, "state=blocked:kind=question")
    report(&vt, "state=working")
    report(&vt, "state=blocked:kind=question")
    let taken = vt.state.takeProgramStatusJournal()
    let journal = try #require(taken)
    #expect(!journal.truncated)
    #expect(states(journal.changes) == [":blocked", ":working", ":blocked"])
    #expect(journal.snapshot.records.map(\.state) == [.blocked])
    let again = vt.state.takeProgramStatusJournal()
    #expect(again == nil)
  }

  @Test
  func `clear, prompt and exit journal removals`() throws {
    var vt = vt()
    report(&vt, "state=working:id=a")
    report(&vt, "state=done:id=b")
    report(&vt, "state=working:id=b/c")
    report(&vt, "state=clear:id=b")
    vt.feed("\u{1B}]133;A\u{07}")
    report(&vt, "state=blocked:id=q")
    vt.state.programExited()
    let taken = vt.state.takeProgramStatusJournal()
    let journal = try #require(taken)
    #expect(
      states(journal.changes) == [
        "a:working", "b:done", "b/c:working", "-b,b/c", "-a", "q:blocked", "-q",
      ]
    )
  }

  @Test
  func `RIS journals a reset even with no records`() throws {
    var vt = vt()
    vt.feed("\u{1B}c")
    let taken = vt.state.takeProgramStatusJournal()
    let journal = try #require(taken)
    #expect(journal.changes == [.reset])
  }

  @Test
  func `overflow truncates but keeps the reset`() throws {
    var vt = vt(journal: 2)
    report(&vt, "state=working")
    vt.feed("\u{1B}c")
    report(&vt, "state=working:id=a")
    report(&vt, "state=done:id=a")
    let taken = vt.state.takeProgramStatusJournal()
    let journal = try #require(taken)
    #expect(journal.truncated)
    #expect(journal.changes == [.reset])
    #expect(journal.snapshot.records.map(\.id) == ["a"])
  }

  @Test
  func `without a limit nothing is journaled`() throws {
    var vt = vt(journal: 0)
    report(&vt, "state=working")
    let taken = vt.state.takeProgramStatusJournal()
    let journal = try #require(taken)
    #expect(journal.changes.isEmpty && !journal.truncated)
  }

  @Test
  func `capacity is configurable within the protocol range`() throws {
    var vt = vt()
    for i in 0 ..< 80 { report(&vt, "state=working:id=r\(i)") }
    _ = vt.state.takeProgramStatusJournal()
    vt.state.programStatusCapacity = 64
    #expect(vt.state.programStatus.records.count == 64)
    #expect(vt.state.programStatus.records.first?.id == "r16")
    let taken = vt.state.takeProgramStatusJournal()
    let journal = try #require(taken)
    #expect(journal.changes == [.removed((0 ..< 16).map { "r\($0)" })])
    report(&vt, "state=working:id=new")
    #expect(vt.state.programStatus.records.count == 64)
    vt.state.programStatusCapacity = 1
    let capacity = vt.state.programStatusCapacity
    #expect(capacity == ProgramStatusStore.minimumCapacity)
  }
}
