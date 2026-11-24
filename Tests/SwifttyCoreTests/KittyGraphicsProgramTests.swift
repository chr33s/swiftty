import Foundation
@testable import SwifttyCore
@testable import SwifttyEngine
import Testing
import TestSupport

/// Kitty graphics from real programs on a macOS PTY (spec.graphics.md
/// KG26) and through tmux with the §17.1 configuration (KG27, guidance).
///
/// `kitten icat` is not a test dependency: the programs replay what icat
/// emits for each transfer mode (direct chunks, `t=f`, `t=t`, `t=s`, and
/// `--unicode-placeholder`), byte for byte, from a shell on the PTY.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct KittyGraphicsProgramTests {
  typealias Harness = IntegrationTests.Harness

  private static let id = 42
  private static let pixels = Array(
    [[UInt8]](repeating: [255, 0, 0, 255], count: 4).joined()
  )

  private let directory: URL = {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "swiftty-kitty-\(UUID().uuidString)"
    )
    try? FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true
    )
    return url
  }()

  private func write(_ name: String, _ bytes: [UInt8]) throws -> String {
    let url = directory.appendingPathComponent(name)
    try Data(bytes).write(to: url)
    return url.path
  }

  private static func apc(_ body: String) -> [UInt8] {
    Array("\u{1B}_G\(body)\u{1B}\\".utf8)
  }

  /// icat's direct transfer: 4096-byte base64 chunks.
  private static func direct(_ keys: String) -> [UInt8] {
    let encoded = Array(Data(pixels).base64EncodedString().utf8)
    var out: [UInt8] = []
    var i = 0
    while i < encoded.count || i == 0 {
      let end = min(encoded.count, i + 4096)
      let more = end < encoded.count ? 1 : 0
      let head = i == 0 ? "\(keys),m=\(more)" : "m=\(more)"
      out +=
        Array("\u{1B}_G\(head);".utf8) + encoded[i ..< end]
        + Array("\u{1B}\\".utf8)
      i = end
    }
    return out
  }

  /// `--unicode-placeholder` cells for a columns×rows virtual placement at
  /// pane row `row` (1-based), column 1, in the image's 256-colour id.
  private static func placeholders(
    columns: Int,
    rows: Int,
    at row: Int
  ) -> [UInt8] {
    let d = KittyGraphics.diacritics
    var text = "\u{1B}[38;5;\(id)m"
    for r in 0 ..< rows {
      text += "\u{1B}[\(row + r);1H"
      for c in 0 ..< columns {
        text.unicodeScalars.append(Unicode.Scalar(KittyGraphics.placeholder)!)
        text.unicodeScalars.append(Unicode.Scalar(d[r])!)
        text.unicodeScalars.append(Unicode.Scalar(d[c])!)
      }
    }
    return Array((text + "\u{1B}[39m\u{1B}[\(row + rows + 1);1H").utf8)
  }

  /// tmux `allow-passthrough`: the sequence inside DCS tmux; with each ESC
  /// doubled.
  private static func passthrough(_ bytes: [UInt8]) -> [UInt8] {
    var out = Array("\u{1B}Ptmux;".utf8)
    for b in bytes {
      if b == 0x1B { out.append(0x1B) }
      out.append(b)
    }
    return out + Array("\u{1B}\\".utf8)
  }

  private func run(
    _ bytes: [UInt8],
    marker: String = "icat-done"
  ) throws -> Harness {
    let path = try write("out.bin", bytes)
    let h = try Harness([
      "/bin/sh", "-c", "cat '\(path)'; echo \(marker); sleep 5",
    ])
    h.session.setCellPixelSize(width: 10, height: 20)
    return h
  }

  private func placements(_ h: Harness) -> [KittyGraphics.Placement] {
    h.session.snapshot().images
  }

  private func storedImage(_ h: Harness) -> Bool {
    h.session.withState { $0.kittyImages.image(id: UInt32(Self.id)) != nil }
  }

  private func waitFor(_ what: String, _ h: Harness, _ ok: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      if ok() { return true }
      usleep(20000)
    }
    Issue.record(
      Comment(
        rawValue: escapedTestText("timed out waiting for \(what):\n\(h.screen)")
      )
    )
    return false
  }

  @Test
  func `icat direct transfer displays at the cursor`() throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let h = try run(Self.direct("a=T,f=32,s=2,v=2,i=\(Self.id),c=3,r=2,q=2"))
    defer { h.session.stop() }
    #expect(h.wait(for: "icat-done"))
    let p = try #require(placements(h).first)
    #expect((p.row, p.column, p.columns, p.rows) == (0, 0, 3, 2))
  }

  @Test(arguments: ["f", "t"])
  func `icat file and temp-file transfer read the program's files`(
    _ medium: String
  ) throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    // Temp files must be named for the protocol and are deleted after.
    let file = try write(
      "img-tty-graphics-protocol-\(medium).rgba",
      Self.pixels
    )
    let name = Data(file.utf8).base64EncodedString()
    let h = try run(
      Self.apc("a=T,t=\(medium),f=32,s=2,v=2,i=\(Self.id),q=2;\(name)")
    )
    defer { h.session.stop() }
    #expect(h.wait(for: "icat-done"))
    #expect(waitFor("placement", h) { !placements(h).isEmpty })
    #expect(FileManager.default.fileExists(atPath: file) == (medium == "f"))
  }

  @Test(.enabled(if: IntegrationTests.which("python3") != nil))
  func `icat shared-memory transfer reads and unlinks the object`() throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let python = try #require(IntegrationTests.which("python3"))
    let shm = "/swiftty-kitty-\(UInt32.random(in: 0 ... .max))"
    let name = Data(shm.utf8).base64EncodedString()
    let script = try write(
      "shm.py",
      Array(
        """
        import sys, time
        from multiprocessing import shared_memory, resource_tracker
        name = "\(shm.dropFirst())"
        m = shared_memory.SharedMemory(name=name, create=True, size=16)
        resource_tracker.unregister(m._name, "shared_memory")
        m.buf[:16] = bytes([255, 0, 0, 255] * 4)
        sys.stdout.write("\\x1b_Ga=T,t=s,f=32,s=2,v=2,i=\(Self.id),q=2;\(name)\\x1b\\\\")
        sys.stdout.flush()
        time.sleep(1)
        try:
            shared_memory.SharedMemory(name=name).unlink()
            print("shm-present")
        except FileNotFoundError:
            print("shm-gone")
        time.sleep(5)
        """
        .utf8
      )
    )
    let h = try Harness([python, "-I", script])
    defer { h.session.stop() }
    h.session.setCellPixelSize(width: 10, height: 20)
    #expect(waitFor("placement", h) { !placements(h).isEmpty })
    // The terminal unlinks the object once read, as kitty does.
    #expect(h.wait(for: "shm-gone"))
  }

  @Test
  func `icat unicode placeholders draw where the program prints them`() throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let h = try run(
      Self.direct("a=T,U=1,f=32,s=2,v=2,i=\(Self.id),c=4,r=2,q=2")
        + Self.placeholders(columns: 4, rows: 2, at: 5)
    )
    defer { h.session.stop() }
    #expect(h.wait(for: "icat-done"))
    let rows = placements(h).filter(\.isPlaceholder).map(\.row).sorted()
    #expect(rows == [4, 5])
  }

  // MARK: tmux (KG27, guidance)

  private struct Tmux {
    let tmux: String
    let socket = "swiftty-kitty-" + UUID().uuidString
    let config: String
    let script: String
    let hidden: String

    func kill() {
      _ = try? TestCommand.run(
        tmux,
        arguments: ["-L", socket, "kill-server"],
        timeout: .seconds(3)
      )
    }
  }

  private func tmux(passthrough: String) throws -> Tmux? {
    guard let tmux = IntegrationTests.which("tmux") else { return nil }
    let config = try write(
      "tmux.conf",
      Array(
        """
        set -g allow-passthrough \(passthrough)
        set -g default-terminal tmux-256color
        set -g status off
        set -g prefix C-b

        """
        .utf8
      )
    )
    let transmit = Self.passthrough(
      Self.direct("a=T,U=1,f=32,s=2,v=2,i=\(Self.id),c=4,r=2,q=2")
    )
    let script = try write(
      "icat.bin",
      transmit + Self.placeholders(columns: 4, rows: 2, at: 5)
    )
    let hidden = try write(
      "hidden.bin",
      Self.passthrough(Self.direct("a=t,f=32,s=2,v=2,i=\(Self.id),q=2"))
    )
    return Tmux(tmux: tmux, config: config, script: script, hidden: hidden)
  }

  private func start(_ t: Tmux) throws -> Harness {
    let h = try Harness(
      [t.tmux, "-L", t.socket, "-f", t.config, "new-session", "/bin/sh"],
      env: ["PS1": "$ "]
    )
    h.session.setCellPixelSize(width: 10, height: 20)
    return h
  }

  private func prefix(_ h: Harness, _ key: String) {
    h.session.send(.key(KeyEvent(.character("b"), modifiers: .control)))
    h.type(key)
  }

  private func placeholderColumns(_ h: Harness) -> [Int] {
    placements(h).filter(\.isPlaceholder).map(\.column)
  }

  @Test(.enabled(if: IntegrationTests.which("tmux") != nil))
  func `tmux placeholders follow splits zoom and window switches`() throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let t = try #require(try tmux(passthrough: "on"))
    defer { t.kill() }
    let h = try start(t)
    defer { h.session.stop() }
    #expect(h.wait(for: "$"))
    prefix(h, "%")  // split: the new right pane is active
    #expect(h.wait("pane border") { $0.contains("│") })
    h.type("clear; cat '\(t.script)'; echo tmux-done\r")
    #expect(h.wait(for: "tmux-done"))
    // In the right pane, offset by the left pane and border.
    #expect(
      waitFor("placeholders in the right pane", h) {
        placeholderColumns(h).allSatisfy { $0 > 30 }
          && !placeholderColumns(h).isEmpty
      }
    )
    prefix(h, "z")  // zoom: the pane fills the window
    #expect(
      waitFor("placeholders after zoom", h) { placeholderColumns(h) == [0, 0] }
    )
    prefix(h, "z")
    prefix(h, "c")  // a new window hides them
    #expect(waitFor("placeholders hidden", h) { placeholderColumns(h).isEmpty })
    prefix(h, "p")  // back: tmux redraws the cells and the image returns
    #expect(
      waitFor("placeholders restored", h) { placeholderColumns(h).count == 2 }
    )
    prefix(h, "[")  // copy mode keeps the cells on screen
    #expect(
      waitFor("placeholders in copy mode", h) {
        placeholderColumns(h).count == 2
      }
    )
    h.type("q")
  }

  @Test(
    .enabled(if: IntegrationTests.which("tmux") != nil),
    arguments: ["on", "all"]
  )
  func `tmux forwards a hidden pane's transmit only with passthrough all`(
    _ mode: String
  ) throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let t = try #require(try tmux(passthrough: mode))
    defer { t.kill() }
    let h = try start(t)
    defer { h.session.stop() }
    #expect(h.wait(for: "$"))
    // Window 0 transmits two seconds later, while window 1 is shown.
    h.type("sleep 2; cat '\(t.hidden)'\r")
    prefix(h, "c")
    #expect(h.wait(for: "$"))
    usleep(3_500_000)
    #expect(storedImage(h) == (mode == "all"))
  }
}
