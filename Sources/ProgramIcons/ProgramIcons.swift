// A program's icon, chosen from a fixed local table by the pane's title
// and foreground program: shared by the Mac app's tabs and pane headers
// and the iPhone and iPad terminal header. Nothing a program sends picks
// an image. Drawing stays with each platform: the Mac loads the brand
// SVGs from `Sources/Swiftty/BrandIcons`, iOS from the app asset catalog
// (`Resources/Assets.xcassets/Brand Icons`).

import Foundation

/// A program's icon. It shows two ways: as a tile (the glyph in white on
/// the brand color, or on a dark neutral square) in tabs, and as the bare
/// glyph, tinted like the text beside it, in pane headers. A `colored`
/// logo instead keeps its own colors, filling the tile.
public struct MuxIcon: Hashable, Sendable {
  /// An SF Symbol: the glyph without a brand, and the fallback when the
  /// brand's file is missing.
  public var symbol: String
  /// A logo from developer-icons (`Sources/Swiftty/BrandIcons/<brand>.svg`,
  /// `Scripts/fetch-brand-icons.sh`), drawn by its alpha only unless
  /// `colored`.
  public var brand: String?
  /// The tile's color as 0xRRGGBB; nil is the neutral tile.
  public var tint: UInt32?
  /// The logo is drawn in its own colors, in place of the tile: its
  /// silhouette is a plain shape (a square, a hexagon), so drawn by its
  /// alpha it would show nothing. Lists the same names as `colored` in
  /// `Scripts/fetch-brand-icons.sh`.
  public var colored: Bool

  public init(
    symbol: String,
    brand: String? = nil,
    tint: UInt32? = nil,
    colored: Bool = false
  ) {
    self.symbol = symbol
    self.brand = brand
    self.tint = tint
    self.colored = colored
  }

  public static let terminal = MuxIcon(symbol: "terminal")
  public static let claude = MuxIcon(
    symbol: "asterisk",
    brand: "claude-ai",
    tint: 0xD9_7757
  )

  /// A logo kept in its own colors (`colored`).
  static func logo(_ brand: String, _ symbol: String, _ tint: UInt32) -> Self {
    MuxIcon(symbol: symbol, brand: brand, tint: tint, colored: true)
  }
}

private let code = "chevron.left.forwardslash.chevron.right"

public enum MuxIcons {
  /// Programs by a word of their title, first match wins: assistants,
  /// then tools before the package managers and runtimes that run them.
  public static let table: [([String], MuxIcon)] = [
    (["claude"], .claude),
    (
      ["codex", "openai", "chatgpt"],
      MuxIcon(symbol: "asterisk", brand: "openai", tint: 0x10_A37F)
    ),
    (
      ["copilot"],
      MuxIcon(symbol: "asterisk", brand: "github-copilot", tint: 0x83_4EF3)
    ), (["cursor"], MuxIcon(symbol: "asterisk", brand: "cursor-dark")),
    (["gemini"], .logo("gemini", "asterisk", 0x42_85F4)),
    (
      ["deepseek"],
      MuxIcon(symbol: "asterisk", brand: "deepseek", tint: 0x4D_6BFE)
    ), (["assistant", "aider"], MuxIcon(symbol: "asterisk")),
    (
      ["git", "tig", "lazygit", "gitui"],
      MuxIcon(symbol: "arrow.triangle.branch", brand: "git", tint: 0xF0_5032)
    ),
    (
      ["gh", "github"],
      MuxIcon(symbol: "arrow.triangle.branch", brand: "github-dark")
    ),
    (
      ["glab", "gitlab"],
      MuxIcon(symbol: "arrow.triangle.branch", brand: "gitlab", tint: 0xFC_6D26)
    ),
    (
      ["vitest"], MuxIcon(symbol: "checkmark", brand: "vitest", tint: 0x72_9B1B)
    ), (["vite"], MuxIcon(symbol: "bolt", brand: "vitejs", tint: 0x64_6CFF)),
    (
      ["playwright"],
      MuxIcon(symbol: "theatermasks", brand: "playwright", tint: 0x2E_AD33)
    ), (["esbuild"], .logo("esbuild", "hammer", 0xFF_CF00)),
    (["tsc", "tsx", "typescript"], .logo("typescript", code, 0x31_78C6)),
    (
      ["pnpm", "pnpx"],
      MuxIcon(symbol: "shippingbox", brand: "pnpm-dark", tint: 0xF6_9220)
    ), (["npm"], .logo("npm", "shippingbox", 0xCB_3837)),
    (["bun", "bunx"], .logo("bunjs", "terminal", 0xFB_F0DF)),
    (
      ["node", "npx", "yarn"],
      MuxIcon(symbol: "terminal", brand: "nodejs", tint: 0x5F_A04E)
    ),
    (
      ["brew", "homebrew"],
      MuxIcon(symbol: "mug", brand: "homebrew", tint: 0xF2_A33A)
    ),
    (
      ["docker"],
      MuxIcon(symbol: "shippingbox", brand: "docker", tint: 0x1D_63ED)
    ),
    (
      ["kubectl", "k9s", "helm", "minikube", "kubernetes"],
      .logo("kubernetes", "helm", 0x32_6CE5)
    ),
    (
      ["torchrun", "torch", "pytorch"],
      MuxIcon(symbol: "flame", brand: "pytorch", tint: 0xEE_4C2C)
    ),
    (
      ["tensorboard", "tensorflow"],
      MuxIcon(symbol: "brain", brand: "tensorflow", tint: 0xFF_6F00)
    ),
    (["hf", "huggingface"], .logo("hugging-face", "face.smiling", 0xFF_D21E)),
    (
      ["python", "python3", "ipython", "pip", "pip3"],
      MuxIcon(symbol: "terminal", brand: "python", tint: 0x37_76AB)
    ), (["go"], MuxIcon(symbol: "terminal", brand: "go", tint: 0x00_ADD8)),
    (
      ["cargo", "rustc", "rustup"],
      MuxIcon(symbol: "terminal", brand: "rust-dark", tint: 0xB7_410E)
    ), (["swift", "swiftc"], .logo("swift", "swift", 0xF0_5138)),
    (
      ["xcodebuild", "xcrun", "xcode", "simctl", "codesign", "notarytool"],
      MuxIcon(symbol: "apple.logo", brand: "apple-dark")
    ),
    (["g++", "clang++", "c++", "cpp"], .logo("c-plus-plus", code, 0x00_599C)),
    (["gcc", "clang", "cc"], .logo("c", code, 0x28_3593)),
    (
      ["java", "javac", "jshell", "mvn", "gradle"],
      MuxIcon(symbol: "cup.and.saucer", brand: "java", tint: 0xE7_6F00)
    ),
    (
      ["kotlin", "kotlinc"],
      MuxIcon(symbol: code, brand: "kotlin", tint: 0x7F_52FF)
    ),
    (
      ["ruby", "irb", "gem", "bundle", "rails", "rake"],
      .logo("ruby", "diamond", 0xCC_342D)
    ), (["php", "composer", "artisan"], .logo("php", code, 0x77_7BB4)),
    (["lua", "luajit"], MuxIcon(symbol: code, brand: "lua", tint: 0x2C_2D72)),
    (
      ["psql", "postgres", "postgresql"],
      MuxIcon(symbol: "cylinder", brand: "postgresql", tint: 0x41_69E1)
    ),
    (["mysql"], MuxIcon(symbol: "cylinder", brand: "mysql", tint: 0x00_758F)),
    (["aws"], MuxIcon(symbol: "cloud", brand: "aws", tint: 0xFF_9900)),
    (
      ["gcloud", "gsutil", "bq"],
      MuxIcon(symbol: "cloud", brand: "google-cloud", tint: 0x42_85F4)
    ),
    (
      ["wrangler", "cloudflared", "cloudflare"],
      MuxIcon(symbol: "cloud", brand: "cloudflare", tint: 0xF3_8020)
    ), (["fly", "flyctl"], .logo("flyio", "paperplane", 0x7B_3BE2)),
    (
      ["nvim", "neovim"],
      MuxIcon(symbol: "doc.text", brand: "neovim", tint: 0x57_A143)
    ), (["vim", "emacs", "nano", "hx", "helix"], MuxIcon(symbol: "doc.text")),
    (
      ["snake", "game", "tetris", "nethack", "2048"],
      MuxIcon(symbol: "gamecontroller")
    ), (["top", "htop", "btop"], MuxIcon(symbol: "chart.bar")),
    (["ssh", "mosh"], MuxIcon(symbol: "network")),
    (["less", "man", "more"], MuxIcon(symbol: "book")),
  ]

  /// Brands of language runtimes: their process runs many tools, so a
  /// title naming the tool says more (`codex` runs as `node`).
  public static let runtimes: Set<String> = ["nodejs", "bunjs", "python"]

  /// A pane's icon, most specific first: the name a script chose
  /// (`ui.setPaneIcon`), Claude Code's status glyph, the foreground
  /// program the service reports, then the title's words.
  public static func icon(
    title: String,
    program: String? = nil,
    override: String? = nil
  ) -> MuxIcon {
    if let override, let icon = named(override) { return icon }
    if marker(of: title) != nil { return .claude }
    let fromTitle = match(title)
    if let program, let fromProgram = match(program) {
      if let brand = fromProgram.brand, runtimes.contains(brand), let fromTitle
      {
        return fromTitle
      }
      return fromProgram
    }
    return fromTitle ?? .terminal
  }

  /// The icon for a sanitized title, from the fixed local table.
  public static func icon(for title: String) -> MuxIcon { icon(title: title) }

  /// A table icon by one of its keys ("git", "claude"), or "terminal".
  public static func named(_ name: String) -> MuxIcon? {
    let key = name.lowercased()
    if key == "terminal" { return .terminal }
    return table.first { $0.0.contains(key) }?.1
  }

  /// The first table entry a word of `text` names.
  private static func match(_ text: String) -> MuxIcon? {
    // "+" stays in a word: "g++" and "clang++" name C++, not "g".
    let words = text.lowercased()
      .split { !$0.isLetter && !$0.isNumber && $0 != "+" }.map(String.init)
    return table.first { $0.0.contains(where: words.contains) }?.1
  }

  /// The SF Symbol for a sanitized title (the icon's fallback glyph).
  public static func symbol(for title: String) -> String {
    icon(for: title).symbol
  }

  /// The title as shown beside its icon: without the status glyph Claude
  /// Code leads its title with, which the icon now stands for.
  public static func displayTitle(_ title: String) -> String {
    guard let marker = marker(of: title) else { return title }
    return String(title[marker...]).trimmingCharacters(in: .whitespaces)
  }

  /// Where the title proper starts after Claude Code's leading status
  /// glyph ("✳ " idle, a braille spinner frame while working), or nil
  /// when it has none.
  private static func marker(of title: String) -> String.Index? {
    guard let first = title.unicodeScalars.first,
      first.value == 0x2733 || (0x2801 ... 0x28FF).contains(first.value)
    else { return nil }
    let scalars = title.unicodeScalars
    var rest = scalars.index(after: scalars.startIndex)
    // "✳️": the emoji presentation selector may follow.
    if rest < scalars.endIndex, scalars[rest].value == 0xFE0F {
      rest = scalars.index(after: rest)
    }
    guard rest < scalars.endIndex, scalars[rest] == " " else { return nil }
    return rest
  }
}
