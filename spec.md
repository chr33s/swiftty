# Swiftty specification

## Goal and scope

Build a small Swift 6.4 terminal core with libghostty behavioral parity for Apple
frontends. Prioritize native Swift APIs, Apple Silicon performance, borrowed
storage and direct Darwin/CoreText/Metal integration. Measure improvements;
a small C helper is acceptable when justified.

| Platform               | Core       | Local PTY   | Frontend             |
| ---------------------- | ---------- | ----------- | -------------------- |
| macOS                  | required   | required    | AppKit, required     |
| iOS/iPadOS             | required   | unavailable | UIKit, required      |
| Mac Catalyst, visionOS | must build | unavailable | UIKit reuse optional |

Scope includes session lifecycle, parsing, terminal state/history, input encoding,
resize, Unicode/graphemes, snapshots, fonts, rendering and frontend features.
The embedder owns external transports, connections, authentication and window/tab/
split management. Linux, Windows, GTK, OpenGL, WebAssembly, plugin APIs and a
stable core C ABI are excluded; Shell supplies its own libghostty embedder API.
Sixel is excluded. Kitty graphics is future work; until separately specified,
ignore APC strings safely. Future graphics support should use bounded image
storage and cover transmission, placement, deletion, z-order and placeholders.

Implementation and verification status belong in [README.md](README.md).

## Architecture and ownership

```text
AppKit / UIKit frontend
          ↓
TerminalSession — one serial queue owns parser and terminal state
  ├─ PTYProcess (macOS) or embedder-supplied byte stream
  ├─ Parser → TerminalState (grid, history, modes, graphemes, status)
  ├─ InputEncoder
  └─ immutable RenderSnapshot → MetalRenderer + CoreTextFontManager
```

Keep targets coarse: `SwifttyCore`, `Swiftty`, `SwifttyMobile`. Within the core,
use `Session`, `Process`, `Terminal`, `Input`, `Unicode`, `Font`, `Renderer` and
`Config` directories. Frontends share everything below view hosting. Isolate
platform code with conditional compilation; avoid a portability layer or
internal C-shaped APIs.

`TerminalSession` provides `start(_:)`, `receive(_:)`, `onWrite`,
`resize(columns:rows:)`, `send(_:)`, `snapshot()` and `stop()`.
PTY I/O uses Darwin `openpty`, `termios`, `ioctl`, `posix_spawn`, dispatch-source
reads and descriptor writes; always reap children, including after stop.
External transports deliver output through `receive`, forward encoded input and
replies, and propagate resize.

I/O enters the existing session queue; UI runs on the main actor. Renderer access
stays on the main thread/render callback.
Use immutable snapshots and coarse synchronization; avoid actors or locks in
parser/grid loops and cross-thread terminal-state mutation.

## Memory, parsing and Unicode

- Common parser and cell-update paths must avoid heap allocation, input-to-`String`
  conversion, repeated `Data` copies, unnecessary ARC and uncontrolled copy-on-write.
  Prefer borrowed `Span`, unique non-copyable ownership, small `InlineArray` storage
  and reusable contiguous buffers.
- Store `BitwiseCopyable` cells in contiguous row-major storage: no cell objects,
  row dictionaries or allocation during ordinary mutation. Reuse resize storage
  where practical. Additional cell metadata belongs in side tables keyed by ID.
- Parse borrowed bytes in batches with a non-copyable state machine, SIMD printable
  scanning and inline UTF-8 decoding optimized for Apple Silicon. Safely ignore
  unsupported or malformed sequences according to terminal rules.
- Use scalars, generated width/grapheme tables and explicit cell semantics rather
  than `Character` storage. Preserve wide cells and grapheme behavior through
  wrap, scroll and resize/reflow.

## Rendering and fonts

Snapshots contain only renderer data and damage. Rebuild damaged rows, retain GPU
buffers and avoid whole-grid copies per frame. Retain damage across missing
drawables and retry a skipped final presentation. Share one Metal renderer across
platforms, with shaders in `.metal` files.
Draw only when needed; suspend frame driving and blink timers for detached,
hidden, fully transparent or empty views and occluded macOS windows. Retain pending
output through fades and opacity pulses; draw while visible and resume animation
on restoration. UIKit also stops momentum while invisible and suspends rendering
and momentum in the background.
Blinking and animated post-processing are the only independent animation sources.

Use CoreText for primary/bold/italic/bold-italic faces, fallback fonts, emoji and
OpenType shaping. Support family per style, point size, features, variations,
synthetic-style controls and cell-size adjustments; default iOS sizing follows
Dynamic Type. Draw box/block/Braille/sextant/Powerline glyphs procedurally.
Render underline styles/colors, blinking text, minimum contrast, opacity/blur and
custom Metal post-processing shaders.

## Frontend milestones

| Milestone     | Required behavior                                                                                                                                                                                                                                                                                      |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1: macOS      | Shell PTY, typing/IME, colors, cursor, reflow, history, alternate screen, mouse, selection/copy, search, clipboard, common prompts and TUIs                                                                                                                                                            |
| 2: iOS/iPadOS | Metal `UIView`, `UITextInput` for keyboard/dictation/IME, hardware key press/release, Esc/Ctrl/Alt/Tab/arrows/symbol accessory bar, touch selection/handles/edit menu, momentum scrolling, touch/pointer mouse reporting, multitasking resize/keyboard avoidance, lifecycle pausing, local demo source |
| 3: protocols  | Semantic prompt marks/jumps/output selection/redraw/click-to-move, underline colors/styles, blinking text, title/SGR stacks, pointer shapes, color-scheme and resize reports, alternate-key encoding and hyperlinks                                                                                    |
| 4: embedding  | Ghostty-style supported configuration/themes, keybinding actions, font/render options, find controls and VoiceOver on both frontends                                                                                                                                                                   |

Milestones require behavioral tests and the performance gates below. Network
clients and frontend window management remain embedder responsibilities.

### Terminal protocols

| Family               | Required support                                                                                                                                                                                         |
| -------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| C0                   | BEL, BS, HT, LF, VT, FF, CR, SO, SI, CAN, SUB                                                                                                                                                            |
| ESC                  | DECSC/DECRC, IND, NEL, HTS, RI, RIS, DECKPAM/DECKPNM, G0/G1 designation including DEC Special Graphics, DECALN                                                                                           |
| CSI movement/editing | CUU/CUD/CUF/CUB/CNL/CPL/CHA/CUP/HVP/VPA/VPR/HPA/HPR/CHT/CBT; ED/EL/ECH/ICH/DCH/IL/DL/SU/SD/REP                                                                                                           |
| CSI state            | TBC, DECSTBM, DECSLRM, SGR (16/256/truecolor, colon subparameters, underline styles and SGR 58/59), SCOSC/SCORC, SM/RM, DECSET/DECRST/DECRQM, DECSCUSR, DECSTR                                           |
| Reports/stacks       | DSR 5/6, DA1/DA2, XTVERSION, XTWINOPS 14/16/18/22/23, XTPUSHSGR/XTPOPSGR (`# {`, `# }`, `# p`, `# q`), color scheme (`? 996 n`)                                                                          |
| Modes                | DEC 1, 3 (with 40), 5, 6, 7, 9, 12, 25, 45, 47, 69, 1000, 1002, 1003, 1004, 1005, 1006, 1007, 1045, 1047, 1048, 1049, 2004, 2026, 2027, 2031, 2048; ANSI 4, 20                                           |
| Input                | Kitty keyboard query/push/pop/set and flags 1/2/4/8/16; X10/normal/any-motion, legacy/UTF-8/SGR mouse; bracketed paste and focus reports                                                                 |
| OSC                  | 0/2 title, 7 cwd, 8 links, 52 clipboard writes, 133 prompts, 21 colors, 22 pointer, 4/10/11/12 set/query and 104/110/111/112 reset, 9 and `777;notify` notifications, `9;4` progress, opt-in 7501 status |
| DCS                  | Streamed tmux control mode (`1000 p`), XTGETTCAP (`+ q`), DECRQSS (`$ q`)                                                                                                                                |

Unknown sequences and other DCS/APC/PM/SOS strings must be ignored safely.
OSC 52 accepts padded/unpadded Base64 and an empty clipboard clear; invalid
characters, whitespace or malformed explicit padding reject the entire write.
Clipboard reads are refused. Paste replaces editing, signal and escape controls
with spaces. Unbracketed LF/CRLF becomes one CR; bracketed paste preserves line
endings and frames empty input. Unsupported upstream protocols/API cases are
tracked separately in [todo.tests.md](todo.tests.md).

## OSC 7501 program status

The core owns protocol validation, state, lifecycle and support replies.
Embedders own badges, notifications, acknowledgment, permission UX, aggregation
and pane-specific transport routing. Keep status distinct from OSC 9;4 progress;
never persist it into a newly created process or interpret it as approval.

### Framing and fields

```text
ESC ] 7501 ; ? ST
ESC ] 7501 ; key=value:key=value... ST
```

Accept BEL or ST across arbitrary input chunk boundaries. Use a dedicated
bounded capture path and apply only complete, validated commands. An over-limit
report must be discarded in full, without applying a truncated prefix.

| Limit                                        |                       Bytes/count |
| -------------------------------------------- | --------------------------------: |
| Whole sequence, including framing/terminator |                        4096 bytes |
| Key                                          |                          16 bytes |
| ID / segment / depth                         | 128 bytes / 32 bytes / 8 segments |
| `app`                                        |                          32 bytes |
| `title`, encoded / decoded                   |                   256 / 192 bytes |
| `msg`, encoded / decoded                     |                 2732 / 2048 bytes |

- `state` is required and case-sensitive: `idle`, `working`, `done`, `blocked`,
  `error` or `clear`. Missing/unknown state rejects the report; `clear` is a
  mutation, never a retained state.
- Omitted `id` addresses the root (`""` in the API). Non-root IDs are slash-separated
  nonempty `[A-Za-z0-9_.+-]` segments. Invalid IDs reject the whole report,
  including clears; they must never fall back to root.
- `progress` is decimal 0–100 for `working`/`blocked`; invalid values are absent.
  `kind` applies only to `blocked`: `permission`, `question` or `auth`;
  unknown values are absent. `app` uses the segment character set.
- `title`/`msg` are standard-alphabet Base64, padded or unpadded, decoding to
  bounded valid UTF-8. Empty values are absent. Reject invalid decoded text,
  C0/DEL/C1 controls and field-limit violations before any mutation.
- Keys use lowercase ASCII letters; value bytes use `[A-Za-z0-9_.,+/=-]`.
  Unknown keys and individually malformed pairs may be ignored; applicable
  repeated keys use the last value, subject to whole-report validation.

Decoded text remains untrusted. Never execute it or interpret it as markup.
Other format characters survive decoding; trusted UI must strip or isolate
bidirectional controls (U+200E/F, U+202A–202E, U+2066–2069).

### Store and lifecycle

The authoritative `ProgramStatusStore` lives in `TerminalState`, independent of
rendering-surface lifetime. Apply commands and lifecycle operations in session
stream order. Keep one record per ID, including root, ordered least recently
updated first. Reports replace the whole record: omitted fields disappear.
A child does not require a stored parent; `app(for:)` resolves its nearest
ancestor's app, then root.

Root clear removes all records. Child clear removes its exact ID and descendants
whose prefix is followed by `/`: clearing `build` removes `build/test`, never
`builder` or `other/build`. Bound storage at 256 records and evict the least
recently updated on insertion; updating an ID moves it to newest.
Observable mutations increment the store revision; invalid/no-op commands do not.
Revisions saturate at `UInt64.max`; consumers must then compare records or use
change notifications.

| Event                                        | Required effect                                                                                                                                                                  |
| -------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Genuine new prompt (OSC 133 A or equivalent) | Remove `idle`, `working`, `blocked`; retain `done`/`error`. Continuation/redraw markers are not command boundaries.                                                              |
| RIS/full reset                               | Clear all records before publishing reset completion. Soft reset preserves them.                                                                                                 |
| Process/session exit                         | Remove transient records; retain existing `done`/`error`, never infer either from the exit code. PTY sessions do this automatically; external transports call `programExited()`. |
| Disable consumption                          | Ignore reports/queries, send no support reply and clear retained records.                                                                                                        |
| Capture reconstruction                       | Explicit `resetForCapture()` preserves records; `continueStream(from:)` restores parser/status state in order. Ordinary RIS still clears status.                                 |

### Consumer and reply contract

`ProgramStatusState` and `ProgramStatusBlockedKind` are typed enums.
`ProgramStatusRecord` exposes immutable `id`, `state`, optional `kind`/`progress`/
`app`/`title`/`message`, and `revision`. `ProgramStatusSnapshot` contains immutable
ordered `records` and `revision`; both are `Sendable` and `Equatable`.

Enable consumption explicitly with `SessionConfiguration.programStatusEnabled`
or `setProgramStatusEnabled(_:)`. Newly attached consumers can immediately read
`TerminalSession.programStatusSnapshot`; `onProgramStatusChange` publishes after
mutation, including status-only updates without cell damage. Copy parser scratch
storage before publication. UI dispatch belongs to the embedder. Presentation
notifications may coalesce, but mutations must not be skipped or reordered.

An enabled support query receives `OSC 7501 ; ?` with its matching BEL/ST
terminator; ordinary reports generate no reply. Deliver generated bytes through
`onTerminalReply: (@Sendable ([UInt8]) -> Void)?`, distinguishable from keyboard/
paste input. Without that callback, transport delivery falls back to `onWrite`;
a PTY sends replies directly to its child. Embedders requiring provenance must
install the callback and route replies to the originating terminal/pane, including
tmux control-mode topologies. Replies and snapshots must work without a surface.

### Required coverage

Cover states/kinds/fields, Unicode, all split boundaries, multiple sequences,
repeated/unknown/malformed pairs, invalid/missing state, ID grammar/depth/length,
each limit boundary including whole sequence ±1, progress edges, Base64/UTF-8/
control rejection and disabled consumption. Verify replacement, root/child clear,
prefix collisions, ordering, capacity/eviction and revisions. Exercise prompt/
reset/exit/reconstruction in stream order, surface-independent publication and
BEL/ST reply provenance. Existing OSC 9;4, OSC 133, reset and response tests
must continue passing. The embedder must consume status without parsing OSC itself.

## Performance and acceptance

| Metric                                            | Requirement                             |
| ------------------------------------------------- | --------------------------------------- |
| Common parser-loop / cell-update heap allocations | 0 / 0                                   |
| Typing latency                                    | no measurable regression                |
| Supported-feature correctness tests               | 100% pass                               |
| Scroll performance                                | no regression from milestone 1          |
| Text-only RSS                                     | ≤15% above milestone 1                  |
| Ordinary-use frame pacing                         | no dropped frames at display rate       |
| UIKit energy behavior                             | no rendering while idle or backgrounded |

Parser throughput must reach ≥95% of upstream Ghostty for every comparison input,
or ≥90% for wide-character-heavy inputs (`Scripts/compare-ghostty.sh`). Maintain
100 MB ASCII/UTF-8, compiler-log, source-file, full-redraw, scroll, resize-stress,
OSC-heavy and CSI-heavy benchmarks. Measure throughput, CPU time, allocations,
peak RSS, frame time and p95 input-to-render latency on Apple Silicon Release
builds; also measure frame time on a physical iPad. Prioritize measurable latency,
throughput and iOS battery behavior over generic architecture or Swift purity.

Tests must cover:

- Parser/state golden cases: CSI/OSC/DCS/APC/SGR, malformed input, cursor/erase/modes,
  UTF-8, history, reflow, alternate screens, wide cells, graphemes and semantic prompts.
- Ghostty oracle cases driven through terminal sequences.
- Real macOS PTY sessions (`sh`, `vim`, `less`, `tmux`, `top`) and recorded iOS
  replays through `receive`.
- Frontend key/IME/selection behavior.

Use window-independent tests where possible and hosted tests for UIKit behavior.

Parity is complete only when:

- All milestones pass their tests and performance gates.
- Both apps support daily shell/TUI work, with supported behavior matching Ghostty.
- Hot paths allocate effectively zero.
- macOS input/render latency is indistinguishable from Ghostty.
- The Swift core remains materially smaller and simpler than a mechanical port.

Automated and offscreen results alone do not establish the interactive acceptance
requirements.
