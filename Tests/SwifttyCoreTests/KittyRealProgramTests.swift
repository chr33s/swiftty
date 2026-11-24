import CoreGraphics
import Foundation
import ImageIO
@testable import SwifttyCore
@testable import SwifttyEngine
import Testing
import TestSupport

/// Real image programs on a macOS PTY (spec.graphics.md KG26), and real
/// `kitten icat` inside tmux (KG27). Each test runs only when its program
/// is installed; `image.nvim` also needs `SWIFTTY_IMAGE_NVIM` pointing at a
/// checkout and ImageMagick's `magick`.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct KittyRealProgramTests {
  typealias Harness = IntegrationTests.Harness

  static func which(_ tool: String) -> String? {
    IntegrationTests.which(tool)
      ?? ["/opt/homebrew/bin/\(tool)", "/usr/local/bin/\(tool)"]
      .first { FileManager.default.isExecutableFile(atPath: $0) }
  }

  private let directory: URL = {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "swiftty-real-\(UUID().uuidString)"
    )
    try? FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true
    )
    return url
  }()

  /// A 64×48 gradient PNG.
  private func png() throws -> String {
    let (w, h) = (64, 48)
    var rgba = [UInt8](repeating: 255, count: w * h * 4)
    for y in 0 ..< h {
      for x in 0 ..< w {
        let i = (y * w + x) * 4
        (rgba[i], rgba[i + 1], rgba[i + 2]) = (UInt8(x * 4), UInt8(y * 5), 128)
      }
    }
    let provider = try #require(CGDataProvider(data: Data(rgba) as CFData))
    let image = try #require(
      CGImage(
        width: w,
        height: h,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: w * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
      )
    )
    let url = directory.appendingPathComponent("picture.png")
    let dest = try #require(
      CGImageDestinationCreateWithURL(
        url as CFURL,
        "public.png" as CFString,
        1,
        nil
      )
    )
    CGImageDestinationAddImage(dest, image, nil)
    #expect(CGImageDestinationFinalize(dest))
    return url.path
  }

  /// Runs `command` through a shell once the PTY reports pixel sizes.
  private func run(
    _ command: String,
    columns: Int = 80,
    rows: Int = 24
  ) throws -> Harness {
    let h = try Harness(
      ["/bin/sh", "-c", "sleep 0.3; \(command); echo real-done; sleep 8"],
      columns: columns,
      rows: rows,
      env: [
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        "TERM": "xterm-kitty",
      ]
    )
    h.session.setCellPixelSize(width: 10, height: 20)
    return h
  }

  private func images(_ h: Harness) -> [KittyGraphics.Placement] {
    h.session.snapshot().images
  }

  private func waitForImage(_ h: Harness, placeholder: Bool? = false) -> Bool {
    h.wait("an image") { _ in
      images(h)
        .contains { placeholder == nil || $0.isPlaceholder == placeholder }
    }
  }

  // MARK: kitten icat (KG26)

  @Test(
    .enabled(if: which("kitten") != nil),
    arguments: ["stream", "file", "memory"]
  )
  func `kitten icat displays with each transfer mode`(_ mode: String) throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let kitten = try #require(Self.which("kitten"))
    let h = try run(
      "\(kitten) icat --transfer-mode=\(mode) --place 16x6@2x1 '\(try png())'"
    )
    defer { h.session.stop() }
    #expect(waitForImage(h))
    let p = try #require(images(h).first)
    // icat centres the unscaled 64×48 image (6.4×2.4 cells of 10×20) in
    // the 16×6 rectangle at column 2, row 1.
    #expect((p.row, p.column, p.columns, p.rows) == (1, 6, 7, 3))
    #expect((p.width, p.height) == (64, 48))
    #expect(h.wait(for: "real-done"))
    // icat's own replies never reach the screen as text.
    #expect(!h.screen.contains("_G"))
  }

  @Test(.enabled(if: which("kitten") != nil))
  func `kitten icat draws Unicode placeholders`() throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let kitten = try #require(Self.which("kitten"))
    let h = try run(
      "\(kitten) icat --unicode-placeholder --place 16x6@0x2 '\(try png())'"
    )
    defer { h.session.stop() }
    #expect(waitForImage(h, placeholder: true))
    // One run per row: 7 cells wide, rows 2–4, centred from column 0.
    let runs = images(h).filter(\.isPlaceholder)
    #expect(runs.map(\.row) == [2, 3, 4])
    #expect(runs.allSatisfy { $0.column == 4 && $0.columns == 7 })
  }

  // MARK: Other programs (KG26)

  @Test(.enabled(if: which("timg") != nil))
  func `timg displays with the kitty protocol`() throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let timg = try #require(Self.which("timg"))
    let h = try run("\(timg) -pk -g20x10 '\(try png())'")
    defer { h.session.stop() }
    #expect(waitForImage(h))
  }

  @Test(.enabled(if: which("chafa") != nil))
  func `chafa displays with the kitty protocol`() throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let chafa = try #require(Self.which("chafa"))
    let h = try run("\(chafa) -f kitty -s 20x10 '\(try png())'")
    defer { h.session.stop() }
    #expect(waitForImage(h))
  }

  @Test(.enabled(if: which("yazi") != nil))
  func `yazi previews an image and clears it on quit`() throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let yazi = try #require(Self.which("yazi"))
    let picture = try png()
    let config = directory.appendingPathComponent("yazi-config")
    try FileManager.default.createDirectory(
      at: config,
      withIntermediateDirectories: true
    )
    let h = try Harness(
      ["/bin/sh", "-c", "sleep 0.3; exec \(yazi) '\(picture)'"],
      columns: 120,
      rows: 30,
      env: [
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        "TERM": "xterm-kitty", "YAZI_CONFIG_HOME": config.path,
        "HOME": directory.path,
      ]
    )
    h.session.setCellPixelSize(width: 10, height: 20)
    defer { h.session.stop() }
    // yazi chooses direct placements or Unicode placeholders itself.
    #expect(waitForImage(h, placeholder: nil))
    h.type("q")
    #expect(h.waitForExit() != nil)
    #expect(images(h).isEmpty)
  }

  @Test(
    .enabled(
      if: which("nvim") != nil && which("magick") != nil
        && ProcessInfo.processInfo.environment["SWIFTTY_IMAGE_NVIM"] != nil
    )
  )
  func `image.nvim renders through the kitty backend`() throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let nvim = try #require(Self.which("nvim"))
    let plugin = try #require(
      ProcessInfo.processInfo.environment["SWIFTTY_IMAGE_NVIM"]
    )
    let picture = try png()
    let initFile = directory.appendingPathComponent("init.lua")
    try """
    vim.opt.rtp:prepend(\(String(reflecting: plugin)))
    require("image").setup({ backend = "kitty", processor = "magick_cli" })
    vim.schedule(function()
      local img = require("image").from_file(\(String(reflecting: picture)), {
        x = 2, y = 2, width = 20, height = 10,
      })
      img:render()
    end)
    """
    .write(to: initFile, atomically: true, encoding: .utf8)
    let h = try Harness(
      [
        "/bin/sh", "-c",
        "sleep 0.3; exec \(nvim) --clean -u '\(initFile.path)'",
      ],
      columns: 100,
      rows: 30,
      env: [
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        "TERM": "xterm-kitty", "HOME": directory.path,
      ]
    )
    h.session.setCellPixelSize(width: 10, height: 20)
    defer { h.session.stop() }
    #expect(waitForImage(h))
    h.type("\u{1B}:qa!\r")
    #expect(h.waitForExit() != nil)
  }

  // MARK: Real icat inside tmux (KG27)

  @Test(.enabled(if: which("kitten") != nil && which("tmux") != nil))
  func `kitten icat inside tmux draws placeholders in a split pane`() throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let kitten = try #require(Self.which("kitten"))
    let tmux = try #require(Self.which("tmux"))
    let socket = "swiftty-real-" + UUID().uuidString
    let config = directory.appendingPathComponent("tmux.conf")
    try """
    set -g allow-passthrough on
    set -g status off
    set -as terminal-features ',xterm-256color:RGB:usstyle'

    """
    .write(to: config, atomically: true, encoding: .utf8)
    defer {
      _ = try? TestCommand.run(
        tmux,
        arguments: ["-L", socket, "kill-server"],
        timeout: .seconds(3)
      )
    }
    let picture = try png()
    let h = try Harness(
      [tmux, "-L", socket, "-f", config.path, "new-session", "/bin/sh"],
      env: ["PS1": "$ ", "TERM": "xterm-256color"]
    )
    h.session.setCellPixelSize(width: 10, height: 20)
    defer { h.session.stop() }
    #expect(h.wait(for: "$"))
    h.session.send(.key(KeyEvent(.character("b"), modifiers: .control)))
    h.type("%")
    #expect(h.wait("pane border") { $0.contains("│") })
    // icat sees $TMUX and uses passthrough with Unicode placeholders.
    h.type(
      "clear; \(kitten) icat --place 16x6@0x1 '\(picture)'; echo icat-$((1+1))\r"
    )
    #expect(h.wait(for: "icat-2"))
    // tmux 3.4–3.8 keep the row, column and high-byte diacritics in their
    // grid but drop them when drawing cells as they arrive; a full redraw
    // (refresh, zoom, window switch) sends them (spec.graphics.md §17.1).
    usleep(300_000)
    _ = try? TestCommand.run(
      tmux,
      arguments: ["-L", socket, "refresh-client"],
      timeout: .seconds(3)
    )
    #expect(waitForImage(h, placeholder: true))
    #expect(images(h).filter(\.isPlaceholder).allSatisfy { $0.column > 30 })
  }
}
