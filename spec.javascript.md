# Swiftty JavaScript automation

**Scope:** embedded JavaScriptCore automation and TypeScript editor support for the macOS terminal.  
**Builds on:** [spec.multiplexer.md](spec.multiplexer.md) (service and pane ownership) and [spec.inbox.md](spec.inbox.md) (OSC 7501 program status).  
**Language:** Swift 6.4 (Swift 6 mode); user configuration is JavaScript.

This document specifies the service-owned automation runtime, its public API,
and native presentation. The workspace, PTY ownership, and client lease rules
remain authoritative in the multiplexer specification. OSC 7501 parsing,
validation, limits, and attention semantics remain authoritative in the inbox
specification.

## 1. Runtime ownership

The persistent `swiftmux-agent` service owns one JavaScriptCore runtime. It
loads `config.js` once, before its first pane starts, and supplies automation
filters and events to its pane runtimes. Closing or reopening a native window
does not reload the script. Applying configuration changes requires restarting
the service; general application configuration reload does not reload JavaScript.

One virtual machine and context run on a private serial queue. JavaScript values
and callbacks stay on that queue; host boundaries carry owned Swift values.
Native UI actions are delivered asynchronously to the macOS client and execute
on the main actor. Neither Node.js nor a package manager is required.

The native client provisions editor assets at launch and subscribes to automation
presentation actions. The service also provisions the assets before loading the
script. Automation protocol operations are feature-gated and preserve existing
ownership and lease checks. Remote clients and observers cannot invoke native
automation key or focus writes; the local native observer can subscribe to UI
updates.

## 2. Configuration and editor support

### 2.1 File layout and ownership

```text
~/.config/swiftty/
├── config.js         # User configuration and automation script
├── jsconfig.json     # Editor language-service configuration
└── swiftty.d.ts       # Host-maintained API declarations
```

Provisioning creates the directory and missing files. Existing `config.js` and
`jsconfig.json` are preserved. The host atomically refreshes `swiftty.d.ts` so
editor declarations match the installed API.

The bundled [starter script](Sources/SwifttyJS/Resources/config.js) demonstrates
stdout filtering, a clock status item, command completion notifications, a split
shortcut, and an optional OSC 7501 listener.

### 2.2 Language-service discovery

The default [jsconfig.json](Sources/SwifttyJS/Resources/jsconfig.json) is:

```json
{
  "compilerOptions": {
    "target": "ES2020",
    "module": "commonjs",
    "allowJs": true,
    "checkJs": true,
    "strict": false
  },
  "include": ["config.js", "swiftty.d.ts"]
}
```

The starter script also begins with an explicit reference, allowing editors to
discover the declarations when opening the file directly:

```js
/// <reference path="./swiftty.d.ts" />
```

The declarations export their interfaces and declare `swiftty` globally.
TypeScript language services provide completion, signature help, JSDoc hover,
and diagnostics in JavaScript without requiring a compilation step.

## 3. Public API

The bundled [swiftty.d.ts](Sources/SwifttyJS/Resources/swiftty.d.ts) defines the
complete public signatures. The root `swiftty` object exposes:

| Member | Purpose |
| --- | --- |
| `filter` | Register stdin and stdout filters. |
| `ui` | Update native badges, tab icons, notifications, and status items. |
| `currentPane` | Obtain a pane handle for the current callback or focused pane. |
| `events` | Register shell, program-status, and keyboard callbacks. |
| `env(key, defaultValue?)` | Read the runtime environment, with an optional fallback. |
| `jsonc.parse(text)` / `jsonc.read(path)` | Parse JSONC data with the shared configuration parser. |

### JSONC data for automation

`config.js` can read separate JSONC data through `swiftty.jsonc.read(path)` or
parse a string through `swiftty.jsonc.parse(text)`. Both reuse `SwifttyConfig`'s
[syntax parser](spec.md#parsing-and-diagnostics), including comments, trailing commas, duplicate-key rejection,
and source-accurate diagnostics. They do not apply the terminal settings schema.
Objects, arrays, and scalar JSON values are supported; JavaScript number
precision applies. Data is passed to `JSON.parse`, never evaluated as code.

Relative paths resolve against the service's configured JavaScript directory
(the directory containing `config.js`), not the shell's current directory.
Absolute paths and `~` are also supported. Reads require regular UTF-8 files and
are bounded to 1 MiB; string input has the same limit. Reads are synchronous, so
load settings during initialization rather than inside stream filters.

Parse failures throw catchable `SyntaxError` values with the original source
path, line and one-based UTF-8 byte column; `line` and `column` are also available
as error properties. File-system errors throw `Error`; non-string arguments
throw `TypeError`. Catching an error does not mark the entire script as failed.

```js
const settings = swiftty.jsonc.read("automation.jsonc");
if (!settings || typeof settings !== "object" || Array.isArray(settings)
    || typeof settings.prefix !== "string") {
  throw new Error("automation.jsonc must contain a string prefix");
}
const prefix = settings.prefix;
swiftty.filter.onStdout(text => prefix + text);
```

For this example, `automation.jsonc` can contain:

```jsonc
{
  // Settings consumed by config.js, not terminal configuration.
  "prefix": "[output] ",
}
```

Automation callbacks remain JavaScript in `config.js`. JSONC does not define a
new declarative automation language or change the service's reload lifecycle.

### 3.1 Stream filters

`filter.onStdout(callback)` and `filter.onStdin(callback)` receive string chunks.
Returning a string replaces the chunk; returning `null` or `undefined` passes it
through unchanged.

Stdout filtering occurs before terminal parsing, including parsing of OSC events.
Stdin filtering occurs after input encoding. Streamed paste filters the payload
while preserving framing and sanitization. Exceptions, invalid return values,
invalid or partial UTF-8, and replacements exceeding host capacity preserve the
original bytes.

Chunks are transport boundaries, not lines or complete tokens. A regular
expression applied to one chunk does not guarantee matching text split across
multiple chunks.

### 3.2 Pane handles

| Member | Behavior |
| --- | --- |
| `id` | Read-only service pane identity. |
| `write(text)` | Submit text or ANSI sequences through the managed pane write path. |
| `split("horizontal")` | Create a top/bottom split and return its pane handle. |
| `split("vertical")` | Create a left/right split and return its pane handle. |
| `close()` | Request closure of the represented pane. |

`currentPane` is bound to the source pane during stream, event, and shortcut
callbacks, and otherwise resolves to the focused pane. A retained handle keeps
its identity when focus changes.

A split reserves a real service pane identity before asynchronous launch. Actions
for the new pane queue until launch completes. Failed launches discard pending
actions and log an error. Pane operations use service admission and write queues;
they do not expose or bypass PTY descriptor ownership.

```js
swiftty.events.bindKey("cmd+shift+d", () => {
  const pane = swiftty.currentPane.split("horizontal");
  pane.write("top\n");
});
```

### 3.3 Native presentation

| Method | Behavior |
| --- | --- |
| `ui.setBadge(text)` | Set dock badge text; an empty string clears it. |
| `ui.setTabIcon(text)` | Replace the source tab's title icon or text; an empty string clears it. |
| `ui.notify(title, message)` | Request a native macOS notification. |
| `ui.registerStatusItem(id, options)` | Register or replace a status item by identity. |
| `ui.refreshStatusItem(id)` | Request a render of an existing status item. |

A tab icon belongs to the tab and persists across pane splits and focus changes.
Updating it replaces the previous icon rather than accumulating title prefixes.
Packaged applications use UserNotifications authorization and foreground banners;
command-line development hosts log notifications.

Status items specify `align: "left" | "right"`, a `render` callback, and an optional
positive finite `refreshInterval` in seconds. Each item renders initially. Without
an interval, subsequent rendering requires manual refresh. An interval requests
polling, not an exact delivery deadline. Registering an existing identity replaces
its callback, alignment, and polling options without accumulating timers.

The renderer returns either a string or `{ text, color?, backgroundColor? }`.
Colors accept supported basic names, hexadecimal strings, or an object with
`red`, `green`, `blue`, and optional `alpha` channels in the range 0–1. Alpha
defaults to 1. Native status items appear on the requested side of the status bar.

## 4. Lifecycle events and shortcuts

### 4.1 Shell events

`events.onCommandFinished(callback)` observes OSC 133 D and supplies
`(command, exitCode)`. Command text is captured from the OSC 133 B/C input region,
or is empty when unavailable. An absent or invalid exit status is `-1`, never an
assumed successful exit.

`events.onDirectoryChanged(callback)` supplies the path from validated OSC 7
file URLs.

### 4.2 Keyboard shortcuts

`events.bindKey(shortcut, callback)` registers an automation shortcut, such as
`"cmd+k"` or `"cmd+shift+d"`. The native client dispatches matching shortcuts
through the service, with `currentPane` scoped to their source pane.

### 4.3 Callback failures

Evaluation and callback errors are logged. One throwing event listener does not
prevent other listeners from receiving the event. Filter failures preserve the
original input as specified in §3.1.

## 5. OSC 7501 program-status events

### 5.1 Event source

`events.onStatusChanged(callback)` observes the same validated OSC 7501
program-status journal used by the attention inbox, after stdout filtering and
terminal parsing. It does not parse status independently or mutate the inbox.
OSC 7501 remains status data, not an executable command protocol.

Every change includes the source `paneId` and `terminalEpoch`. Within the
callback, `swiftty.currentPane` is the source pane even if another pane has
keyboard focus. Retaining that handle retains its identity.

### 5.2 Payload types

```ts
interface ProgramStatus {
  id: string;
  state: "idle" | "working" | "done" | "blocked" | "error";
  kind?: "permission" | "question" | "auth";
  progress?: number;
  app?: string;
  title?: string;
  message?: string;
  revision: string;
}

interface StatusChangeSource {
  paneId: string;
  terminalEpoch: string;
}

type ProgramStatusChange = StatusChangeSource & (
  | { type: "report"; record: ProgramStatus }
  | { type: "removed"; ids: string[] }
  | { type: "reset" }
  | { type: "sync"; records: ProgramStatus[] }
);
```

The empty record id identifies the pane's root record. `revision` is a decimal
UInt64 string, preserving precision in JavaScript. Program-supplied strings are
plain data and must never be evaluated as JavaScript or interpreted as markup.

### 5.3 Change semantics and ordering

| Change | Required consumer behavior |
| --- | --- |
| `report` | Replace the whole record. Omitted optional fields do not inherit previous values. |
| `removed` | Remove the exact listed ids. Hierarchical clears include each removed descendant. |
| `reset` | Discard every cached record for the pane. The epoch is the new identity created by terminal reset (RIS). |
| `sync` | Replace the entire cached set for the pane/epoch with `records`, which may be empty. |

Removals cover clear, eviction, prompt cleanup, and process exit. Clearing a
nonexistent id emits no change. A `sync` recovers from bounded journal overflow;
intermediate changes are not guaranteed after overflow. A retained reset precedes
its sync.

Changes arrive in journal order per pane. Status batches publish at the terminal
read/publish boundary. No global ordering with keyboard events, other panes, or
OSC 133 callbacks is promised. Registering a callback observes future changes;
it does not replay historical attention occurrences. Support queries and
malformed or rejected OSC reports emit no status callbacks.

### 5.4 Consumer example

This listener maintains the observed status set and requests attention for a
blocked report:

```js
const statuses = new Map();
swiftty.events.onStatusChanged(change => {
  const key = change.paneId;
  let records = statuses.get(key) || new Map();
  if (change.type === "reset") records = new Map();
  if (change.type === "sync") {
    records = new Map(change.records.map(record => [record.id, record]));
  }
  if (change.type === "report") {
    records.set(change.record.id, change.record);
    if (change.record.state === "blocked") {
      swiftty.ui.setTabIcon("⏳");
      swiftty.ui.notify(change.record.title || "Program needs attention",
        change.record.message || change.record.kind || "Waiting for input");
    }
  }
  if (change.type === "removed") {
    for (const id of change.ids) records.delete(id);
  }
  statuses.set(key, records);
});
```

## 6. Source layout and packaging

| Location | Responsibility |
| --- | --- |
| [Sources/SwifttyJS](Sources/SwifttyJS) | Serialized JavaScriptCore runtime, host values, configuration provisioning, and bundled editor assets. |
| [MuxService+JavaScript.swift](Sources/SwiftMuxService/MuxService+JavaScript.swift) | Service lifecycle, pane operations, event delivery, and presentation routing. |
| [MuxWorkspaceController+JavaScript.swift](Sources/Swiftty/MuxWorkspaceController+JavaScript.swift) | Native client integration and UI actions. |
| [JavaScriptStatusBar.swift](Sources/Swiftty/JavaScriptStatusBar.swift) | Native status-item presentation. |
| [package-swiftmux.sh](Scripts/package-swiftmux.sh) | Include `swiftty_SwifttyJS.bundle` in the packaged application. |

The packaged service must resolve the same runtime and editor resources used by
development builds. No external JavaScript toolchain is required at runtime.

## 7. Acceptance criteria

### 7.1 Provisioning and editor support

- Launch creates all three configuration files and preserves existing user edits
  to `config.js` and `jsconfig.json` while refreshing declarations.
- TypeScript language services complete `swiftty` members, show API signatures
  and JSDoc, and reject nonexistent members.
- `onStatusChanged` completion and discriminated-union narrowing work for every
  change type; nonexistent status fields produce diagnostics.

### 7.2 Runtime and native integration

- Configuration evaluates once before the service's first pane starts. Reopening
  the native client does not duplicate registrations.
- Filters transform stdin/stdout and preserve bytes on invalid input or failure.
- A custom shortcut invokes its callback without locking the native UI or
  crashing the PTY read loop.
- Split handles identify real panes, queued writes reach the child after launch,
  and failed launches discard pending work.
- Badges, tab icons, notifications, and status items reach native presentation;
  tab icons persist through splitting and focus changes.
- Packaged builds include the resource bundle and can provision and evaluate the
  starter script from an isolated configuration directory.

### 7.3 OSC 7501 integration

- Send working → blocked → done reports through a real PTY. Verify callback
  payloads, whole-record replacement, exact revision strings, and source pane
  identity.
- Send hierarchical clear, prompt cleanup, capacity eviction, process exit, and
  RIS. Verify removal sets, epoch changes, and reset behavior without changing
  inbox results.
- Overflow the journal and verify authoritative `sync` delivery, including an
  empty snapshot, so consumers discard stale records.
- Send support queries and malformed or oversized reports; verify no callbacks.
- Register multiple listeners, including one that throws; verify later listeners
  still receive the changes.
