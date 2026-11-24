import AppKit
import SwiftMuxProtocol
import SwifttyCore
import SwifttyJS
import ProgramIcons
@testable import Swiftty
import Testing

@MainActor
struct MuxIconTests {
  @Test
  func `programs map to brand icons from the local table`() {
    #expect(MuxIcons.icon(for: "claude") == .claude)
    #expect(MuxIcons.icon(for: "git log").brand == "git")
    #expect(MuxIcons.icon(for: "nvim notes.md").brand == "neovim")
    #expect(MuxIcons.icon(for: "vim notes.md") == MuxIcon(symbol: "doc.text"))
    #expect(MuxIcons.icon(for: "brew upgrade").brand == "homebrew")
    #expect(MuxIcons.icon(for: "zsh ~") == .terminal)
    #expect(MuxIcons.icon(for: "") == .terminal)
    // Words only: a program name inside another word picks nothing.
    #expect(MuxIcons.icon(for: "gopher digit") == .terminal)
  }

  @Test
  func `Claude Code's status glyph picks its icon and leaves the title`() {
    for title in [
      "✳ Build and lint warnings", "✳️ Build and lint warnings",
      "⠂ Build and lint warnings", "⠐ Build and lint warnings",
    ] {
      #expect(MuxIcons.icon(for: title) == .claude)
      #expect(MuxIcons.displayTitle(title) == "Build and lint warnings")
    }
    // Without the space it is part of the title, not a status.
    #expect(MuxIcons.icon(for: "✳build") == .terminal)
    #expect(MuxIcons.displayTitle("✳build") == "✳build")
    #expect(MuxIcons.displayTitle("✳ ") == "")
    #expect(MuxIcons.displayTitle("zsh ~") == "zsh ~")
  }

  @Test
  func `every brand in the table ships and loads as a template`() throws {
    let brands = Set(MuxIcons.table.compactMap(\.1.brand))
    #expect(brands.count >= 10)
    for brand in brands {
      let image = try #require(MuxIcons.brandImage(brand), "\(brand)")
      #expect(image.isTemplate)
      #expect(image.size.width > 0 && image.size.height > 0)
    }
    #expect(MuxIcons.brandImage("not-a-brand") == nil)
    // A missing brand falls back to its symbol.
    #expect(MuxIcons.image(MuxIcon(symbol: "terminal", brand: "nope")) != nil)
  }

  @Test
  func `a split tab stacks its panes' tiles, the active one in front`() {
    let badge = MuxTabIconBadge()
    badge.heightAnchor.constraint(equalToConstant: 20).isActive = true
    badge.icons = [.terminal]
    badge.layoutSubtreeIfNeeded()
    #expect(badge.tiles.filter { !$0.isHidden }.count == 1)
    #expect(badge.fittingSize.width == 20)
    badge.icons = [.claude, .terminal, .claude]
    badge.layoutSubtreeIfNeeded()
    let shown = badge.tiles.filter { !$0.isHidden }
    #expect(shown.map(\.icon) == [.claude, .terminal])
    #expect(badge.fittingSize.width == 20 + MuxTabIconBadge.peek)
    // The front tile draws over the one behind it.
    let order = badge.subviews.compactMap { $0 as? MuxIconTile }
    #expect(order.last === shown[0])
    #expect(shown[1].frame.minX == MuxTabIconBadge.peek)
    // A branded tile takes its color; a plain one stays neutral.
    #expect(shown[0].fill.usingColorSpace(.sRGB)?.redComponent ?? 0 > 0.8)
    badge.icons = [.terminal]
    #expect(badge.tiles.filter { !$0.isHidden }.map(\.icon) == [.terminal])
  }
}

@MainActor
struct MuxProgramIconTests {
  @Test
  func `program names are bare, sanitized executable names`() {
    #expect(ProgramName.sanitize("/usr/bin/git") == "git")
    #expect(ProgramName.sanitize("-zsh") == "zsh")
    #expect(ProgramName.sanitize("python3.12") == "python3.12")
    #expect(ProgramName.sanitize("mosh-client") == "mosh-client")
    #expect(ProgramName.sanitize("") == nil)
    #expect(ProgramName.sanitize("bad name") == nil)
    #expect(ProgramName.sanitize("\u{1b}]0;x") == nil)
    #expect(ProgramName.sanitize("gït") == nil)
    #expect(ProgramName.sanitize(String(repeating: "a", count: 65)) == nil)
    #expect(ProgramName.command("git push") == "git")
    #expect(
      ProgramName.command("  sudo -E env A=1 nohup ./bin/claude -p x")
        == "claude"
    )
    #expect(ProgramName.command("FOO=1 BAR=2") == nil)
    #expect(ProgramName.command("") == nil)
  }

  @Test
  func `a pane's icon takes the most specific source`() {
    // The program beats the title's words.
    #expect(MuxIcons.icon(title: "zsh ~", program: "git").brand == "git")
    // A shell or unknown program leaves the title to decide.
    #expect(MuxIcons.icon(title: "git log", program: "zsh").brand == "git")
    #expect(MuxIcons.icon(title: "~/src", program: "make") == .terminal)
    // A runtime defers to a title naming the tool it runs...
    #expect(MuxIcons.icon(title: "codex", program: "node").brand == "openai")
    // ...but stands when the title names nothing.
    #expect(MuxIcons.icon(title: "~/src", program: "node").brand == "nodejs")
    #expect(MuxIcons.icon(title: "x", program: "python3.12").brand == "python")
    // Claude Code's status glyph beats its process name.
    #expect(MuxIcons.icon(title: "✳ Fix it", program: "2.1.0") == .claude)
    // A script's choice beats everything, by table key only.
    #expect(
      MuxIcons.icon(title: "✳ Fix it", program: "git", override: "docker").brand
        == "docker"
    )
    #expect(MuxIcons.icon(title: "vim", override: "terminal") == .terminal)
    #expect(
      MuxIcons.icon(title: "git", override: "/tmp/evil.svg").brand == "git"
    )
  }
}

extension MuxNativeTests {
  @Test(.enabled(if: hasMetal))
  func `the service reports each pane's foreground program for its icon`()
    async throws
  {
    let f = try await open()
    defer { f.controller.close() }
    let c = f.controller
    let pane = try #require(c.activePane)
    // The shell itself first (`/bin/sh` is bash or dash by another name).
    #expect(await until { c.displayState.programs[pane] != nil })
    let shell = try #require(c.displayState.programs[pane])
    #expect(["bash", "sh", "dash", "zsh"].contains(shell))
    // A program the shell runs, then the shell again once it ends. The
    // stand-ins are scripts: an interpreter is named by its script.
    c.send(
      .text(
        "d=$(mktemp -d); for p in git ssh; do printf '#!/bin/sh\\nsleep 30\\n'"
          + " > \"$d/$p\"; chmod +x \"$d/$p\"; done; \"$d/git\"\r"
      ),
      to: pane
    )
    #expect(await until { c.displayState.programs[pane] == "git" })
    #expect(c.icon(of: pane).brand == "git")
    #expect(c.tabStrip.buttons.first?.item?.icons.first?.brand == "git")
    c.send(.text("\u{3}"), to: pane)
    #expect(await until { c.displayState.programs[pane] == shell })
    // Behind ssh, the remote shell's marked command names the program.
    c.send(
      .text(
        "printf '\\033]133;A\\007$ \\033]133;B\\007claude --resume"
          + "\\033]133;C\\007\\n'; \"$d/ssh\"\r"
      ),
      to: pane
    )
    #expect(await until { c.displayState.programs[pane] == "claude" })
    #expect(c.icon(of: pane) == .claude)
    // Once it ends, the local shell is back.
    c.send(.text("\u{3}"), to: pane)
    c.send(.text("printf '\\033]133;D;0\\007'; rm -rf \"$d\"\r"), to: pane)
    #expect(await until { c.displayState.programs[pane] == shell })
  }

  @Test(.enabled(if: hasMetal))
  func `a script picks a pane's icon from the built-in set`() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    let config = try JavaScriptConfiguration.provision(at: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    try """
    swiftty.events.onCommandFinished((command) => {
      swiftty.ui.setPaneIcon(command.includes('clear') ? '' : 'docker');
    });
    """
    .write(to: config, atomically: true, encoding: .utf8)
    let f = try await open(javaScriptDirectory: directory)
    defer { f.controller.close() }
    let c = f.controller
    let pane = try #require(c.activePane)
    c.send(.text("printf '\\033]133;D;0\\007'\r"), to: pane)
    #expect(await until { c.automationPaneIcons[pane] == "docker" })
    #expect(c.icon(of: pane).brand == "docker")
    #expect(c.containers[pane]?.header.state.icon.brand == "docker")
    // An empty name returns the pane to automatic detection.
    c.send(
      .text(
        "printf '\\033]133;A\\007$ \\033]133;B\\007clear\\033]133;C\\007"
          + "\\033]133;D;0\\007'\r"
      ),
      to: pane
    )
    #expect(await until { c.automationPaneIcons[pane] == nil })
    #expect(c.icon(of: pane).brand == nil)
  }
}

@MainActor
struct MuxIconTableTests {
  @Test
  func `tools win over the package managers and runtimes that run them`() {
    #expect(MuxIcons.icon(for: "npm exec vitest").brand == "vitest")
    #expect(MuxIcons.icon(for: "pnpm vite dev").brand == "vitejs")
    #expect(MuxIcons.icon(for: "npm install").brand == "npm")
    #expect(MuxIcons.icon(for: "pnpm install").brand == "pnpm-dark")
    #expect(MuxIcons.icon(for: "bunx playwright test").brand == "playwright")
    #expect(MuxIcons.icon(for: "torchrun train.py").brand == "pytorch")
    // A runtime program defers to the tool its title names.
    #expect(
      MuxIcons.icon(title: "tsc --watch", program: "bun").brand == "typescript"
    )
  }

  @Test
  func `C++ compilers keep their plus signs`() {
    #expect(MuxIcons.icon(for: "g++ -O2 main.cpp").brand == "c-plus-plus")
    #expect(MuxIcons.icon(for: "clang++ main.cc").brand == "c-plus-plus")
    #expect(MuxIcons.icon(for: "gcc main.c").brand == "c")
  }

  @Test
  func `logos shaped as plain silhouettes keep their colors`() {
    for title in ["swift build", "tsc", "npm test", "kubectl get pods"] {
      #expect(MuxIcons.icon(for: title).colored)
    }
    for title in ["git status", "psql", "gh pr list", "claude"] {
      #expect(!MuxIcons.icon(for: title).colored)
    }
  }

  @Test
  func `every table logo ships on the Mac and in the iOS catalog`() throws {
    let root = URL(filePath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let catalog = root.appending(path: "Resources/Assets.xcassets/Brand Icons")
    for icon in MuxIcons.table.map(\.1) {
      guard let brand = icon.brand else { continue }
      #expect(MuxIcons.brandImage(icon) != nil, "\(brand) missing on the Mac")
      let set = catalog.appending(path: "brand-\(brand).imageset/Contents.json")
      let json = try String(contentsOf: set, encoding: .utf8)
      let intent = icon.colored ? "original" : "template"
      #expect(json.contains("\"\(intent)\""), "\(brand) catalog intent")
    }
  }
}
