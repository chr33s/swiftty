# Swiftty OSC 7501 Program Status Support

**Repository:** `chr33s/swiftty`  
**Status:** Proposed  
**Protocol:** OSC 7501 Program Status  
**Scope:** Terminal-core support. UI, notifications, tab aggregation, and tmux topology-specific routing remain embedder responsibilities.

## 1. Objective

Add first-class OSC 7501 support to Swiftty. Swiftty should parse and validate reports, own their protocol-defined state, apply lifecycle rules, answer support probes, and expose typed immutable state to embedders.

```text
program → OSC 7501 → Swiftty parser → ProgramStatusStore → typed snapshot/event → embedder
```

Swiftty owns **what OSC 7501 means**. Applications such as `chr33s/shell` own **how status is presented and how terminal replies are transported through app-specific topologies such as tmux control mode**.

## 2. Goals

Swiftty MUST:

1. Recognize OSC 7501 support queries and reports across arbitrary input chunk boundaries.
2. Enforce protocol-specific framing, byte limits, field validation, base64 decoding, and UTF-8 safety.
3. Model `idle`, `working`, `done`, `blocked`, and `error`; treat `clear` as a mutation rather than retained state.
4. Maintain one record per `id`, including the root record.
5. Implement whole-record replacement and hierarchical clear semantics.
6. Bound record storage and deterministically evict old records.
7. Apply lifecycle cleanup on semantic prompt start, full terminal reset, and process/session exit.
8. Answer `OSC 7501 ; ?` only when OSC 7501 consumption is enabled.
9. Expose generated responses as **terminal replies**, distinguishable from keyboard/paste input.
10. Expose immutable typed snapshots/events independent of rendering-surface lifetime.
11. Be testable entirely in Swiftty without application UI.

## 3. Non-goals

Swiftty MUST NOT implement pane/tab badges, notifications, acknowledgment UX, permission approval, tmux pane addressing, application priority rules, or persistence across a newly created terminal process.

OSC 7501 MUST remain distinct from OSC 9;4 progress reporting.

## 4. Ownership and data flow

The authoritative status store MUST live at terminal/session lifetime, not `Surface` lifetime. A session can continue receiving output while no renderer is attached; those updates must survive surface teardown/recreation.

```text
OSC bytes
  ↓
incremental OSC parser
  ↓
validated ProgramStatusCommand
  ↓
TerminalState applies mutation in stream order
  ↓
ProgramStatusStore
  ↓
ProgramStatusSnapshot
```

Consumer notification occurs only after mutation completes.

## 5. Public types

Recommended API shape:

```swift
public enum ProgramStatusState: Sendable, Equatable {
    case idle
    case working
    case done
    case blocked
    case error
}

public enum ProgramStatusBlockedKind: Sendable, Equatable {
    case permission
    case question
    case auth
}

public struct ProgramStatusRecord: Sendable, Equatable, Identifiable {
    public let id: String              // empty string = root
    public let state: ProgramStatusState
    public let kind: ProgramStatusBlockedKind?
    public let progress: UInt8?        // 0...100
    public let app: String?
    public let title: String?
    public let message: String?
    public let revision: UInt64
}

public struct ProgramStatusSnapshot: Sendable, Equatable {
    public let records: [ProgramStatusRecord]
    public let revision: UInt64
}
```

Unknown optional `kind` values map to `nil`. `clear` never becomes a stored record.

Snapshots MUST have deterministic ordering; update order is recommended.

## 6. Parser requirements

Recognize:

```text
ESC ] 7501 ; ? ST
ESC ] 7501 ; key=value:key=value... ST
```

Support BEL and ST terminators consistently with other OSC handling.

No mutation occurs until a complete sequence has been terminated and validated.

### Dedicated limits

OSC 7501 MUST use a protocol-specific bounded capture path rather than relying only on Swiftty's generic OSC limit.

Recommended limits matching the current protocol/reference implementation:

| Field | Limit |
|---|---:|
| Entire sequence | 4096 bytes |
| Key | 16 bytes |
| `id` | 128 bytes |
| `id` segment | 32 bytes |
| `id` depth | 8 |
| `app` | 32 bytes |
| encoded `title` | 256 bytes |
| decoded `title` | 192 bytes |
| encoded `msg` | 2732 bytes |
| decoded `msg` | 2048 bytes |

An over-limit report MUST be discarded in full. Never apply a truncated prefix.

### States

Recognized, case-sensitive values:

```text
idle
working
done
blocked
error
clear
```

Missing or unknown state discards the report.

### IDs

Absent `id` addresses the root. Non-root IDs are slash-separated valid name segments. Empty segments are invalid:

```text
/
a/
/a
a//b
```

Invalid IDs discard the entire report. This is especially important for `clear`: an invalid child ID must never degrade into a root clear.

### Progress and kind

`progress` is read only for `working` and `blocked`; valid values are decimal integers 0...100. Invalid/out-of-range progress is absent unless the protocol revision requires report rejection.

`kind` is read only for `blocked`. Known values are `permission`, `question`, and `auth`; unknown values are absent.

### Human-readable text

`title` and `msg` are base64-encoded UTF-8. Public API exposes decoded strings only.

Decoded text MUST be valid UTF-8, within byte limits, and free of terminal control characters. It remains untrusted program-provided text and MUST NOT be interpreted as markup.

Repeated recognized keys use the last applicable value, subject to whole-report validation rules. Unknown/individually malformed pairs may be ignored where the protocol permits.

## 7. Store semantics

### Whole-record replacement

Each non-clear report completely replaces its addressed record.

```text
state=working:id=build:app=cargo:progress=20
state=working:id=build:progress=30
```

After the second report, `app == nil`. Omitted fields do not inherit previous values.

### Hierarchical clear

`state=clear` without `id` clears all records.

`state=clear:id=build` removes `build`, `build/test`, and `build/test/unit`, but not `builder` or `other/build`.

Descendant matching MUST be exact ID or prefix followed by `/`.

A child does not require a stored parent.

### Capacity

Retain at least 64 records and impose a finite maximum; 256 is recommended. When insertion exceeds capacity, evict the least recently updated record. Updating an existing record makes it newest without increasing count.

### Revisions

Every observable mutation increments a monotonically increasing store revision. Invalid reports do not increment it.

## 8. Lifecycle semantics

Lifecycle operations MUST execute in the same serialized stream order as report handling.

### Semantic prompt start

On a genuine new-prompt event (OSC 133 A or existing equivalent):

- remove `working`;
- remove `blocked`;
- `idle` may also be removed;
- preserve `done` and `error` for embedder acknowledgment unless the protocol requires otherwise.

Prompt redraw markers MUST NOT accidentally act as new-command boundaries.

### Full reset

RIS/full reset clears all records before reset completion is published to consumers. Soft reset does not clear status unless protocol semantics require it.

### Process/session exit

The session layer needs an explicit status-cleanup hook for process exit when no final prompt marker exists.

On exit, transient `working`/`blocked` state is removed. Swiftty MUST NOT invent `done` or `error` from an exit code. Existing `done`/`error` records may remain for application acknowledgment.

## 9. Support query and reply provenance

When OSC 7501 consumption is enabled, receiving:

```text
ESC ] 7501 ; ? ST
```

generates the corresponding support reply with the matching terminator. When consumption is disabled, no reply is sent.

The response is a **terminal-generated reply**, not user input. Preserve that distinction in the public/session API, for example:

```swift
public var onTerminalReply: (@Sendable (Data) -> Void)?
```

or an equivalent typed outbound event.

This is required so embedders can route a reply appropriately. For example, a tmux control-mode embedder may need to address the reply to the originating pane rather than write it to the outer control connection.

Ordinary status reports generate no reply.

## 10. Consumer API

Recommended capability:

```swift
public var programStatusSnapshot: ProgramStatusSnapshot { get }

public var onProgramStatusChange:
    (@Sendable (ProgramStatusSnapshot) -> Void)?
```

An equivalent typed action/event stream is acceptable.

Requirements:

- publication happens after mutation;
- snapshots are immutable `Sendable` values;
- parser scratch strings are copied before publication;
- newly attached consumers can immediately retrieve current state;
- updates publish even when no terminal cells changed;
- status exists without an attached `Surface`.

Presentation notifications may be coalesced, but store mutations MUST NOT be skipped or reordered.

## 11. Concurrency

Parser and store mutation run on the existing serialized terminal/session execution context. Avoid a separate locking model unless required.

UI/main-actor dispatch remains the embedder's responsibility.

## 12. Security

Treat every report as untrusted terminal input. Required protections include:

- bounded framing and fields;
- no producer-controlled unbounded allocation;
- safe base64 decoding;
- UTF-8 validation;
- control-character rejection in display text;
- no markup interpretation;
- no execution/approval behavior;
- no invalid-ID fallback to root;
- bounded retained records;
- deterministic reset cleanup.

Document whether embedders must additionally strip invisible directional-formatting characters before displaying `title`/`message` in trusted UI.

## 13. Suggested source layout

Exact paths should follow current Swiftty organization:

```text
Sources/SwifttyCore/Terminal/
  TerminalState+OSC.swift
  TerminalState+Shell.swift
  ProgramStatus.swift          # new
  ProgramStatusStore.swift     # new or combined
  Parser.swift

Sources/SwifttyCore/Session/
  TerminalSession.swift

Tests/
  ProgramStatusParserTests.swift
  ProgramStatusStoreTests.swift
  ProgramStatusLifecycleTests.swift
  ProgramStatusSessionTests.swift
```

Prefer adding a typed OSC command to the existing parser/state-machine architecture rather than parsing directly into application callbacks.

## 14. Tests

### Parser

Cover BEL/ST queries, minimal reports, every state/kind, all fields, split writes, multiple sequences per write, repeated keys, unknown keys, malformed pairs, missing/unknown state, valid/invalid IDs, maximum depth/lengths, sequence limit ±1 byte, progress edge cases, padded/unpadded base64, invalid base64, invalid UTF-8, control characters, and Unicode.

### Store

Cover root/child insertion, child without parent, whole replacement, disappearance of omitted fields, exact/descendant/root clear, similarly prefixed IDs, ordering, capacity eviction, and revisions.

### Lifecycle

Cover exact stream ordering, including:

```text
working report
prompt-start
done report
```

Also verify prompt cleanup, preservation of completed/error state, full reset, soft reset, process exit, and operation without a `Surface`.

### Replies

Verify:

- no reply when support is disabled;
- correct reply when enabled;
- BEL query → BEL reply;
- ST query → ST reply;
- reports produce no reply;
- reply carries terminal-reply provenance;
- replies work without a rendering surface.

### Regression

Existing OSC parsing, OSC 9;4 progress, OSC 133 semantic prompts, terminal reset, and terminal-response tests must continue to pass.

## 15. Acceptance criteria

- [ ] OSC 7501 query/report parsing is incremental and bounded.
- [ ] Swiftty claims support only when a consumer is enabled.
- [ ] Query response is surfaced as terminal-reply provenance.
- [ ] Valid reports produce typed records.
- [ ] Invalid reports cannot partially mutate state.
- [ ] Reports replace records rather than merge fields.
- [ ] Hierarchical clear is segment-correct.
- [ ] Root clear removes all records.
- [ ] Record storage is bounded.
- [ ] Prompt-start removes transient working/blocked state.
- [ ] Full reset clears all status.
- [ ] Session exit applies transient cleanup.
- [ ] Done/error can remain for embedder acknowledgment.
- [ ] State survives temporary absence of a rendering surface.
- [ ] A new consumer can retrieve the current snapshot.
- [ ] Updates are observable without terminal-cell damage.
- [ ] Existing OSC/progress/prompt/reset behavior does not regress.

## 16. Embedder contract

After this lands, an embedder such as `chr33s/shell` should only need to:

1. enable/subscribe to OSC 7501;
2. read `ProgramStatusSnapshot`;
3. render pane/tab/application presentation;
4. route `terminalReply` to the correct transport;
5. implement acknowledgment and notification policy.

For native `tmux -CC`, pane-specific reply routing remains outside Swiftty core. Swiftty's responsibility ends at producing the correct typed terminal reply for the terminal instance that received the query.

## 17. Recommended implementation order

1. Add typed protocol model and parser tests.
2. Implement bounded OSC 7501 parser.
3. Implement `ProgramStatusStore` and unit tests.
4. Integrate prompt/reset lifecycle.
5. Add terminal-reply query support.
6. Expose immutable snapshot/event API.
7. Add session-exit cleanup.
8. Run existing terminal/OSC regression suite.
9. Integrate from `chr33s/shell` in a separate dependent change.

## 18. Definition of done

Swiftty can be considered OSC 7501-capable when a producer can probe support, send valid status reports, update/clear hierarchical records, cross prompt/reset/session lifecycle boundaries correctly, and an embedder can consume current typed state and transport terminal replies without parsing or understanding OSC 7501 itself.
