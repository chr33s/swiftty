# Swiftty: Swift and Apple Design Review

**Date:** 2026-10-30  
**Reviewed document:** [Swiftty Apple Platform Compatibility Specification v1.0][SPEC]  
**Implementation snapshot:** `chr33s/swiftty@6a3831ca0fdb088326dd9cba41e0fa895d6dd661`  
**Status:** Review and proposed amendments; the published v1.0 specification is unchanged.

## Verdict

The architecture fits Swift and Apple development well. The strongest native-UX departure is allowing Settings to open only a configuration file. The main implementation risks come from ambiguous scene-lifecycle wording, insufficient keyboard-context rules, and incomplete concurrency and automation contracts. None requires replacing the terminal engine, rewriting the UI in SwiftUI, or putting an actor around every operation.

“Apple way” is not a single rule. This review distinguishes platform requirements, Human Interface Guidelines, Swift safety obligations and reasonable product choices. A missing acceptance clause does not establish a bug in the current implementation.

| Finding | Spec location | Assessment |
| --- | --- | --- |
| A01 — Native settings | CFG-01 | Explicit departure from the usual macOS settings experience |
| A02 — Scene lifecycle | SESSION-03 | Ambiguity that could cause a regression if implemented literally |
| A03 — Keyboard context | CFG-03, UI-01 | Missing responder/IME precedence and cancellation contract |
| A04 — Isolation and ordering | ARCH-01, SESSION-02, CFG-03, Appendix A | Important Swift safety clarification |
| A05 — Accessibility settings | UI-01/02, CFG-04 | Acceptance needs explicit platform-preference coverage |
| A06 — App Intents | MAC-02, CFG-02 | Execution/authentication context needs specification |
| A07 — Distribution updates | MAC-03, DIST-01 | Mandatory App Store boundary needs firmer wording |
| A08 — Memory and performance | TXT-04, PERF-01, Appendix A | Sound approach; constrain representation and optimization claims |
| A09 — Service authorization | SESSION-01, DIST-01 | Preserve existing native behavior explicitly |
| A10 — Testing framework | Appendix A | Small clarification separating hosting from framework selection |

## A01 — Provide a small native settings interface

The spec currently accepts opening the config file as the entire settings experience. That was a sufficient minimum for the scoped Ghostty comparison, but it is weaker than Apple's macOS convention: App → Settings and Command–Comma open an app-owned settings window. Other platforms need settings presented in their appropriate native interface. [Apple settings guidance][SETTINGS] [Platform implementation guidance][SETTINGS-API]

This is a UX recommendation, not a claim that text configuration violates an App Store rule. The existing file format can remain authoritative, and a complete GUI for every terminal option is unnecessary.

### Proposed CFG-01 amendment

> Native macOS MUST provide an app-owned Settings window for common preferences and configuration diagnostics, accessible through App → Settings and Command–Comma. Full-client platforms MUST expose their common preferences through an appropriate native settings interface. Advanced configuration remains available through an explicit Edit Configuration or Import Configuration action where the platform supports it. The native interface and text configuration MUST use the same typed configuration model and documented precedence. A GUI for every supported option is not required.

Useful initial settings include font size, theme, cursor behavior and common keyboard preferences. Preserve existing native settings views rather than replacing them with a file-editing requirement.

**Acceptance:** Menu/shortcut behavior, keyboard and VoiceOver operation, invalid-config diagnostics, changes reflected through the same model, and no silent overwriting of unrelated advanced options.

## A02 — Distinguish inactivity, backgrounding and shared scene ownership

SESSION-03 says clients perform detach/cleanup when “unavailable or backgrounded.” “Unavailable” is too broad. Apple distinguishes temporary inactivity, including system interruptions, from backgrounding. Scene-level and application-level state also differ. [UIKit lifecycle][INACTIVE] [Scene aggregation][SCENEPHASE]

The current code already ignores transient `.inactive` in the RST lifecycle path and detaches on `.background`. This review recommends preserving that behavior, not fixing a demonstrated Control Center disconnect bug. [Current implementation][S-LIFECYCLE]

### Proposed SESSION-03 replacement

> Lifecycle decisions MUST distinguish scene inactivity, scene backgrounding and application suspension. Temporary inactivity pauses input and unnecessary presentation work without detaching solely because a system interruption occurred. Backgrounding suspends or detaches resources owned exclusively by that scene through the bounded cleanup path. A scene transition MUST NOT close a shared connection or release a session still required by another eligible foreground scene. App-level cleanup uses aggregate scene state. Mac window focus changes remain separate from sleep and termination. Recovery validates the current screen, attachment and authorization before admitting input.

This preserves the persistent host model and avoids treating every UI interruption as a connection failure.

**Acceptance:** System permission alert, Control Center, switching focus between windows, closing one of two windows using shared state, last-scene backgrounding, sleep and foreground recovery.

## A03 — Scope Ghostty-compatible keys to the terminal

The sequence grammar is a legitimate terminal feature. It should not capture typing in Find, authentication prompts, connection fields or native settings controls. UIKit normally prioritizes text input/focus handling before app key commands; an override needs deliberate justification. [Keyboard event precedence][KEY-PRIORITY] [Keyboard conventions][KEYBOARDS]

### Proposed CFG-03 / UI-01 addition

> Terminal key sequences and key-table state MUST be scoped to the focused terminal and its attachment. Native text fields retain their normal editing, focus and shortcut behavior. System input-method composition takes precedence over terminal sequence matching; provisional marked text MUST NOT reach the shell, and committed text is admitted exactly once. Moving focus outside the originating terminal cancels its pending sequence without replaying buffered keys into a different responder. Global shortcuts remain limited to explicitly global-safe actions. Standard app commands remain available by default.

Retain the specified no-timeout sequence behavior while the terminal remains in its valid input context. This amendment does not require an invented timeout or replacing terminal Control-key conventions with Command shortcuts.

**Acceptance:** Start a sequence, move to Find or an authentication prompt, then type. Repeat with IME marked text, a keyboard-layout switch and a revoked attachment. Confirm that no buffered bytes reach the wrong destination.

## A04 — Specify isolation, transfer and suspension invariants

One serial session owner is a sensible design. Swift 6 checking does not by itself prove manually synchronized types safe: the current `TerminalSession` and `RenderSnapshot` use `@unchecked Sendable`, with documented queue/storage invariants. Those annotations require maintained implementation guarantees. [Sendable semantics][SENDABLE] [Session source][S-SESSION] [Snapshot source][S-SNAPSHOT]

A wholesale actor conversion is not a remedy. Actor tasks can interleave across suspension, and actor scheduling is not generally FIFO. Terminal ordering must remain an explicit contract. [Swift actor semantics][ACTORS]

### Proposed ARCH-01 / Appendix A addition

> Each session MUST have one explicit isolation domain. UI state remains main-actor isolated. Values crossing isolation boundaries MUST use checked Sendable conformance, valid ownership transfer, or a documented manually verified synchronization contract. Every unchecked Sendable conformance MUST identify its mutable state, synchronization or immutability invariant, and backing-storage lifetime. Parser/grid mutation occurs in synchronous batches. Input ordering MUST NOT depend on actor scheduling order. State and authorization assumptions are revalidated after suspension.

### Proposed CFG-03 addition

> After awaiting an action, validate the expected post-action target, attachment epoch and lease generation before dispatching the next action. Intended target changes caused by the chain are allowed; unrelated replacement, cancellation or lost authority stops the remaining chain.

This keeps queues, actors and custom executors available where appropriate. It does not require per-byte tasks, locks or actor hops.

**Acceptance:** Lease revoked during an awaited action, target replaced while a new window opens, concurrent snapshot use during pool maintenance, and cancellation between chained operations.

## A05 — Make accessibility preferences part of acceptance

The spec already includes VoiceOver and inherits some text-scaling behavior from the base specification. Its Apple-wide acceptance should explicitly cover larger text, contrast, reduced motion/transparency and keyboard access. Custom rendering does not automatically inherit every behavior of native text views. [Accessibility design][ACCESSIBILITY] [System settings testing][ACCESSIBILITY-TEST]

### Proposed UI-01 / UI-02 / CFG-04 addition

> App chrome and companion text MUST support applicable system text-size settings without clipping essential controls. Terminal content MUST provide usable text enlargement with defined grid, resize and reflow behavior. The terminal accessibility representation MUST expose readable content, selection and navigable structure, rather than only a label for the canvas. Controls MUST remain usable with VoiceOver and Full Keyboard Access. Nonessential animation, including animated shaders, MUST offer a reduced-motion presentation. Custom translucent surfaces MUST provide an appropriate reduced-transparency treatment, and essential UI must remain legible with increased contrast.

A fixed terminal grid can retain intentional typography and user font controls. It need not become one SwiftUI text view per cell. Apple allows custom enlargement mechanisms; the outcome must be usable. [Larger text evaluation][LARGER-TEXT]

**Acceptance:** Largest applicable text sizes, VoiceOver reading/selection, Full Keyboard Access, increased contrast, reduced motion and reduced transparency. Check both app controls and the custom terminal surface.

## A06 — Add explicit App Intent adapters and policies

Sharing a typed action executor between menus, AppleScript and App Intents is sound. Execution context differs: intents can run in the background, and authentication policy can permit execution while locked. Foreground-only UI work cannot be assumed available. [Intent modes][INTENT-MODES] [Authentication policies][INTENT-AUTH]

### Proposed MAC-02 amendment

> Each App Intent MUST declare its supported execution modes and authentication policy. Operations exposing protected session information or mutating session state MUST use the documented authenticated policy selected for that operation. UI actions MUST execute on the main actor in an available foreground context, or return a supported continuation/error without performing the action. Background actions MUST identify their target explicitly rather than relying on an ambient focused window. Intent confirmation uses the platform's confirmation mechanism where applicable. Authentication and confirmation do not replace SSH trust, capability checks or writer-lease validation.

The exact policy is a Swiftty product decision; Apple does not require local-device authentication for every intent. For operations depending on locally protected credentials, choose a policy consistent with that protection rather than weakening Keychain accessibility to make background execution succeed.

**Acceptance:** Invocation from Shortcuts while the app is backgrounded, locked-device policy, missing/stale target, unavailable foreground continuation, cancellation and takeover refusal.

## A07 — Make the App Store update boundary mandatory

MAC-03 currently says not to require a custom updater in store clients. For the Mac App Store profile, that wording is too weak: Apple requires updates through the store. This is a concrete distribution rule, conditional on choosing that profile. [App Review Guidelines `2.4.5(vii)][STORE-RULES]

### Proposed MAC-03 / DIST-01 replacement

> Developer ID builds MAY implement the specified update discovery and staging flow. App Store builds MUST receive application updates through the App Store and MUST NOT enable the custom application updater. Packaging, entitlements and update acceptance MUST be defined separately for each distribution profile.

Keep the existing service staging/compatibility barrier for Developer ID releases. Apple-only targeting does not imply that every macOS build must use the App Sandbox.

This finding concerns wording; it does not establish that the current app ships a prohibited updater.

## A08 — Keep compact storage and low allocation, with precise boundaries

The systems-programming choices are aligned with Swift. Recent Swift releases explicitly develop borrowing, spans, inline storage and noncopyable containers for efficient, safe code. [Swift systems APIs][SWIFT-SYSTEMS]

The amendments should prevent an internal optimization from being mistaken for a universal layout guarantee or an application-wide ban on ordinary Swift types.

### Proposed TXT-04 addition

> Preserve the current 16-byte cell stride on supported toolchains and targets. Verify size, stride, alignment and field offsets used by optimized code. Native cell representation is an internal storage contract, not the SMX/RST wire format or an unversioned persistence format. Side-table references remain typed, generation-safe and bounded. A representation change requires measured total-memory/cache/latency evidence and an explicit contract update.

The source relies on the glyph field remaining at offset zero, making this testable rather than merely stylistic. [Cell representation][S-CELL] [Memory layout][LAYOUT]

### Proposed memory-safety addition

> Keep unsafe-pointer construction and lifetime overrides inside a small audited storage layer. Borrowed views MUST remain within their backing-storage lifetime and mutation/reuse contract. Snapshot storage remains immutable while referenced. Experimental compiler features and optimizer workarounds MUST remain tied to the pinned toolchain and covered by optimized-build regression tests.

The current snapshot accessors contain such low-level lifetime operations. This is a preservation requirement, not evidence that they are currently invalid. [Snapshot accessors][S-SNAPSHOT]

### Proposed PERF-01 clarification

> Zero-allocation gates apply only to named, prewarmed parser and ordinary cell-update paths at fixed capacity. Startup, resize, new metadata, connection setup and UI construction use separate bounded budgets. Normal Swift collections, reference types and concurrency abstractions remain appropriate outside measured hot paths. Optimize from observed latency, memory and energy results.

For example, allocating one new bounded hyperlink record is different from allocating an object for every printed cell. Apple's performance guidance supports measured tradeoffs across allocation, copying, representation and responsiveness. [Swift performance][PERFORMANCE]

## A09 — Preserve user-controlled service registration and pasteboard access

The current native app already uses `SMAppService.agent` and handles `requiresApproval`. Keep that architecture. Service Management registration remains subject to user authorization, including revocation. [Existing registration][S-SERVICE] [Registration API][SERVICE]

### Proposed SESSION-01 / DIST-01 addition

> Preserve the bundled per-user SMAppService registration model and run the helper without root privileges. Explain why the helper persists, respect disabled/revoked/unregistered states, and provide the normal removal path. Reconnection MUST NOT start an unmanaged substitute to bypass authorization. Session retention applies while the service is authorized and available; it does not override explicit disablement, logout, shutdown or operating-system termination. Helper registration MUST NOT implicitly register the main UI app to open at login.

“Without root privileges” is the appropriate Swiftty constraint, not a statement that Apple never supports privileged services.

### Proposed SAFE-01 clipboard clarification

> Clipboard operations MUST satisfy both Swiftty's capability/consent policy and platform pasteboard privacy behavior. User paste UI SHOULD use system paste commands or controls. Availability checks MUST avoid reading clipboard contents merely to enable a control. Denied access MUST fail cleanly without leaking contents or leaving a protocol request pending indefinitely.

An OSC clipboard grant is not an exemption from the OS privacy layer. UIKit and AppKit both distinguish user-originated paste from programmatic reads. [UIKit paste control][PASTE] [AppKit access behavior][MAC-PASTE]

## A10 — Separate test hosting from test-framework selection

App-hosted tests do not all require XCTest. Swift Testing is appropriate for new unit and component tests; XCTest/XCUITest remains useful for UI automation and the corresponding performance APIs. [Apple testing guidance][TESTING]

### Proposed Appendix A replacement

> Use Swift Testing for new unit/component tests, including app-hosted and main-actor tests where appropriate. Use XCTest/XCUITest for UI automation and platform performance-testing APIs. Preserve the existing native-host and completion-audit requirements. Serialize suites sharing application state; independent engine fixtures may run separately when their runner isolation is verified.

This is a small precision improvement. It does not require discarding existing tests or replacing the repository's native AppKit host.

## Choices to retain

| Existing decision | Why it remains suitable |
| --- | --- |
| AppKit/UIKit terminal views with SwiftUI where useful | Apple supports framework integration in both directions; a renderer rewrite is unnecessary. |
| CoreText and Metal | Appropriate specialized APIs for terminal text rendering. |
| Damage-driven rendering and idle suspension | MetalKit expressly supports event-driven drawing. |
| One serial terminal owner | Fits deterministic mutation and explicit input ordering. |
| Compact cells, borrowed storage and bounded side metadata | Suitable for a systems workload when safety and measurements are explicit. |
| Headless engine separated from UI | Keeps process/state ownership independent of views. |
| Windowed visionOS and focus-oriented tvOS | Appropriate platform-specific product profiles. |
| Read-only watch companion | A deliberate product boundary; no terminal engine is needed to improve native fit. |
| Explicit Kitty graphics exclusion | Protocol scope is independent of Swift/Apple UI conventions. |
| OS 27.0 baseline | A support-policy choice inherited from the repository, not a requirement for writing idiomatic Swift. |

[Framework interoperability][INTEROP] [MetalKit drawing modes][METALKIT]

## Recommended amendment order

1. Tighten lifecycle, keyboard context and concurrency/ordering before implementation work uses those clauses.
2. Specify intent execution/authentication and distribution/service authorization before adding automation or packaging.
3. Add the native settings and accessibility acceptance requirements.
4. Clarify memory/performance scope and test-framework wording.

The review was performed through specification/source inspection and official Apple/Swift documentation. It did not execute Apple application builds, accessibility sessions, performance measurements or device tests.

## Sources

[SPEC]: https://chatgpt.com/library?file_id=libfile_dadf256d53548191bbf9692a31da06f5&account_id=personal
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
[S-LIFECYCLE]: https://github.com/chr33s/swiftty/blob/6a3831ca0fdb088326dd9cba41e0fa895d6dd661/Apps/Shared/LiveTerminalSurface.swift#L390-L402
[S-SESSION]: https://github.com/chr33s/swiftty/blob/6a3831ca0fdb088326dd9cba41e0fa895d6dd661/Sources/SwifttyCore/Session/TerminalSession.swift#L12-L38
[S-SNAPSHOT]: https://github.com/chr33s/swiftty/blob/6a3831ca0fdb088326dd9cba41e0fa895d6dd661/Sources/SwifttyCore/Renderer/RenderSnapshot.swift#L11-L134
[S-CELL]: https://github.com/chr33s/swiftty/blob/6a3831ca0fdb088326dd9cba41e0fa895d6dd661/Sources/SwifttyEngine/Terminal/Cell.swift#L132-L146
[S-SERVICE]: https://github.com/chr33s/swiftty/blob/6a3831ca0fdb088326dd9cba41e0fa895d6dd661/Sources/Swiftty/MuxWorkspaceController%2BConnection.swift#L66-L107

