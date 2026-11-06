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
split management; the Swiftty app's own SwiftMux workspace window is specified
below. Linux, Windows, GTK, OpenGL, WebAssembly, plugin APIs and a
stable core C ABI are excluded from the terminal core and frontends (`Package.swift`
reduces itself on Linux to the `swsh` shell and confined-execution targets in
[spec.shell.md](spec.shell.md)); Shell supplies its own libghostty embedder API.
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

The diagram describes direct byte-stream sessions. `SwifttyEngine` is headless;
`SwifttyCore` adds session/rendering functionality, and `SwifttyMac` and
`SwifttyMobile` host native views. `SwiftMuxService` depends on the headless
engine, not AppKit or Metal. Keep targets coarse and isolate platform code with
conditional compilation; avoid a portability layer or internal C-shaped APIs.

Terminal capabilities compose: engine and ordered runtime, persistent workspace
service, local/roaming attachments, then product workflows. Shared presentation
sits alongside those owners; this is not an inheritance hierarchy or a requirement
that every target import the next layer. The renderer does not own workspace
policy, and ordinary SSH/SFTP does not require roaming.

| Path | Parser and presentation | Lifetime |
|---|---|---|
| Direct local / embedding | Local runtime; retained renderer snapshots | Direct session / embedding API |
| Ordinary SSH | Client-side parser; locally parsed byte stream | Ends with SSH connection |
| Native SwiftMux | Agent-side runtime; validated owned pane frames | Outlives app window |
| Roaming workspace | Same agent-side runtime; validated RST snapshots | Outlives network attachment within service retention guarantees |
| Confined execution ([spec.shell.md §11](spec.shell.md#11-confined-execution-an-execution-context-with-swsh-as-its-runner)) | Confined pane PTY or headless `swsh` runner inside a per-context Linux VM | Bounded by execution-service lease and grant |

`swiftmux-agent` remains the single persistent workspace/PTY authority. Local
SMX and roaming RST address the same workspaces and leases. For confined
workloads, the app, the multiplexer service and the JavaScript runtime are
clients of the execution service (`SwifttyExec`) and gain no path around it: a
confined pane attaches a PTY to one execution context, an agent identity never
receives host-pane writes, the JavaScript bridge or SSH as a path to the host,
and an unreachable execution service reports `service_unavailable` instead of
falling back to host execution ([spec.shell.md §11.5](spec.shell.md#115-swiftty)). Applications own
windows, navigation, trust prompts and credentials; attachments own protocol
identity, recovery and delivery; surfaces own visible interaction. A workspace,
tab, view, connection and PTY have distinct lifetimes. Hide, detach and end are
separate operations. Neither an attachment nor a mux view creates another emulator.
Do not force direct rendering through network encoding or full-grid export/import.

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

### Shared native presentation and interaction

`TerminalView` and `MuxPaneView` compose package-internal helpers in `SwifttyMac`:

| Helper | Shared behavior |
|---|---|
| `TerminalComposition` | IME state, Unicode range clamping, cancellation, preedit and candidate geometry |
| `TerminalDisplay` | Renderer configuration, MTK setup, visibility, coalesced retries, submission, blink and animation scheduling |
| `TerminalKeyboard` | Binding consumption, key equivalents and IME dispatch |
| `TerminalPointer` | Gesture routing, click units, cell geometry and fractional scrolling |
| `TerminalAccessibility` | Unicode text/ranges, hit testing and rectangles; cache keyed by retained source identity and sequence |

Small adapters retain direct state/history access and mux frozen-frame semantics.
They obtain complete immutable presentations without unbounded queues, coalesce
redraw notifications, submit ordered bounded semantic input, propose geometry
without declaring authority acceptance, expose supported capabilities, and route
history/search/links/actions to their owner. Preserve dead keys, modifiers,
special keys, negotiated keyboard modes and exactly-once IME commits. Unsupported
capabilities are disabled honestly. Invalid scroll deltas preserve accumulated
fractions and report loops remain bounded.

Public `TerminalView` remains a final `MTKView` with its nonoptional `session` and
existing initializers; do not add a dummy session to mux or a public plugin API.
The public `MetalRenderer.tryDraw(_:in:)` signature is also preserved. Native
presentation callbacks use a package-internal overload guarded to native macOS.

Only accepted renderer submission advances the snapshot/mode baseline for
hit-testing, links, selection, IME, cursor placement and accessibility. Busy,
unavailable or hidden rendering keeps the prior baseline. Direct pointer lookups
are fenced to that presentation. Selection-only overlay mutations may retain a
source/revision ticket; any other published change retires it. Edge dragging
selects the displayed edge before requesting a scroll, so new output cannot
silently become selectable. No full-grid copy is required for this fencing.
View replacement cancels composition and releases subscriptions/resources without
ending a service-owned process. Mux-specific requirements are in
[spec.multiplexer.md §7](spec.multiplexer.md#7-later-frontend-native-swiftty-with-metal).

Standalone native UI input reserves a 64 KiB budget before encoding or semantic
callbacks are queued; credit includes blocked PTY bytes and is released on drain
or teardown. Immediate refusal beeps, and paste/drop actions report failure.
Explicit LocalPTY/SSH backends keep their own admission policy. Public
`TerminalSession.send` retains its unbounded embedding contract. The reservation
calculation is shared as `TerminalInput.encodedByteReservation`. Semantic callbacks
are captured at submission, preventing queued input from following a replacement
attachment; see [roaming attachment ownership](spec.roaming.md#production-attachment-ownership).

### Runtime extraction and deferred boundaries

Share one proven behavior at a time, preferably starting with a failing or
characterization test. Candidate mechanics include parser/state sequencing,
ordered replies and provenance, input encoding, publication, scrollback upkeep,
capture/events and PTY I/O where semantics match. An extraction must remove more
duplicate behavior than wrappers, preserve single-owner ordering, bounded
backpressure and cleanup, and stay within existing performance gates. Avoid
`isMux`/`isRemote`/`ownsWorkspace` switches throughout common hot paths or
cross-executor indirection without a deletion benefit.

`TerminalSession` remains the embedding facade. `PaneRuntime` retains workspace
identity, persistent launch/ownership, writer leases, bounded paste, observer
viewports, service exit/drain rules, frame identity/SMX encoding and attention.
They already share parser/state and scrollback maintenance; the input-reservation
extraction is used by actual callers. Their different reply, callback and lifetime
policies do not justify wholesale runtime consolidation.

Owned-capture replacement, SSH bootstrap relocation, XPC target separation and
module renaming remain optional, not prerequisites:

- Borrowed queue-ordered `MuxService.inspect` is valid. Replace it only for an
  observed consistency, coupling or testability limitation, with bounded coherent
  capture, stable revisions and explicit viewport semantics. Keep RST clipping,
  palette/grapheme limits and encoding in its adapter; avoid gratuitous copies.
- Move `runBootstrap` into `SSHBootstrapper` only if that removes generic SSH-layer
  RST policy without duplicating timeout, path-validation or error handling.
- Split Foundation SMX contracts from XPC only for an enforceable dependency/build
  benefit; do not create separately versioned packages for diagram symmetry.
- Preserve target/product names and the dependency graph unless a concrete change
  needs a new boundary. No universal backend ABI, wire DTO, extra parser/renderer/
  SSH stack, service or PTY owner is required. SFTP and watch companion data stay
  outside the terminal display pipeline. Lease/input-ledger protocols and survival
  after logout, reboot or agent crash remain unchanged.

### SwiftPM C security settings

The Xcode app wrappers compile Swift only; their C/Objective-C warnings do not
configure the SwiftPM C targets `SwiftMuxLauncher` and `CAllocCounter`.
Adding warning flags through `cSettings.unsafeFlags` remains deferred: it was
not approved in the recorded security-settings review, and unsafe flags would
prevent use of the affected package products as remote dependencies.
`CLANG_WARN_SUSPICIOUS_IMPLICIT_CONVERSION`, `CLANG_WARN_ASSIGN_ENUM`,
`GCC_WARN_SIGN_COMPARE` and `CLANG_ANALYZER_SECURITY_BUFFER_OVERFLOW_EXPERIMENTAL`
would matter through those C targets rather than the Swift app wrappers.

`ENABLE_C_BOUNDS_SAFETY` also remains deferred. It requires an annotation-based
programming model, with `Sources/SwiftMuxLauncher/main.c` the candidate scope;
the recorded adoption workflow is the `adopt-c-bounds-safety` skill. This is a
separate source-adoption task, not an enabled build flag. App-target settings and
platform exceptions live in
[the roaming specification](spec.roaming.md#25-xcode-security-build-settings).

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
| 4: embedding  | JSONC configuration/themes, keybinding actions, font/render options, find controls and VoiceOver on both frontends                                                                                                                                                                   |

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
tracked in [the deferred terminal checks](todo.md#deferred-terminal-feature-checks).

Committed typing/IME text without a physical key uses key code zero when Kitty
flag 8 is set; flag 16 adds its Unicode scalars as associated text. Other flags
retain UTF-8 commits. Key-report mode refuses committed text containing C0, DEL
or C1 controls; control actions use key events and explicit byte writes stay raw.
PTY and SSH admission reserve the largest possible encoding before queueing,
because keyboard modes can change before encoding. This may refuse a large
commit even when its current UTF-8 encoding would fit the pending-byte limit.

## Configuration

### JSONC format and discovery

Terminal settings use JSONC: JSON with `//` and `/* ... */` comments and
trailing commas in objects and arrays. The shared `SwifttyConfig` library MUST
use only the Swift standard library and Foundation, including `JSONDecoder`
and `JSONEncoder`; no external parser dependency is required.

Resolve configuration in this order:

1. Explicit `--config <path>`. A missing argument or missing explicit file is
   an error, not permission to select a fallback.
2. `${XDG_CONFIG_HOME:-~/.config}/swiftty/config.jsonc`.
3. `~/.swiftty.jsonc`, then `~/.config/swiftty/config.json`.

Ghostty-style `key = value` files and includes are not supported. Discovery
ignores extensionless legacy files. Explicit files are always parsed as JSONC.
With no file, use internal JSONC defaults. Edit Configuration File can create a
commented template on demand at the selected/default JSONC path; startup need
not write a file. Reload and Settings edits MUST retain the selected path,
including an explicit CLI override. Native settings and persistence behavior
are specified in [the Apple platform spec](spec.apple.md#a01--native-settings-cfg-01).

### Parsing and diagnostics

The processing pipeline is UTF-8 source → byte-preserving sanitizer → syntax
validation/source index → Foundation decoding → typed validation. Reads MUST
require regular UTF-8 files and enforce the shared 1 MiB input limit.

The sanitizer MUST replace each comment byte and permitted trailing comma with
ASCII space, retaining CR and LF at their original offsets. It MUST operate
outside quoted strings and respect escaped quotes and backslashes. URLs and
comment-like text inside strings remain untouched. Scan UTF-8 bytes rather than
Swift `Character` values so non-ASCII comments do not shift source positions.
Reject unterminated comments, malformed JSON and duplicate keys; sanitization
must not turn invalid comma placement into valid JSON.

Syntax errors, unknown keys, missing required values, type mismatches and range
errors MUST report the original file, one-based line and one-based UTF-8 byte
column (tabs count as one), plus the coding path when available. Preserve a
source index for mapping decoding paths to locations; Foundation decoding
contexts alone do not guarantee exact source positions.

The same syntax parser serves [JavaScript JSONC data](spec.javascript.md#jsonc-data-for-automation).
Terminal configuration validation applies only when loading terminal settings.

### Typed model and editor schema

`SwifttyConfig` and its font, window, terminal and keybinding models are mutable
`Codable` values. Omitted sections and settings use defaults:

| Section | Settings and defaults |
| --- | --- |
| `font` | `family: "Menlo"`, `size: 13`, `line_height: 1.2` |
| `window` | `opacity: 0.95`, `blur: true`, `padding: 8`; optional `width` and `height` in content points |
| `terminal` | `shell: null` (default login shell), `scrollback_limit: 10000` history rows |
| `keybindings` | Empty array; each entry requires `trigger` and `action` strings |

A shell setting is an executable path, not a shell command. The existing
scrollback byte budget also bounds history. Optional `theme`, `copy_on_select`,
`mouse_hide_while_typing`, `cursor_style` and `cursor_style_blink` fields support
native Settings edits. Use snake_case JSON keys and map `$schema` to the model's
schema field.

The repository's [schema.json](schema.json) MUST describe supported fields,
defaults, types and ranges for editor completion and agree with runtime
validation. Unknown keys are rejected. The optional `$schema` value is the
plain URL `https://raw.githubusercontent.com/chr33s/swiftty/main/schema.json`,
not a Markdown link; it resolves once published to the main branch.

Example user configuration:

```jsonc
{
  "$schema": "https://raw.githubusercontent.com/chr33s/swiftty/main/schema.json",
  // Font configuration
  "font": { "family": "SF Mono", "size": 14, "line_height": 1.15, },
  /* Window styling and compositor blur */
  "window": { "opacity": 0.92, "blur": true, "padding": 12, },
  "terminal": { "shell": "/bin/zsh", "scrollback_limit": 50000, },
  "keybindings": [
    { "trigger": "cmd+k", "action": "clear_screen" },
    { "trigger": "cmd+t", "action": "new_tab" },
  ],
}
```

Theme files also use JSONC. Supported color keys are `foreground`, `background`,
`cursor`, `cursor_text`, `selection_foreground` and `selection_background`;
`palette` maps indexed-color numbers (0–255) to color strings. Look up names in
Swiftty's theme directory, then the built-in light/dark themes; do not search
Ghostty's directory. A name containing a slash selects an explicit path. Theme
files must be regular UTF-8 files of at most 64 KiB. Reject invalid theme
documents as a whole and continue to the next named-theme fallback.

### Serialization and required coverage

Runtime settings mutations MUST round-trip through the typed model.
`ConfigLoader.save` validates before atomically writing with
`JSONEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]`. Saving replaces
JSONC comments and formatting with canonical JSON; it does not promise textual
round-trip preservation. Resolve a symlink's target when saving so linked
dotfiles keep their links.

Required verification covers:

- URLs, escaped quotes, backslashes and comment markers inside strings.
- Multiline and non-ASCII comments with identical UTF-8 byte offsets and line
  endings after sanitization; valid trailing commas in both arrays and objects.
- Unterminated comments, malformed commas, duplicate and unknown keys, missing
  required values, invalid types/ranges and oversized or non-UTF-8 input.
- Exact original-source diagnostics, including a type mismatch below a 20-line
  comment block, nested coding paths, CRLF and non-ASCII input.
- Discovery precedence, missing explicit paths, defaults and template creation.
- Mutating settings, saving canonical sorted JSON and reloading equivalent
  values, including validation failure and preservation of symlink targets.
- Native Settings and JavaScript consumers using the shared parser/model
  contracts, with their platform-specific acceptance criteria in their specs.

## OSC 7501 program status

The core owns protocol validation, state, lifecycle and support replies.
Embedders own badges, notifications, acknowledgment, permission UX, aggregation
and pane-specific transport routing. Keep status distinct from OSC 9;4 progress;
never persist it into a newly created process or interpret it as approval. Output
and terminal control sequences from an execution context are untrusted data and
cannot draw approval state, open URLs, set the clipboard or trigger UI actions;
scope, backend, expiry and cleanup state come from service state in UI that
terminal output cannot imitate ([spec.shell.md §11.3](spec.shell.md#113-the-service), [§11.5](spec.shell.md#115-swiftty)).

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
- Trim surrounding whitespace on keys and values before field validation;
  a spaced `id` must retain its scope rather than become an omitted ID.
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

## SwiftMux native workspace

The Swiftty app is also the native frontend for SwiftMux, the persistent
per-user session service. The service, its wire protocol and its acceptance
record are in [spec.multiplexer.md](spec.multiplexer.md). Remote attachment,
leases, the attention inbox and deep links are in
[spec.inbox.md](spec.inbox.md). This section covers the native workspace
window.

**Not a character compositor.** AppKit draws the window chrome: tab strip,
dividers, pane headers, focus and geometry. Swiftty's Metal renderer draws
each pane's cells. The service owns sessions, pane identities, PTYs, parsers,
history and the canonical layout. The `swmux` terminal client remains a
secondary frontend.

**One window type.** Every terminal window the app opens is a workspace
window, and a plain shell is the smallest workspace: one tab, one pane, one
login shell. Adding a tab or splitting grows the same workspace; it never
restarts, transfers or recreates the original process. There is no second,
app-owned terminal window: `TerminalView` and `TerminalSession` remain
reusable library APIs (the roaming clients and tests use them), but a shell
in a workspace is never an app-owned `TerminalView` session. Presentation
helpers are shared where useful, without a second authoritative emulator.

### Commands

**Terms.** *Workspace* names the persistent thing a person creates, opens,
renames and ends; *window* names only its on-screen view. Commands on the
workspace say Workspace (the Workspace menu, New Workspace, End Workspace);
Close Window and the Window menu act on the window and leave the workspace
running. Tabs and panes are parts of a workspace.

The window starts with minimal chrome (workspace title, the terminal, add
and inbox controls) and shows the tab strip once there is a choice. Access
to the workspace chooser and lifecycle commands is never hidden.

| Command | Meaning |
|---|---|
| New Workspace (⌘N) | Create one workspace with one shell, in its own window. |
| New Tab (⌘T) | A shell in a new tab of the focused workspace. |
| Split Right / Split Below | A sibling shell in the current tab's split tree. |
| Open Workspace… (⇧⌘O) | List workspaces; reveal one this app shows, or attach it in another window. Opening never creates a shell; the chooser's New Workspace button does, as ⌘N would. |
| Rename Tab / Workspace | Metadata only. |
| Close Window (⌘W) | Detach this window; processes keep running. |
| End Pane / Tab / Workspace | Terminate exactly that scope, confirming while processes run. A tab's close button says it ends its processes. |

Commands travel the responder chain to the key window's controller and are
validated against that window's actual attachment (connected, controller,
target present). A text field (search, a tab rename) and IME composition
keep their own editing commands. Helper management (staging and installing
updates) sits under the app menu's Terminal Service item.

### Startup and discovery

- **First launch** creates a one-shell workspace.
- **Later launches** reopen the last workspace when it is free, or the only
  free workspace when the last is unknown or gone; otherwise they offer the
  existing workspaces before creating another. The remembered value is an
  identity, never a copy of the split tree.
- **Opening** a workspace this app shows reveals its window. One held by
  another client needs an explicit takeover; declining or failing leaves the
  current windows usable.
- **Service unavailable** (helper missing, awaiting approval, unreachable or
  a different running version): the app says so and offers a retry. It never
  starts a non-persistent local shell instead.

### App coordination

`WorkspaceCoordinator` owns the application-level registry:
- create, open and reveal are distinct operations, and a repeat while one
  is pending joins it;
- windows are keyed by service instance and workspace identity, never by
  name; a window that lost its lease or connection matches nothing, so a
  service-instance change invalidates stale registrations;
- each window has its own connection and holds its workspace's lease;
  reopening a workspace already shown reveals it rather than adding a writer;
- configuration reload, staged-update detachment and Quit apply to every
  window; closing one window never detaches another; attention links reveal
  or open their target without detaching an unrelated window.

The coordinator manages windows, the window controller presents one
attachment, and the service stays authoritative for workspace and process
state; no client-side workspace tree mirrors it.

### Launch settings

`WorkspaceLaunch` turns configuration into a new workspace's `LaunchSpec`
with the rules of `Configuration.sessionConfiguration()`:
- `command` keeps Ghostty's `shell:` expansion and `direct:` arguments;
  unset runs the login shell;
- `working-directory` is an explicit path, `home`, or `inherit`, which
  resolves in the frontend (its current directory) because the agent runs
  elsewhere;
- the frontend's environment is snapshotted; the service still sets the
  terminal variables it requires over it.

New tabs reuse the workspace's spec; splits start a login shell in the split
pane's directory. `scrollback-limit` (and `scrollback-limit-bytes`,
`scrollback-limit-lines`, `scrollback-compression`) is not carried: the service
applies its own history limit to every pane, and its local
`MuxServiceConfiguration.scrollbackCompression` decides idle compression.

### Layout model

A workspace holds tabs, and each tab holds a typed split tree. Layouts are
never stored as absolute pixel coordinates.

```swift
indirect enum LayoutNode { case pane(PaneID); case split(axis:ratio:first:second:) }
enum SplitAxis { case leftRight, topBottom }
```

- **Splits:** `leftRight` has left/right children and `topBottom` has
  top/bottom children. `ratio` is the share given to `first`, in (0, 1).
  It is derived from the available geometry and changed by dragging a
  divider.
- **Panes:** each pane has a stable ID, one PTY and one authoritative
  emulator.
- **Titles:** a tab or pane title is either a user label or a bounded,
  sanitized title reported by the program. Tab icons are local UI metadata,
  never remote content.
- **Tabs:** switching tabs hides views without suspending server-side
  processes or parsers.
- **Close actions:** hiding, detaching and terminating are distinct.
  Terminating a running pane or tab asks for confirmation first.

### Ownership

| Service owns | Native app owns |
|---|---|
| Workspace, tab and pane IDs; split tree; pane lifecycle | Window, tab strip, focus, pane headers, dividers, hover, selection |
| PTY, child process, exit status, terminal state, bounded history | One `MTKView` and Metal renderer per visible pane; fonts, atlases, GPU resources |
| Canonical grid sizes and accepted geometry generations | Pixel rectangles and proposed grids from font metrics, scale and padding |
| Input sequencing, mode-aware encoding, terminal query replies | AppKit key events, IME composition, paste, native shortcuts |
| Bounded owned frame export and pane events | Frame validation and import, display coalescing, presentation baseline |

One XPC connection holds the interactive lease for the attached workspace.
Each `MuxPaneView` subscribes to its pane through that connection. Destroying
a view never ends the lease or a PTY. On reconnect the app requests the
workspace tree and a complete frame for every visible pane.

### Pane presenter and frame bridge

`MuxPaneView` keeps a client-side frame store. It never runs another shell,
PTY or parser. The service exports **owned semantic frames** (`PaneFrame`):
- graphemes, cell widths and continuations;
- attributes and palette;
- wrap flags, cursor, active screen and dimensions;
- revision and geometry identity.

The bridge (`SwiftMuxBridge`) validates counts and sizes before allocating,
then imports the frame into snapshot storage for the renderer. It never sends
raw `RenderSnapshot` pointers, pooled storage, cell ABI dumps, GPU buffers or
Swift object serialization. It never turns frames back into ANSI for a second
parser.

The pipeline:
1. **Parse.** The service parses every PTY byte in order, including for
   hidden panes.
2. **Publish.** It publishes a full owned frame tagged with pane, attachment,
   revision, layout revision and geometry generation.
3. **Check.** The app accepts the frame only for the current attachment and
   accepted geometry.
4. **Bound.** Each presenter keeps the displayed frame, one frame in
   preparation and the newest pending replacement, never a backlog.
5. **Draw.** On the main actor it imports the frame, schedules the `MTKView`
   and draws.
6. **Advance the baseline.** Only a frame actually accepted for presentation
   replaces the interaction baseline used for hit testing, IME placement,
   selection and accessibility. A skipped drawable does not advance it. GPU
   resources live until their command buffers complete.

### Interaction

- **Tab strip:** editable labels, local icons, activity dots, new tab, and
  separate close and detach actions. It is a view of the service's workspace
  state.
- **Pane headers:** the program or title label, an active-pane indicator,
  and split, zoom and close actions. Title text is sanitized before display.
- **Dividers:** adjustable ratios with minimum pane sizes, keyboard- and
  VoiceOver-adjustable. A drag updates the proposed layout locally and sends
  coalesced geometry, never one request per pixel.
- **Focus and keys:**
  - Clicking a pane focuses it by ID, and semantic input goes to the focused
    pane.
  - Window and tab focus changes never end processes.
  - App shortcuts (new tab, split, focus, zoom, resize, end pane or tab,
    find) are never forwarded as terminal input.
  - Ctrl-C, arrows, paste and IME commits go to the pane.
- **Selection and search:** selection freezes the displayed viewport for
  copy. Find runs the service's bounded history search. Selection across
  fetched pages is deferred.
- **Accessibility:** pane names, status, dividers, tab titles and displayed
  text are exposed through AppKit accessibility. Mutable server state is
  never read synchronously on the main actor.
- **Attention inbox:** the toolbar badge and popover are specified in
  spec.inbox.md §3.5.

**Terminal parity.** A workspace pane offers what a direct terminal window
did. Behaviour that needs the emulator runs in the service and is advertised
in `Welcome.features` (spec.multiplexer.md §7.5); a frontend disables the
matching menu items with a service that lacks it, rather than leaving them
inert:
- mouse reporting to programs (Shift still selects), button and any-motion
  modes, and the alternate-screen wheel sending arrows;
- `copy-on-select`, `cursor-click-to-move`, `mouse-hide-while-typing` and
  `custom-shader` (animated shaders drive frames);
- ⌘-click and ⌘-hover links (OSC 8, or detected URLs with `link-url`);
- prompt jumps, scroll to top, Select Command Output, Clear Screen and Reset
  Terminal, from menus and key bindings;
- user key bindings, search, font zoom, theme and padding as in the direct
  view.

### Resize and full-screen programs

- **Geometry batch:** for each visible pane the app computes columns and rows
  from the real font metrics, backing scale and content rectangle, excluding
  the header, padding and divider. It submits one batch tagged with the layout
  revision and a client geometry generation. The service accepts a valid
  batch atomically, resizes emulators and PTYs, then publishes frames carrying
  the matching generation. Stale frames and stale batches are ignored.
- **Full-screen programs:** alternate screen, raw keys, cursor visibility,
  terminal queries, bracketed paste and resize notifications behave as in a
  plain Swiftty window.
- **Hidden and small panes:** a hidden pane keeps parsing and keeps its last
  accepted size until it is visible again. A pane too small for its program
  keeps a valid PTY size and clips; it is never zero-sized.

### Lifetime

A window, tab, pane view or app process never owns the last reference to a
shell.
- Closing a view ends its subscription.
- Quitting the app detaches its lease.
- Only an explicit end of a pane, tab or workspace kills shells.
- Reopening the app lists workspaces and requests fresh full frames.

- A shell that exits follows the service's exit and remain-on-exit rules; no
  empty workspace snapshot is invented.
- Another client taking control stops this window's input and shows it
  detached.
- After an agent restart, workspaces are listed and identities resolved
  again; old leases, process IDs and queued input are never reused.

"Persistent" means shells outlive windows and the app while the service runs.
A service crash, logout or reboot is not restored transparently, and no
submitted command is ever replayed to recreate a process. The endpoint checks
that the peer is the same user, and every lease, input and resize is fenced
by attachment generation. Queues for PTY writes, parsing and frame delivery
are bounded.

### Required coverage

- Three independent PTYs in a left-stacked, right-tall layout, with distinct
  input routing and process IDs.
- Switching tabs and quitting and reopening the app while a full-screen
  program runs; its screen converges after reattach.
- Rapid resize, zoom and moving between displays; stale frames never restore
  old dimensions.
- One pane flooding output while typing in another; the UI stays responsive
  and queue memory stays bounded.
- Pasting text that contains shortcut characters never triggers a split, tab
  switch or prefix command.
- IME composition, grapheme widths, selection of changing output and cursor
  placement.
- Renderer failure, missing drawables and a client crash never end a PTY or
  advance the presentation baseline early.
- An explicit destructive action ends only the intended pane; disposing a
  view never does.
- New Workspace makes exactly one workspace, tab and shell; a second makes
  another workspace; New Tab and Split keep the original shell.
- Two windows are controlled independently; commands reach only the focused
  one, and Open Workspace never duplicates a writer or PTY.
- Closing a window during create, open or takeover retires the pending
  operation; a timeout after a possible create does not create again, and
  the workspace stays listed.
- Custom commands and directory policies match the direct-window rules.
- The parity features above, including text-field focus and IME.
- Helper approval, absence, unavailability and a different version are
  recoverable, with no direct-shell fallback.
- Configuration reload and Quit reach every window; stale service instances
  and frames are rejected; attention links detach no unrelated window.

Status and measurements for these are recorded in spec.multiplexer.md §11.

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
or ≥90% for wide-character-heavy inputs (`Scripts/compare-ghostty.py`). Maintain
100 MB ASCII/UTF-8, compiler-log, source-file, full-redraw, scroll, resize-stress,
OSC-heavy and CSI-heavy benchmarks. Measure throughput, CPU time, allocations,
peak RSS, frame time and p95 input-to-render latency on Apple Silicon Release
builds; also measure frame time on a physical iPad. Prioritize measurable latency,
throughput and iOS battery behavior over generic architecture or Swift purity.

Scrollback compression (`spec.scrollback.md`) adds these gates: output into a
full compressed ring reaches ≥98% of uncompressed throughput with restoration
timed; idle encoding of one ≤256 KiB unit stays below 1 ms p99; a cold 120×80
viewport capture stays within p95 4 ms and p99 8 ms; text corpora save ≥70% of
the accounted backing of eligible cold units; read-only scans leave history
compressed; clearing history decodes nothing. `swiftty-bench --only
scrollback-memory,scrollback-compression,scrollback-resume` measures them.
Retention budgets count uncompressed history cells, so compression never
changes which rows are kept or SwiftMux pane admission.

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

### Shared-surface regression gates

Behavior fixes must be inherited by both direct and mux adapters, with no second
frontend emulator and no unused parallel production attachment. Preserve existing
security, protocol, resource and lifecycle guarantees. Required checks include:

- A direct local terminal and a native mux pane render the same deterministic terminal content, widths, attributes, cursor and wraps.
- IME composition and commit, dead keys, modifiers, special keys and paste deliver intended input exactly once.
- A mux pane accepts frames only for the current server/attachment/pane/geometry and rejects stale frames.
- Renderer unavailable/busy/hidden does not advance the interaction baseline prematurely.
- Selection on a frozen displayed frame survives ongoing output and accurately copies wrapped/wide text.
- Switching tabs or destroying a pane view does not terminate any process.
- Closing an app window, app Quit and local/remote detach retain the same service-owned shell and workspace until an explicit end or applicable service failure.
- One writer is authoritative across local and remote transports; takeover fences old queued input.
- Lost/uncertain input is not replayed into a new shell; ordinary SSH fallback is visibly separate.
- Hidden/detached panes continue parsing output, draining replies and maintaining bounded history.
- Final output, process exit and attention status are delivered in established order.
- Search, prompt navigation, mouse reporting, clipboard security policy, accessibility, theme, focus and font zoom retain their existing supported behavior.
- Backpressure and slow receivers cannot grow input, frame or UI queues without bound.


Compare before/after on the same hardware, OS, build mode (including testability)
and workload: parser throughput/allocations; direct typing/rendering; mux input,
frame and presentation stages; visible/hidden/detached CPU, memory and allocations;
submission/frame pacing under load; and affected mobile lifecycle/energy behavior.
A reproducible regression outside existing gates calls for revisiting the
abstraction before optimizing around it.

### Shared-surface implementation and validation — 2026-11-01

Baseline: `78ee561d977bf4c1c25976126c07f8480370ec65`. Shared native behavior and
production roaming attachment are implemented, without new targets/dependency
edges or public embedding breaks. Independent implementations decreased; total
source lines increased because accessibility parity and regression checks add
behavior. Conditional runtime and optional cleanup scope remains deferred above.

Final verification passed 2,931 Debug and 2,930 Release tests across ten native
bundles. Release tests used `--build-tests -Xswiftc -enable-testing`, then
`Scripts/test-native.sh -c release --skip-build`. Logs are
`/private/tmp/swiftty-layered-audit-final-{debug,release-tests}.log`.
Strict formatting passed for 33 changed Swift files and `git diff --check` passed.
Physical-device and shipping iOS results are in [spec.apple.md A08](spec.apple.md#a08--memory-and-performance-txt-04-perf-01-appendix-a);
roaming ownership coverage is in [spec.roaming.md](spec.roaming.md#production-attachment-ownership).
These are refactor validation results, not a claim that every product acceptance
gate or the upstream Ghostty comparison has newly been rerun.

`BridgeTests.exportImportParity` covers content, widths, attributes, cursor, wraps
and graphemes. `MuxNativeTests` covers real Metal submission, IME, frozen selection,
slow GPU, missing drawable and shell-preserving detach. Native view/capability/
visibility tests and service/integration suites cover admission, lease fencing,
reconnect, uncertain input, lifecycle queues, reply backpressure and natural exit.
Final focused interaction/admission and client-lifetime runs passed 92 and 10 tests,
respectively. The earlier broad filtered `swiftty-presented-selection-green.log`
did not complete integration tests and is not counted as a full pass.

| Regression | Evidence logs under `/private/tmp/` |
|---|---|
| Direct pointer targets unseen output | `swiftty-display-state-red.log`, `swiftty-display-state-green.log` |
| Mux pending command-output freezes too early | `swiftty-pending-selection-red2.log`, `swiftty-baseline-fence-regressions.log` |
| Queued semantic input follows replacement | `swiftty-queued-attachment-red.log`, `swiftty-view-admission-binding-green.log` |
| Drag selects overwritten, undisplayed cells | `swiftty-unpresented-drag-regression-red.log`, `swiftty-final-interaction-focused.log` |
| Closed client retained through display callback | `swiftty-roaming-retention-red.log`, `swiftty-roaming-retention-green.log` |


#### Production parser and direct rendering

Hardware: Mac17,7, 18 cores, 128 GiB; macOS 27.2 (26B123), Swift 6.4.2.
Baseline sources are archived at `/private/tmp/swiftty-layered-baseline`.
Both versions use plain `swift build -c release`. A compiler import check confirmed
that **both** final modules reject `@testable import`; unlike the early exploratory
runs, these measurements use matching production testability settings.
The final driver log is `/private/tmp/swiftty-final-performance.log`.

| Metric (same workload) | Baseline | Current |
|---|---:|---:|
| ASCII parser, MB/s | 1135.5 | 1139.3 |
| UTF-8 parser, MB/s | 306.2 | 305.3 |
| Wide UTF-8 parser, MB/s | 1178.4 | 1178.8 |
| Compiler-log parser, MB/s | 797.1 | 794.4 |
| CSI-heavy parser, MB/s | 233.7 | 226.9 |
| Scroll parser, MB/s | 336.3 | 327.6 |
| Text-phase peak RSS, MiB | 138.8 | 138.7 |
| Direct PTY-to-snapshot p95, ms | 0.059 | 0.060 |
| Redraw parse+snapshot p95, ms | 0.051 | 0.051 |
| Redraw GPU p95, ms | 1.470 | 1.478 |
| Scroll-frame p95, ms | 0.333 | 0.334 |
| Resize p95, ms | 3.23 | 3.23 |

Workload: `swiftty-bench --mb 100 --repeat 3`, run serially with no concurrent
desktop build/test workload. Logs:
`/private/tmp/swiftty-final-{baseline,current}-core-bench.log`.
Allocation counts match for every corpus: zero for common loops, nine for source
and 28,800 for OSC-heavy input. Final matching-build measurements supersede the
earlier testability-mismatched exploratory runs.

#### Native presentation

Three valid native presentation pairs measured p95 latency in milliseconds:

| Pair | Baseline | Current |
|---|---:|---:|
| 1 | 23.931 | 23.951 |
| 2 (current first) | 24.053 | 24.186 |
| 3 | 24.437 | 23.914 |

Median paired change was +0.019 ms. Every accepted run had zero idle draws and
zero hidden drawable acquisitions. Accepted logs are `swiftty-final-baseline-native-1.log`,
`swiftty-final-current-native-1-retry.log`, `swiftty-final-{baseline,current}-native-2.log`
and `swiftty-final-{baseline,current}-native-3-isolated.log` under `/private/tmp`.
The third pair was repeated in isolation to exclude overlap with another benchmark.
Both versions had an initial occluded-window attempt; those attempts are excluded.
Native probes associate the expected PTY echo with the draw's entry state and use
actual drawable presentation timestamps. Each run has 20 warmups and 100 samples,
then checks two seconds each of idle and hidden activity. Occluded attempts contribute no latency samples.

These measure synthetic key-to-drawable presentation, not physical keyboard or
photon latency. Mux/resource and isolated-frame measurements are recorded in
[spec.multiplexer.md §11](spec.multiplexer.md#shared-surface-measurements--2026-11-01).
Temporary probe sources/builders are `/private/tmp/swiftty-frame-probe.swift`,
`build-swiftty-frame-probes.py`, `swiftty-native-presentation-probe.swift` and
`build-swiftty-native-probes.py`; executables/resources are under
`/private/tmp/swiftty-frame-probes/{baseline,current}`. These local artifacts are
provenance, not repository-managed test fixtures.
