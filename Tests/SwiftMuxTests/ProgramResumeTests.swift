import Darwin
import Foundation
import SwiftMuxGuardian
import SwiftMuxProtocol
import SwifttyEngine
@testable import SwiftMuxGateway
@testable import SwiftMuxService
import Testing

struct ProgramResumeSelectionTests {
  func info(
    _ ppid: Int32,
    uid: uid_t = 1,
    start: UInt64 = 10
  ) -> ProgramResumeProcessInfo {
    ProgramResumeProcessInfo(ppid: ppid, uid: uid, start: start)
  }

  func report(
    _ pid: Int32,
    _ argv: [String],
    cwd: String? = nil,
    time: Int64 = 50
  ) -> ProgramResumeReport {
    ProgramResumeReport(pid: pid, argv: argv, workingDirectory: cwd, time: time)
  }

  func choose(
    _ reports: [ProgramResumeReport],
    memory: inout ProgramResumeMemory,
    table: [Int32: ProgramResumeProcessInfo],
    root: Int32 = 1,
    now: ContinuousClock.Instant
  ) -> SavedProgramResume? {
    ProgramResumeSelection.select(
      reports: reports,
      memory: &memory,
      lookup: { table[$0] },
      root: root,
      uid: 1,
      now: now
    )
  }

  @Test
  func ancestorBeatsDescendantAndSiblingsChooseNone() {
    let now = ContinuousClock.now
    var memory = ProgramResumeMemory()
    let table: [Int32: ProgramResumeProcessInfo] = [
      1: info(0, start: 1), 2: info(1, start: 2), 3: info(2, start: 3),
    ]
    let command = choose(
      [report(2, ["shell"]), report(3, ["nvim"])],
      memory: &memory,
      table: table,
      now: now
    )
    #expect(command?.argv == ["shell"])

    var siblings = ProgramResumeMemory()
    let both = choose(
      [report(2, ["a"]), report(3, ["b"])],
      memory: &siblings,
      table: [1: info(0), 2: info(1, start: 2), 3: info(1, start: 3)],
      now: now
    )
    #expect(both == nil)
  }

  @Test
  func graceKeepsAJustExitedOwnerAheadOfADescendant() {
    let now = ContinuousClock.now
    var memory = ProgramResumeMemory()
    let alive: [Int32: ProgramResumeProcessInfo] = [
      1: info(0, start: 1), 2: info(1, start: 2), 3: info(2, start: 3),
    ]
    let first = choose(
      [report(2, ["shell"]), report(3, ["nvim"])],
      memory: &memory,
      table: alive,
      now: now
    )
    #expect(first?.argv == ["shell"])
    // The shell has exited. The editor is reparented to the pane root.
    let dying: [Int32: ProgramResumeProcessInfo] = [
      1: info(0, start: 1), 3: info(1, start: 3),
    ]
    let held = choose(
      [report(2, ["shell"]), report(3, ["nvim"])],
      memory: &memory,
      table: dying,
      now: now.advanced(by: .seconds(1))
    )
    #expect(held?.argv == ["shell"])
    let later = choose(
      [report(2, ["shell"]), report(3, ["nvim"])],
      memory: &memory,
      table: dying,
      now: now.advanced(by: .seconds(3))
    )
    #expect(later?.argv == ["nvim"])
  }

  @Test
  func clearDropsTheOwnerAndAReusedPidDoesNotMatch() {
    let now = ContinuousClock.now
    var memory = ProgramResumeMemory()
    let table: [Int32: ProgramResumeProcessInfo] = [
      1: info(0, start: 1), 2: info(1, start: 2),
    ]
    _ = choose([report(2, ["shell"])], memory: &memory, table: table, now: now)
    let cleared = choose([], memory: &memory, table: table, now: now)
    #expect(cleared == nil)

    var reused = ProgramResumeMemory()
    _ = choose([report(2, ["shell"])], memory: &reused, table: table, now: now)
    let replaced = choose(
      [report(2, ["shell"])],
      memory: &reused,
      table: [1: info(0, start: 1), 2: info(1, start: 99)],
      now: now
    )
    #expect(replaced == nil)
  }

  @Test
  func aDeadRootKeepsTheCommandAndAForeignUserDoesNot() {
    let now = ContinuousClock.now
    var memory = ProgramResumeMemory()
    _ = choose(
      [report(2, ["shell"])],
      memory: &memory,
      table: [1: info(0, start: 1), 2: info(1, start: 2)],
      now: now
    )
    let kept = choose(
      [report(2, ["shell"])],
      memory: &memory,
      table: [:],
      now: now.advanced(by: .seconds(30))
    )
    #expect(kept?.argv == ["shell"])

    var foreign = ProgramResumeMemory()
    let rejected = choose(
      [report(2, ["shell"])],
      memory: &foreign,
      table: [1: info(0), 2: info(1, uid: 2)],
      now: now
    )
    #expect(rejected == nil)
  }
}

struct ProgramResumeLaunchTests {
  @Test
  func generatedTokenIsValidAndTheLauncherReplacesAnInheritedOne() {
    let token = ProgramResumeToken.generate()
    #expect(ProgramResumeToken.isValid(token))
    #expect(token.count == 43)
    let launcher = PaneLauncher(
      launcherPath: "/bin/sh",
      innerTerm: "xterm-256color"
    )
    let inherited = "inherited-token-value-xxxx"
    var spec = LaunchSpec(
      environment: [ProgramResumeToken.name: inherited, "HOME": "/tmp"],
      resumeToken: token
    )
    let installed = launcher.environment(
      for: spec,
      pane: PaneID(),
      workspace: WorkspaceID()
    )
    #expect(installed[ProgramResumeToken.name] == token)
    spec.resumeToken = nil
    let stripped = launcher.environment(
      for: spec,
      pane: PaneID(),
      workspace: WorkspaceID()
    )
    #expect(stripped[ProgramResumeToken.name] == nil)
    spec.resumeToken = "short"
    let invalid = launcher.environment(
      for: spec,
      pane: PaneID(),
      workspace: WorkspaceID()
    )
    #expect(invalid[ProgramResumeToken.name] == nil)
  }

  @Test
  func chosenResumeReplacesTheLaunchCommandAndRequiresItsDirectory() throws {
    let state = onePane(
      launch: .command(["top"]),
      directory: "/tmp/saved",
      resume: SavedProgramResume(
        argv: ["nvim", "-S", "/tmp/session"],
        workingDirectory: "/tmp/project"
      )
    )
    let content = try #require(SavedLayoutContent(state))
    let slots = content.commandSlots
    #expect(slots.map(\.command) == [["nvim", "-S", "/tmp/session"]])
    #expect(slots.map(\.origin) == [.resume])
    #expect(
      slots.first?.listingLabel
        == "nvim -S /tmp/session — the program's resume command"
    )
    // Launch and resume stay beside the decision for an older reader.
    #expect(content.panes[0].launch == .command(["top"]))
    #expect(content.panes[0].resume?.argv == ["nvim", "-S", "/tmp/session"])
    #expect(content.panes[0].reopen?.origin == .resume)
    #expect(content.panes[0].reopen?.directoryRequired == true)
    let base = LaunchSpec(workingDirectory: "/home", environment: [:])
    let chosen = content.template(
      SavedReopenRequest(
        record: state.graph!.id,
        launch: base,
        runCommandSlots: [0]
      ),
      name: "work"
    )
    #expect(chosen.panes[0].command == ["nvim", "-S", "/tmp/session"])
    #expect(chosen.panes[0].workingDirectory == "/tmp/project")
    #expect(chosen.directoryRequiredSlots == [0])
    let shells = content.template(
      SavedReopenRequest(record: state.graph!.id, launch: base),
      name: "work"
    )
    #expect(shells.panes[0].command == nil)
    #expect(shells.directoryRequiredSlots.isEmpty)

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("resume-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let present = MuxService.withoutMissingResumeDirectory(
      LaunchSpec(
        command: ["nvim"],
        workingDirectory: directory.path,
        environment: [:]
      )
    )
    #expect(present.command == ["nvim"])
    let gone = MuxService.withoutMissingResumeDirectory(
      LaunchSpec(
        command: ["nvim"],
        workingDirectory: directory.path + "-missing",
        environment: [:]
      )
    )
    #expect(gone.command == nil)
    #expect(gone.workingDirectory == directory.path + "-missing")
    let file = directory.appendingPathComponent("not-a-directory")
    try Data("x".utf8).write(to: file)
    let blocked = MuxService.withoutMissingResumeDirectory(
      LaunchSpec(
        command: ["nvim"],
        workingDirectory: file.path,
        environment: [:]
      )
    )
    #expect(blocked.command == nil)
    #expect(blocked.workingDirectory == file.path)
  }

  @Test
  func publishedLaunchCommandIsCopiedAheadOfResume() throws {
    let resume = SavedProgramResume(
      argv: ["nvim", "-S", "/tmp/session"],
      workingDirectory: "/tmp/project"
    )
    let state = onePane(
      launch: .command(["top"]),
      directory: "/tmp/saved",
      resume: resume,
      reopen: SavedReopenCommand(argv: ["top"], origin: .launch)
    )
    let content = try #require(SavedLayoutContent(state))
    #expect(content.panes[0].launch == .command(["top"]))
    #expect(content.panes[0].resume == resume)
    #expect(content.panes[0].reopen?.argv == ["top"])
    #expect(content.panes[0].reopen?.origin == .launch)
    #expect(content.panes[0].reopen?.directoryRequired == false)
    let slot = try #require(content.commandSlots.first)
    #expect(slot.origin == .launch)
    #expect(slot.listingLabel == "top — the command this pane was opened with")
    let chosen = content.template(
      SavedReopenRequest(
        record: try #require(state.graph?.id),
        launch: LaunchSpec(workingDirectory: "/home", environment: [:]),
        runCommandSlots: [0]
      ),
      name: "work"
    )
    #expect(chosen.panes[0].command == ["top"])
    #expect(chosen.panes[0].workingDirectory == "/tmp/saved")
    #expect(chosen.directoryRequiredSlots.isEmpty)
  }

  @Test
  func olderRecordWithoutAReopenCommandPrefersResume() throws {
    let state = onePane(
      launch: .command(["top"]),
      directory: "/tmp/saved",
      resume: SavedProgramResume(
        argv: ["nvim", "-S", "/tmp/session"],
        workingDirectory: "/tmp/project"
      )
    )
    let content = try #require(SavedLayoutContent(state))
    let encoded = try JSONEncoder().encode(content)
    let object = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    var panes = try #require(object["panes"] as? [[String: Any]])
    #expect(panes[0]["reopen"] != nil)
    panes[0].removeValue(forKey: "reopen")
    var stripped = object
    stripped["panes"] = panes
    let decoded = try JSONDecoder()
      .decode(
        SavedLayoutContent.self,
        from: JSONSerialization.data(withJSONObject: stripped)
      )
    #expect(decoded.panes[0].reopen == nil)
    #expect(decoded.panes[0].launch == .command(["top"]))
    #expect(decoded.panes[0].resume?.argv == ["nvim", "-S", "/tmp/session"])
    let decision = SavedLayoutContent.reopenDecision(decoded.panes[0])
    #expect(decision?.origin == .resume)
    #expect(decision?.directoryRequired == true)
    let chosen = decoded.template(
      SavedReopenRequest(
        record: try #require(state.graph?.id),
        launch: LaunchSpec(workingDirectory: "/home", environment: [:]),
        runCommandSlots: [0]
      ),
      name: "work"
    )
    #expect(chosen.panes[0].command == ["nvim", "-S", "/tmp/session"])
    #expect(chosen.panes[0].workingDirectory == "/tmp/project")
    #expect(chosen.directoryRequiredSlots == [0])
    #expect(
      decoded.commandSlots.first?.listingLabel
        == "nvim -S /tmp/session — the program's resume command"
    )
  }

  @Test
  func unrunnableReopenCommandDoesNotFallThrough() {
    let resume = SavedProgramResume(
      argv: ["nvim"],
      workingDirectory: "/tmp/project"
    )
    let pane = SavedPaneContent(
      launch: .command(["top"]),
      localDirectory: "/tmp/saved",
      resume: resume,
      reopen: SavedReopenCommand(argv: ["-nvim"], origin: .launch)
    )
    #expect(SavedLayoutContent.reopenDecision(pane) == nil)
    #expect(
      SavedLayoutContent.storedReopen(
        pane.reopen,
        launch: pane.launch,
        resume: pane.resume
      ) == nil
    )
    let resolved = SavedLayoutContent.storedReopen(
      nil,
      launch: pane.launch,
      resume: pane.resume
    )
    #expect(resolved?.origin == .resume)
    #expect(resolved?.directoryRequired == true)
    #expect(
      SavedReopenCommand.resolve(launch: .command(["./tool"]), resume: nil)
        == nil
    )
    #expect(
      SavedReopenCommand.resolve(launch: .commandTooLong, resume: nil) == nil
    )
    #expect(SavedReopenCommand.resolve(launch: .loginShell, resume: nil) == nil)
    #expect(
      SavedWorkspaceListing.CommandSlot(slot: 0, command: ["top"]).listingLabel
        == "top"
    )
  }

  private func onePane(
    launch: SavedPaneLaunch,
    directory: String?,
    resume: SavedProgramResume? = nil,
    reopen: SavedReopenCommand? = nil
  ) -> SavedLayoutState {
    let pane = PaneID()
    let tab = TabID()
    return SavedLayoutState(
      graph: WorkspaceSnapshot(
        id: WorkspaceID(),
        name: "work",
        tabs: [
          TabSnapshot(
            id: tab,
            name: "edit",
            layout: .pane(pane),
            activePane: pane
          )
        ],
        activeTab: tab,
        panes: [PaneSummary(id: pane, columns: 80, rows: 24)],
        layoutRevision: 1
      ),
      panes: [
        SavedPaneMetadata(
          pane: pane,
          launch: launch,
          localDirectory: directory,
          resume: resume,
          reopen: reopen
        )
      ],
      outputOptOut: false,
      causes: .metadata,
      end: nil
    )
  }
}
