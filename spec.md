# Spec: Swift 6.4 Terminal Core with libghostty Parity on Apple Platforms

## 1. Goal

Implement a **Swift 6.4 terminal core for Apple platforms** (`SwifttyCore`) that reaches feature parity with `libghostty` for everything an Apple frontend needs, plus first-party frontends for **macOS** (AppKit) and **iOS/iPadOS** (UIKit).

The implementation should prioritize:

- small codebase;
- native Swift APIs;
- Apple Silicon performance;
- zero-copy / low-allocation hot paths;
- direct Darwin, CoreText, and Metal integration;
- behavioral compatibility with Ghostty.

This is **not** a line-by-line Zig port.

### Status

Milestones 1–4 (§11, §12) are implemented: the macOS core and app; the iOS/iPadOS frontend (`SwifttyMobile`); the protocol parity items; and configuration, themes, keybindings and accessibility on both platforms. `README.md` records what was verified and how.

---

## 2. Scope

### Platforms

| Platform | Core | Local process (PTY) | Frontend |
|---|---|---|---|
| macOS | required | required | AppKit, required |
| iOS / iPadOS | required | not available (sandbox) | UIKit, required |
| Mac Catalyst, visionOS | must build | not available | may reuse the UIKit frontend; not required |

### In scope

- terminal session lifecycle;
- PTY/process management (macOS);
- a host-supplied byte stream for platforms without a PTY (`receive` / `onWrite`); as with libghostty, the embedder owns the connection;
- VT parser;
- terminal grid/state;
- scrollback;
- keyboard/input encoding;
- resize handling;
- Unicode width / grapheme behavior;
- renderer-facing snapshot/damage model;
- CoreText-backed font lookup;
- the Metal renderer, shared across platforms;
- frontend features libghostty's embedder layer provides: configuration, keybinding actions, selection, search, hyperlinks, accessibility (§12).

### Out of scope

- Linux, Windows, GTK, OpenGL, WebAssembly;
- stable external C ABI (the libghostty embedder API is provided by the separate Shell project);
- generic cross-platform abstractions beyond Apple platforms;
- plugin APIs;
- Sixel (Ghostty does not support it);
- SSH, mosh, or any other network client: libghostty has none, and remote sessions are the embedding app's concern.

### Future (out of this spec)

- **Kitty graphics protocol.** Deferred to a later spec. Until then APC
  strings are ignored safely, and nothing here should be designed around
  image support. When it is taken up, it is expected to cover transmission
  (direct, chunked; file and shared-memory media on macOS), placement,
  deletion, z-ordering and Unicode placeholders, with images in a bounded
  side table rendered as textured quads.

---

## 3. Architecture

```text
AppKit frontend (macOS)        UIKit frontend (iOS/iPadOS)
      |                               |
      +---------------+---------------+
                      v
               TerminalSession ─ one serial queue owns all terminal state
                      |
      +-- Transport: PTYProcess (macOS) | host-supplied bytes
      +-- Parser
      +-- TerminalState
      |    +-- Grid, Scrollback, Modes, Graphemes
      |    +-- Selection, Search, Hyperlinks, Semantic prompts
      +-- InputEncoder
      +-- UnicodeWidth / GraphemeBreak
      +-- RenderSnapshot
                      |
                      v
       MetalRenderer + CoreTextFontManager + BoxDrawing
```

Primary API:

```swift
final class TerminalSession {
    func start(_ configuration: SessionConfiguration) throws   // macOS PTY
    func receive(_ bytes: [UInt8])                             // host-supplied transport
    var onWrite: (([UInt8]) -> Void)?
    func resize(columns: Int, rows: Int)
    func send(_ input: TerminalInput)
    func snapshot() -> RenderSnapshot
    func stop()
}
```

Do not expose C-shaped APIs internally. Platform-specific code lives behind `#if os(...)` in the few files that need it (PTY, view hosting); do not build a portability layer.

---

## 4. Module layout

```text
Sources/
├── SwifttyCore/
│   ├── Session/      TerminalSession, SessionConfiguration
│   ├── Process/      PTYProcess, FileDescriptor (macOS only)
│   ├── Terminal/     Parser, TerminalState(+Control, +OSC, +Grapheme), Grid, Cell,
│   │                 Scrollback, Modes, Damage, Graphemes, GraphemeBreak, Selection, Dump
│   ├── Input/        InputEncoder
│   ├── Unicode/      Width, ScalarInfo, Tables (generated)
│   ├── Font/         CoreTextFontManager
│   ├── Renderer/     RenderSnapshot, MetalRenderer, Shaping, BoxDrawing, Shaders.metal
│   └── Config/       configuration file, themes, keybindings (new)
├── Swiftty/          AppKit frontend (macOS)
└── SwifttyMobile/    UIKit frontend (iOS/iPadOS) (new)
```

Keep targets coarse. Frontends share everything below the view layer.

---

## 5. Core implementation rules

### Memory

Hot-path code must avoid:

- `String` conversion of terminal input;
- per-byte allocation;
- per-cell heap allocation;
- repeated `Data` copies;
- unnecessary ARC traffic;
- uncontrolled copy-on-write.

Prefer:

- `Span<UInt8>`;
- non-copyable types where ownership is unique;
- `InlineArray` for fixed small storage;
- uniquely-owned contiguous storage;
- explicit borrowing;
- preallocated buffers.

### Terminal grid

Use a contiguous row-major cell buffer of `BitwiseCopyable` cells:

- no class per cell;
- no dictionary per row;
- no allocation during normal cell mutation;
- resize reuses storage where practical.

New per-cell data (such as underline color) goes into side tables keyed by id, as graphemes and hyperlinks do, so the cell does not grow.

### Strings / Unicode

Do not use `Character` as the terminal's storage unit. Use Unicode scalars, explicit width tables, explicit grapheme handling, and generated tables. Terminal cell semantics take precedence over Swift string semantics.

---

## 6. Parser

The parser is a state machine operating directly on borrowed bytes:

```swift
struct Parser: ~Copyable {
    mutating func consume(_ bytes: borrowing Span<UInt8>, into terminal: inout TerminalState)
}
```

Requirements:

- zero allocation for common ASCII/UTF-8 input;
- no intermediate `String`;
- process buffers in batches;
- SIMD scanning of printable runs;
- optimize for Apple Silicon ARM64.

Unsupported sequences must fail safely and be ignored according to terminal rules.

---

## 7. I/O

### macOS: PTY

Implement directly against Darwin: `openpty`, `termios`, `ioctl`, `posix_spawn`, `DispatchSource` reads, direct file-descriptor writes. Children are always reaped, including when the session is stopped.

### iOS/iPadOS: host-supplied

There is no local process. As with libghostty, the core does not open connections: the embedding app delivers program output with `receive`, takes replies and encoded input from `onWrite`, and forwards `resize` to whatever is on the other end (an SSH channel, mosh, an in-process interpreter). Connection setup, authentication, reconnection and background policy belong to the app.

Ownership model for both:

```text
transport read -> single terminal queue (Parser, TerminalState, damage) -> immutable render snapshot
```

The terminal state has one mutation owner. Do not use one actor per subsystem.

---

## 8. Concurrency

- UI: main actor;
- terminal parser/state: one serial queue per session;
- renderer: main thread or the view's render callback;
- I/O: dispatch sources (PTY) or the host's own queue, hopping onto the session queue through `receive`.

Rules:

- no cross-thread mutation of `TerminalState`;
- no fine-grained actor hops in parser/grid loops;
- render state passes as immutable snapshots;
- synchronization points stay coarse.

---

## 9. Rendering

The core outputs a compact snapshot containing only the data the renderer needs; the renderer rebuilds only damaged rows, retains GPU buffers, and never copies the whole grid per frame. A frame skipped for lack of a drawable must not lose damage.

One `MetalRenderer` serves every platform (`MTKView` / `CAMetalLayer`). Shader code stays in `.metal` files.

Rendering parity work (§12): underline styles and colors, blinking text, minimum contrast, background opacity/blur, custom post-processing shaders.

---

## 10. Fonts

Use CoreText directly:

```swift
final class CoreTextFontManager {
    func resolve(_ descriptor: FontDescriptor) -> ResolvedFont
}
```

Done: primary/bold/italic/bold-italic faces, fallback fonts, emoji, shaping with OpenType features, procedural box drawing, block elements, Braille, sextants and Powerline glyphs.

Remaining: font configuration (family per style, size, features, variations), synthetic bold/italic control, cell width/height adjustment, and Dynamic Type-aware default sizing on iOS.

---

## 11. Milestone 1 (complete)

macOS core and app: launching a shell, typing, UTF-8, colors, cursor movement, resizing with reflow, scrollback, alternate screen, `vim`, `less`, `tmux`, common prompts, mouse reporting, selection and copy, IME, search, OSC 52.

---

## 12. Parity milestones

### Milestone 2 — iOS/iPadOS frontend

- `UIView` hosting the Metal renderer, adopting `UITextInput` for the software keyboard, dictation and IME marked text;
- hardware keyboard through `pressesBegan`/`pressesEnded` (key up/down for the Kitty protocol);
- an input accessory bar: Esc, Ctrl, Alt, Tab, arrows, and common symbols;
- touch selection (long-press, drag handles), `UIEditMenuInteraction` for copy/paste;
- scrolling with momentum, and mouse reporting from touch and from the iPad pointer (`UIPointerInteraction`, scroll wheel);
- resize for Split View, Slide Over and Stage Manager; keyboard-avoidance;
- scene lifecycle: pause rendering in the background;
- the view takes a session the app has connected; the reference app ships only a local demo source (an in-process echo/replay), not a network client.

### Milestone 3 — terminal protocol parity

- OSC 133 semantic prompts: prompt marks per row, jump to previous/next prompt, select command output, prompt-aware resize, click-to-move-cursor;
- underline styles (curly, dotted, dashed) drawn, and underline color (SGR 58/59);
- blinking text (SGR 5) with the cursor's blink phase;
- title stack (`CSI 22 t` / `CSI 23 t`), XTPUSHSGR/XTPOPSGR (`CSI # {` / `CSI # }`);
- OSC 22 pointer shape, OSC 21 Kitty color protocol;
- color-scheme reporting (DEC mode 2031, `CSI ? 996 n`);
- in-band resize notifications (DEC mode 2048);
- Kitty keyboard flag 4 (report alternate keys);
- hyperlinks in the frontends: hover detection, underline, open with the system handler.

### Milestone 4 — embedder features

- configuration file and themes compatible with Ghostty's syntax for the options these frontends support;
- keybinding actions (copy, paste, font size, scroll, prompt jumps, search, clear screen, reset);
- accessibility: VoiceOver text exposure and navigation on both platforms;
- window/tab/split management stays in each frontend, not the core.

Each milestone is done when its features have tests in the existing layers (§15) and do not break the performance gates (§13).

---

## 13. Performance requirements

### Hard requirements

| Metric | Requirement |
|---|---:|
| parser-loop heap allocations | 0 for common input |
| cell update allocations | 0 |
| typing latency | no measurable regression |
| terminal correctness tests | 100% for supported features |
| scroll performance | no regression from milestone 1 |
| RSS | <= 15% above milestone 1 for text-only sessions |
| frame pacing | no dropped frames at the display rate for ordinary use |
| iOS energy | no rendering while idle or backgrounded |

### Target

Parser throughput stays at or above 95% of upstream Ghostty on the comparison corpus (`Scripts/compare-ghostty.sh`) for every input except wide-character-heavy ones, which must reach 90%.

---

## 14. Benchmarks

Maintain microbenchmarks for: 100 MB ASCII and UTF-8 streams, compiler logs, `cat` of large files, full-screen redraw, scrolling, resize stress, OSC-heavy and CSI-heavy input.

Measure MB/s, CPU time, allocations, peak RSS, frame time, and p95 input-to-render latency, on Apple Silicon Release builds. Frame time is also measured on an iPad.

---

## 15. Testing

### Parser tests

Golden tests for CSI, OSC, DCS, APC, SGR, cursor movement, erase, modes, UTF-8, and malformed input.

### Terminal-state tests

Wrapping, scrolling, resize/reflow, alternate screen, graphemes, wide characters, cursor behavior, semantic prompts.

### Oracle tests

Port Ghostty's `Terminal.zig` tests (and its OSC tests as those features land) and drive them through escape sequences.

### Integration tests

On macOS, launch real applications through the PTY: shell, `vim`, `less`, `tmux`, `top`. On iOS, replay recorded sessions of the same applications through `receive` and check the resulting screens.

### Frontend tests

Input-handling tests for both frontends (key translation, IME commit, selection gestures) that do not require a window server where possible.

---

## 16. Non-goals for optimization

Do not optimize early for Intel Macs, generic CPU architectures, external ABI stability, maximal abstraction, or zero dependencies at all costs.

Optimize for:

1. Apple Silicon;
2. the macOS and iOS/iPadOS frontends;
3. measurable terminal latency and throughput;
4. battery use on iOS.

---

## 17. Definition of done

Parity is reached when:

- the macOS and iPadOS apps run daily shell work (`vim`, `tmux`, shells, common TUIs) correctly;
- every milestone in §12 is complete with tests;
- supported behavior matches Ghostty's ported tests;
- parser and cell hot paths allocate effectively zero memory;
- input/render latency is indistinguishable from Ghostty on macOS;
- the Swift core remains materially smaller and simpler than a mechanical Zig port.

---

## 18. Design principle

```text
Apple-native simplicity
    over
cross-platform architectural parity
```

and:

```text
measured performance
    over
language-style purity
```

A tiny C helper for one kernel is acceptable. The goal is a small, Swift-native terminal core for Apple platforms, not 100% Swift purity.
