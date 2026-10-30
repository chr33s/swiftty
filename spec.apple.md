# Swiftty: Apple platform and Swift design requirements

**Status:** Normative. Amends the Apple Platform Compatibility
Specification v1.0 clauses named below (design review of 2026-10-30,
findings A01–A10, against `6a3831ca`), gives the reason for each
amendment, and records how this repository satisfies them. Where this
document and an older clause disagree, this document wins.

The review found the architecture a good fit for Swift and Apple
platforms. None of the amendments requires replacing the terminal engine,
rewriting the UI in SwiftUI, or putting an actor around every operation.
They separate platform requirements, Human Interface Guidelines, Swift
safety obligations and product choices; a missing clause was not taken as
evidence of a bug.

Clause IDs (CFG-, SESSION-, ARCH-, UI-, MAC-, DIST-, TXT-, PERF-, SAFE-,
Appendix A) refer to that specification. "Implemented" means the code
and tests named exist in this tree; it does not mean device, accessibility
session or App Review evidence has been collected.

## A01 — Native settings (CFG-01)

**Rationale.** Opening the config file was the whole settings experience,
weaker than the macOS convention of an app-owned window behind App →
Settings and ⌘,. This is a UX expectation, not an App Store rule; the file
format stays authoritative. ([HIG: Settings][SETTINGS],
[Settings interface][SETTINGS-API])

> Native macOS MUST provide an app-owned Settings window for common
> preferences and configuration diagnostics, accessible through App →
> Settings and Command–Comma. Full-client platforms MUST expose their
> common preferences through an appropriate native settings interface.
> Advanced configuration remains available through an explicit Edit
> Configuration or Import Configuration action where the platform supports
> it. The native interface and text configuration MUST use the same typed
> configuration model and documented precedence. A GUI for every supported
> option is not required.

**Acceptance:** menu/shortcut behavior, keyboard and VoiceOver operation,
invalid-config diagnostics, changes reflected through the same model, and
no silent overwriting of unrelated advanced options.

**Implementation.**

- swiftty › Settings… (⌘,) opens `SettingsWindowController`
  (`Sources/Swiftty/SettingsWindow.swift`): font family and size, theme,
  background opacity, cursor style and blink, copy on select, hide pointer
  while typing, the file path, the configuration's problems, and Edit
  Configuration File… (⌥⌘,, also in the menu). Reload Configuration stays
  on ⇧⌘,. Controls are standard SwiftUI `Form` controls, so VoiceOver and
  Full Keyboard Access work without custom handling.
- Each change goes through `ConfigurationEditor`
  (`Sources/SwifttyCore/Config/ConfigurationEditor.swift`): it validates the
  value with `Configuration.set`, replaces only that key's line(s) in the
  root file, keeps comments, includes, key bindings and unknown keys byte
  for byte, writes atomically to a symlink's target, then the app reloads
  the file. The window shows the reloaded `Configuration`, so it and the
  file share one model and one precedence; when an included file overrides
  a saved value the window says so.
- Only single-line scalar keys are editable (`ConfigurationEditor.editableKeys`);
  repeatable keys (`keybind`, `palette`, `config-file`, …) stay in the file.
- The direct clients keep their existing native `SettingsView`
  (`Apps/Shared/SettingsView.swift`).
- Tests: `ConfigurationEditorTests`, `SettingsModelTests`.

## A02 — Scene lifecycle (SESSION-03, replacement)

**Rationale.** "Unavailable or backgrounded" was too broad: Apple
separates temporary inactivity (permission alerts, Control Center) from
backgrounding, and scene state from app state. The code already ignored
`.inactive`; the clause preserves that rather than fixing a demonstrated
bug, and keeps UI interruptions from being treated as connection failures.
([sceneWillResignActive][INACTIVE], [ScenePhase][SCENEPHASE])

> Lifecycle decisions MUST distinguish scene inactivity, scene backgrounding
> and application suspension. Temporary inactivity pauses input and
> unnecessary presentation work without detaching solely because a system
> interruption occurred. Backgrounding suspends or detaches resources owned
> exclusively by that scene through the bounded cleanup path. A scene
> transition MUST NOT close a shared connection or release a session still
> required by another eligible foreground scene. App-level cleanup uses
> aggregate scene state. Mac window focus changes remain separate from sleep
> and termination. Recovery validates the current screen, attachment and
> authorization before admitting input.

**Acceptance:** system permission alert, Control Center, switching focus
between windows, closing one of two windows using shared state, last-scene
backgrounding, sleep and foreground recovery.

**Implementation.** `ScenePhases` (`Apps/Shared/ScenePhases.swift`) combines
the phases of every window sharing an owner as SwiftUI combines an app's
phase (active › inactive › background). A roaming terminal controller
belongs to its screen model, which several iPad/visionOS windows can show,
so `RoamingTerminalController.scenePhaseChanged(_:scene:)` detaches only
when the combined phase reaches background and ignores `.inactive`.
`RoamingAppModel.scenePhaseChanged(_:scene:)` drives foreground-only sync
and SFTP suspension from the combined phase too. Mac Catalyst still ignores
window focus; sleep and wake go through `SystemPowerMonitor`. Tests:
`ScenePhasesTests`.

## A03 — Keyboard context (CFG-03, UI-01)

**Rationale.** Key sequences are a legitimate terminal feature but must not
capture typing in Find, authentication prompts, connection fields or
settings. UIKit normally lets text input win over app key commands; an
override needs justification. No invented timeout or Command-key
substitution is required. ([wantsPriorityOverSystemBehavior][KEY-PRIORITY],
[HIG: Keyboards][KEYBOARDS])

> Terminal key sequences and key-table state MUST be scoped to the focused
> terminal and its attachment. Native text fields retain their normal
> editing, focus and shortcut behavior. System input-method composition
> takes precedence over terminal sequence matching; provisional marked text
> MUST NOT reach the shell, and committed text is admitted exactly once.
> Moving focus outside the originating terminal cancels its pending sequence
> without replaying buffered keys into a different responder. Global
> shortcuts remain limited to explicitly global-safe actions. Standard app
> commands remain available by default.

The specified no-timeout sequence behavior is retained while the terminal
remains in its valid input context.

**Acceptance:** start a sequence, move to Find or an authentication prompt,
then type; repeat with IME marked text, a keyboard-layout switch and a
revoked attachment; no buffered bytes reach the wrong destination.

**Implementation.** Sequences (`a>b`) and `global:` bindings are rejected
at parse time (`Keybindings.apply`), so no pending sequence state exists.
macOS bindings run only while the terminal is first responder and not
composing (`TerminalView`/`MuxPaneView.performKeyEquivalent`, `keyDown`).
On iOS, `TerminalUIView.keyCommands` (which carry
`wantsPriorityOverSystemBehavior`) are offered only while the terminal
itself is first responder; while focus is in its own Find field only
search navigation (`navigate_search`, `end_search`) remains, so the field
keeps its editing shortcuts. Key presses during composition belong to the
input method on both platforms; held keys are released on focus loss.

## A04 — Isolation, transfer and suspension (ARCH-01, Appendix A, CFG-03)

**Rationale.** One serial session owner is sound, but Swift 6 checking does
not prove `@unchecked Sendable` types (`TerminalSession`, `RenderSnapshot`)
safe; their invariants must be maintained. Converting everything to actors
is not a remedy: actor work interleaves across suspension and is not FIFO,
so ordering stays an explicit contract. Queues, actors and executors remain
available; no per-byte tasks, locks or hops. ([Sendable][SENDABLE],
[SE-0306][ACTORS])

> Each session MUST have one explicit isolation domain. UI state remains
> main-actor isolated. Values crossing isolation boundaries MUST use checked
> Sendable conformance, valid ownership transfer, or a documented manually
> verified synchronization contract. Every unchecked Sendable conformance
> MUST identify its mutable state, synchronization or immutability
> invariant, and backing-storage lifetime. Parser/grid mutation occurs in
> synchronous batches. Input ordering MUST NOT depend on actor scheduling
> order. State and authorization assumptions are revalidated after
> suspension.

> After awaiting an action, validate the expected post-action target,
> attachment epoch and lease generation before dispatching the next action.
> Intended target changes caused by the chain are allowed; unrelated
> replacement, cancellation or lost authority stops the remaining chain.

**Acceptance:** lease revoked during an awaited action, target replaced
while a new window opens, concurrent snapshot use during pool maintenance,
and cancellation between chained operations.

**Implementation.** Every `@unchecked Sendable` in `Sources/` and `Apps/`
carries a `/// Sendable:` paragraph stating its state, synchronization and
storage lifetime; `Scripts/check-unchecked-sendable.sh` enforces this in
CI. Action chains do not exist yet (one binding runs one action); the
chain rule applies when they are added.

## A05 — Accessibility preferences (UI-01, UI-02, CFG-04)

**Rationale.** Custom rendering does not inherit native text-view
accessibility, so acceptance names larger text, contrast, reduced
motion/transparency and keyboard access explicitly. The grid need not
become one text view per cell; a custom enlargement mechanism is fine if
the result is usable. ([HIG: Accessibility][ACCESSIBILITY],
[Testing system features][ACCESSIBILITY-TEST], [Larger text][LARGER-TEXT])

> App chrome and companion text MUST support applicable system text-size
> settings without clipping essential controls. Terminal content MUST
> provide usable text enlargement with defined grid, resize and reflow
> behavior. The terminal accessibility representation MUST expose readable
> content, selection and navigable structure, rather than only a label for
> the canvas. Controls MUST remain usable with VoiceOver and Full Keyboard
> Access. Nonessential animation, including animated shaders, MUST offer a
> reduced-motion presentation. Custom translucent surfaces MUST provide an
> appropriate reduced-transparency treatment, and essential UI must remain
> legible with increased contrast.

**Acceptance:** largest applicable text sizes, VoiceOver reading/selection,
Full Keyboard Access, increased contrast, reduced motion and reduced
transparency, for both app controls and the custom terminal surface.

**Implementation.** `DisplayAccommodations`
(`Sources/SwifttyCore/Config/DisplayAccommodations.swift`) is read from
`NSWorkspace` (`SwifttyMac`) or `UIAccessibility` (`SwifttyMobile`) and
applied with `Configuration.accommodating(_:)`, never written to the file:

- Reduce Motion: `RenderOptions.reducesMotion` freezes a custom shader's
  `time` at zero and stops the host's continuous frame driving.
- Reduce Transparency: the terminal background is opaque and unblurred.
- Increase Contrast / Darken Colors: `minimum-contrast` is at least 4.5.

`TerminalView`, `TerminalUIView` and the SwiftMux app re-apply the stored
configuration when a preference changes. System glass surfaces
(`GlassPanel.swift`) already follow these preferences. Dynamic Type sizing
and the terminal accessibility text model are unchanged. Tests:
`DisplayAccommodationTests`.

## A06 — App Intents (MAC-02)

**Rationale.** A shared typed action executor for menus, AppleScript and
intents is sound, but intents may run in the background or while locked,
so foreground UI cannot be assumed. The exact policy per intent is a
product decision. ([supportedModes][INTENT-MODES],
[IntentAuthenticationPolicy][INTENT-AUTH])

> Each App Intent MUST declare its supported execution modes and
> authentication policy. Operations exposing protected session information
> or mutating session state MUST use the documented authenticated policy
> selected for that operation. UI actions MUST execute on the main actor in
> an available foreground context, or return a supported
> continuation/error without performing the action. Background actions MUST
> identify their target explicitly rather than relying on an ambient
> focused window. Intent confirmation uses the platform's confirmation
> mechanism where applicable. Authentication and confirmation do not
> replace SSH trust, capability checks or writer-lease validation.

For operations that depend on locally protected credentials, choose a
policy consistent with that protection rather than weakening Keychain
accessibility to make background execution succeed.

**Acceptance:** invocation from Shortcuts while the app is backgrounded,
locked-device policy, missing/stale target, unavailable foreground
continuation, cancellation and takeover refusal.

**Status.** No App Intents ship today; this clause gates their addition.

## A07 — Distribution updates (MAC-03, DIST-01, replacement)

**Rationale.** "Do not require a custom updater in store clients" was too
weak: App Review guideline 2.4.5(vii) requires App Store updates. This
concerned wording, not a prohibited updater in the shipped app.
([App Review Guidelines][STORE-RULES])

> Developer ID builds MAY implement the specified update discovery and
> staging flow. App Store builds MUST receive application updates through
> the App Store and MUST NOT enable the custom application updater.
> Packaging, entitlements and update acceptance MUST be defined separately
> for each distribution profile.

Apple-only targeting does not imply every macOS build uses the App Sandbox.

**Status.** The native app is distributed with Developer ID only
(`Scripts/package-swiftmux.sh`, `Scripts/notarize.sh`); its service
staging (`MuxUpdate.swift`) is the permitted Developer ID flow. An App
Store profile must be defined, without that updater, before one ships.

## A08 — Memory and performance (TXT-04, PERF-01, Appendix A)

**Rationale.** Compact cells, borrowing and low allocation match where Swift
is heading (spans, inline storage, noncopyable containers). The clauses
stop an internal optimization being read as a wire/persistence format or
an app-wide ban on ordinary Swift types: one bounded hyperlink record is
not an allocation per printed cell. Glyph-at-offset-zero is relied on, so
the layout is tested, not stylistic. ([Swift 6.4][SWIFT-SYSTEMS],
[MemoryLayout][LAYOUT], [WWDC24 Swift performance][PERFORMANCE])

> Preserve the current 16-byte cell stride on supported toolchains and
> targets. Verify size, stride, alignment and field offsets used by
> optimized code. Native cell representation is an internal storage
> contract, not the SMX/RST wire format or an unversioned persistence
> format. Side-table references remain typed, generation-safe and bounded.
> A representation change requires measured total-memory/cache/latency
> evidence and an explicit contract update.

> Keep unsafe-pointer construction and lifetime overrides inside a small
> audited storage layer. Borrowed views MUST remain within their
> backing-storage lifetime and mutation/reuse contract. Snapshot storage
> remains immutable while referenced. Experimental compiler features and
> optimizer workarounds MUST remain tied to the pinned toolchain and
> covered by optimized-build regression tests.

> Zero-allocation gates apply only to named, prewarmed parser and ordinary
> cell-update paths at fixed capacity. Startup, resize, new metadata,
> connection setup and UI construction use separate bounded budgets.
> Normal Swift collections, reference types and concurrency abstractions
> remain appropriate outside measured hot paths. Optimize from observed
> latency, memory and energy results.

**Implementation.** `GridInvariantTests` asserts `Cell` size 16, stride 16,
alignment 4 and the offsets of `glyph` (0, relied on by
`TerminalState.storeASCII`), `attributes` (4) and `width` (15).

## A09 — Service authorization and pasteboard (SESSION-01, DIST-01, SAFE-01)

**Rationale.** The existing per-user `SMAppService.agent` model with
`requiresApproval` handling is kept; registration stays subject to user
authorization and revocation. "Without root" is a Swiftty constraint, not
an Apple one. An OSC clipboard grant does not exempt Swiftty from the OS
pasteboard privacy layer, which distinguishes user paste from programmatic
reads. ([SMAppService.register][SERVICE], [UIPasteControl][PASTE],
[NSPasteboard.AccessBehavior][MAC-PASTE])

> Preserve the bundled per-user SMAppService registration model and run the
> helper without root privileges. Explain why the helper persists, respect
> disabled/revoked/unregistered states, and provide the normal removal path.
> Reconnection MUST NOT start an unmanaged substitute to bypass
> authorization. Session retention applies while the service is authorized
> and available; it does not override explicit disablement, logout,
> shutdown or operating-system termination. Helper registration MUST NOT
> implicitly register the main UI app to open at login.

> Clipboard operations MUST satisfy both Swiftty's capability/consent
> policy and platform pasteboard privacy behavior. User paste UI SHOULD use
> system paste commands or controls. Availability checks MUST avoid reading
> clipboard contents merely to enable a control. Denied access MUST fail
> cleanly without leaking contents or leaving a protocol request pending
> indefinitely.

**Status.** Satisfied by existing code: only `SMAppService.agent` is
registered (never `.mainApp`), `requiresApproval` is surfaced
(`MuxWorkspaceController+Connection.swift`), paste validation uses
`UIPasteboard.hasStrings` metadata, and contents are read only by a paste
command or a granted OSC/Kitty clipboard request.

## A10 — Testing framework (Appendix A, replacement)

**Rationale.** App-hosted tests need not be XCTest. Existing tests and the
native AppKit host stay. ([Testing][TESTING])

> Use Swift Testing for new unit/component tests, including app-hosted and
> main-actor tests where appropriate. Use XCTest/XCUITest for UI automation
> and platform performance-testing APIs. Preserve the existing native-host
> and completion-audit requirements. Serialize suites sharing application
> state; independent engine fixtures may run separately when their runner
> isolation is verified.

**Status.** The tests added for A01–A08 use Swift Testing; XCTest remains
in `Tests/AppUITests` and the signed runtime suites.

## Retained choices

AppKit/UIKit terminal views with SwiftUI where useful (Apple supports
integration both ways; no renderer rewrite); CoreText and Metal;
damage-driven rendering with idle suspension (MTKView supports event-driven
drawing); one serial terminal owner (deterministic mutation and input
order); compact cells, borrowed storage and bounded side metadata; a
headless engine separate from UI; windowed visionOS and focus-oriented
tvOS; a read-only watch companion; the Kitty graphics exclusion; and the
OS 27.0 baseline (a support policy, not an idiom requirement).
([AppKit integration][INTEROP], [MTKView][METALKIT])

## Remaining verification

Not exercised by this change: device and simulator sessions for the A02
acceptance list, VoiceOver/Full Keyboard Access/largest-text passes for
A05, the iOS Find-field shortcut behavior on hardware keyboards (A03), and
App Review for any future App Store profile (A07).

The review was done by specification/source inspection against Apple and
Swift documentation, without builds, accessibility sessions, measurements
or device tests.

## Sources

[SETTINGS]: https://developer.apple.com/design/human-interface-guidelines/settings
[SETTINGS-API]: https://developer.apple.com/documentation/foundation/adding-a-settings-interface-to-your-app
[INACTIVE]: https://developer.apple.com/documentation/uikit/uiscenedelegate/scenewillresignactive(_:)
[SCENEPHASE]: https://developer.apple.com/documentation/swiftui/scenephase
[KEY-PRIORITY]: https://developer.apple.com/documentation/uikit/uikeycommand/wantspriorityoversystembehavior
[KEYBOARDS]: https://developer.apple.com/design/human-interface-guidelines/keyboards
[SENDABLE]: https://docs.swift.org/latest/documentation/swift/sendable/
[ACTORS]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0306-actors.md
[ACCESSIBILITY]: https://developer.apple.com/design/human-interface-guidelines/accessibility
[ACCESSIBILITY-TEST]: https://developer.apple.com/documentation/accessibility/testing-system-accessibility-features-in-your-app
[LARGER-TEXT]: https://developer.apple.com/help/app-store-connect/manage-app-accessibility/larger-text-evaluation-criteria
[INTENT-MODES]: https://developer.apple.com/documentation/appintents/appintent/supportedmodes
[INTENT-AUTH]: https://developer.apple.com/documentation/appintents/intentauthenticationpolicy
[STORE-RULES]: https://developer.apple.com/app-store/review/guidelines/
[SWIFT-SYSTEMS]: https://www.swift.org/blog/swift-6.4-released/
[LAYOUT]: https://developer.apple.com/documentation/swift/memorylayout
[PERFORMANCE]: https://developer.apple.com/videos/play/wwdc2024/10217/
[SERVICE]: https://developer.apple.com/documentation/servicemanagement/smappservice/register()
[PASTE]: https://developer.apple.com/documentation/uikit/uipastecontrol
[MAC-PASTE]: https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-swift.enum/ask
[TESTING]: https://developer.apple.com/documentation/xctest/
[INTEROP]: https://developer.apple.com/documentation/swiftui/appkit-integration
[METALKIT]: https://developer.apple.com/documentation/metalkit/mtkview
