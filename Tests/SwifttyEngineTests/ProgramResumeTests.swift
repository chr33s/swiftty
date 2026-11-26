import Foundation
@testable import SwifttyEngine
import Testing

/// OSC 7577: the documented reports, the ignore/reject table, and checkpoints.
struct ProgramResumeTests {
  static let token = "dummy-token-replace-me"
  static let clock: Int64 = 1_795_543_200

  static let nvim =
    "pid=74877:time=1795543200:argv=bnZpbQ==,LVM=,L2hvbWUvdXNlci8ubG9jYWwvc3RhdGUvbnZpbS9zZXNzaW9ucy84ZjJjMWQudmlt:mac=9dbb99bfb856749a87563839d7ce9062818d78cf25909db93f309e0cd3b1909b"
  static let clear =
    "pid=74877:time=1795543200:clear=1:mac=c30603369f98fef581a4098be889175b0c74f0641e49f8b25f4326cb38f97c93"
  static let lazygit =
    "pid=74877:time=1795543200:argv=bGF6eWdpdA==:cwd=L2hvbWUvdXNlci9zcmMvcHJvamVjdA==:mac=35cb909805c380336efd3689a125acc774a9dec8422a1d21492ebec06ca758e1"
  static let wrapper =
    "pid=90412:time=1795543200:argv=cmVzdW1lLXdyYXA=,c3No,ZGV2Ym94:mac=e76149d0ba54a83570ffab0583867dacdfa23928ba9d18604f0badea88b62b65"

  func make() -> VT {
    var vt = VT(20, 3)
    vt.state.programResumeToken = Self.token
    vt.state.programResumeTime = Self.clock
    return vt
  }

  func osc(_ body: String, bell: Bool = false) -> String {
    "\u{1B}]7577;\(body)" + (bell ? "\u{07}" : "\u{1B}\\")
  }

  func signed(_ prefix: String) -> String {
    let mac = ProgramResumeMAC.hex(
      prefix: Array(prefix.utf8),
      token: Self.token
    )
    return prefix + ":mac=" + mac
  }

  @Test
  func publishedMacsMatchTheToken() {
    let cases = [Self.nvim, Self.clear, Self.lazygit, Self.wrapper]
    for body in cases {
      let parts = body.split(separator: ":mac=", maxSplits: 1)
      let mac = ProgramResumeMAC.hex(
        prefix: Array(parts[0].utf8),
        token: Self.token
      )
      #expect(mac == String(parts[1]))
    }
  }

  @Test
  func documentedReportsStoreTheCommand() {
    var vt = make()
    vt.feed(osc(Self.nvim))
    let nvim = vt.state.programResumeReports
    #expect(nvim.count == 1)
    #expect(nvim.first?.pid == 74877)
    #expect(
      nvim.first?.argv == [
        "nvim", "-S", "/home/user/.local/state/nvim/sessions/8f2c1d.vim",
      ]
    )
    #expect(nvim.first?.workingDirectory == nil)

    vt.feed(osc(Self.lazygit, bell: true))
    let lazy = vt.state.programResumeReports.first
    #expect(lazy?.argv == ["lazygit"])
    #expect(lazy?.workingDirectory == "/home/user/src/project")

    var wrapped = make()
    wrapped.feed(osc(Self.wrapper))
    let command = wrapped.state.programResumeReports.first
    #expect(command?.pid == 90412)
    #expect(command?.argv == ["resume-wrap", "ssh", "devbox"])
  }

  @Test
  func clearRemovesOnlyThatPidAndBlocksAnEarlierReplay() {
    var vt = make()
    vt.feed(osc(Self.nvim))
    vt.feed(osc(Self.wrapper))
    vt.feed(osc(Self.clear, bell: true))
    let left = vt.state.programResumeReports
    #expect(left.map(\.pid) == [90412])
    vt.feed(osc(signed("pid=74877:time=1795543199:argv=bnZpbQ==")))
    let after = vt.state.programResumeReports
    #expect(after.map(\.pid) == [90412])
    vt.feed(osc(signed("pid=74877:time=1795543200:argv=bnZpbQ==")))
    #expect(vt.state.programResumeReports.count == 2)
  }

  @Test
  func invalidTableIgnoresOrRejects() {
    var vt = make()
    vt.feed(osc(Self.nvim))
    let kept = vt.state.programResumeReports
    let ignored = [
      "pid=74877:time=1795543200:argv=bnZpbQ==:mac=0000000000000000000000000000000000000000000000000000000000000000",
      "pid=74877:time=1795543200:argv=bnZpbQ==",
      "mac=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:pid=74877:time=1795543200:argv=bnZpbQ==",
      signed("pid=74877:time=1000000000:argv=bnZpbQ=="),
      signed("pid=74877:argv=bnZpbQ=="), "?",
    ]
    for body in ignored {
      vt.feed(osc(body))
      #expect(vt.state.programResumeReports == kept)
    }
    let rejected = [
      signed("pid=74877:time=1795543200:argv=Li9ydW4uc2g="),
      signed("pid=74877:time=1795543200:argv=bnZpbQ==:clear=1"),
      signed("pid=74877:time=1795543200:argv=bnZpbQ==:cwd=cHJvamVjdA=="),
      signed("pid=74877:time=1795543200:argv=bnZpbQ==:need=later"),
    ]
    for body in rejected {
      var again = make()
      again.feed(osc(Self.nvim))
      again.feed(osc(body))
      #expect(again.state.programResumeReports.isEmpty)
    }
  }

  @Test
  func resetsAndOversizedReportsLeaveTheRecord() {
    var vt = make()
    vt.feed(osc(Self.nvim))
    vt.feed("\u{1B}c")
    vt.feed("\u{1B}[!p")
    let huge = "\u{1B}]7577;" + String(repeating: "a", count: 9000) + "\u{07}"
    vt.feed(huge)
    let leadingZeroHuge =
      "\u{1B}]07577;" + String(repeating: "a", count: 9000) + "\u{07}"
    vt.feed(leadingZeroHuge)
    // RIS, DECSTR, and an oversized body leave the accepted record in place.
    #expect(vt.state.programResumeReports.count == 1)
    var many = "pid=74877:time=1795543200:argv="
    many += Array(repeating: "YQ==", count: 65).joined(separator: ",")
    // 65 elements is authenticated and then rejected, so the record goes.
    vt.feed(osc(signed(many)))
    #expect(vt.state.programResumeReports.isEmpty)

    var kept = make()
    kept.feed(osc(Self.nvim))
    kept.feed(huge)
    #expect(kept.state.programResumeReports.count == 1)
    let wide = String(repeating: "a", count: 4096)
    let encoded = Data(("/" + wide).utf8).base64EncodedString()
    kept.feed(osc(signed("pid=74877:time=1795543200:argv=\(encoded)")))
    #expect(kept.state.programResumeReports.isEmpty)
  }

  @Test
  func unknownKeyIsIgnoredUnlessNeedNamesIt() {
    var vt = make()
    vt.feed(osc(signed("pid=74877:time=1795543200:argv=bnZpbQ==:color=red")))
    #expect(vt.state.programResumeReports.first?.argv == ["nvim"])
    vt.feed(osc(signed("pid=74877:time=1795543200:argv=bnZpbQ==:need=color")))
    #expect(vt.state.programResumeReports.isEmpty)
  }

  @Test
  func checkpointRoundTripOmitsAnEmptyResume() throws {
    var fresh = TerminalState(columns: 8, rows: 3)
    let empty = try fresh.checkpoint()
    var restored = try TerminalState.restored(checkpoint: empty)
    let again = try restored.checkpoint()
    #expect(again == empty)
    #expect(restored.programResumeToken == nil)
    #expect(restored.programResumeReports.isEmpty)

    var vt = make()
    vt.feed(osc(Self.nvim))
    vt.feed(osc(Self.clear))
    var original = vt.state
    let bytes = try original.checkpoint()
    var loaded = try TerminalState.restored(checkpoint: bytes)
    #expect(loaded.programResumeToken == Self.token)
    #expect(loaded.programResumeReports.isEmpty)
    #expect(loaded.programResumeTime == nil)
    let replay = signed("pid=74877:time=1795543199:argv=bnZpbQ==")
    loaded.programResumeTime = Self.clock
    // The clear's time survived the checkpoint, so the older report does not.
    var parser = Parser()
    parser.consume(Array(osc(replay).utf8).span, into: &loaded)
    #expect(loaded.programResumeReports.isEmpty)
    // The test clock is not part of the checkpoint. Restore the original
    // bytes so the rewritten checkpoint stays token-only.
    var fromOriginal = try TerminalState.restored(checkpoint: bytes)
    let rewritten = try fromOriginal.checkpoint()
    #expect(rewritten == bytes)
  }
}
