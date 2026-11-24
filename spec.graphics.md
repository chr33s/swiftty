# Spec: Kitty graphics protocol

**Repository:** [chr33s/swiftty](https://github.com/chr33s/swiftty)  
**Status:** Implemented 2026-11-24 for the engine, direct rendering, SwiftMux, RST/1, the terminal clients, accessibility, Off mode and Phase 5 frame sets; §26 records what differs from this proposal and what remains open. [README.md](README.md) records verification status  
**Date:** 2026-11-24  
**Baseline:** `29b8c8fc` (`main`)  
**Reference:** Ghostty [`167acf0c`](https://github.com/ghostty-org/ghostty/tree/167acf0c4e3c29c1037c4fa935dfe5c053e04849) (2026-11-23), `src/terminal/kitty/graphics_*.zig`, `src/terminal/render.zig`, `src/renderer/image.zig`, `src/terminal/snapshot/kitty.zig`  
**Protocol:** [kitty terminal graphics protocol][K01]  
**Platforms:** macOS 27+, iOS/iPadOS 27+; Mac Catalyst and visionOS must build; tvOS follows iOS; the watch companion shows no images  
**Supersedes:** the Kitty graphics exclusion and "ignore APC" rule in [spec.md](spec.md#goal-and-scope), [spec.keyboard.md §1](spec.keyboard.md), [spec.apple.md](spec.apple.md), the graphics deferrals in [spec.multiplexer.md](spec.multiplexer.md) and the graphics exclusions in [spec.roaming.md](spec.roaming.md) (§20 lists each edit)

## 1. Decision and intended outcome

Implement the kitty graphics protocol in `SwifttyEngine`, with Ghostty's behaviour as the oracle, and carry its result to every Swiftty presentation path: direct sessions, ordinary SSH, SwiftMux panes, RST/1 roaming and the `swmux`/`swroam` terminal clients.

Sixel is not implemented, now or as a fallback. Every supported device runs a 2027 Apple OS with a Metal renderer, so a second raster protocol buys nothing. DCS `q` (Sixel) stays ignored. The only downgrade path is Unicode half-blocks, used by the terminal clients when the outer terminal cannot show kitty images (§16.5).

The user-visible result:

- `kitten icat`, `yazi`, `timg`, `chafa -f kitty`, `viu`, `ranger`, `neovim` image plugins and `matplotlib` kitty backends draw images in Swiftty on Mac, iPhone and iPad.
- Images live in the authoritative host engine, so a roaming session keeps its images through network changes, sleep and reattachment. A Mosh session strips them (§17).
- Unicode placeholders (`U=1`) work inside tmux, through `allow-passthrough`, and across Swiftty's own panes. The same mechanism lets `swmux` and `swroam` draw images inside another terminal.
- A terminal without images pays nothing: no allocation, no extra snapshot work, no parser throughput loss.

### Assumptions

- "Parity" means the Ghostty *app* profile for the protocol surface: all transmission media on a local Mac, PNG decoding, animation, relative placements and placeholders. The libghostty embedding defaults (direct medium only, no PNG, 10 MB) are stricter than the app; Swiftty follows the app where the program runs on the same Mac as the engine and the libghostty defaults everywhere else (§7.1).
- Images are presentation state. They are never written to disk by Swiftty, never synced, and never included in saved output, transcripts or crash reports.
- Image pixels from a remote host are untrusted input, decoded with bounded resources, like any other screen content.

## 2. Scope

| Included | Excluded |
|---|---|
| APC `G` framing, chunking, all keys from Ghostty `167acf0c` | Sixel, iTerm2 inline images (OSC 1337), DECterm ReGIS |
| Actions `t T q p d f a c`; every delete target | A Sixel or iTerm2 encoder in the terminal clients |
| Media `d f t s` on a local Mac; `d` elsewhere | File, temp-file or shared-memory media for remote programs |
| Formats RGB (24), RGBA (32), PNG (100); zlib (`o=z`) | JPEG, HEIC, GIF or other formats through `f=` |
| Placements, cell offsets, source rects, scaling, cursor movement, z layers | Image editing, saving or sharing from the terminal |
| Relative placements (`P Q H V`), virtual placements and Unicode placeholders | tmux control-mode (`-CC`) graphics |
| Animation: frames, composition, playback, frame deletes | Persisting images across worker restart, crash or reboot |
| Per-screen bounded storage and priority eviction | Kitty's on-disk frame cache |
| SwiftMux and RST/1 transport, client caches, Low Data Mode | Image transfer to the watch companion |
| Half-block fallback in `swroam`/`swmux` for outer terminals without kitty graphics | Half-block rendering in the native Metal frontends |

## 3. What the repository does today

| Area | Current behaviour | Consequence |
|---|---|---|
| Parser | `ESC _` enters `.stringIgnore` together with SOS and PM ([Parser.swift:729](Sources/SwifttyEngine/Terminal/Parser.swift)). No buffer, no dispatch. APC bytes go through `step` one at a time. | A new APC state, buffer and bulk path are needed. |
| String bounds | OSC grows to `maxOSCBytes = 8 MiB` and an over-limit string is dropped whole (Parser.swift:66-78, 968-1058). | The APC body needs its own larger bound and a streaming payload path. |
| Kitty precedents | OSC 5522 clipboard (`KittyClipboard.swift`, `TerminalState+KittyClipboard.swift`) and OSC 72 drag-and-drop (`KittyDragAndDrop.swift`). Both are documented as Ghostty ports with deviations, and both share `Base64.Stream`. | Graphics follows the same file layout, header and test conventions. |
| Replies | `TerminalState.reply(_:)` into `output`, capped by `maxQueryReplyBytes = 64 KiB`. Parsing pauses after replies (`consumePrefix(..., replyLimit: 1)`). Mux panes drop replies larger than the reply reserve (PaneRuntime.swift:433-451). | A graphics response is at most 1 KiB and fits every reserve. |
| Cells | 16-byte `Cell`. Foreground and background are tagged `TerminalColor`. `underlineColor` is a 6-bit id into a table of at most 63 colours (`internUnderlineColor` returns 0 when it is full). Graphemes live in `GraphemeTable`. | Placeholder cells fit without layout changes. Placement ids carried in underline colour are limited (§10.3). |
| Rows | Physical row ids rotate through `rowMap`. IL/DL and margin scrolls rotate rows too. History is a ring of row ids; `screenAbsoluteRow` gives stable absolute rows on the primary screen. | Anchors follow absolute rows with explicit hooks, not physical row ids, because Ghostty does not move images on IL/DL (§9.1). |
| Pixel geometry | `cellPixelSize` and `textAreaPixelSize` back XTWINOPS 14/16/18 t. Direct frontends call `setCellPixelSize`, which also sets the PTY winsize. Mux panes never set it, and the guardian sets `ws_xpixel = ws_ypixel = 0`. | Mux and roaming geometry must carry cell pixel size first (§14.2). |
| Rendering | One Metal pass: clear, then opaque backgrounds for every cell, then glyphs, then decorations and the cursor, then optional post-processing ([MetalRenderer.swift:394-523](Sources/SwifttyCore/Renderer/MetalRenderer.swift)). | Three image layers are inserted. Default-background cells must stop painting over below-background images (§13.3). |
| Frames | `PaneFrame`/SMXB/1 tags 1-18 and 20-22; tag 19 is free. Unknown tags are rejected. `ServiceFeatures` bits are used up to 1<<14. `RSTFeatures` are used up to 1<<6. | New frame section and features (§14, §16). |
| Identity | Panes set `keyboardProtocolEnabled = false` and `clipboardWritesAdvertised = false` (PaneRuntime.swift:236-242). DECRQM 5522 reports 0 without a reader. | Graphics gets the same per-state enable switch. |
| Checkpoints | Sections 1-14. `checkpoint()` refuses unsettled clipboard and DnD state. The parser checkpoint stores only an OSC body. | Section 15 and parser APC state (§18). |
| Benchmarks | `Scripts/compare-ghostty.py` omits kitty's Images payload because "Swiftty ignores APC strings" (README.md:672-675). | That payload becomes a gate (§21.3). |

## 4. Architecture and ownership

```text
program ──APC G──▶ Parser (.apcKitty) ──▶ KittyGraphics (per TerminalState)
                                            ├─ KittyImageStorage ×2 (primary, alternate)
                                            │    images: KittyImage (immutable pixels, generation)
                                            │    placements: anchored | virtual | relative
                                            │    loading: one chunked load
                                            └─ responses ──▶ TerminalState.reply
TerminalState ──▶ KittyRenderState (resolved, viewport-relative placements)
                    ├─ direct:  RenderSnapshot.images ──▶ MetalRenderer image layers
                    ├─ SwiftMux: PaneFrame §19 placements + MuxImageBlob ──▶ client ImageCache ──▶ MuxPaneView
                    └─ RST/1:   frame §19 + KGIB/1 image streams ──▶ client ImageCache ──▶ renderer
                                                                   └─ swroam/swmux: TTYGraphics ──▶ outer terminal
```

| Owner | Responsibilities |
|---|---|
| `SwifttyEngine` | APC parsing, command grammar, media, decoding, storage, eviction, anchoring, placeholders, animation state, responses, checkpoints. No Metal, no UI. ImageIO, Compression and CryptoKit are allowed. |
| `SwifttyCore` | Snapshot image layer, Metal textures and passes, animation clock, memory-pressure response. |
| `SwiftMuxProtocol` / `SwiftMuxExport` / `SwiftMuxService` | Frame section, blob messages, pane budgets, cell pixel geometry, migration. |
| `ScreenProtocol` / `TerminalHost` / `RoamingKit` | RST/1 feature, image streams, content digests, client cache, path policy. |
| `TTYKit` | `TTYGraphics`: outer-terminal detection, placeholder re-emission, tmux passthrough wrapping, half-block raster. CPU only. `Scripts/check-layering.sh` still forbids renderer and Metal imports. |
| Frontends | Accessibility, Reduce Motion, settings UI, memory warnings, cellular policy. |

The engine owns the protocol; transports carry *resolved presentation* (placements in viewport coordinates and the pixels they reference), never APC bytes. No client re-parses graphics commands from a host, matching the rule that a client never interprets a snapshot as ANSI output ([spec.roaming.md §6](spec.roaming.md#6-the-authoritative-terminal)). The single exception is `TTYGraphics`, which *emits* kitty commands to an outer terminal the user chose.

## 5. Framing and command parsing

### 5.1 APC state machine

- `ESC _` enters `.apcIdentify`. If the first body byte is `G`, enter `.apcKitty`; otherwise `.stringIgnore`, as today. SOS (`ESC X`) and PM (`ESC ^`) stay in `.stringIgnore`. Ghostty routes SOS and PM through its APC handler, so `ESC X G…` is a graphics command there. Swiftty treats that as a quirk, not behaviour to copy (deviation D1, §19).
- `ESC` ends the string. The following `\` is consumed as ST, exactly as for OSC. BEL does not end an APC. CAN and SUB abort it and discard the command. Other C0 bytes, including CR and LF, are payload, as in Ghostty. Swiftty has no 8-bit C1 controls, so Ghostty's 0x9C ST and C1 abort rules do not apply.
- The body is scanned in bulk with the same SIMD non-control scanner as OSC (`scanNonControl`), not byte-by-byte.
- `maxAPCBytes = 64 MiB` (Ghostty's 65 MiB default rounded to a power of two). A longer command is dropped with no response. Its bytes are consumed until the terminator without buffering.
- The parser splits the body at the first `;`:
  - The control part goes into an inline buffer of at most 1 KiB. A longer control part is malformed and dropped.
  - The payload streams straight into the base64 decoder of the target load (§5.3). It is never buffered twice.
- `Parser.Continuation`, checkpoint and restore, and RIS gain the APC state and its control buffer (§18).

### 5.2 Grammar

`key=value(,key=value)*[;payload]`, parsed with exactly Ghostty's rules (`graphics_command.zig:135-323`):

- **Keys.** A key is one ASCII letter, and a repeated key overwrites the earlier value. Longer keys and non-letter keys are ignored together with their values. A control part that ends after a key, with no `=`, is malformed.
- **Values.**
  - A single non-digit character is stored as its ASCII code. That is how `a=T` works, and it is why `i=a` means image id 97.
  - Every other value is a decimal integer: `Int32` for `z`, `H` and `V`, `UInt32` for all other keys.
  - A value longer than 11 bytes means the key is absent; it is not an error.
  - Overflow, an empty value, or a negative value for a `UInt32` key is malformed.
  - Swiftty rejects `+` and `_`, which Zig's `parseInt` may accept (deviation D2).
- **Defaults.** `a=t`, `t=d`, `f=32`, `q=0`. `d` defaults to `a`.
- **Malformed commands.** Any malformed command is dropped with no response and no state change. That includes an unknown action, medium, compression, delete letter, or bad base64. Ghostty answers nothing in these cases, and programs depend on the DA1 fence for detection rather than on an error.

| Key | Meaning | Key | Meaning |
|---|---|---|---|
| `a` | action `t T q p d f a c` | `x y w h` | source rect (px) / frame origin / compose size |
| `t` | medium `d f t s` | `X Y` | cell pixel offset / compose source origin / frame blend mode and background |
| `f` | format 24, 32 (or 0), 100; other values → `EINVAL: unsupported format` | `c r` | columns and rows / base and edit frame |
| `o` | `z` only | `C` | 1 = do not move the cursor (other values move it) |
| `s v` | width, height (px); `s` is also the playback state for `a=a` | `U` | nonzero = virtual placement |
| `S O` | read size, offset | `z` | z-index / frame gap (ms) |
| `i I p` | image id, image number, placement id | `P Q H V` | parent image, parent placement, cell offsets |
| `m` | more chunks follow; honoured only for `t=d` | `N` | usage hints; bit 0 = transient |
| `q` | 1 suppresses OK replies; ≥2 suppresses all replies | `d` | delete target `aAiInNcCfFpPqQrRxXyYzZ` |

### 5.3 Base64

- Each APC payload must be valid base64 *by itself*, using the standard alphabet with padding optional.
- ASCII whitespace inside a payload is skipped, matching Ghostty's SIMD build (simdutf). Ghostty's scalar fallback rejects whitespace; Swiftty follows the SIMD build, which is the one users run.
- Decoding is incremental into the load buffer:
  - Before decoding a chunk, record the buffer length.
  - A decode error truncates the buffer back to that length and drops the chunk's command with no response. The rest of the load is untouched.
  - This is observably the same as Ghostty's decode-on-completion. It is tested by feeding every split point (`ParserChunkPropertyTests` style).
- Reuse `Base64.Stream` from `KittyClipboard.swift`, extended with the whitespace rule. OSC 52's stricter rules are unchanged.

## 6. Actions and responses

### 6.1 Actions

The gates below apply in this order:

1. When graphics is disabled (storage limit 0 or the state switch off, §12), nothing is answered, not even `a=q`. This is what makes a pane or profile look like a terminal without graphics.
2. `i` and `I` together on any action reply `EINVAL: image ID and number are mutually exclusive` before any state changes.

| Action | Behaviour |
|---|---|
| `q` | Requires `i`. Runs the full load (medium, decompression, PNG decode, length check) and then discards the result, so the program learns whether the medium and format work. Storage is not touched. |
| `t` / `T` | Validates the medium and format, then accumulates the chunks. On the final chunk it completes the image and adds it. `T` then displays the image using the display keys saved from the *first* chunk. A non-final chunk produces no reply. |
| `p` | Requires `i` or `I`. `I` resolves to the newest image transmitted with that number. Errors: `ENOENT: image not found`; `EINVAL: virtual placement cannot refer to a parent` (checked first); the relative-placement errors in §9.4. |
| `d` | Abandons any chunked load in progress, applies the delete (§8.3), never replies. |
| `f` `a` `c` | Animation (§11). |

### 6.2 Ids

| Request | Id assigned |
|---|---|
| `I` without `i` | The smallest free id from 1 (Kitty's `get_free_client_id`) |
| Neither `i` nor `I` | An implicit id counting upward from 2147483647, wrapping at `UInt32.max` and skipping 0 and ids in use. The image never gets responses. |
| `i` that already exists | Replaces the image. Its placements and their dependent relative placements are removed, and its animation is dropped. The old image stays displayed until the replacement completes. If the replacement fails or is abandoned, the old image is still deleted (Ghostty `exec:1050-1185`). |

### 6.3 Responses

- **Format.**
  - The reply is `ESC _ G i=<id>[,I=<num>][,p=<pid>][,r=<frame>];<message> ESC \`. Each key is written only when it is nonzero, in that order.
  - Nothing is written when both `i` and `I` are 0.
  - On success the reply reports the resolved id. A chunked load replies with the identifiers and `q` of its first chunk, unless a later chunk raises `q`.
  - Replies go through `TerminalState.reply`. The parser yields after each reply, as for other queries.
- **Quiet levels.**
  - `q=0` suppresses only replies that would carry no id.
  - `q=1` suppresses OK replies.
  - `q≥2` suppresses everything.
- **No reply, ever:**
  - deletes
  - a successful `a=a`
  - non-final chunks
  - implicit-id images
  - a disabled protocol
  - malformed commands
- **Messages.** Use Ghostty's exact strings so oracle tests compare bytes:
  - `OK`
  - `ENOMEM: out of memory`
  - `ENODATA: insufficient data`
  - `ENOENT: image not found`
  - `EINVAL:` followed by one of: `invalid data`, `decompression failed`, `unsupported format`, `unsupported medium`, `dimensions required`, `dimensions too large`, `temporary file not in temp dir`, `temporary file not named correctly`, `image ID required`, `image ID or number required`, `image ID and number are mutually exclusive`, `virtual placement cannot refer to a parent`, `failed to prepare terminal state`
  - `ENOPARENT: parent image not found`, `ENOPARENT: parent placement not found`
  - `EINVAL: placement cannot be its own parent`
  - `ECYCLE: parent chain creates a cycle`
  - `ETOODEEP: parent chain too deep`
  - `ENOENT: parent chain ancestor not found`
  - the animation messages in §11
- **I/O failures.** Every file and shared-memory failure maps to `EINVAL: invalid data`. No errno detail reaches the program.

## 7. Transmission

### 7.1 Media by presentation path

| Path | Where the engine runs | `d` | `f` | `t` | `s` |
|---|---|---|---|---|---|
| Local macOS shell (direct session or SwiftMux pane) | Same Mac as the program | ✓ | ✓ | ✓ | ✓ |
| RST/1 roaming pane | Host Mac, same as the program | ✓ | ✓ | ✓ | ✓ |
| Ordinary SSH (client-side parser on iOS, iPadOS, Catalyst, macOS) | Client device; program is remote | ✓ | — | — | — |
| Embedder byte stream (`receive(_:)`) | Unknown | ✓ | Opt-in | Opt-in | Opt-in |
| tmux on a remote host, through any path | Wherever the outer engine runs | ✓ | Per the row above | Per the row above | Per the row above |

A refused medium replies `EINVAL: unsupported medium`, before any I/O. A PNG over a refused medium gives the same reply. For a remote program, a path names a file on the *client* device, so honouring it would let remote output read the user's local files. `SessionConfiguration.kittyGraphicsMedia` defaults to `.direct` and is set to `.all` only by the local PTY and pane launch paths. This narrows the blanket "filesystem actions carried by escape sequences" ban in [spec.roaming.md §12](spec.roaming.md#12-resource-and-security-limits) to remote programs (§20).

### 7.2 File and temporary file (`t=f`, `t=t`)

Follow Ghostty's order (`graphics_image.zig:342-529`):

1. **Path payload.** The base64-decoded payload is the path. An internal NUL means invalid data.
2. **Open, then canonicalise.** Open with `O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK`, then take the canonical path of the *opened* descriptor with `fcntl(F_GETPATH)`. This avoids a time-of-check race. Refuse any canonical path under `/dev`; on Darwin `/dev/shm` does not exist and no exemption applies. Ghostty's `/proc` and `/sys` checks have no Darwin equivalent.
3. **Temp-file location** (`t=t` only). The canonical path must lie inside one of `/tmp`, `/private/tmp`, `/var/tmp`, `/private/var/tmp`, or `confstr(_CS_DARWIN_USER_TEMP_DIR)` and its realpath (the per-user `/private/var/folders/…/T/`). Matching respects separator boundaries. Otherwise reply `EINVAL: temporary file not in temp dir`.
4. **Temp-file name** (`t=t` only). The canonical path must contain `tty-graphics-protocol`, otherwise `EINVAL: temporary file not named correctly`.
5. **Temp-file deletion** (`t=t` only). Once steps 3 and 4 pass, the file is unlinked when the command finishes, whatever happens later.
6. **Regular file.** Require a regular file (`fstat`).
7. **Read.** `O` seeks. `S > 0` reads exactly `S` bytes, and a short read is an error. Without `S` the rest of the file is read, up to 400 MB.
8. **Off the parse queue.** Read at most 64 KiB per `read` call, so a slow file cannot stall the session queue indefinitely. A read that takes longer than 250 ms is abandoned and replies `EINVAL: invalid data` (deviation D3: Ghostty has no timeout).

### 7.3 Shared memory (`t=s`)

- **Name.** The payload is passed to `shm_open(O_RDONLY)` unmodified. It must be 1 to `PSHMNAMLEN` (31 on Darwin) bytes, must not be `/`, and must not contain NUL.
- **Mapping.** Require size > 0 from `fstat`, then map it read-only.
- **Unlink.** Always `shm_unlink` once the object is open.
- **Range.**
  - The start is `O` and must be ≤ the object size.
  - The length is `S` if given. Otherwise it is `w·h·bpp` for uncompressed raw formats, or the remainder of the object. For `w·h·bpp`, dimensions above 10000 are rejected *before* multiplying.
  - The length must be ≤ 400 MB and must fit in the object.
- **App-group names.** Names without a leading slash are allowed, which macOS app-group shared memory needs.

### 7.4 Decode pipeline

Run these steps in order and use checked arithmetic throughout:

1. **Decompress (`o=z`).** Inflate as RFC 1950 zlib, capped at 400 MB of output and at the remaining storage budget, whichever is smaller. Failure replies `EINVAL: decompression failed`.
   - Move the RFC 1950 codec from `ScreenProtocol/Zlib.swift` into `SwifttyEngine`, or a small shared target below both, so one bounded implementation serves frames and graphics.
   - Apple's `COMPRESSION_ZLIB` is raw DEFLATE. The wrapper validates the header and the Adler-32 trailer.
2. **Decode PNG (`f=100`).** Use ImageIO with these restrictions:
   - Create the source with `kCGImageSourceTypeIdentifierHint = public.png` and `kCGImageSourceShouldCache = false`. Require that `CGImageSourceGetType` is `public.png`. Any other container replies `EINVAL: invalid data`, even when ImageIO could decode it.
   - Read the pixel dimensions from the properties *before* decoding. Reject 0 or anything above 10000 per side.
   - Decode into a caller-allocated RGBA8 premultiplied-last sRGB bitmap context. Its size is bounded before allocation by the dimension check and the storage budget.
   - Use only the first image of the PNG, as Ghostty does; APNG frames are ignored.
3. **Validate dimensions.** A width or height of 0 replies `EINVAL: dimensions required`; above 10000 replies `EINVAL: dimensions too large`.
4. **Validate length.** The data length must equal `w·h·bpp` exactly, otherwise `EINVAL: invalid data`. Animation frames are the exception: longer data is truncated, and shorter replies `ENODATA: insufficient data`.

- **Accumulated data cap.** Undecoded chunk data in flight is capped at `min(400 MB, storageLimit)`. Exceeding it abandons the load with `ENOMEM: out of memory` (deviation D4: Ghostty caps only at 400 MB, but on iOS that is more than the whole budget).
- **Pixel storage.** RGB is stored as RGB and expanded to RGBA only at texture upload, as in Ghostty. The internal gray and gray-alpha formats are not reachable through the protocol.
- **Synchronous decoding.** Decoding is synchronous on the session queue, as in Ghostty, because later commands in the same stream depend on the result. §21.3 gates its cost. Move it off the queue only if measurements require it, using Ghostty's pending-image tickets (`graphics_storage.zig:205-287`).

## 8. Storage

### 8.1 Model

```swift
/// Immutable after completion; shared by snapshots, frames and caches without copying.
final class KittyImagePixels: Sendable { width, height, format, bytes /* page-aligned */ }

struct KittyImage {          // one per (screen, image id)
  id: UInt32, number: UInt32?, implicitID: Bool, transient: Bool
  pixels: KittyImagePixels   // or .pending while restored pixels stream in
  generation: UInt64         // displayed pixels changed — texture and blob cache key
  transmission: UInt64       // identity of this transmission
  serial: UInt64             // unique per worker lifetime; survives migration (§18)
  animation: KittyAnimation? // §11
}
```

- **Two storages.** `KittyImageStorage` is noncopyable, one per screen (primary and alternate). It is created lazily on the first graphics command, so a terminal without images allocates nothing.
- **Inheritance.** The alternate screen inherits the limit and media from the primary screen.
- **Pixel buffers.** Use `mmap`-backed page-aligned buffers with `madvise(MADV_FREE_REUSABLE)` on release, the same Darwin adapter as [spec.scrollback.md](spec.scrollback.md). The buffer can then back a no-copy Metal buffer on Apple Silicon (§13.2), and freed memory returns to the system immediately.
- **Counters.** `generation` is a process-global monotonic stamp bumped on content changes. `dirty` is a wrapping counter bumped whenever placements may have moved: scroll, resize, history erase or viewport movement. On a screen switch the new screen's `dirty` jumps past both screens' values, as in Ghostty's `Terminal.zig:5786-5797`.

### 8.2 Limits and eviction

| Profile | Per screen | Notes |
|---|---|---|
| macOS direct session | 320 MB (Ghostty app default) | `image_storage_limit` configures it |
| iOS / iPadOS ordinary SSH | 128 MB | Decided 2026-11-24; device jetsam measurements ([spec.apple.md A08](spec.apple.md)) confirm it, not choose it |
| SwiftMux pane | `min(config, MuxLimits.imageBytesPerScreen = 256 MB)` | Plus `MuxLimits.totalImageBytes = 1 GiB` across a worker (§14.4) |
| Embedder default | 10 MB (libghostty default) | `SessionConfiguration.imageStorageLimitBytes` |

- **Oversized images.** An image larger than the limit replies `ENOMEM: out of memory`.
- **Eviction order.** Otherwise evict in Ghostty's order (`evictImageExcept`, `graphics_storage.zig:1823-1906`), never evicting the image being replaced:
  1. transient and unplaced
  2. unplaced
  3. transient and placed
  4. placed

  Within a class, evict the oldest transmission first, then the lowest id.
- **What eviction removes.** Evicting an image removes its placements and their orphaned relative placements.
- **Insufficient space.** When eviction cannot free enough, reply `ENOMEM`.
- **Zero limit.** Setting the limit to 0 wipes storage and disables the protocol.

### 8.3 Deletes

- **Lowercase and uppercase.** Lowercase deletes placements. Uppercase also frees images that the delete left without placements. After every delete, cascade orphaned relative placements, and free them too on uppercase.
- **Virtual and relative placements.** Geometric targets never match virtual or relative placements directly.
- **Ghostty reference.** `graphics_storage.zig:1395-1679`.

| Target | Selects |
|---|---|
| `a A` | Anchored placements visible in the active area, including ones anchored in history that extend into it. `A` frees only images selected this way. |
| `i I` | With `p=0`: all placements of the image, virtual ones included. With `p>0`: that placement only. `I` frees the image only if the selector matched. |
| `n N` | The newest image with that number, then as `i I`. |
| `c C` | Placements intersecting the cursor cell. |
| `p P` / `q Q` | The cell at 1-based `x,y` / the same, also matching `z`. Zero coordinates are a no-op. |
| `x X` / `y Y` | The 1-based column, including history / the 1-based active row. |
| `z Z` | Anchored and relative placements with that `z`. |
| `r R` | Image ids `x…y`. `y=0` or `x>y` selects nothing. `R` also frees unplaced images in the range. |
| `f F` | Animation frames (§11). |

### 8.4 Terminal operations

| Operation | Effect on graphics |
|---|---|
| ED 2, ED 22 | Delete visible anchored placements and their orphans, then free *every* unplaced image (Ghostty `clearScreen`). |
| ED 3, `clearHistory`, scrollback limit change | Remove placements anchored in the erased history rows. |
| History eviction (ring full) | A placement whose anchor row leaves retained history is removed. An image left unplaced stays until it is evicted or deleted. |
| RIS (`fullReset`) | Rebuild storage, keep limits and media, carry `dirty` forward, drop the alternate storage, abandon any chunked load. |
| 1049 enter, 1047 leave | The ED-complete they perform clears alternate-screen placements. |
| 47 | Alternate-screen images are kept. |
| DECSTR | No effect on graphics, as in Ghostty. |
| Clear screen and scrollback (Cmd-K and the iOS action) | `delete(all: true)` on the active screen, as Ghostty's `Termio.zig:636` does. |
| Resize and reflow | Anchors move with reflow (§9.1). Only `dirty` changes. |
| `compactGraphemes` | Placeholder cells are graphemes; compaction preserves them like any cluster. |
| Scrollback compression | Unaffected. Anchors live in a side table, not in cells ([spec.scrollback.md §8.3](spec.scrollback.md)). |

## 9. Placements

### 9.1 Anchoring without pins

Ghostty tracks placements with page pins. Swiftty has no pins, so an anchored placement stores:

```text
KittyAnchor { screen, absoluteRow: Int64, column: Int32, addressingGeneration }
```

- **Coordinates.** `absoluteRow` uses `screenAbsoluteRow`, which is stable while a line moves from the primary screen into history. That makes full-screen output scrolling free. The alternate screen has no history, so its absolute row is the screen row.
- **Side table.** Anchors live in a side table keyed by absolute row, as spec.md requires for extra metadata. They are never stored in cells or physical rows, because rows rotate on IL/DL and Ghostty does not move images on IL/DL.
- **Explicit hooks.** These operations update anchors, and nothing else does:

| Hook | Rule (Ghostty `scrollMarginsBegin`, `graphics_storage.zig:596-726`) |
|---|---|
| SU, SD, IND, RI, LF at the bottom margin *with a scroll region or left/right margins set* | A placement entirely inside the region moves with the content. At the margins it is clipped by shrinking its source rect proportionally. A fully clipped placement is deleted. Placements that straddle the region, or lie outside it, stay put. |
| Full-screen scroll on the alternate screen | Rows shift up and the top rows are discarded. A placement whose anchor row is discarded is deleted, because the pin was pruned. |
| IL, DL, ICH, DCH, ECH, EL, ED 0/1 | Anchors do not move. Erasing cells does not delete placements. |
| `reflowPrimary` | Anchors ride through reflow as pseudo-cursors, the mechanism already used for search marks and the input mark (TerminalReflow.swift:258-275). The column is clamped to the new width. |
| `addressingGeneration` change without reflow (alternate resize, clear) | Remap or drop, per the operation in §8.4. |

Anchors whose row is no longer retained are garbage. They are reaped on the next placement add or parent resolution, as Ghostty does (`graphics_storage.zig:735-759`), and the render state skips them in the meantime.

### 9.2 Geometry

Port Ghostty's `Placement` maths exactly (`graphics_storage.zig:1966-2318`), using saturating `UInt64` intermediates.

- **Source rect.** `x,y,w,h` intersected with the image. `w=0` or `h=0` means the full remainder.
- **Cell offset.** At display time `X`/`Y` are clamped to `cellSize − 1` when the cell size is known.
- **Pixel size.**

| `c` | `r` | Pixel size |
|---|---|---|
| unset | unset | The source rect at native size |
| set | set | `c·cw − X` by `r·ch − Y` |
| set | unset | Width `c·cw − X`; height from the aspect ratio, rounded to nearest |
| unset | set | The mirror of the row above |

- **Grid size.** `ceil((px + offset) / cell)`; 0 when the cell size is 0.
- **Cell size.** Cell size means the engine's `cellPixelSize`, in backing pixels. Each path has a source for it (§14.2, §16.2).

### 9.3 Cursor movement

- **Which placements move it.** Only anchored placements with `C≠1`. Relative and virtual placements never move the cursor.
- **Index count.** Call `index()` `(rows − 1) + wraps` times, where `wraps = anchor.column + cols ≥ terminal columns`.
- **Cap.** The number of calls is capped at the rows left to the bottom of the scroll region plus the screen rows, which defends against a hostile `r`.
- **Final position.** Clear pending wrap, then set the column to `anchor.column + cols`, or to 0 if the placement wrapped (Ghostty `exec:396-447`).

### 9.4 Placement ids, relative placements, z layers

- **Placement ids.**
  - `p=0` gets an internal auto-incrementing id, so one image can have many unnamed placements.
  - `p>0` is keyed by (image, p) and replaces any existing placement with that key.
  - Each image may have at most 2³⁰ placements; overflowing that replies `ENOMEM`.
- **Relative placements.** `P`/`Q`/`H`/`V` follow Ghostty's `resolveParent` (`graphics_storage.zig:887-1051`):
  - The parent chain is at most 8 deep. Cycles are rejected.
  - Without `Q`, the preferred parent placement is the external one, then the lowest id.
  - A relative placement's position is the root's anchor cell, or the top-left of the root virtual placement's placeholder run, plus the summed `H`/`V`.
  - Removing a parent removes its children transitively.
- **Layers.**

| z | Layer |
|---|---|
| `z < −1,073,741,824` (`Int32.min / 2`) | Below cell backgrounds |
| `−1,073,741,824 ≤ z < 0` | Below text, above backgrounds |
| `z ≥ 0` | Above text |

Within a layer, sort by z and then by image id. Placeholder runs are always below text at z = −1, whatever the virtual placement's z (deviation from kitty, kept for Ghostty parity).

## 10. Virtual placements and Unicode placeholders

### 10.1 Cell encoding

U+10EEEE is the placeholder. Per cell (Ghostty `graphics_unicode.zig:343-449`):

| Source in the cell | Meaning |
|---|---|
| Foreground colour | Low 24 bits of the image id. A palette index contributes its index value; RGB contributes `r<<16 \| g<<8 \| b`. |
| Underline colour | Placement id; 0 means none. |
| 1st combining diacritic | Row |
| 2nd combining diacritic | Column |
| 3rd combining diacritic | High byte of the image id |

- **Diacritics table.** The 297-entry table comes from kitty's `rowcolumn-diacritics.txt`. Generate it with a script into a Swift table, with a dense lookup below U+2E00 and a binary search above it. Do not hand-transcribe it.
- **Unusable diacritics.** Invalid diacritics count as absent, and extra diacritics are ignored.
- **Runs.** A cell continues the run to its left when all of these hold:
  - its image-low bits and placement id are equal
  - its row is missing or equal
  - its column is missing or equal to the next column
  - its high byte is missing or equal

  The first cell of a run defaults a missing row or column to 0.
- **Target.** The run's target is the exact external virtual placement. With placement id 0 it is the image's preferred virtual placement (Ghostty `placeholderTarget`).
- **Fitting.** The virtual grid is `c`×`r`, or `ceil(image px / cell)` when unset. The image is fitted with its aspect ratio preserved and centred, and each run draws its slice. The virtual placement's `x,y,w,h` and `X,Y` are ignored, as in Ghostty.

### 10.2 Storage and rendering of placeholder cells

- **Storage.** U+10EEEE plus its diacritics is an ordinary grapheme cluster in `GraphemeTable`, width 1. No `Cell` layout change is needed.
- **Row flag.** Printing U+10EEEE sets a row metadata bit, `GridStorage.placeholderBit` in `marks`. Erasing the row clears it, and reflow copies or clears it. Only flagged rows are scanned for runs, so text-only rows cost nothing.
- **Glyph.** The renderer draws placeholder cells as a space, with background, selection and cursor as usual. The image slice is drawn in the below-text layer.
- **Snapshot refill.** `SnapshotStorage.fill` refills fully when any pending row contains a grapheme. Exempt placeholder-only grapheme rows, by copying their clusters per damaged row, so an image list redrawing every frame cannot force full refills (§21.3 gate).
- **Copy, search and VoiceOver.** These yield the stored scalars, U+10EEEE and its diacritics included. This is Ghostty parity, because its formatter has no placeholder case, and the decision is final. A copied placeholder run pasted back into a terminal that holds the image redraws it; that is the protocol's intent.

### 10.3 Placement ids and the 63-entry underline table

`internUnderlineColor` returns 0 when the per-terminal table is full. A placeholder printed with a 64th distinct underline colour would therefore silently resolve to placement id 0, the image's preferred placement.

Decision: keep the table, and when interning fails for a cell that starts with U+10EEEE, record the placement id losslessly in a side table keyed by grapheme id. The cluster is already a grapheme, so it has an id. Other cells keep today's behaviour. Test with 1,000 distinct placement ids (KG17).

## 11. Animation

Port Ghostty's model (`graphics_animation.zig`; `exec:457-979`; `storage:1188-1768`):

- **Frames.**
  - Frames are composed eagerly into full RGBA buffers the size of the image. Frame 1 is the image's own data, converted to RGBA on the first composition.
  - Frame bytes count against the storage limit. When the reservation fails, reply `ENOSPC: animation frame storage full`.
- **`a=f`** (frame transmission):
  - The image must already exist. Chunked frame loads are supported, and continuation chunks without `a=f` still go to the frame.
  - `r` in 1…count edits that frame; any other `r` appends a new frame. The default gap is 40 ms, and a negative gap means gapless.
  - `c` names the base frame, which must exist. Without a base frame the canvas starts as the background colour `Y` (RGBA). `X=1` overwrites; otherwise the frame alpha-blends.
  - The reply includes `r=<frame>`.
  - Errors: `EINVAL: image data incomplete`, `EINVAL: frame dimensions exceed image`, `EINVAL: base frame not found`, `EINVAL: frame data incomplete`, `ENOENT: image not found`.
- **`a=c`** (composition):
  - Copies or blends a rectangle between frames. Bounds are checked in `UInt64`.
  - Errors: `ENOENT: source frame not found`, `ENOENT: destination frame not found`, `EINVAL: source rectangle out of bounds`, `EINVAL: destination rectangle out of bounds`, `EINVAL: source and destination rectangles overlap`.
  - Replies OK on success.
- **`a=a`** (playback control), which never replies:
  - `s` sets the state: 1 stop, 2 run-wait, 3 run. Any state change resets the loop counter.
  - `r` with `z` sets that frame's gap. `c` sets the current frame. `v` sets loops, where `v=1` loops forever.
  - Invalid values are ignored.
- **Playback.**
  - Images start stopped, and only placed images animate.
  - Playback advances at most one frame per tick, with no catch-up. Gapless frames are skipped. Run-wait parks on the last frame.
  - The engine owns the animation state (current frame, loop count, next deadline). The *clock* is the presenter's, so hidden or backgrounded views do not wake ([spec.md §Rendering](spec.md#rendering-and-fonts)).
- **`d=f`/`F`** (frame deletes):
  - The frame number is clamped, and 0 means the root frame. Deleting the root frame promotes frame 2.
  - Lowercase on a non-animated image is a no-op. Uppercase removes the whole image.
- **Reduce Motion.** With Reduce Motion on, Swiftty frontends hold animations on their current frame. A tap on the image, or the accessibility action "Play animation", plays it once (deviation D5, an Apple-platform accessibility requirement in the spirit of [spec.apple.md A05](spec.apple.md)).

## 12. Advertisement and terminal identity

Programs detect graphics with `a=q` fenced by DA1, and many also consult `TERM_PROGRAM` or the winsize pixel fields. Swiftty advertises graphics only where it can draw.

| Signal | Rule |
|---|---|
| `a=q` | Answered only when `TerminalState.kittyGraphicsEnabled` is true and the limit is nonzero. |
| DA1, DA2, XTVERSION, XTGETTCAP | Unchanged. Kitty defines no capability bit, and Swiftty adds none. |
| `TIOCGWINSZ` `ws_xpixel`/`ws_ypixel` | The text-area pixel size wherever the engine knows the cell size: direct PTYs today, and panes after §14.2. `icat` and `timg` read these. |
| XTWINOPS 14/16 t | Already implemented. They return real values once panes carry geometry. |
| `TERM_PROGRAM` | Unchanged (`swiftty` or `swmux`). Graphics does not depend on it. |

| Path | `kittyGraphicsEnabled` |
|---|---|
| Direct session, ordinary SSH | `image_storage_limit > 0` |
| SwiftMux pane | Workspace setting on (default) *and* the worker build supports `ServiceFeatures.kittyGraphics`. Independent of which client is attached: the host is authoritative and every client can present the result (§16.5). |
| RST/1 roaming pane | Same as the pane row above. No client can make the program think images are unsupported, so reattaching from a different device needs no program restart. |

## 13. Rendering

### 13.1 Render state

`KittyRenderState` is a port of Ghostty's `render.zig` `Kitty` (1848-2621). It is computed under the session queue, and the renderer never reads anchors.

- **Rebuild triggers.**
  - `roots` (everything except position) is rebuilt when the storage `generation`, the cell pixel size or the grid size changes.
  - `placed` is rebuilt when the viewport moves, `dirty` changes, or flagged placeholder rows are rebuilt.
  - `placementsGeneration` bumps only when the output actually changes.
- **Output.** A list of `ResolvedPlacement`:

```text
{ imageRef, layer, z, sourceRect (px), destOriginCell (row may be negative), destOffsetPx, destSizePx }
```

- **Coverage.** The list covers the viewport plus the overscan rows used for smooth scrolling.
- **Exclusions.** Pending images and zero-size results are skipped.
- **Placeholder runs.** Each run becomes a one-row placement.
- **Limit.** At most 4,096 resolved placements per snapshot; beyond that, the lowest layers and z values are dropped first.

`RenderSnapshot` gains `images: ImageLayerSnapshot`: the resolved list, references to `KittyImagePixels` (one ARC retain per distinct image, never per cell) and `placementsGeneration`. A snapshot with no images carries an empty static value.

### 13.2 Textures

- **Cache.** `ImageTextureCache` lives in `SwifttyCore/Renderer/`, separate from `GlyphAtlas`. It is keyed by `(pixels identity, generation)`, and a texture is reuploaded only when the generation changes, as in Ghostty `prepImage`.
- **Upload.**
  - RGBA uses a shared-storage `MTLBuffer` created with `bytesNoCopy` over the page-aligned pixel buffer, plus a blit into a private `rgba8Unorm_srgb` texture.
  - RGB is expanded to RGBA on a background queue, because Metal has no RGB8 format.
  - Uploads never block the draw callback. A placement whose texture is not ready is skipped for that frame and drawn on the next one.
- **Mipmaps.** Generate mipmaps for images drawn below 50% scale. Sample with linear filtering, clamp to edge, premultiplied alpha.
- **Size.** Images larger than the device's maximum texture size, or larger than 4096 px per side on iOS, are downsampled once with vImage to the largest size at which any placement is displayed, capped at those limits. The cache records the variant.
- **Budget.** The texture budget is 256 MB on macOS and 128 MB on iOS. Textures not referenced by the last snapshot are evicted least-recently-used first and marked `MTLPurgeableState.volatile` until then. On `didReceiveMemoryWarning`, on backgrounding (UIKit), and when a view detaches, drop every unreferenced texture.

### 13.3 Passes

Ghostty's draw order (`generic.zig:1921-2000`) within the existing single encoder is:

1. Clear to the default background times opacity, then any window background image.
2. **Images below cell backgrounds.**
3. Cell backgrounds. When the below-background layer is non-empty, the background pass skips cells whose background is the default, so those images show through. It does this with a per-instance flag rather than a second pipeline. With no such images, the pass is unchanged.
4. **Images below text.**
5. Glyphs. Placeholder cells draw as spaces.
6. **Images above text.**
7. Decorations and the cursor, unchanged. The cursor stays visible above images, as in Ghostty, where it is a cell element.
8. Post-processing, which includes images.

- **Pipeline.** One `image_vertex`/`image_fragment` pipeline in `Shaders.metal`, with premultiplied source-over blending.
- **Quad.** One instanced quad per placement, positioned at `origin + destOriginCell × cellSize + destOffsetPx`.
- **Draw calls.** One draw call per run of consecutive placements that share a texture.
- **Clipping.** A scissor rect equal to the text area replaces Ghostty's implicit clipping by projection, so images never draw into padding.
- **Colour.** Image pixels are sRGB and are composited in the same colour space and with the same opacity rules as cell backgrounds.

### 13.4 Frame driving and accessibility

- **Animation clock.** Kitty animation becomes the third independent animation source, after blinking and animated post-processing. The presenter's display link schedules the next animation deadline. It is suspended under the existing rules for hidden, occluded, detached or backgrounded views, and the frame does not advance while suspended. Update spec.md's animation-source sentence (§20).
- **Accessibility elements.** Each visible placement larger than one cell exposes an element labelled "Image, *c* by *r* cells". There is no OCR or content description: the pixels are program output with no alt text. Images do not take part in selection.
- **Damage.** Text damage and image changes are independent. A change in `placementsGeneration` forces a redraw without marking text rows dirty.

## 14. SwiftMux

Every Swiftty app window is a SwiftMux workspace ([spec.md §SwiftMux](spec.md#swiftmux-native-workspace)), so this path is what makes graphics ship.

### 14.1 Negotiation

- `ServiceFeatures.kittyGraphics = 1 << 15`, added to `supported`.
- `ClientCapabilities.images = 1 << 8`. Like `clipboardRequests`, it is opt-in, and only clients that can draw or re-emit images ask for it. A client without it receives frames with no §14.3 section.

### 14.2 Pane pixel geometry

- `GeometryBatch.Entry` gains `cellWidthPixels` and `cellHeightPixels` (`UInt16`; 0 means unknown) from the controller's renderer.
- `PaneRuntime` calls `setCellPixelSize`, and the guardian sets `ws_xpixel`/`ws_ypixel` with `TIOCSWINSZ`. This fixes today's 14t/16t zeros independently of graphics.
- The engine's cell pixel size is the current *controller's*. When another client becomes controller, existing placements keep their pixel size and their grid extent is recomputed, as Ghostty does on a font-size change.
- Observers and roaming viewers with different metrics render the host's cell grid in their own cells (§14.3). This is the same rule as for text: the host's grid is authoritative.

### 14.3 Frame section

SMXB tag 19, `images`, is emitted only when the client has `images`. Field names below are wire semantics; `Messages.swift` and `SMXB.swift` define the encoding.

```text
hostCellPixelSize: UInt16 × 2
images:     [ { key: ImageKey(serial: UInt64, generation: UInt64), width, height: UInt32,
                format: rgb|rgba, byteCount: UInt64, animation: { frameKeys, gaps, state }? } ]   ≤ 64
placements: [ { imageIndex: UInt16, layer: UInt8, z: Int32, placeholder: Bool,
                sourceRect: UInt32 × 4, row: Int32, column: UInt16,
                offset: UInt16 × 2 (host px), size: UInt32 × 2 (host px) } ]                    ≤ 1,024
```

- **Frame sets (built, Phase 5).** After the placements, `prefetch` lists up to 64 more `{ key, width, height, bpp }` entries: the other frames of visible animations. Clients fetch them after the shown images, so the pane's own frame changes never wait on pixels (§26.2).
- **Coordinates.** `row` is relative to the frame's first row. It may be negative, or extend past the bottom, when part of the placement is visible.
- **Scaling.** Clients scale host pixels by `clientCell / hostCell` on each axis.
- **Reported range.** With `historyViewport` or history frames, placements are reported for exported history rows too.
- **Validation** (`Validation.swift`):
  - counts are within the limits above
  - `imageIndex` is in range
  - the source rect lies within the image
  - sizes are nonzero and bounded by `4 × 10000` host pixels
  - `byteCount = width × height × bpp`
- **Row versions.** Placements are frame metadata and are not part of row versions. `FrameDelta` always carries the complete `images` section, like the other complete metadata. Placements change rarely, and the section is small.

### 14.4 Blob transfer

The client fetches pixels by key:

- **Request.** `MuxCommand.requestImages(pane, keys ≤ 32)`.
- **Reply.** `MuxEvent.imageBlob(pane, key, offset, bytes)`, with records ≤ 4 MiB, raw pixel bytes and no compression, followed by `imageBlobEnd(key)`. Or `imageUnavailable(key)` when the image has been evicted or replaced.
- **Budget.** Blobs have a separate `MuxLimits.pendingImageBudget = 128 MiB` per connection, so images never delay frames or input.
- **Ordering.** Blob delivery is lower priority than frames and control events in the service's write scheduler.
- **Display while fetching.** Until a blob completes, the client treats the image as *pending*, Ghostty's restore concept (`snapshot/kitty.zig`). The layout is complete, nothing is drawn for it, and text never waits for pixels.

Each client keeps a per-connection `ImageCache`, keyed by `ImageKey`, with a 256 MB budget on macOS. It is shared by every pane view on the connection, and `MuxPaneView` resolves snapshot image references from it. A later optimisation may pass pixel buffers as shared memory over the local socket (SCM_RIGHTS) instead of copying. It is not required.

Decision 2026-11-24: not built. A 3840×2160 RGBA image (33 MB) fetches over the local socket in 98 ms in a debug build (about 320 MB/s, `KittyGraphicsMuxTests`), once per image key. Shared memory would save a copy that is not on any frame's critical path.

- **Worker budget.** Each screen is bounded by §8.2. `totalImageBytes` caps the whole worker: a transmission that would exceed it evicts within its own pane first, then replies `ENOMEM`.
- **Admission.** Pane admission accounts images separately from history ([spec.multiplexer.md §4](spec.multiplexer.md) limits table).

### 14.5 The `swmux` terminal client

`swmux` composes panes into an outer Swiftty terminal. With `ServiceFeatures.kittyGraphics`, it uses `TTYGraphics` (§16.5) in placeholder mode. Because its outer terminal is always Swiftty (`TERM_PROGRAM == swiftty`), detection is a formality, and the half-block fallback applies only to an outer Swiftty with graphics disabled.

## 15. Ordinary SSH and embedders

- **Ordinary SSH.** It parses on the client, so graphics works with no protocol work. Media are `direct` only (§7.1), and the storage limit is the client profile's. Images are lost when the SSH connection ends, along with the rest of the screen.
- **Embedders.** `SessionConfiguration` gains `imageStorageLimitBytes` (default 10 MB) and `kittyGraphicsMedia` (default `.direct`). An embedder enables file media only for local programs.

## 16. RST/1 roaming and `swroam`

### 16.1 Negotiation

- `RSTFeatures.kittyGraphics = 1 << 7`, with wire name `kittyGraphics`. It is not required. Clients list it when they can present images: every native client and `swroam`; not the watch companion.
- `SurfaceCapabilities` gains `images`. `.roaming` sets it when the feature is negotiated.
- A host or client without the feature exchanges frames without the images section. The validator rejects tag 19 from a peer that did not negotiate it, as it rejects `dropTarget` today.

### 16.2 Geometry

- `Attach` and the resize record carry `cellPixelSize` (in device pixels) alongside columns and rows.
- The roaming host forwards it as the pane's geometry when the roaming client is the controller (§14.2). The frame carries `hostCellPixelSize` in any case, so a client renders correctly whoever set it.

### 16.3 Image streams

- **Frames.** They carry the §14.3 section unchanged. RST frames come from the worker's frames ([spec.roaming.md §6](spec.roaming.md#6-the-authoritative-terminal)).
- **Pixels.** They travel on their own server-initiated unidirectional streams, never inside snapshots.

```text
UInt8      encoding: 4 = KGIB/1 image blob
UInt32BE   headerLength, then header (SMXB-style tags):
             key (serial, generation), digest: SHA-256 of the full-size RGBA pixels,
             width, height (this variant), variant: full | reduced, codec: png | heic
UInt32BE   encodedLength
Byte[]     encoded image
FIN
```

- **Encoding.**
  - The host encodes variants with ImageIO, off the session queue, in the roaming host's encoder slots.
  - **`full`**: lossless PNG. It is downsampled only when the largest displayed size on the client is smaller than the image, never below that size, and capped at 4096 px per side.
  - **`reduced`**: at most 1024 px per side and at most 1 MiB. Encode PNG first. If the downscaled PNG fits in 1 MiB, send it: screenshots, diagrams, charts and text compress well and stay lossless, which matters because lossy compression smears the hard edges terminal images are made of. Otherwise encode HEIC at quality 0.75, with alpha preserved, stepping the quality down by 0.1 to a floor of 0.5 until it fits. If it still does not fit at 0.5, halve the dimensions and retry. The client asks for `reduced` only through §16.4's policy. HEIC rather than JPEG: it keeps alpha, every supported OS decodes it in hardware, and it is about 40% smaller at equal quality.
  - When the image was transmitted as PNG at full size and not composed, the original PNG bytes may be sent unchanged.
- **Digest.** The worker computes the SHA-256 lazily, the first time a remote attachment needs the image, and caches it per `(serial, generation)`. A local-only workspace never hashes.
- **Push.** The host *pushes* blobs for keys that newly appear in a frame and that the attachment is not known to hold. A pull would add a round trip, about 300 ms on cellular.
  - **Inventory.** On `Attach`, the client lists up to 256 cached digests for this session (`imageInventory`).
  - **Acknowledgement.** After decoding a blob, the client sends `ImageAck { digest }`.
  - **Mapping.** The host maps keys to digests, so identical pixels under new keys are not resent. A reattachment after an outage resends no image the client still holds.
- **Explicit messages.**
  - `ImageRequest { attachmentEpoch, keys ≤ 32, variant }` asks for images again after client-side eviction, or for `full` after `reduced`.
  - `ImageLoad { attachmentEpoch, keys ≤ 32, variant }` sends images once without changing the attachment's variant: a tap on an Off-mode box.
  - `CellSize { attachmentEpoch, cellWidth, cellHeight }` (1–4096 device pixels each) reports a cell size that changed after `Attach`: layout, rotation or font size. The host gives the pane's PTY the new pixel size.
  - `ImageUnavailable { key }` answers a request for an image that is gone.
- **Scheduling.** Images add to [spec.roaming.md §7.3](spec.roaming.md#73-bounded-snapshot-scheduling) without changing its snapshot guarantees:
  - At most two image streams are in flight, separate from the two snapshot streams.
  - An image stream starts only when no snapshot is waiting for a stream slot.
  - An image stream is cancelled when every frame that referenced it is superseded and no installed frame references it.
  - Image streams share the encoder and send work slots with snapshots and yield to them.
  - Images never block input, control records or snapshot acknowledgement.
  - At most 8 MiB of image bytes are unacknowledged per attachment.
- **Display.** As for SwiftMux, the client displays frames immediately and draws each image when its blob decodes. A *partial* frame is never visible ([spec.roaming.md §7.3](spec.roaming.md#73-bounded-snapshot-scheduling)), but a complete frame with pending images is complete.
- **Deltas.** `screenDeltas` carries the complete images section in every delta (§14.3). A row map that moves rows does not move images; the section's coordinates are authoritative.

### 16.4 Client cache and network policy

- **Cache.**
  - The client `ImageCache` is keyed by digest, with a per-session key-to-digest map.
  - It survives attachment epochs and outages, but not session end or app termination. It is memory-only and never written to disk.
  - The budget is 128 MB on iPhone and iPad and 256 MB on Mac Catalyst and macOS, evicted least-recently-used first. It is purged on memory warnings and trimmed to 16 MB when the app is backgrounded.
- **Path policy.** Policy follows `NWPath` and a setting, *Images on cellular*: Full, Reduced (default) or Off.

| Path | Variant requested |
|---|---|
| Wi-Fi or wired, not constrained | `full` |
| `isExpensive` (cellular, personal hotspot) | The *Images on cellular* setting |
| `isConstrained` (Low Data Mode) | `reduced`, whatever the setting |

- **Off.** A native client draws a neutral rounded box with an image symbol over the placement's cells, and tapping it requests that image once. The program on the host still believes images work, because they do: only this client's presentation changed.
  - **Built as:** the host keeps sending the images section to an Off attachment but pushes no pixels. `RoamingImageCache.drawsBoxes` resolves placements without pixels to a shared box tile. On iOS a tap inside an image region calls `TerminalSession.imageTapHandler`, and `RoamingClient.loadVisibleImages()` sends `ImageLoad` with `reduced` for the visible keys the cache lacks.
- **Animation over RST/1.**
  - **Phase 4:** the frame carries the current frame's key, and the host recaptures at most 2 Hz while an animation runs.
  - **Phase 5:** the images section's `animation` entry carries frame keys, gaps and the playback state. The client fetches frames like images and plays them locally. The host sends state changes rather than per-tick frames, and animations whose frames exceed 25% of the client cache budget stay at 2 Hz.
  - **Built as (§26.2):** frame sets without client playback. The images section lists the other frames of visible animations (`prefetch`), and clients fetch or receive them ahead of time. The host's clock still changes frames, so each tick sends only a frame record whose image key the client already holds.

### 16.5 `TTYGraphics`: `swroam` and `swmux` inside another terminal

`swroam` is "mosh-style, for any terminal": it draws RST frames into an outer terminal through `TTYKit`'s cell-diff renderer. `TTYGraphics` adds images to that output without changing the diff model.

**Detection.**

- At startup, and after `SIGCONT`, write:
  - `ESC _ G i=31,s=1,v=1,a=q,t=d,f=24;AAAA ESC \`
  - then `CSI c`.
- A `G` reply before the DA1 reply means the outer terminal supports kitty graphics. DA1 first, or no reply within 500 ms, means it does not.
- When `$TMUX` is set, the query is wrapped as tmux passthrough (`ESC P tmux; …ESC ESC… ESC \`, with every inner ESC doubled). No reply then means either a terminal without graphics or tmux without `allow-passthrough`. `swroam` prints a one-time hint naming `set -g allow-passthrough on`.
- `--graphics auto|kitty|halfblocks|off` overrides detection.
- `TTYKit.InputDecoder` consumes every `ESC _ G … ESC \` reply from the outer terminal and never forwards it as input to the remote PTY. A forwarded reply would be typed into the user's shell.

**Kitty mode: placeholders.**

- Transmit each image once to the outer terminal:
  - `a=t,f=32,t=d,q=2`, base64, in chunks of at most 4096 bytes
  - then one virtual placement `a=p,U=1,i=<outer id>,c=<cols>,r=<rows>,q=2`
- Allocate outer ids from a private namespace. Use 24-bit ids so that image ids encode as RGB foreground colours. Use one virtual placement per `(image, cell size)` and the underline colour for its placement id.
- Draw every resolved placement as placeholder cells, U+10EEEE with row and column diacritics, *in the composed screen buffer*:
  - Clipping at pane edges, overlapping popups, scrolling and full redraws then happen in the cell diff, with no image-specific logic.
  - This is the technique that makes kitty images work inside tmux.
- **Limits of this mode.** Placeholders cannot express sub-cell offsets, layers above text, or source rects that are not cell-aligned:
  - Above-text placements draw below text.
  - Offsets snap to cells.
  - The image is fitted to its cell rectangle with its aspect ratio preserved.
  - Kitty's own clients accept the same limits under tmux.
- **Re-sending.**
  - Responses are suppressed (`q=2`), so the outer cache cannot be observed. `TTYGraphics` re-sends an image whenever it does a full redraw: attach, resize, Ctrl-L, outer `SIGWINCH`.
  - It also re-sends when the outer terminal could have evicted the image under its own limit: when the bytes emitted since the last full redraw exceed 64 MB.
- **Transmission budget.** At most 2 MiB of image bytes per outer write batch, interleaved with cell updates so that typing stays responsive.

**Half-block mode** (no kitty support, or `--graphics halfblocks`):

- **Raster.**
  - Each cell shows two vertical image samples as `▀` (U+2580): the foreground is the top half and the background the bottom half.
  - Samples are box-filtered from the image region the cell covers and alpha-composited over the frame's default background.
  - Truecolor is used when `COLORTERM` is `truecolor` or `24bit`, or XTGETTCAP `RGB`/`Tc` answers. Otherwise colours are quantised to the 256-colour palette.
- **Layering.**
  - Placements with z < 0 and placeholder runs fill only cells whose text is blank.
  - Placements with z ≥ 0 replace the cell's text.
  - The cell diff then treats half-block cells like any other cells.
- **Downsampling.** It is CPU-only and pure Swift, so `TTYKit` stays free of renderer, Metal and Accelerate imports. Cache the result per `(image key, cell rect, cell size)`.
- **Scope.** This is the only fallback. There is no Sixel encoder.

**Off mode.** Image cells are left as their underlying text.

## 17. tmux and Mosh

### 17.1 tmux inside a Swiftty terminal

tmux running on a local pane, over ordinary SSH, or on a roaming host forwards graphics to its outer terminal only through passthrough. Swiftty's engine is that outer terminal, so tmux unwraps `ESC P tmux; … ESC \` and Swiftty sees ordinary APC commands. No Swiftty code is tmux-specific.

| Program behaviour under tmux | Result in Swiftty |
|---|---|
| Transmits with `U=1` and prints placeholders (`kitten icat --unicode-placeholder --passthrough=tmux`, yazi, timg, chafa) | Works. Placeholders are text cells in tmux's grid, so tmux handles pane layout, splits, scrolling, copy mode, zoom and window switching, and Swiftty draws the images wherever the cells land. |
| Places images directly (`a=T` without `U=1`) | Lands at the *outer* cursor, which tmux does not track. The placement is misplaced or overwritten. This is a tmux limitation, documented in the user guide, not a Swiftty defect. |

Recommended tmux configuration, to be documented in the README:

```tmux
set -g allow-passthrough all                          # 3.4+; `on` drops passthrough from hidden panes
set -as terminal-features ',xterm-256color:RGB:usstyle' # 24-bit ids in fg; placement ids in underline colour
set -ga update-environment 'TERM_PROGRAM'
```

- `on` instead of `all` loses images transmitted while their pane was hidden. The placeholders then reappear without pixels.
- Without `RGB`, tmux downgrades the foreground colour, which corrupts image ids above 255. Programs then fall back to 8-bit ids.
- Without `usstyle`, tmux drops underline colours, so placement ids become 0 and the image's preferred placement draws. That is still correct for single-placement images.
- **Support boundary.** Swiftty supports the kitty protocol in its own engine: it parses what tmux forwards and draws placeholder cells correctly. Swiftty's width tables measure U+10EEEE as 1 column and the row/column diacritics as 0, verified against `UnicodeWidth` at the baseline and pinned by KG16. How tmux measures U+10EEEE is tmux's behaviour on the remote host, outside Swiftty's control. A tmux that measures it differently misaligns its own grid, and Swiftty does not compensate. KG27 exercises the recommended configuration to keep the README guidance accurate. It is not a release gate, and Swiftty makes no claim for particular tmux versions.
- **Observed in KG27 (tmux 3.4, 3.5a, 3.6a, 3.7c and 3.8).** tmux keeps each placeholder's row, column and high-byte diacritics in its grid but drops them when it draws cells as they arrive. Only a full redraw (`refresh-client`, zoom, a window switch, reattaching) sends them. Until then every row shows the image's first row, and an image id with a nonzero high byte (as `kitten icat` chooses) resolves to no image. Swiftty never receives the diacritics, so it cannot compensate. The README tells users to redraw.
- tmux control mode (`-CC`) passes pane output to the embedder through `controlModeData`. It does not pass through the graphics engine, so `-CC` graphics stays out of scope.

### 17.2 Mosh and why roaming is different

Mosh synchronises only a character-cell state buffer and strips graphics escape sequences, so neither Sixel nor kitty images reach the client. Programs that probe over Mosh get no reply and fall back to half-blocks or text themselves.

Swiftty's roaming path is server-authoritative like Mosh. But both ends are Swiftty, and the state it synchronises includes images:

| | Mosh | `swroam` / Swiftty roaming (this spec) | tmux + `allow-passthrough` |
|---|---|---|---|
| What the program sees | No graphics reply | Kitty graphics, always (host engine answers) | The outer terminal's reply, via passthrough |
| Images survive network change or sleep | — | Yes. Host storage, client cache by digest, push after reattach | Only while the outer terminal keeps them |
| Client without image support | — | Client-side half-blocks (`swroam` in a plain terminal) or a placeholder box (Off on cellular). The program is unchanged. | No images |
| Reattach from another device | — | The new client draws the same images at its own resolution | Depends on the new outer terminal |
| Bandwidth control | — | Digest dedupe, downsampled `full`, `reduced` on cellular or Low Data Mode, Off | None |
| Direct (non-placeholder) placements | — | Full fidelity in native clients; snapped to cells in `swroam` kitty mode | Misplaced |

`swroam` inside tmux on the client Mac combines both: `TTYGraphics` wraps its placeholder transmissions in tmux passthrough (§16.5).

## 18. Durability and checkpoints

Extend [spec.durability.md](spec.durability.md) §6 and the pane migration checkpoint:

- **Section.** Checkpoint section 15, `kittyGraphics`, per screen, modelled on Ghostty's `snapshot/kitty.zig` records:
  - storage limit, media and counters
  - images with id, number, serial, generation, transmission, flags and pixels
  - animation frames and state
  - placements with anchors, geometry, ids, z and relative links
  - virtual placements
- **Write rule.** The section is written only when non-empty, so checkpoints of terminals without images are byte-identical to today's. MR2 canonical-bytes fixtures must stay unchanged.
- **Restore order.** Pixels restore after the grid. The images are *pending* until their pixel records are read, so a migrated pane is usable before every image arrives.
- **Keys.** Serials are preserved, so clients keep their caches across migration with no blob re-fetch.
- **Chunked load at the migration cut.** An in-flight chunked load (`m=1`) is abandoned with no reply, as a delete abandons it. It is not checkpointed: a continuation that arrives at the new worker finds no load and is handled as Ghostty handles an orphan continuation. Test it (KG30).
- **Parser state.** The parser checkpoint gains the APC state and the control-part buffer of a partially received command. The payload is not stored; an interrupted payload is dropped.
- **Size.** Checkpoint image bytes count against the migration transfer bound, and that bound grows by the worker's `totalImageBytes`. A pane over the bound migrates without pixels, with its images dropped and a diagnostic, rather than blocking migration.
- **Never saved.** Saved output and layout restoration ([spec.durability.md §12.2.3](spec.durability.md)) never save images. Add images to the "Never save" list.

## 19. Deviations from Ghostty

| ID | Deviation | Reason |
|---|---|---|
| D1 | SOS and PM are not parsed as graphics; APC bytes 0x80 and above are dropped (Swiftty has no 8-bit C1 controls) | Ghostty quirk; no program depends on it |
| D2 | Integers reject `+` and `_` | Zig `parseInt` artefact |
| D3 | A file read is abandoned after 250 ms | Bounds the serial session queue on network filesystems and FIFOs |
| D4 | In-flight chunk data and zlib output are capped by the storage limit, replying `ENOMEM` (past 400 MB still `EINVAL`) | Ghostty's 400 MB exceeds iOS budgets |
| D5 | Reduce Motion holds animations | Apple accessibility |
| D6 | Media are refused for remote programs | Remote output must not read client files; libghostty's default is the same |
| D7 | Placeholder cells printed after the 63-entry underline table is full resolve to placement id 0 (the image's preferred virtual placement); the side table in §10.3 is not built | Swiftty's 6-bit underline id |
| D8 | Darwin temp-directory set and `F_GETPATH` | Platform equivalents of Ghostty's Linux rules |
| D9 | Full-screen scrolls on the alternate screen move and clip placements as region scrolls do (kitty); Ghostty leaves pins on the top row in place | Ghostty's pin quirk would pin an image to the top row |

Every deviation has a test that states it.

## 20. Edits to other documents

| Document | Edit |
|---|---|
| spec.md "Goal and scope" | Replace "Kitty graphics is future work; … placeholders." with a pointer to this spec. Keep "Sixel is excluded." |
| spec.md "Terminal protocols" | Add an `APC` row: "Kitty graphics ([spec.graphics.md](spec.graphics.md))". Change "other DCS/APC/PM/SOS strings" to name the exception. |
| spec.md "Rendering and fonts" | Kitty animation becomes a third independent animation source. |
| spec.md "Performance and acceptance" | Add the §21.3 gates. Remove the Images exclusion from the comparison text. |
| spec.keyboard.md §1, spec.apple.md "Retained choices" | Remove "Kitty graphics remains excluded". |
| spec.multiplexer.md §1 (deferrals), §4 (frames contain no images), feature list | Point to §14. Frames carry image *references*; pixels travel as blobs. |
| spec.roaming.md §2, §6, §12, A9 | Graphics is a negotiated feature (§16). §12's ban becomes "filesystem actions carried by escape sequences from remote programs". A9 adds image-stream fuzzing. |
| spec.durability.md §6, §12.2.3 | Section 15 and "never save images" (§18). |
| README.md | Status, measurements, the tmux configuration from §17.1 and `swroam --graphics`. |

## 21. Verification

### 21.1 Correctness matrix

Tests use Swift Testing with backtick sentence names, in the existing targets. Ghostty ports say so in their doc comments, as `KittyDragAndDropTests` does.

| ID | Area | Required result | Suite |
|---|---|---|---|
| KG1 | Framing | `ESC _ G` is recognised; non-`G` APC, SOS and PM are ignored; CAN/SUB abort; split at every byte boundary; over-limit commands are dropped without buffering | `KittyGraphicsParserTests` |
| KG2 | Grammar | Ghostty `graphics_command.zig` tests ported: unknown long or non-letter keys, very long values, u32/i32 overflow, all i32 values, unknown flag values fail, payload-only command | `KittyGraphicsCommandTests` |
| KG3 | Base64 | Whitespace, optional padding, per-chunk validity, rollback of a bad chunk | `KittyGraphicsCommandTests` |
| KG4 | Responses | Exact bytes for every message; quiet levels; chunk-inherited identifiers and `q`; no reply for deletes, `a=a`, implicit ids, malformed input or disabled state | `KittyGraphicsExecTests` |
| KG5 | Ids | `i`/`I` exclusive for every action; smallest free id; implicit ids never replace client ids; retransmit keeps the old image until completion | `KittyGraphicsExecTests` |
| KG6 | Media | Temp files in `/tmp`, `/private/tmp` and `$TMPDIR` accepted; prefix lookalikes rejected; name rule; deletion; symlink swap after open still blocked; `/dev` refused; short reads; shm name, range and dimension-before-multiply; remote profiles refuse `f t s` | `KittyGraphicsMediaTests` |
| KG7 | Decoding | zlib bounds and Adler-32; PNG type pinning (a JPEG or HEIC labelled `f=100` is rejected); dimension pre-check; decoder allocation bound; exact length; corpus fuzzing | `KittyGraphicsDecodeTests` |
| KG8 | Storage | Eviction priority order; ENOMEM; zero limit disables everything; per-screen storages; alternate inherits limits; RIS keeps limits | `KittyImageStorageTests` |
| KG9 | Deletes | Every target letter in both cases, ported from Ghostty's storage tests, including "delete all includes placements spanning into active area" and "uppercase range deletes unplaced image data" | `KittyImageStorageTests` |
| KG10 | Anchors | Output scrolling into history keeps placements; history eviction removes them; ED 2/3/22; 1047/1049/47 | `KittyGraphicsAnchorTests` |
| KG11 | Margins | The Ghostty "scroll margins …" series: region-internal moves and proportional clipping; IL/DL do not move placements; left and right margins | `KittyGraphicsAnchorTests` |
| KG12 | Reflow | Anchors and placeholder row flags through widen, narrow and rewrap (`TerminalReflowTests` style) | `KittyGraphicsAnchorTests` |
| KG13 | Geometry | Pixel size and grid size for every `c`/`r` combination; offset clamping; zero cell size | `KittyPlacementTests` |
| KG14 | Cursor | Movement, wrap, `C=1`, and the bound for hostile `r` | `KittyPlacementTests` |
| KG15 | Relative | Ghostty's "relative placement …" series: cycle, depth 8, missing parent, transitive delete | `KittyPlacementTests` |
| KG16 | Placeholders | U+10EEEE measures 1 column and every row/column diacritic 0; Ghostty's "dog 4x2 / 2x2 with blank cells / 1x1" cases; palette and RGB ids; third diacritic; run joining; preferred placement; erase clears the flag | `KittyPlaceholderTests` |
| KG17 | Placement ids | 1,000 distinct underline placement ids resolve exactly (D7) | `KittyPlaceholderTests` |
| KG18 | Animation | Ghostty's "animation: …" and "animation tick …" series; ENOSPC; root promotion; Reduce Motion hold | `KittyAnimationTests` |
| KG19 | Oracle | Sequences replayed against libghostty `167acf0c` with PNG and file media enabled: responses and placement render info equal | `GhosttyOracle/KittyGraphicsOracleTests` |
| KG20 | Rendering | Layer order (below background, below text, above text) with pixel readback; default-background skip; scissor to the text area; RGB expansion; texture reuse across generations; budget eviction; memory-warning drop | `KittyGraphicsRenderTests` (SwifttyCoreTests) |
| KG21 | Snapshot | Text-only snapshots unchanged and allocation-free; placeholder rows do not force full refills | `SnapshotTests` |
| KG22 | Mux frames | Tag 19 round trip; validation rejects every bound; deltas carry the complete section; clients without `images` get no section | `KittyGraphicsFrameTests` (SwiftMuxTests) |
| KG23 | Mux blobs | Pending until complete; `imageUnavailable` after eviction; budget backpressure never delays frames or input; cell pixel size reaches the winsize and 14t/16t | `KittyGraphicsMuxTests` |
| KG24 | RST/1 | Negotiation in both directions; KGIB/1 validation and fuzzing; no resend after reattachment for inventoried digests; `reduced` under a constrained path; image streams never block snapshots under the A3 loss profile; impossible keys rejected | `KittyGraphicsRoamingTests` (ProtocolTests) |
| KG25 | TTYGraphics | Detection with replies, without replies and through tmux wrapping; outer replies never reach the remote PTY; placeholder emission clipped at pane edges; resend on full redraw; half-block raster golden images; 256-colour quantisation | `TTYGraphicsTests` |
| KG26 | Programs | `kitten icat` (direct, `--transfer-mode file`, `stream` and `memory`, `--unicode-placeholder`), yazi, timg, chafa and the neovim `image.nvim` plugin on a real macOS PTY | `IntegrationTests` (filtered by exact names) |
| KG27 | tmux (guidance check, not gating) | tmux 3.4 and 3.5 with the §17.1 configuration: icat placeholders through splits, zoom, window switch and copy mode; a hidden-pane transmit with `all` versus `on` | `IntegrationTests` |
| KG28 | Devices | iPhone over cellular and Wi-Fi switching 20 times with images on screen: images remain and no blob is re-sent for cached digests; iPad memory warnings; Reduce Motion | Device validation record |
| KG29 | Security | Remote output naming `~/.ssh/id_ed25519` via `t=f` in ordinary SSH is refused; malicious PNG, HEIC and zlib corpora stay within bounds; 64 MiB APCs; 10,000 placements | `KittyGraphicsSecurityTests` |
| KG30 | Durability | Section 15 round trip; checkpoints without images are byte-identical (MR2); pending pixel restore; chunked load abandoned at the cut; serials preserved | `CheckpointTests`, `MigrationTests` |

### 21.2 Memory criteria

- With no graphics command received, the per-terminal heap is unchanged (`CAllocCounter`), and text-only RSS gates are unchanged.
- Storage accounting equals the sum of pixel and frame bytes. Released images return memory within one second (`MADV_FREE_REUSABLE`, measured with `footprint`).
- Texture memory stays within the §13.2 budget across a 1,000-image `icat` slideshow.

### 21.3 Throughput and latency gates

| Gate | Requirement |
|---|---|
| Parser throughput, existing `compare-ghostty.py` inputs | No regression (≥ 99% of the baseline). The APC state adds no work to ground or OSC paths. |
| kitty `__benchmark__` Images payload | ≥ 95% of Ghostty throughput. Remove the omission in `Scripts/compare-ghostty.py` and README. |
| 3840×2160 RGBA, direct, 4096-byte chunks | Session-queue time ≤ 1.1× Ghostty's, measured with paired `--repeat 5` runs |
| 2000×2000 PNG decode | ≤ 25 ms p95 on an M-series Mac and ≤ 60 ms on a recent iPad |
| Texture upload | No dropped frames at 120 Hz while a 33 MB image uploads |
| Placeholder screen (80×40 of U+10EEEE, typing elsewhere) | Snapshot build time within 10% of the same screen of ASCII |
| RST/1 80×24 typing with one image on screen | No change in bytes per screen after the first blob. Typing latency unchanged under the recovery-target network profile. |

Add `swiftty-bench --only kitty-transmit,kitty-png,kitty-placeholders,kitty-render`. Run measurements with the paired, repeated method in the README.

## 22. Source changes

| Target | New or changed files |
|---|---|
| `SwifttyEngine/Terminal` | `KittyGraphicsCommand.swift` (grammar, keys, values), `KittyGraphicsExec.swift` (actions and responses), `KittyGraphicsMedia.swift` (file, temp and shm; Darwin rules), `KittyImageDecode.swift` (zlib, PNG via ImageIO), `KittyImageStorage.swift` (images, eviction, deletes, anchors), `KittyPlacement.swift` (geometry, cursor, relative placements), `KittyPlaceholder.swift` (diacritics, runs), `KittyAnimation.swift`, `KittyRenderState.swift`, `TerminalState+KittyGraphics.swift`, generated `KittyDiacritics.swift`. Changes to `Parser.swift` (APC states and bulk path), `TerminalState` hooks (§8.4, §9.1), `GridStorage` placeholder bit, `TerminalReflow`, and `TerminalState+Checkpoint.swift`. |
| `SwifttyEngine/Session` | `SessionConfiguration.imageStorageLimitBytes` and `kittyGraphicsMedia`; `SurfaceCapabilities.images` |
| `SwifttyCore/Renderer` | `ImageLayerSnapshot`, `ImageTextureCache.swift`, `MetalRenderer` passes, `Shaders.metal` image functions, `SnapshotStorage` placeholder exemption |
| `SwifttyCore/Config`, `SwifttyConfig`, `schema.json` | `image_storage_limit` (bytes; 0 disables; platform defaults §8.2); `images_on_cellular` (`full`, `reduced`, `off`) |
| `SwiftMuxProtocol` / `SwiftMuxExport` / `SwiftMuxService` / `SwiftMuxGuardian` | Feature and capability bits, tag 19, blob messages, `MuxLimits` fields, geometry pixel fields, `TIOCSWINSZ` pixels, migration |
| `SwiftMuxBridge` / `Swiftty` | `FrameImporter` image section, per-connection `ImageCache`, `MuxPaneView` |
| `ScreenProtocol` / `TerminalHost` / `RoamingKit` | `RSTFeatures.kittyGraphics`, KGIB/1 stream, `ImageAck` / `ImageRequest` / `ImageUnavailable` / `imageInventory`, digest cache, path policy |
| `TTYKit` / `SwRoamCLI` / `SwiftMuxTerminal` | `TTYGraphics.swift`, an `InputDecoder` APC reply filter, `--graphics`, compositor placeholder emission |
| `Scripts` | `gen-kitty-diacritics.py` (from a pinned kitty source revision), `compare-ghostty.py` Images payload |

Code conventions:

- Each new engine file opens with a header in the style of `KittyClipboard.swift`: what it ports from Ghostty, by path, and its deviations by D-number.
- The parser hot path stays allocation-free.
- Pixel buffers are the only large allocations. Their size is bounded before allocation, using checked arithmetic.

## 23. Delivery phases

| Phase | Deliverable | Exit criteria |
|---|---|---|
| 1 | Engine protocol: parser, grammar, all actions and media, decoding, storage, anchors, placeholders, animation state, responses. Not yet advertised (`kittyGraphicsEnabled` false by default). | KG1–KG19, KG29; parser throughput gates |
| 2 | Direct rendering, and enabling graphics for direct sessions and ordinary SSH | KG20, KG21, KG26; render and memory gates |
| 3 | SwiftMux: pane geometry, frames, blobs, caches, migration. Enabled in app windows. | KG22, KG23, KG30; `swmux` kitty mode |
| 4 | RST/1 and `swroam`: image streams, inventory, network policy, `TTYGraphics` kitty and half-block modes, tmux guidance | KG24, KG25, KG28 (KG27 informs the README) |
| 5 | Remote animation frame sets; optional shared-memory blob transfer | KG18 over RST/1; bandwidth report |

Each phase updates README status and the §20 documents for what it enables.

## 24. Decisions to validate

### Open

1. The items §26.3 lists as not built or not measured.

### Decided 2026-11-24

| Decision | Outcome | Where |
|---|---|---|
| iOS and iPadOS image budgets | 128 MB per screen, 128 MB client cache, 128 MB texture budget | §8.2, §13.2, §16.4 |
| `reduced` variant encoding | Lossless PNG when it fits in 1 MiB, otherwise HEIC 0.75 stepping to 0.5, then halved dimensions | §16.3 |
| Placeholder text in copy and search | Keep U+10EEEE and its diacritics (Ghostty parity) | §10.2 |
| tmux | Swiftty supports the protocol in its own engine only. tmux width behaviour is tmux's; KG27 is guidance, not a gate. | §17.1 |
| 250 ms file-read bound (D3) | Keep. A 381 MB local file reads in 23.8 ms (`kitty-file`), a tenth of the bound; a slower network home directory gets `EINVAL` rather than a stalled session, which is the bound's purpose. | §5, D3 |
| Shared-memory pixel transfer over SwiftMux | Not built: a 33 MB image fetches locally in 98 ms (debug), once per key (§14.4) | §14.4 |
| Remote animation | Frame sets with host-clocked frames rather than client playback (§26.2) | §14.3, §16.4 |

## 25. Sources

- [K01] kitty, *Terminal graphics protocol*: <https://sw.kovidgoyal.net/kitty/graphics-protocol/>
- [K02] kitty, `rowcolumn-diacritics.txt`: <https://github.com/kovidgoyal/kitty/blob/master/gen/rowcolumn-diacritics.txt>
- [G01] Ghostty `src/terminal/kitty/graphics_command.zig`, `graphics_exec.zig`, `graphics_image.zig`, `graphics_storage.zig`, `graphics_unicode.zig`, `graphics_animation.zig` at `167acf0c`
- [G02] Ghostty `src/terminal/apc.zig`, `stream.zig`, `stream_terminal.zig`, `Terminal.zig`, `Screen.zig`, `render.zig`, `snapshot/kitty.zig` at `167acf0c`
- [G03] Ghostty `src/renderer/image.zig`, `generic.zig`, `shaders/shaders.metal`, `src/config/Config.zig` (`image-storage-limit`) at `167acf0c`
- [T01] tmux `allow-passthrough` and `terminal-features`, tmux(1) manual
- [M01] Winstein and Balakrishnan, *Mosh: An Interactive Remote Shell for Mobile Clients* (USENIX ATC 2012): state synchronisation of the character-cell screen only
- Repository: `Parser.swift`, `TerminalState*.swift`, `KittyClipboard.swift`, `MetalRenderer.swift`, `SnapshotStorage.swift`, `PaneRuntime.swift`, `Messages.swift`, `SMXB.swift`, `ControlMessage.swift`, `TTYPresentationSink.swift`, as cited inline at baseline `29b8c8fc`

## 26. Implementation record (2026-11-24)

### 26.1 Built

- **Engine** (`Sources/SwifttyEngine/Graphics/`, `TerminalState+KittyGraphics.swift`): every section from §5 to §11, ported from Ghostty `167acf0c`, plus checkpoint section 15. Anchors use absolute rows. They are moved only by region scrolls, bottom-margin and alternate-screen scrolls, reflow (as auxiliary reflow marks) and history erases.
- **Direct rendering**: `RenderSnapshot.images` and `ImageTextureCache`. Three passes, with default-background cells skipped for below-background images, scissored to the text area. Placeholder cells draw no glyph.
  - The view's display clock drives animation. Reduce Motion holds it (D5).
  - iOS trims textures on memory warnings and backgrounding.
- **SwiftMux**:
  - **Geometry**: `GeometryBatch.Entry` carries the cell size, which sets the engine's cell size and the PTY's `ws_xpixel`/`ws_ypixel` through the guardian.
  - **Frames**: frames carry the SMXB tag 19 `images` section for clients with `ClientCapabilities.images`.
  - **Pixels**: fetched by `MuxCommand.imageChunk`, at most 4 MiB per reply, into a per-connection `MuxImageStore`.
  - **Animation**: panes tick animations on their queue.
- **RST/1**:
  - **Negotiation**: the `kittyGraphics` feature. `Attach` carries the inventory, the variant and the cell size.
  - **Pixels**: `KGIB/1` records use snapshot encoding 4 (§26.2). The host pushes new keys, aliases inventoried digests, answers `ImageRequest`, and rate-limits image starts.
  - **Client**: `RoamingImageCache` keyed by digest. The app chooses the variant from the path and `images-on-cellular`.
- **Terminal clients**: `TTYGraphics` for `swroam` and `swmux`, and `swroam --graphics`. `InputDecoder` turns outer-terminal replies into `.reply`, which never reaches the remote program.
- **Accessibility (§13.4)**: `RenderSnapshot.imageRegions` merges placeholder runs and clips placements to the viewport; each region larger than one cell is labelled "Image, *c* by *r* cells". macOS exposes `TerminalImageElement` children (direct views and SwiftMux panes); iOS adds `UIAccessibilityElement`s with the image trait while VoiceOver runs.
- **Off mode (§16.4)**: placements without pixels, a box tile, and `ImageLoad` on tap.
- **Frame sets (Phase 5)**: the `prefetch` list in the images section (§14.3), fetched over SwiftMux and pushed over RST/1 after the shown images.
- **Placeholder scanning (§10.2)**: see §26.2.
- **Fixed by the first KG28 iPhone run** (20 reattachments: 37 aliases, 6 blobs of one image, 5 resends):
  - Two keys with the same pixels that were encoded concurrently each sent a blob. The host now aliases a blob whose digest is already delivered or in flight (`digestsSending`); `HostImageTests` covers it.
  - The app replaced its `RoamingClient` on some reconnects, and each new client started with an empty image cache, so its `Attach` offered no inventory. `RoamingClientConfiguration.images` now carries one cache per terminal surface across clients; a new client keeps the pixels and forgets the old keys (`RoamingImageCacheTests`).
  - The host's image log used `info`, which macOS does not keep; it now uses `notice`.
- **KG28 passed (2026-11-24, iPhone 16 over Wi-Fi and cellular).** With an image from `kitten icat` on screen, the iPhone switched between Wi-Fi and cellular until the gateway logged 20 attachments. `Scripts/kg28-image-resends.sh "2026-11-24 21:26:50"`: `attachments=20 blobs=2 aliases=18 not_held=2 resends=0`. The two blobs were first sends to the freshly reinstalled app, which held nothing; every later attachment offered the digest and got one alias. The image stayed on screen throughout. Three runs before this one found the bugs listed below.
- **Fixed by the third KG28 iPhone run.** Every Wi-Fi↔cellular switch changes the image variant, and `RoamingClient.setImageVariant` asked again for every visible image, so held pixels were resent on each switch. Now only an upgrade asks (`full` wanted while the cache holds `reduced`), and a `reduced` blob never replaces cached `full` pixels (`RoamingImageCacheTests`). `Scripts/kg28-image-resends.sh` also takes a start time, so runs after a gateway restart exclude earlier builds.
- **Fixed by the second KG28 iPhone run.** After the fixes above, attachments whose inventory held the image got a single alias each. Two resends remained. The host aliased a digest whose blob was still in flight; the client, lacking it, requested the key at once, and the host sent the pixels again. The client now holds an alias for a missing digest until the blob arrives, and requests the key only if none comes within 2 s (`RoamingImageAliasTests`). The host also ignores a request for a digest whose blob is in flight. The client logs its requests (subsystem `dev.chr33s.swiftty.client`). `Scripts/kg28-image-resends.sh` now reads only the gateway's log (in-process test hosts log under the same subsystem), and counts as resends only blobs the client listed in its inventory, plus a second blob of one digest in one attachment.
- **Fixed during the iPhone run**: `kitten icat` in a roaming or SSH session on the iPhone failed with "Terminal does not support reporting screen sizes in pixels". The roaming client read its cell size once, before layout, and never sent a later one; SSH sent 0 pixels in `pty-req` and `window-change`. `TerminalSession.cellPixelSizeHandler` now reports changes, the roaming client sends `CellSize`, and `SSHStreamBackend` sends pixels with each window change (`HostImageTests`, `SSHReplyBackpressureTests`).
- **Fixed during device verification**: `TerminalSession.publish` asked the view for a frame only on text damage or cursor movement, so an image displayed with `C=1`, or a delete, was not drawn until other output arrived. It now also compares the graphics revision. SwiftMux panes were unaffected.
- **Tests**:
  - **Engine and checkpoints**: `KittyGraphicsTests.swift`, the Ghostty ports covering KG1–KG18 and KG30.
  - **Rendering**: `KittyGraphicsRenderTests`, pixel readback for KG20 and KG21.
  - **SwiftMux**: `KittyGraphicsMuxTests` for KG22 and KG23.
  - **RST/1**: `HostImageTests` for KG24.
  - **Terminal clients**: `TTYGraphicsTests` for KG25.
  - **Ghostty ports (KG19)**: `GhosttyOracle/KittyGraphicsOracleTests.swift`, about 209 of Ghostty's 234 kitty graphics tests at `167acf0c` with Ghostty's exact values (172 cases). The 22 skipped tests are listed in the file: Windows paths, Ghostty-only internals and pending-image completion.
  - **Programs (KG26)**: `KittyGraphicsProgramTests` on a real PTY replays what `kitten icat` emits for direct, file, temp-file (deleted after reading), shared-memory (unlinked after reading) and `--unicode-placeholder` transfers. `KittyRealProgramTests` runs the real programs when installed: `kitten icat` (`--transfer-mode` stream, file and memory, and `--unicode-placeholder`), timg (`-pk`), chafa (`-f kitty`), yazi (preview, then cleared on quit) and image.nvim (kitty backend, `magick_cli`; `SWIFTTY_IMAGE_NVIM` names the checkout). Verified with kitty 0.51.1, timg 1.6.3, chafa 1.18.3, yazi 26.9.1 and Neovim 0.12.6 with image.nvim `365e2ac`.
  - **tmux (KG27)**: both suites run tmux 3.4, 3.5a, 3.6a, 3.7c and 3.8 with `allow-passthrough`, including real `kitten icat` in a split pane (with the redraw §17.1 describes): placeholders follow a split, zoom, window switch and copy mode, and a hidden pane's transmit arrives with `all` but not with `on`.
  - **Devices (KG28)**: `KittyDeviceTests` (PNG decode, 4K transmit and upload, placeholder snapshots) and `KittyDeviceViewTests` (memory warnings drop textures not on screen; the animation clock follows Reduce Motion) run on a physical iPad and iPhone through `Scripts/test-ipad-frame-time.sh <udid> <team>`. Results are in §26.4.
  - **Off mode and frame sets**: `HostImageTests` (Off placements without pixels, `ImageLoad`, typing beside an image resends no pixels), `RoamingImageCacheTests`, and `KittyGraphicsMuxTests` (prefetch export and SMXB round trip, a pane's clock swapping frames).

### 26.2 Different from the proposal

- **No ImageAck.** `KGIB/1` records reuse the 9-byte snapshot header with encoding 4, so transports bound them like screens. Encoded images are therefore at most 4 MiB, not 8 MiB. There is no `ImageAck`: the host records a delivery when its send completes.
- **Remote animation.** Frame sets without client playback. The images section lists every other frame of a visible animation (`prefetch`), so clients hold the frames before the host's clock reaches them; each tick then costs one frame record that references a key the client already has. Client-side playback would duplicate the engine's animation state machine (loops, gaps, frame edits and compose) on every client and let it drift from the host's state, for no visible gain. The RST/1 host starts at most 2 images per second after a burst of 8, so a long animation fills in over its first loops. The 25%-of-cache cut-off is not built; `prefetch` is capped at 64 frames.
- **Placeholder scanning (§10.2).** There is no row flag in the grid, which would add work to the print path. Instead:
  - `SnapshotBuilder` keeps each viewport row's placeholder runs and rescans only damaged rows.
  - While `SnapshotStorage.fill` copies a damaged row, it records whether the row may hold a placeholder: a grapheme, or (with images on screen) a plane-16 scalar, found by OR-ing the glyphs. A damaged row that held no runs and has no candidate costs nothing more.
  - `TerminalState.kittySnapshotKey` reads the image check, revision and viewport top in one call. Diacritics resolve through a two-level table, not a binary search.
  - The snapshot refill exemption is unnecessary: `SnapshotStorage` keeps an append-only grapheme table and refills fully only when it outgrows its bounds.
- **Payload decoding.** Base64 blocks of 64 bytes decode with NEON in the C target `CKittyBase64` (table lookups, `vld4`/`vst3`). Blocks holding padding, whitespace or other bytes fall back to a 16-byte table path and then to the scalar decoder, which applies Ghostty's rules. The parser's payload scan (NEON, in `CTerminalSIMD`) treats bytes as signed, so one minimum per 64 bytes finds controls and bytes ≥ 0x80 together; written in Swift, its `pointwiseMin` and `any` compiled to calls.
- **Parser layout.** The APC terminator is handled inside the out-of-line bulk scan (`kittyBulk`), and `ESC _` entry inside `apcStep`. `step`'s ESC, CAN and SUB paths are unchanged from the baseline, which keeps OSC-heavy throughput at the baseline (§26.4).
- **D7 side table.** Not built; D7 documents the 63-entry behaviour.
- **KG19 is a port, not a live replay.** The oracle suite asserts the values Ghostty's own tests expect at `167acf0c`, in the style of the other `GhosttyOracle` files. It does not link libghostty.
- **Pull, not push, over SwiftMux.** SwiftMux fetches pixels by request and reply (`imageChunk`), not pushed `imageBlob` events, and needs no separate pending budget. Only the controller's lease path serves image requests; observers get frames without fetchable pixels.
- **Cell size updates.** The RST/1 client sends its cell size in `Attach` and, when it changes afterwards, in a `CellSize` message (§16.3); resize operations carry none. Plain SSH sends the pixel size in every `window-change`.
- **Serials are not kept.** Checkpoints do not preserve pixel serials (§18): a migrated worker assigns new ones, and clients fetch again.
- **Platform defaults for embedders.** Embedders get the platform defaults (320 MB / 128 MB) rather than 10 MB.
- **Plain pixel buffers.** Pixels are Swift arrays, not page-aligned `mmap` buffers. Textures are shared-storage and uploaded by copy, with no mipmaps or downsampling.
- **No 1 KiB control-part cap.** The parser buffers each APC body (base64 included) and decodes it when the command completes, as Ghostty does. The control part is not capped at 1 KiB.

### 26.3 Not built or not measured

- **Reduce Motion on.** The device runs checked that the animation clock matches the device setting, which was off. The held branch is covered on the Mac by the renderer's `reducesMotion` option.

### 26.4 Gate measurements (2026-11-24, Apple Silicon, Release)

| Gate | Result | Status |
|---|---|---|
| Parser throughput ≥ 99% of baseline | Paired `--repeat 5` runs against the parent commit, load average about 1.2: every text workload 99.2–101.2%. `osc-heavy` measured 97.5% until the APC handling moved out of `step` (above); eight interleaved `--repeat 10` rounds then gave 100.5%. | Met |
| Images payload ≥ 95% of Ghostty | `Scripts/compare-ghostty.py` against Ghostty `167acf0c` (zig 0.17.1, ReleaseFast), CPU time: 28.6–29.2 ms against Ghostty's 29.6–30.7 ms, 103.7–105.2%. It was 53% before payload decoding moved to NEON (`CKittyBase64`) and the payload scan stopped making a second pass for bytes ≥ 0x80. | Met |
| 4K transmit ≤ 1.1× Ghostty | The comparison's `transmit-4k` input (3840×2160 RGBA, direct, 4096-byte chunks, deleted after each image, 127 MB): 36.1 ms against Ghostty's 36.4 ms, 100.7% of Ghostty's throughput. | Met |
| 2000×2000 PNG ≤ 25 ms p95 (Mac) | p50 22.98 ms, p95 23.05 ms | Met |
| 2000×2000 PNG ≤ 60 ms p95 (iPad) | iPad Pro 12.9″ (M1): p95 34.6 ms. iPhone 16: p95 26.9 ms. | Met |
| No dropped frames at 120 Hz during a 33 MB upload | Mac: upload frame 4.93 ms, steady 1.14 ms (budget 8.33 ms). iPad Pro (120 Hz): 6.85–7.25 ms upload, 1.7 ms steady. iPhone 16 (60 Hz, budget 16.7 ms): 8.55 ms upload. These are offscreen render times; a hitch trace on the display has not been recorded. | Met |
| Placeholder screen within 10% of ASCII (typing elsewhere) | Interleaved 500-frame batches. Mac: ratio 1.03–1.06 (0.74 against 0.77 µs). iPad Pro: 1.03–1.05. iPhone 16: 1.04. A full repaint of the same screen (not part of the gate) costs 2.3 µs as ASCII, 15.8 µs as placeholder text without an image (grapheme cells) and about 36 µs with the image (down from 76 µs). | Met |
| RST/1 typing with one image | No blob after the first; typing frames at most 927 bytes at 80×24, of which the images section is about 93 bytes | Met |

A later comparison (2026-11-25, after the payload scanners and ASCII stores moved to NEON, README "Swiftty vs Ghostty") measured the Images payload at 26.5 ms against Ghostty's 30.4 ms, 114.9% (113.9–116.2%), and `transmit-4k` at 33.3 ms against 36.4 ms, 109.2%.
