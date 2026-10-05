# swiftty

A small Swift 6.4 terminal core (`SwifttyCore`) with libghostty-level
features, plus frontends for macOS (`swiftty`, AppKit) and iOS/iPadOS
(`SwifttyMobile`, UIKit), implementing [spec.md](spec.md).

`SwifttyCore` builds for macOS, iOS, Mac Catalyst and visionOS. On macOS a
session can own a child process on a PTY; everywhere, a session can instead
use an external transport (`receive` program output, take replies and
encoded input from `onWrite`) — SSH channels, in-process shells, tmux panes.
[Shell](https://github.com/chr33s/shell) embeds it behind the libghostty
embedder API.

```text
swiftty (AppKit)          SwifttyMobile (UIKit)
      |                          |
      +------------+-------------+
                   |
TerminalSession ─ one serial queue owns all terminal state
      ├─ PTYProcess        openpty + posix_spawn, DispatchSource I/O
      ├─ Parser            VT500 state machine, SIMD ASCII scan, inline UTF-8
      ├─ TerminalState     Grid, Scrollback, Modes, cursor, damage, prompt marks
      ├─ InputEncoder      xterm keys, mouse (X10/normal/SGR/UTF-8), paste, focus
      ├─ UnicodeWidth      generated two-stage width table
      ├─ RenderSnapshot    pooled, damage-driven, Span-based
      └─ Configuration     Ghostty-syntax config, themes, keybindings
      |
MetalRenderer + CoreTextFontManager (shaders in Renderer/Shaders.metal)
```

## Usage

Tooling is pinned in `mise.toml`: Swift 6.4.0, swiftformat, swiftlint, tmux,
and, for the Ghostty comparison, Zig 0.16.0 and hyperfine.

```sh
mise install
mise run test      # unit + PTY integration tests (sh, vim, less, tmux, top)
mise run app       # launch the terminal
mise run bench     # release-build microbenchmarks (100 MB streams)
mise run lint      # swiftlint; `mise run format` applies swiftformat
mise run unicode   # regenerate Unicode/Tables.swift from EastAsianWidth.txt
mise run compare <ghostty-src> <corpus-dir>  # hyperfine vs upstream ghostty-bench
```

`SDKROOT` is set by `mise.toml` because swift.org toolchains need Xcode's macOS
SDK to link.

The iOS frontend builds with Xcode (the package's AppKit app keeps the
`swiftty-Package` scheme macOS-only):

```sh
xcodebuild -scheme SwifttyMobile -destination 'generic/platform=iOS Simulator' build
```

`Tests/SwifttyMobileTests/Fixtures` holds recorded `sh`, `vim`, `less`,
`tmux` and `top` sessions that the replay tests feed through `receive` (the
iOS path, with no PTY) on macOS and the simulator. Re-record them with
`SWIFTTY_RECORD=1 swift test --filter SessionRecorder`.

### Configuration

Settings use Ghostty's syntax (`key = value`, `#` comments, repeatable keys,
an empty value restores the default, `config-file` includes). macOS reads
`$XDG_CONFIG_HOME/swiftty/config` (default `~/.config/swiftty/config`;
Settings… opens it, Shift-Cmd-, reloads it); iOS reads `Documents/config`.
Unknown keys are reported and ignored, so a Ghostty file can be shared.

```text
font-family = JetBrains Mono        # also -bold, -italic, -bold-italic
font-size = 14
font-feature = calt                 # font-variation = wght=500
font-synthetic-style = no-bold
adjust-cell-height = 10%            # or points: adjust-cell-width = 1
theme = light:Swiftty Light,dark:Swiftty Dark
background = #1e1e2e                # foreground, cursor-color, cursor-text,
palette = 1=#f38ba8                 # selection-foreground/-background
background-opacity = 0.9
background-blur = true
minimum-contrast = 3
custom-shader = ~/.config/swiftty/crt.metal
cursor-style = bar                  # block, underline, block_hollow
cursor-style-blink = false
cursor-click-to-move = true
copy-on-select = true
link-url = true
mouse-hide-while-typing = true
window-padding-x = 6
scrollback-limit = 20000000
command = /opt/homebrew/bin/fish
keybind = super+shift+k=clear_screen
keybind = ctrl+shift+arrow_up=jump_to_prompt:-1
```

Themes are Ghostty theme files looked up in `~/.config/swiftty/themes`,
`~/.config/ghostty/themes`, then the built-ins (`Swiftty Dark`,
`Swiftty Light`). Keybinding actions: `copy_to_clipboard`,
`paste_from_clipboard`, `increase_font_size:N`, `decrease_font_size:N`,
`reset_font_size`, `select_all`, `scroll_to_top`, `scroll_to_bottom`,
`scroll_page_up`, `scroll_page_down`, `scroll_page_lines:N`,
`jump_to_prompt:N`, `start_search`, `search_selection`,
`navigate_search:next|previous`, `end_search`, `clear_screen`, `reset`,
`text:…`, `csi:…`, `esc:…`, `ignore`, and `unbind`.

Custom shaders are Metal, not GLSL: the file defines
`float4 postprocess(float2 position, texture2d<float> source, constant PostUniforms &u)`,
with `u.resolution` and `u.time` (see `Renderer/PostProcess.swift`).

## Layout

| Spec module | File(s) |
|---|---|
| Session | `Session/TerminalSession.swift`, `Session/SessionConfiguration.swift` |
| Process | `Process/PTYProcess.swift`, `Process/FileDescriptor.swift` (`~Copyable`) |
| Terminal | `Terminal/{Parser,TerminalState,TerminalState+Control,TerminalState+OSC,TerminalState+Grapheme,Grid,Cell,Scrollback,Modes,Damage}.swift` |
| Shell integration | `Terminal/TerminalState+Shell.swift` (OSC 133, title/SGR stacks, reports, OSC 21/22, underline colors), `Terminal/Links.swift` |
| Graphemes | `Terminal/{Graphemes,GraphemeBreak,GraphemeBreakTables}.swift` (tables generated by `Scripts/gen-grapheme-tables.swift`) |
| Selection, search, dump | `Terminal/Selection.swift`, `Terminal/Dump.swift` |
| Input | `Input/InputEncoder.swift` |
| Unicode | `Unicode/Width.swift`, `Unicode/ScalarInfo.swift`, `Unicode/Tables.swift` (generated by `Scripts/gen-unicode-tables.swift`) |
| Font | `Font/CoreTextFontManager.swift` |
| Renderer | `Renderer/{RenderSnapshot,MetalRenderer,Shaping,BoxDrawing,PostProcess,AccessibilityText}.swift`, `Renderer/Shaders.metal` |
| Config | `Config/{Configuration,Themes,Keybindings}.swift` |
| macOS app | `Sources/Swiftty/{AppDelegate,TerminalView}.swift` and `TerminalView+{Mouse,Actions,TextInput,Accessibility}.swift` |
| iOS/iPadOS | `Sources/SwifttyMobile/` (`TerminalUIView` and its `+Keyboard`, `+Touch`, `+Search`, `+Accessibility` extensions, `AccessoryBar`, `InputModel`, `Behavior`, `DemoSource`, `SwifttyMobileApp`) |

`Sources/CAllocCounter` is a ~40-line C helper, used only by the tests and the
benchmark. It hooks libmalloc's `malloc_logger` to count heap allocations made
by the calling thread.

## Design notes

- **Cells**: 16-byte `BitwiseCopyable` structs in fixed-width row-major rows,
  allocated in contiguous 64-row chunks. Logical rows map through a row
  index, so scrolling rotates indices and moves no cells. Each row tracks an
  *extent*: cells past it are known to be blank, so clears only touch written
  cells.
- **Graphemes**: combining marks and ZWJ sequences go into a side table. The
  cell stores an id, and the table is compacted (double-buffered) once
  garbage builds up.
- **Scrollback**: the screen and its history share one row pool. Scrolling
  the full primary screen moves the top row's index into a history ring
  instead of copying it, as Ghostty's page list does. Once the ring is full
  (10 MB default, Ghostty's `scrollback-limit`), the oldest row is recycled
  as the new bottom row. Steady-state scrolling therefore neither allocates
  nor copies. Resizing reflows wrapped lines, wide characters and the cursor
  across the screen and scrollback.
- **Parser**: `consume(_: borrowing Span<UInt8>, into: inout TerminalState)`.
  - Printable ASCII runs are found 16 bytes at a time with `SIMD16<UInt8>`
    and written in bulk.
  - Mixed UTF-8 runs are decoded inline into a scratch buffer and written in
    one call. Cells past a row's extent are stored as whole 16-byte vectors
    without wide-character checks.
  - Everything else goes through the VT500 state machine.
  - CSI parameters live in an `InlineArray<24, UInt16>`.
- **Concurrency**: one serial `DispatchQueue` per session owns the parser and
  state. PTY reads arrive on that queue and are parsed in place from a
  preallocated 64 KiB buffer, with a 1 MiB budget per event so snapshots can
  interleave. The UI touches state only through `send`, `resize` and
  `snapshot`.
- **Snapshots**: a pool of up to three storages. Each one accumulates the
  damage it missed and copies only those rows. A storage is reused only when
  no live snapshot references it, so snapshots are immutable. Synchronized
  output (mode 2026) holds frames for up to 1 s, then redraws even if the
  application never ends the update.
- **Renderer**: a persistent per-row instance buffer, where only dirty rows
  and the old and new cursor rows are rebuilt. It uses three instanced draws
  (backgrounds, glyphs, decorations). The atlas is CoreText-rasterized, with
  fallback fonts and Apple Color Emoji for color glyphs. Underline styles
  are drawn in the decoration shader, blinking text is a uniform (no
  rebuild), and an optional post-processing pass runs a user shader. It can
  render to a view or offscreen; offscreen is used by tests and the
  benchmark.
- **Underline colors** live in the six spare bits of the foreground color's
  tag byte as an id into a per-terminal table (63 colors), so cells stay 16
  bytes. Prompt marks are one byte per physical row beside the wrap flags.

### Supported sequences

- **C0 controls**: BEL, BS, HT, LF, VT, FF, CR, SO, SI, CAN, SUB.
- **ESC**:
  - DECSC/DECRC, IND, NEL, HTS, RI, RIS, DECKPAM/DECKPNM
  - G0/G1 designation, including DEC Special Graphics
  - DECALN
- **CSI**:
  - Cursor movement: CUU, CUD, CUF, CUB, CNL, CPL, CHA, CUP, HVP, VPA, VPR,
    HPA, HPR, CHT, CBT
  - Editing: ED, EL, ECH, ICH, DCH, IL, DL, SU, SD, REP
  - Tabs, margins and attributes: TBC, DECSTBM, DECSLRM, SGR (16, 256 and truecolor;
    colon sub-params; underline styles)
  - Cursor save/restore: SCOSC/SCORC
  - Modes: SM/RM, DECSET/DECRST, DECRQM
  - Reports: DSR 5/6, `CSI ? 996 n` (color scheme), DA1, DA2, XTVERSION,
    XTWINOPS 14/16/18
  - Stacks: XTWINOPS 22/23 (title), XTPUSHSGR/XTPOPSGR (`CSI # {`/`}`, `# p`/`q`)
  - Other: DECSCUSR, DECSTR, SGR 58/59 underline color
  - Kitty keyboard protocol: query/push/pop/set (`CSI ? u`, `> u`, `< u`,
    `= u`); flags 1, 2, 4, 8 and 16 change key encoding
- **DEC modes**: 1, 3 (with 40), 5, 6, 7, 9, 12, 25, 45, 47, 69, 1000,
  1002, 1003, 1004, 1005, 1006, 1007, 1045, 1047, 1048, 1049, 2004, 2026,
  2027, 2031, 2048. **ANSI modes**: 4 (IRM), 20 (LNM).
- **OSC**:
  - 0/2 title, 7 cwd, 8 hyperlinks, 52 clipboard write (reads are refused)
  - 133 semantic prompts, 22 pointer shape, 21 kitty color protocol
  - 4, 10, 11, 12 color set/query; 104, 110, 111, 112 reset
  - 9 and 777;notify notifications, 9;4 progress
- **DCS**: tmux control mode (`DCS 1000 p`, streamed to the host),
  XTGETTCAP (`DCS + q`), DECRQSS (`DCS $ q`).
- **Ignored safely**: other DCS, APC, PM, SOS strings and unknown sequences.

## Results

### Against Ghostty

Upstream Ghostty `main` (`5dc28bb`, Zig 0.16.0, ReleaseFast) was run with
`ghostty-bench +terminal-stream`. Swiftty was run with
`swiftty-bench stream`, which does the same work: input is read in 64 KiB
chunks into a 120×80 terminal with Ghostty's default benchmark scrollback
(10,000 bytes). Both read identical 100 MB files and were timed with
`hyperfine` (20 runs, median, Apple Silicon). Reproduce with:
`Scripts/compare-ghostty.sh <ghostty-src> <corpus-dir>`.

The `ghostty-*` inputs come from Ghostty's own `ghostty-gen`. The others
come from `swiftty-bench gen`.

| Input | Ghostty | swiftty | swiftty speed vs Ghostty |
|---|---:|---:|---:|
| ghostty-ascii | 65 ms | 61 ms | **107%** |
| ghostty-styled | 102 ms | 107 ms | 95% |
| ghostty-utf8 | 675 ms | 418 ms | **161%** |
| ghostty-osc | 3980 ms | 749 ms | **531%** |
| ascii | 94 ms | 101 ms | 93% |
| cat-source | 132 ms | 139 ms | 95% |
| compiler-log | 135 ms | 123 ms | **110%** |
| csi-heavy | 464 ms | 286 ms | **162%** |
| osc-heavy | 1094 ms | 263 ms | **416%** |
| scroll | 401 ms | 318 ms | **126%** |
| utf8 (mixed scripts) | 327 ms | 307 ms | **107%** |
| utf8-latin | 124 ms | 128 ms | 97% |
| utf8-cjk | 97 ms | 121 ms | 80% |
| startup (empty input) | 4.9 ms | 2.5 ms | |

- **Spec targets**: 12 of 13 inputs meet the ≥90% target, and 10 of 13
  meet ≥95%.
- **CJK, the one miss**: wide characters cost two 16-byte cells each, while
  Ghostty packs a cell into 8 bytes. Closing that gap needs a smaller cell
  (glyph and width packed, attributes in a shared style table). That
  redesign is deferred.

### Internal benchmarks

Release build on Apple Silicon (18 cores), `mise run bench`. The 200×60
streams are fed in 64 KiB chunks with the scrollback at its 10 MB limit:

| Workload | MB/s | Allocations in measured loop |
|---|---:|---:|
| ASCII 100 MB | 1051 | 1 (one-time Swift metadata instantiation) |
| UTF-8 mixed 100 MB (CJK, emoji, combining marks) | 343 | 6 (grapheme table growth) |
| UTF-8 CJK / Latin | 912 / 866 | 0 |
| Compiler log (SGR-heavy) | 847 | 0 |
| `cat` of source files | 795 | 0 |
| CSI-heavy | 336 | 0 |
| OSC-heavy (title/cwd every line) | 370 | ~1 per changed title per read batch |
| Scroll (short lines) | 333 | 0 |

| Interactive metric | Result |
|---|---|
| Keystroke → PTY echo → parse → snapshot | p50 0.045 ms, p95 0.062 ms |
| 200×60 full redraw (parse + snapshot) | p95 0.050 ms |
| 200×60 full redraw (Metal, offscreen, GPU complete) | p95 1.01 ms |
| Scroll 20 lines/frame at 120×40, incl. render | p95 0.27 ms |
| Resize with full 10 MB scrollback (reflow) | p95 2.2 ms |

Peak RSS figures in the benchmark output include the 100 MB input buffers.

The allocation tests (`AllocationTests`) assert exactly zero heap
allocations in steady state for ASCII, UTF-8 and CSI parsing and for grid
cell updates.

## Status against the spec

**Done**
- Milestone 1 (§11): the macOS core and app. Every component in §2–§10, the
  §14 benchmarks and the §15 test layers; the integration tests run a real
  `sh`, `vim`, `less`, `tmux` and `top` through the PTY.
- Milestone 2: the iOS/iPadOS frontend (`SwifttyMobile`): `UITextInput`
  keyboard, dictation and IME, hardware keys with releases, the accessory bar,
  touch and pointer selection with an edit menu, momentum scrolling, mouse
  reporting, multitasking resize, keyboard avoidance, background pausing, and
  an in-process demo shell. It builds for the iOS Simulator; its tests,
  including replays of recorded `sh`, `vim`, `less`, `tmux` and `top`
  sessions, run on macOS and the simulator. The macOS app's key handling has
  its own tests (`SwifttyAppTests`).
- Milestone 3: OSC 133 prompts (marks, prompt jumps, command-output
  selection, prompt clearing on resize with `redraw=1`, click-to-move), drawn
  underline styles and colors, blinking text, title and SGR stacks, OSC 21
  and 22, modes 2031 and 2048, kitty keyboard flag 4, and hyperlinks
  (Cmd-hover and Cmd-click on macOS, tap and pointer hover on iPad; bare URLs
  are detected too).
- Milestone 4: Ghostty-syntax configuration with themes, keybinding actions
  (menu shortcuts follow them on macOS, key commands on iPad), find bars,
  VoiceOver on both platforms, font options, minimum contrast, background
  opacity and blur, and Metal post-processing shaders.

**Not applicable in this repository**
- The Ghostty comparison is the parser-throughput table above; the remaining
  regression budgets are measured against milestone 1 (`mise run bench`).
- Ghostty's test vectors are not vendored as data. Its `Terminal.zig` tests
  are ported by hand into `Tests/SwifttyCoreTests/GhosttyOracle`, driven
  through escape sequences; the other golden tests are written from xterm/VT
  behavior.

**Not verified interactively**
- Pointer hover and shapes, link clicks, the find bars, VoiceOver, blur and
  custom shaders were exercised through their logic and tests, and the macOS
  rendering path through offscreen renders, but not driven by hand in either
  app. No Xcode app project is included: an iOS app target references
  `SwifttyMobileAppDelegate` and `SwifttyMobileSceneDelegate`.

**Out of scope (§2)**
- The Kitty graphics protocol (future), Sixel, and any network client: as
  with libghostty, remote sessions are the embedding app's job.
