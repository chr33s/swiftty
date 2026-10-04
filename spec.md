# Spec: Small Swift 6.4 Rewrite of Ghostty Core

## 1. Goal

Implement a **macOS-only Swift 6.4 terminal core** that replaces the minimum useful portion of `libghostty` needed by the existing Ghostty macOS frontend.

The implementation should prioritize:

- small codebase;
- native Swift APIs;
- Apple Silicon performance;
- zero-copy / low-allocation hot paths;
- direct Darwin, CoreText, and Metal integration;
- behavioral compatibility with Ghostty where required.

This is **not** a line-by-line Zig port.

---

## 2. Scope

### In scope

Implement only:

- terminal session lifecycle;
- PTY/process management;
- VT parser;
- terminal grid/state;
- scrollback;
- keyboard/input encoding;
- resize handling;
- Unicode width / combining behavior;
- renderer-facing snapshot/damage model;
- CoreText-backed font lookup;
- Metal renderer host-side integration where required by the existing macOS app.

### Out of scope

Do not implement:

- Linux;
- Windows;
- GTK;
- OpenGL;
- WebAssembly;
- stable external C ABI;
- generic cross-platform abstractions;
- plugin APIs;
- public embedding SDK;
- portability layers that exist only for non-macOS targets.

---

## 3. Architecture

```text
Ghostty macOS UI
      |
      v
TerminalSession
      |
      +-- PTYProcess
      +-- Parser
      +-- TerminalState
      |    +-- Grid
      |    +-- Scrollback
      |    +-- Modes
      |
      +-- InputEncoder
      +-- UnicodeWidth
      +-- RenderSnapshot
      |
      v
Metal/CoreText/Darwin
```

Primary API:

```swift
final class TerminalSession {
    func start(_ configuration: SessionConfiguration) throws
    func resize(columns: Int, rows: Int)
    func send(_ input: TerminalInput)
    func snapshot() -> RenderSnapshot
    func stop()
}
```

Do not expose C-shaped APIs internally.

---

## 4. Module layout

```text
GhosttyCore/
├── Session/
│   ├── TerminalSession.swift
│   └── SessionConfiguration.swift
├── Process/
│   ├── PTYProcess.swift
│   └── FileDescriptor.swift
├── Terminal/
│   ├── Parser.swift
│   ├── TerminalState.swift
│   ├── Grid.swift
│   ├── Cell.swift
│   ├── Scrollback.swift
│   ├── Modes.swift
│   └── Damage.swift
├── Input/
│   └── InputEncoder.swift
├── Unicode/
│   ├── Width.swift
│   └── Tables.swift
├── Font/
│   └── CoreTextFontManager.swift
└── Renderer/
    ├── RenderSnapshot.swift
    └── MetalRenderer.swift
```

Keep targets/modules coarse. Avoid framework fragmentation unless build boundaries require it.

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
- `UniqueArray` or equivalent uniquely-owned contiguous storage;
- explicit borrowing;
- preallocated buffers.

### Terminal grid

Use a contiguous row-major cell buffer.

Conceptual model:

```swift
struct Cell {
    var glyph: UInt32
    var attributes: CellAttributes
    var width: UInt8
}
```

Requirements:

- no class per cell;
- no dictionary per row;
- no allocation during normal cell mutation;
- resize should reuse storage where practical.

### Strings / Unicode

Do not use `Character` as the terminal's fundamental storage unit.

Use:

- Unicode scalars / code points;
- explicit width tables;
- explicit grapheme/combining handling;
- generated Unicode tables where needed.

Terminal cell semantics take precedence over Swift string semantics.

---

## 6. Parser

The parser is a state machine operating directly on borrowed bytes.

API shape:

```swift
struct Parser: ~Copyable {
    mutating func consume(
        _ bytes: borrowing Span<UInt8>,
        into terminal: inout TerminalState
    )
}
```

Requirements:

- zero allocation for common ASCII/UTF-8 input;
- no intermediate `String`;
- process buffers in batches;
- minimize branching in printable ASCII runs;
- use Swift SIMD where it improves scanning;
- optimize primarily for Apple Silicon ARM64.

Initial parser support:

1. printable UTF-8;
2. C0 controls;
3. ESC;
4. CSI;
5. OSC;
6. DEC private modes;
7. SGR;
8. cursor movement;
9. erase operations;
10. alternate screen;
11. title / clipboard sequences only if required by the macOS frontend.

Unsupported sequences must fail safely and be ignored according to terminal rules.

---

## 7. PTY / I/O

Implement directly against Darwin.

Use:

- `openpty` / equivalent PTY APIs;
- `termios`;
- `ioctl`;
- `posix_spawn`;
- `DispatchSourceRead` or a dedicated read thread/queue;
- direct file-descriptor writes.

Recommended ownership model:

```text
PTY read
   |
   v
single terminal execution queue
   |
   +-- Parser
   +-- TerminalState
   +-- Damage tracking
   |
   v
immutable/borrowed render snapshot
```

Do not use one actor per subsystem.

The terminal state should have one mutation owner.

---

## 8. Concurrency

Use explicit queue/executor ownership.

Recommended:

- UI: main actor;
- terminal parser/state: one dedicated serial executor/queue;
- renderer: existing Metal/render queue;
- PTY read/write: dispatch source or dedicated I/O queue.

Rules:

- no cross-thread mutation of `TerminalState`;
- no fine-grained actor hops in parser/grid loops;
- pass render state as immutable snapshots or safely borrowed storage;
- keep synchronization points coarse.

---

## 9. Rendering boundary

The core should output a compact render snapshot containing only data needed by Metal.

Example:

```swift
struct RenderSnapshot {
    let rows: Span<RowSnapshot>
    let cursor: CursorState
    let damage: DamageRegion
}
```

Renderer goals:

- avoid rebuilding the entire screen if damage is localized;
- batch glyph work;
- retain/reuse GPU buffers;
- avoid copying the entire terminal grid every frame.

Keep Metal shader code in `.metal` files.

---

## 10. Fonts

Use CoreText directly.

Provide:

```swift
final class CoreTextFontManager {
    func resolve(_ descriptor: FontDescriptor) -> ResolvedFont
    func glyph(for scalar: Unicode.Scalar, in font: ResolvedFont) -> CGGlyph?
}
```

Support only what the macOS frontend needs initially:

- primary font;
- bold;
- italic;
- bold italic;
- fallback fonts;
- emoji fallback.

Defer advanced font configuration until core parity is stable.

---

## 11. Minimal feature milestone

First usable milestone must support:

- launching a shell;
- typing;
- UTF-8 text;
- basic ANSI colors;
- cursor movement;
- resizing;
- scrollback;
- alternate screen;
- `vim`;
- `less`;
- `tmux`;
- common shell prompts;
- basic mouse input if required by the frontend.

Do not block the first milestone on every terminal extension Ghostty currently supports.

---

## 12. Migration strategy

### Phase 1 — Swift shell

Create `GhosttyCore` and expose `TerminalSession`.

Existing Zig implementation remains active underneath if needed.

### Phase 2 — PTY + input

Move:

- PTY;
- process launch;
- input encoding;
- resize.

### Phase 3 — terminal state

Move:

- grid;
- scrollback;
- modes;
- cursor;
- damage tracking.

### Phase 4 — parser

Move the minimum VT parser needed for the supported milestone.

### Phase 5 — rendering integration

Feed Swift terminal state directly to the existing Metal path or a reduced Swift Metal renderer.

### Phase 6 — remove Zig dependency

Only after correctness and performance gates pass.

---

## 13. Performance requirements

### Hard requirements

| Metric | Requirement |
|---|---:|
| parser-loop heap allocations | 0 for common input |
| cell update allocations | 0 |
| typing latency | no measurable regression |
| terminal correctness tests | 100% for supported features |
| CPU during ordinary shell use | <= 10% regression |
| scroll performance | <= 10% regression |
| RSS | <= 15% regression |
| frame pacing | no visible regression |

### Target

Parser throughput should reach at least:

```text
>= 90% of current Zig implementation initially
>= 95% before replacing Zig by default
```

Exact parity is preferred but not required if interactive performance is unchanged.

---

## 14. Benchmarks

Maintain microbenchmarks for:

- 100 MB ASCII stream;
- 100 MB UTF-8 stream;
- compiler log output;
- `cat` large file;
- rapid full-screen redraw;
- repeated scrolling;
- resize stress;
- OSC-heavy input;
- CSI-heavy input.

Measure:

- MB/s;
- CPU time;
- allocations;
- peak RSS;
- frame time;
- p95 input-to-render latency.

Run benchmarks on Apple Silicon Release builds.

---

## 15. Testing

Required test layers:

### Parser tests

Golden input/output tests for:

- CSI;
- OSC;
- SGR;
- cursor movement;
- erase;
- modes;
- UTF-8;
- malformed input.

### Terminal-state tests

Verify:

- wrapping;
- scrolling;
- resize;
- alternate screen;
- combining marks;
- wide characters;
- cursor behavior.

### Integration tests

Launch real applications:

- shell;
- `vim`;
- `less`;
- `tmux`;
- `top` / equivalent TUI.

Where possible, reuse Ghostty's existing behavioral test vectors as the oracle.

---

## 16. Non-goals for optimization

Do not optimize early for:

- Intel Macs unless still required;
- generic CPU architectures;
- Linux compatibility;
- external ABI stability;
- maximal abstraction;
- zero dependencies at all costs.

Optimize for:

1. Apple Silicon;
2. macOS;
3. Ghostty's macOS frontend;
4. measurable terminal latency and throughput.

---

## 17. Definition of done

The rewrite is ready to replace the Zig core when:

- the macOS app launches and operates without Zig;
- supported terminal behavior matches existing Ghostty tests;
- `vim`, `tmux`, shells, and common TUIs work correctly;
- parser and cell hot paths allocate effectively zero memory;
- input/render latency is indistinguishable from current Ghostty;
- CPU/RSS remain within the agreed regression budget;
- the internal C bridge is removed;
- the resulting Swift core is materially smaller and simpler than a mechanical Zig port.

---

## 18. Design principle

The implementation should prefer:

```text
macOS-native simplicity
    over
cross-platform architectural parity
```

and:

```text
measured performance
    over
language-style purity
```

If a tiny C/assembly helper is required for one SIMD scanning kernel, that is acceptable. The goal is a small, Swift-native macOS terminal core, not a literal 100% Swift purity constraint.
