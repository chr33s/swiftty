import Foundation
import ScreenProtocol
import SessionCore
import SwiftMuxProtocol
@testable import SwiftMuxService
import SwifttyCore
@testable import TerminalHost
import Testing

@testable import RoamingKit
@testable import TerminalSurface

/// Wheel notches from a roaming frontend to the host's pane, so a program
/// tracking the mouse on the alternate screen scrolls instead of seeing
/// arrow keys.
struct MouseWheelProtocolTests {
  @Test
  func `frontend wheel presses become semantic wheel input`() {
    #expect(
      SurfaceInput(
        .mouse(
          MouseEvent(
            .press,
            .wheelUp,
            column: 4,
            row: 7,
            modifiers: [.shift, .command]
          )
        )
      ) == .wheel(SemanticWheel(.up, column: 4, row: 7, modifiers: .shift))
    )
    #expect(
      SurfaceInput(.mouse(MouseEvent(.press, .wheelLeft, column: 0, row: 0)))
        == .wheel(SemanticWheel(.left, column: 0, row: 0))
    )
    #expect(
      SurfaceInput(.mouse(MouseEvent(.release, .wheelUp, column: 0, row: 0)))
        == nil
    )
    #expect(
      SurfaceInput(.mouse(MouseEvent(.press, .left, column: 0, row: 0))) == nil
    )
    let wheel = SurfaceInput.wheel(SemanticWheel(.down, column: 2, row: 3))
    guard case let .mouse(event) = wheel.terminalInput else {
      Issue.record("not a mouse event")
      return
    }
    #expect(event == MouseEvent(.press, .wheelDown, column: 2, row: 3))
  }

  @Test
  func `wheel input is required of every host`() {
    let wheel = InputOperation.wheel(SemanticWheel(.up, column: 1, row: 1))
    #expect(RSTFeatures.required.contains(.mouseWheel))
    #expect(RoamingClient.operation(wheel, for: .required) == wheel)
    #expect(RoamingClient.fitsControlRecord(wheel))
  }

  @Test
  func `the roaming host forwards wheel input as a pane mouse press`() {
    let mouse = RoamingSession.muxMouse(
      SemanticWheel(.right, column: 5, row: 6, modifiers: [.control, .alt])
    )
    #expect(
      mouse
        == MuxMouse(
          .press,
          .wheelRight,
          column: 5,
          row: 6,
          modifiers: [.control, .alt]
        )
    )
    #expect(
      RoamingSession.muxMouse(SemanticWheel(.up, column: 0, row: 0)).button
        == .wheelUp
    )
  }

  @Test
  func `panes report forwarded wheel presses with the program's encoding`() {
    var modes = Modes.initial.union([.alternateScreen, .mouseNormal, .mouseSGR])
    var out: [UInt8] = []
    let event = PaneRuntime.mouse(
      RoamingSession.muxMouse(SemanticWheel(.up, column: 2, row: 3))
    )
    #expect(InputEncoder.encode(.mouse(event), modes: modes, into: &out))
    #expect(String(decoding: out, as: UTF8.self) == "\u{1B}[<64;3;4M")
    modes.subtract(Modes.mouseTracking)
    out.removeAll()
    #expect(!InputEncoder.encode(.mouse(event), modes: modes, into: &out))
  }

  @Test
  func `snapshots carry mouse tracking only when set`() throws {
    var snapshot = ScreenSnapshot.blank(
      sessionID: .random(),
      columns: 2,
      rows: 1
    )
    let plain = try JSONEncoder().encode(snapshot)
    #expect(!String(decoding: plain, as: UTF8.self).contains("mouseTracking"))
    #expect(
      try JSONDecoder().decode(ScreenSnapshot.self, from: plain) == snapshot
    )
    snapshot.mouseTracking = true
    let tracked = try JSONEncoder().encode(snapshot)
    #expect(
      try JSONDecoder().decode(ScreenSnapshot.self, from: tracked) == snapshot
    )
    #expect(PresentationMapper.map(snapshot).mouseTracking)
  }

  @Test
  func `presentation sessions show the host's mouse tracking`() {
    let session = TerminalSession(presentationColumns: 2, rows: 1)
    var frame = PresentationMapper.map(
      ScreenSnapshot.blank(sessionID: .random(), columns: 2, rows: 1)
    )
    frame.alternateScreen = true
    frame.mouseTracking = true
    #expect(session.installPresentation(frame))
    let tracked = session.snapshot().modes
    #expect(!tracked.isDisjoint(with: Modes.mouseTracking))
    // Roaming surfaces keep taps local but route scrolling to the wheel.
    #expect(
      SurfaceCapabilities.roaming.effectiveModes(tracked)
        .isDisjoint(with: Modes.mouseTracking)
    )
    #expect(
      !SurfaceCapabilities.roaming.scrollModes(tracked)
        .isDisjoint(with: Modes.mouseTracking)
    )
    frame.mouseTracking = false
    #expect(session.installPresentation(frame))
    #expect(session.snapshot().modes.isDisjoint(with: Modes.mouseTracking))
  }
}
