# Swiftty iPhone and iPad terminal keyboard — implementation specification

**Version:** 1.1  
**Date:** 2026-10-30  
**Status:** Ready for implementation; product constants require device validation  
**Source baseline:** chr33s/swiftty at commit **6a3831ca0fdb088326dd9cba41e0fa895d6dd661**  
**Deliverable:** Native UIKit accessory keyboard with a compact, expanding directional pad

## 1. Objective and governing decisions

Provide terminal controls above Apple's normal iPhone/iPad keyboard. Consolidate the four arrow buttons into one circular control that matches the other accessory keys at rest and expands only after the user intentionally slides toward a direction.

**The latest sizing requirement supersedes the earlier sketch's permanently enlarged pad.** The attached references establish the circular glyph and highlighted directional wedge; their oversized resting geometry is not the production geometry.

The implementation must satisfy these decisions:

1. Resting pad: **44 × 44 pt**, equal to the standard accessory key size.
2. Active directional slide: **56 × 56 pt visual presentation**, approximately **1.273×** scale.
3. Its layout slot and initial touch target remain **44 × 44 pt throughout**.
4. Touch-down, a stationary hold, a simple tap, pointer hover and accessibility focus do not enlarge the pad.
5. Once a directional slide activates, the pad stays enlarged while that direction is held, even when the finger stops moving.
6. Returning to neutral, moving outside the tracking envelope, lifting or cancelling stops input and restores resting size.
7. Native text entry, language selection, dictation and IME continue through the system keyboard and existing UITextInput integration.

**Interaction assumption:** an ordinary touch tap without a directional slide sends no arrow. Discrete one-step arrows are available through accessibility actions and the Keys → Navigate panel. This makes intentional sliding the single direct-touch activation rule.

UIKit supports app-owned controls through inputAccessoryView. This feature uses that extension point and Swiftty's existing TerminalAccessoryBar. [Apple accessory API][A-ACCESSORY] [Current accessory][S-ACCESSORY]

### Scope

The implementation targets iOS and iPadOS, including narrow iPad windows, floating keyboard arrangements and hardware-keyboard use. Shared UIKit code must continue compiling for the repository's existing platform targets, but this interaction is enabled only for the iPhone/iPad product.

Kitty graphics remains excluded. Existing terminal keyboard encoding, including any already-supported negotiated keyboard protocol, remains responsible for translating arrow events. This specification does not introduce a graphics protocol or a system-wide keyboard extension.

## 2. Accessory layout

### iPhone

Use this order:

| Position | Control | Behavior |
| --- | --- | --- |
| 1 | Esc | Terminal Escape |
| 2 | Tab | Terminal Tab |
| 3 | Ctrl | Existing sticky Control modifier |
| 4 | Alt | Existing sticky Alt/Option modifier |
| 5 | Paste | Existing user-initiated paste flow |
| 6 | Keys | Additional terminal-key panel |
| 7 | Directional pad | Slide for Left, Down, Up or Right |

Use compact native glyphs for Paste and other controls where localized text cannot fit. Accessibility labels remain descriptive and localized. Keys provides Navigate, Symbols, F1–F12, Paste when collapsed, and Hide Keyboard. Hide Keyboard remains an explicit, discoverable action.

### Default geometry

All measurements are in points and describe the default content size.

| Metric | Value | Requirement |
| --- | ---: | --- |
| Standard key height and compact width | 44 | Actual hit region, not just nominal row height |
| Resting pad artwork | 44 × 44 | Same visual scale and weight as adjacent keys |
| Pad layout slot and initial hit region | 44 × 44 | Fixed and untransformed |
| Active pad artwork | 56 × 56 | Presentation only |
| Accessory paint height | 56 | Fixed for the entire gesture |
| Normal inter-key gap | 4 | Five gaps in the seven-control phone row |
| Gap immediately before pad | 8 | Allows its 6 pt visual expansion on that side |
| Leading/trailing inset | 8 each | Applied inside available safe-area width |
| Resting navigation glyph | Approximately 20 | Center hub, four arrowheads and ring |

The full row needs **352 pt** of available width:

**7 × 44 + 5 × 4 + 8 + 2 × 8 = 352.**

Below that width, move Paste into Keys. The remaining six-control row needs **304 pt**:

**6 × 44 + 4 × 4 + 8 + 2 × 8 = 304.**

These are lower bounds for the default glyph layout. Measure actual localized content and accessibility metrics before selecting a layout.

At larger accessibility sizes, increase the shared key height as needed, keep the pad's resting diameter equal to that height, and reflow controls into an additional row when necessary. Scale the pad's active artwork by the same 56/44 ratio and reserve its paint height before interaction begins. Never compress hit regions to preserve a single row. If any geometry changes during a gesture, cancel the gesture before relayout.

Apple's button guidance recommends at least a 44 × 44 pt hit region and a visible pressed state. The exact gaps, 56 pt paint height and scale ratio here are Swiftty product choices. [Apple buttons][A-BUTTONS]

### iPad and hardware keyboards

On wide iPad layouts, expose slash, pipe, tilde, Symbols and Fn between the core modifiers and trailing pad. Collapse promoted controls according to measured width, converging on the phone layout.

Keep the pad outside a horizontally scrolling key container so its directional slide cannot become a toolbar-scroll gesture. Its expanded artwork must fit within the accessory's own reserved paint area.

Use the actual accessory width and system keyboard geometry. Account for floating/undocked keyboards, rotation and multitasking. Hardware keyboard users can retain or collapse the accessory; physical arrow keys continue through the existing hardware path. [Keyboard layout guide][A-LAYOUT]

## 3. Visual behavior and animation

Use the accessory's native material, semantic foreground colors and appearance adaptation.

At rest, show the small circular navigation glyph. On touch-down, provide a subtle tint change without scaling. During an active slide, highlight exactly one 90-degree sector, retain a distinct neutral hub, and emphasize the corresponding arrow.

| State | Scale | Direction highlight |
| --- | ---: | --- |
| Idle or disabled | 1.0 | None |
| Touch-down or stationary contact | 1.0 | Neutral pressed tint |
| Pointer hover | 1.0 | Subtle preview only |
| Active directional slide/hold | 56/44 | One active sector |
| Neutral center or outside pause | 1.0 | None |
| Lift or cancellation | Returns to 1.0 | Cleared |
| VoiceOver focus or discrete accessible arrow action | 1.0 | No drag expansion |

Animate expansion over **120 ms**, collapse over **100 ms**, using an ease-out curve without bounce or overshoot. Begin key delivery when the gesture activates; input must not wait for animation completion. Direction highlighting follows the logical direction immediately.

Retarget interrupted animations from their current presentation. On hard cancellation caused by removal, scene loss or geometry replacement, restore identity immediately. No animation completion may trigger input or reactivate a gesture.

With Reduce Motion enabled, apply the size changes immediately without interpolation. Preserve all touch geometry and input behavior. Respond if the preference changes during a gesture. [Reduce Motion API][A-MOTION]

Pointer hover must use a non-scaling effect, such as hover with prefersScaledContent set to false. Automatic/lift effects must not add an enlargement that violates the slide-only rule. A pressed pointer drag follows the touch contract. [Pointer effects][A-POINTER]

## 4. Touch geometry and state machine

### Coordinate system

Track one initiating touch in the pad's fixed, untransformed coordinate system. Its center is the center of its 44 × 44 pt bounds. Measure every threshold relative to this coordinate system, never the animated artwork.

| Parameter | Default |
| --- | ---: |
| Minimum intentional movement from initial touch location | 6 pt |
| Direction activation radius from fixed center | 12 pt |
| Return-to-neutral radius | 9 pt |
| Captured-drag retention envelope | 64 × 64 pt, centered on pad |
| Reentry envelope after leaving retention envelope | 60 × 60 pt, centered on pad |
| Angular hysteresis | 8 degrees beyond a sector boundary |

These are implementation defaults for device testing, not Apple-prescribed gesture constants. Scale distance thresholds proportionally if the shared resting key size increases.

### Activation and boundaries

Touch-down must begin inside the initial 44 × 44 pt hit region. It captures the touch, records its starting location, and enters Armed state without sending input.

The first activation requires both:

- Movement of at least 6 pt from that starting location.
- A radial distance of at least 12 pt from the fixed pad center.

Select the nearest cardinal direction. At an exact diagonal with no previous direction, choose the horizontal direction deterministically. Once active, retain that direction until the touch crosses the nearest diagonal boundary by more than 8 degrees. A direct jump to a distant sector selects that sector immediately. Diagonal key combinations are never emitted.

Returning to a radius of 9 pt or less pauses input. The 9–12 pt band preserves the previous active/neutral classification and prevents center jitter.

For a captured drag, outside means **abs(dx) > 32 or abs(dy) > 32**, regardless of the artwork's size. Pause input outside. Resume eligibility only after reentering **abs(dx) ≤ 30 and abs(dy) ≤ 30**. Reentry still requires the directional activation radius.

This larger envelope tolerates finger drift; it does not enlarge initial hit testing. A new touch beginning outside the 44 × 44 pt target belongs to the neighboring interface. The decorative artwork never intercepts touches.

### State transitions

| Current state/event | Next state | Required actions |
| --- | --- | --- |
| Idle + eligible touch-down | Armed | Capture touch and initial position; remain 1× |
| Armed + movement below activation thresholds | Armed | No key or scale change |
| Armed/Neutral + valid directional activation | Active(direction) | Admit one press; capture chord; expand; schedule repeat |
| Active + movement within same sector | Active(same) | Presentation update only; no extra press |
| Active + accepted direction change | Active(new) | Invalidate repeat; release old key; admit new press; restart delay |
| Active + center radius reached | Neutral | Stop repeat; release; clear sector; collapse |
| Active/Armed/Neutral + outside envelope | Outside | Stop/release if needed; collapse; retain original touch |
| Outside + reentry threshold reached | Neutral or Active | Evaluate radius; fresh press and full repeat delay if activated |
| Any tracking state + lift | Idle | Stop/release once; discard touch; collapse |
| Any tracking state + UIKit cancellation/removal or other hard cancellation | Idle | Stop/release; discard captured touch; restore 1×; invalidate generation |
| Any tracking state + input-source preemption while touch remains tracked | Suppressed | Stop/release; restore 1×; ignore remaining moves from this touch |
| Suppressed + original touch ends or UIKit cancels it | Idle | Clear captured touch; permit a new gesture |

An established slide may remain still in a sector while repeating. Expansion is tied to active direction state, not instantaneous finger velocity.

Only the initiating touch controls the pad. Additional fingers do not replace its identity. A preempted or invalidated gesture cannot reacquire input merely because the finger moves again; it requires a new touch. UIKit cancellation may never be followed by an end event, so hard cancellation must clear the touch and return to Idle immediately. Only a still-tracked, preempted touch remains Suppressed until it ends or is cancelled.

## 5. Terminal event contract

### Semantic keys

Emit ordinary terminal KeyEvent values through the existing encoder:

- One .press when a direction is admitted.
- .repeat events while it remains held.
- One .release when that held direction ends, where the original destination still admits cleanup.

The encoder decides which events have a wire representation under the current terminal mode. The control must not hardcode escape strings, synthesize UIKit hardware events, or treat arrow gestures as text insertion.

Use **350 ms initial delay**, followed by **12 repeats per second**. Moving within a sector does not restart the delay. Changing direction, resuming from center or reentering from outside starts a new delay. Late scheduler callbacks produce at most one repeat; do not replay a backlog of missed arrows.

### Modifiers

Keep the current off → latched → locked → off modifier tap cycle for this implementation. Distinguish its UI states as **Off**, **Next key** and **Locked**; include a lock indicator for Locked. This replaces the earlier concept's optional modifier-cycle redesign with the current source contract. [Modifier model][S-INPUT]

Consume a latched modifier only when a directional press is accepted. Neutral touch, rejected input and pointer hover consume nothing.

Store the accepted modifiers with the held key. Every repeat and its release use that same captured chord, even if the visible one-shot modifier has returned to Off. Show a concise chord indication such as Ctrl + Left while that run is active.

A direction change is a new keypress. A consumed one-shot modifier does not carry into it; a locked modifier does. Changing a modifier during a held direction affects the next admitted key, not the current held key.

### Repeat ownership and mixed input

Maintain one repeat owner per terminal input context, separate from hardware held-key records.

1. A newly routed physical terminal keypress preempts a virtual pad/accessory run. Stop its repeat and release its held virtual key before delivering the physical press.
2. While a physical terminal key has an outstanding logical press, reject all virtual key presses introduced or routed by this feature: pad activation, ordinary accessory keys, Navigate buttons and accessibility arrow actions. Reject before consuming modifiers or emitting a press. This prevents a virtual press/release from overlapping a physically held arrow. Modifier-only keys do not count as competing repeat owners, and modifier-button toggles do not acquire ownership.
3. A new ordinary accessory key can preempt a pad run, and a new pad run can stop ordinary accessory repeat. Preemption cancels the old pad gesture until lift.
4. Stopping a hardware repeat timer must preserve the hardware key's pending release record.
5. A stale callback or release from a previous owner must not stop the current owner.
6. Every virtual held-key path introduced by this work must provide its matching release. Existing press-only callbacks must not be assumed to provide one.

The current accessory repeat loop calls the ordinary accessory handler again, which consumes sticky state and constructs another press. The pad must use a dedicated semantic event path with captured modifiers rather than copying that loop unchanged. [Accessory implementation][S-ACCESSORY] [Keyboard integration][S-KEYBOARD]

## 6. UIKit implementation structure

### Existing integration points and proposed files

Paths below are relative to the repository root.

| File | Implementation responsibility |
| --- | --- |
| Sources/SwifttyMobile/AccessoryBar.swift | Replace the four visible arrow buttons with one pad; fixed row layout; panel routing; cancellation bridge |
| Sources/SwifttyMobile/DirectionPadModel.swift — new | Value-type geometry/state reducer; intent and presentation state; no UIKit view ownership |
| Sources/SwifttyMobile/TerminalDirectionPad.swift — new | Main-actor UIControl; touch tracking, artwork, hover and accessibility |
| Sources/SwifttyMobile/TerminalUIView+Keyboard.swift | Admit semantic pad events; captured chord; repeat ownership; eligibility and composition guards |
| Sources/SwifttyMobile/TerminalUIView.swift | Wire callbacks and lifecycle/context invalidation |
| Tests/SwifttyMobileTests/DirectionPadModelTests.swift — new | Geometry, transitions and deterministic event traces |
| Tests/SwifttyMobileHostedTests/DirectionPadEventTests.swift — new | UIKit event dispatch, clipping, ownership and cancellation |
| Existing ViewAccessoryTests and hosted ViewAccessoryEventTests | Update assumptions about four visible arrow buttons; preserve relevant cancellation coverage |

Keep the semantic arrow cases in AccessoryKey available for discrete navigation actions and existing callers. Change the phone/iPad presentation rather than removing those public cases.

The audited accessory has a 44 pt total height, 5 pt top/bottom stack insets and only a 36 pt minimum button width. That does not establish 44 × 44 pt controls. This change must give ordinary keys and the pad genuine minimum hit regions. [Current layout][S-ACCESSORY]

### Tracking and presentation

Use UIControl's beginTracking, continueTracking, endTracking and cancelTracking methods. Keep cancellation idempotent and call the superclass where required, including cancelTracking. Accept cancellation with a nil event. [UIControl tracking][A-CONTROL] [Cancellation API][A-CANCEL]

The tracking UIControl retains identity transform and fixed constraints. A noninteractive, accessibility-hidden child renders the circular artwork and receives the scale transform. Its bounds and center are stable. Parent layout reserves the full 56 pt paint height and trailing clearance, so expansion does not depend on escaping a clipped keyboard hierarchy.

Never calculate hit testing from the transformed child's frame: Apple documents frame as undefined under a nonidentity transform. [UIView transform][A-TRANSFORM]

Do not change the first responder when starting a pad gesture. Keep the pad outside any scrolling ancestor that would take over its directional drag.

### Suggested internal shape

This is an interface sketch, not a compiled implementation:

~~~swift
enum PadDirection: Equatable, Sendable {
  case left, down, up, right
}

enum PadIntent: Equatable, Sendable {
  case activate(PadDirection)
  case pause
  case end
  case cancel
}

@MainActor
final class TerminalDirectionPad: UIControl {
  var onIntent: ((PadIntent) -> Void)?
  private let artwork = UIView()
  // The model owns gesture geometry and presentation state.
  // The terminal input owner admits keys and owns repeats.
}
~~~

Match the repository's two-space Swift formatting, use internal visibility by default, and keep UI mutations on the main actor. Keep geometry/state as small value types. Add no package dependency for this feature.

### Scheduler and reentrancy

Use a cancellable, owned main-actor task with a monotonic clock, with an injectable scheduling boundary for tests. Cancel it when its held key ends.

If implementation instead uses Foundation timers, register them explicitly in an appropriate run-loop mode for touch tracking. The convenience scheduledTimer API uses the default mode; relying on that alone is insufficient for a hold interaction that must repeat during tracking. [Timer scheduling][A-TIMER]

Every scheduled callback captures and validates the active generation and original input context. Recheck eligibility after callbacks that can synchronously detach the view, change focus or cancel the gesture. A cancellation during the initial press callback must not be undone by subsequently scheduling repeat.

## 7. Input eligibility, lifecycle and native behavior

Admit a pad press only when the terminal is the active input destination, text input capability is present, the relevant attachment permits input, and no IME marked text is active.

While marked text exists, show the pad as disabled and reject pad events defensively at the input boundary. Do not force commit, unmark text or consume a sticky modifier. If composition begins during a pad run, cancel that run and require a fresh touch after composition ends. Native software typing and physical keys retain their existing text-system handling. [UITextInput][A-TEXT]

Cancel on responder/focus loss, scene deactivation, keyboard dismissal, view removal, input-capability loss, attachment replacement, disconnect, or geometry change. Wire pad cleanup into the existing releaseHardwareKeys / accessory stopRepeating lifecycle path. [Existing cleanup][S-KEYBOARD] [View lifecycle][S-VIEW]

A held-key record captures the original input context and a monotonically changing generation. Validate both before every press/repeat. On cleanup, send a release only through the original still-valid destination; if authority has ended, discard local held state without sending into a replacement or unauthorized destination. Reconnection never resumes a held gesture.

Use the existing deliberate paste flow and policy checks. Accepted text goes through existing bracketed-paste handling where applicable, with no extra Return appended. Preserve the normal keyboard's language switching and dictation; the accessory does not relabel or replace its alphabetic keys. [Virtual keyboards][A-KEYBOARD]

## 8. Accessibility

Expose the pad as one accessible control named **Arrow keys**, with a hint such as **Slide to move; additional actions send individual arrows**.

Provide four localized custom actions: Move left, Move down, Move up and Move right. Each action admits one press/release pair through the same input boundary, without drag, enlargement or automatic repeat. Primary accessibility activation opens Keys → Navigate. Provide the same four discrete arrow controls there for Switch Control and users who prefer tapping.

Decorative sectors are not four tiny separate accessibility targets. The enlarged artwork is not a second accessible element. Do not announce every repeat. Announce meaningful modifier state and disabled state, and expose the active direction without repeatedly interrupting speech. [UIKit accessibility][A-ACCESSIBILITY]

Respect Reduce Motion, Reduce Transparency, increased contrast, light/dark appearance and larger text. Color is supplementary to the selected-sector shape, arrow emphasis and modifier lock indicator. Hover is supplementary; every action must have an accessible touch or keyboard route.

## 9. Verification and acceptance

Use a fake clock/scheduler for timing tests and assert ordered semantic events. Use the real hosted UIKit harness for control delivery and visual geometry; synthetic target-action calls alone cannot verify directional touch tracking.

| ID | Scenario | Acceptance |
| --- | --- | --- |
| P01 | Resting layout | Pad and ordinary compact keys are 44 × 44 pt; all initial hit regions meet the minimum |
| P02 | Touch-down, simple tap, stationary hold | No arrow; no scale beyond 1× |
| P03 | Directional activation | Both 6 pt movement and 12 pt radial conditions are required; exactly one press |
| P04 | Active hold | Artwork reaches 56 pt; neighboring frames, accessory height and terminal viewport do not move |
| P05 | Repeat timing | No repeat before 350 ms; then 12 Hz under the fake clock; movement samples add no presses |
| P06 | Direction change | Old release precedes new press; old repeat is invalidated; new delay begins |
| P07 | Center hysteresis | At ≤9 pt, release and collapse; neutral does not reactivate until ≥12 pt |
| P08 | Outer hysteresis | Leaving 64 pt envelope pauses; reentry requires 60 pt envelope; new full delay |
| P09 | Angular jitter | Samples inside the 8-degree hysteresis margin retain the previous sector |
| P10 | Cancellation | Lift, nil-event cancellation, detach, focus loss and geometry change stop exactly once; UIKit cancellation restores Idle without requiring a later end event |
| P11 | Reentrant cancellation | Cancellation inside initial press callback prevents all later repeat work |
| P12 | Latched/locked modifiers | Captured modifier survives repeats/release; next-key versus locked behavior matches section 5 |
| P13 | Context or authority change | No stale event reaches a replacement session; reconnect requires a fresh gesture |
| P14 | Input-source preemption | Physical key preempts virtual run; all virtual key paths reject overlap with a held physical terminal key; old callbacks/releases cannot cancel the newer owner |
| P15 | Composition | Disabled pad sends nothing, consumes no modifier and preserves marked text |
| P16 | Pointer/accessibility | Hover/focus never scales or sends input; custom actions and Navigate buttons work without dragging |
| P17 | Neighbor interaction | Expanded artwork cannot receive a new touch intended for another key |
| P18 | Adaptation | Full row at ≥352 pt; Paste collapses below; 304 pt compact row; larger content reflows |
| P19 | Native keyboard arrangements | Docked/floating keyboard, hardware keyboard and iPad window resizing preserve layout/focus |
| P20 | Motion/appearance | Reduce Motion has immediate scale changes; high contrast/transparency preferences remain legible |
| P21 | Encoding | Normal/application cursor modes and already-supported negotiated keyboard modes retain correct encoding |
| P22 | Text and paste regression | Unicode/IME/dictation remain correct; paste appends no extra Return |

Physical-device checks must include a phone and tablet, repeated direction changes, accidental diagonal movement, center pausing, one-handed use and keyboard arrangement changes. Validate the proposed gesture distances and repeat speed before release.

### Repository verification commands

Run from a macOS checkout with the toolchain and SDK required by the repository's Package.swift, plus the existing simulator-script prerequisites. The inspected manifest declares Swift tools 6.4 and the repository's current Apple platform minimums; this feature does not revise them. [Manifest][S-PACKAGE] [Documented commands][S-README] [Hosted harness][S-HARNESS]

~~~sh
mise run format-check
mise exec -- swift test --filter SwifttyMobileTests
xcodebuild -scheme SwifttyMobile -destination 'generic/platform=iOS Simulator' build
xcrun simctl list devices available
~~~

Select installed iPhone and iPad simulator identifiers from that listing, set the two task-specific environment variables, then run:

~~~sh
: "${SWIFTTY_IPHONE_SIMULATOR_UDID:?Set an installed iPhone simulator UDID}"
: "${SWIFTTY_IPAD_SIMULATOR_UDID:?Set an installed iPad simulator UDID}"
Scripts/test-ios-simulator.sh "$SWIFTTY_IPHONE_SIMULATOR_UDID"
Scripts/test-ios-simulator.sh "$SWIFTTY_IPAD_SIMULATOR_UDID"
~~~

The macOS Swift test invocation does not prove UIKit behavior; the hosted simulator runs are required. This document specifies future verification. No feature implementation or Apple-platform test run is claimed by delivery of this specification.

## 10. Implementation sequence and completion boundary

1. Add the geometry/state reducer and deterministic gesture/event tests.
2. Build the fixed-size UIControl and noninteractive scaled artwork; verify bounds and pointer behavior.
3. Connect semantic key admission, captured modifiers, repeat ownership and lifecycle cleanup.
4. Replace the arrow-button presentation and implement responsive Keys/paste placement.
5. Add accessible actions and Navigate controls; complete hosted and device validation.

Always preserve native text ownership, the existing input authorization boundary and semantic encoder. Keep this change within the mobile accessory/input feature. Changes to shared transport protocols, public package APIs, platform minimums or third-party dependencies require a separate scope decision.

The feature is complete when the acceptance matrix passes, default and active sizes match this specification, the new gesture remains stable under interruption, and the implementation records any device-validated adjustments to the proposed constants.

## References

### Apple primary documentation

[A-ACCESSORY]: https://developer.apple.com/documentation/uikit/uiresponder/inputaccessoryview
[A-BUTTONS]: https://developer.apple.com/design/human-interface-guidelines/buttons
[A-LAYOUT]: https://developer.apple.com/documentation/uikit/adjusting-your-layout-with-keyboard-layout-guide
[A-MOTION]: https://developer.apple.com/documentation/uikit/uiaccessibility/isreducemotionenabled
[A-POINTER]: https://developer.apple.com/documentation/uikit/uipointereffect-swift.enum
[A-CONTROL]: https://developer.apple.com/documentation/uikit/uicontrol
[A-CANCEL]: https://developer.apple.com/documentation/uikit/uicontrol/canceltracking(with:)
[A-TRANSFORM]: https://developer.apple.com/documentation/uikit/uiview/transform
[A-TIMER]: https://developer.apple.com/documentation/foundation/timer/scheduledtimer(withtimeinterval:repeats:block:)
[A-TEXT]: https://developer.apple.com/documentation/uikit/uitextinput
[A-KEYBOARD]: https://developer.apple.com/design/human-interface-guidelines/virtual-keyboards
[A-ACCESSIBILITY]: https://developer.apple.com/documentation/uikit/accessibility-for-uikit

### Swiftty source pinned to the inspected commit

[S-ACCESSORY]: https://github.com/chr33s/swiftty/blob/6a3831ca0fdb088326dd9cba41e0fa895d6dd661/Sources/SwifttyMobile/AccessoryBar.swift
[S-INPUT]: https://github.com/chr33s/swiftty/blob/6a3831ca0fdb088326dd9cba41e0fa895d6dd661/Sources/SwifttyMobile/InputModel.swift
[S-KEYBOARD]: https://github.com/chr33s/swiftty/blob/6a3831ca0fdb088326dd9cba41e0fa895d6dd661/Sources/SwifttyMobile/TerminalUIView+Keyboard.swift
[S-VIEW]: https://github.com/chr33s/swiftty/blob/6a3831ca0fdb088326dd9cba41e0fa895d6dd661/Sources/SwifttyMobile/TerminalUIView.swift
[S-PACKAGE]: https://github.com/chr33s/swiftty/blob/6a3831ca0fdb088326dd9cba41e0fa895d6dd661/Package.swift
[S-README]: https://github.com/chr33s/swiftty/blob/6a3831ca0fdb088326dd9cba41e0fa895d6dd661/README.md
[S-HARNESS]: https://github.com/chr33s/swiftty/blob/6a3831ca0fdb088326dd9cba41e0fa895d6dd661/Scripts/test-ios-simulator.sh


## Implementation record

**Implemented:** 2026-10-30, uncommitted working tree on main.

| Item | Status |
| --- | --- |
| Reducer, layout and repeat owner (`DirectionPadModel.swift`) | Done; `DirectionPadModelTests` pass on macOS |
| Pad control (`TerminalDirectionPad.swift`) and accessory (`AccessoryBar.swift`) | Done; builds for iOS, iPadOS, Mac Catalyst, visionOS and tvOS |
| Hosted acceptance (`DirectionPadEventTests`, updated accessory tests) | All 230 hosted tests pass on iPhone 18 Pro and iPad Pro 11-inch simulators (iOS 27.2) |
| P19 native keyboard arrangements, P22 dictation/IME | Covered by existing behavior only; needs device check |
| Physical-device validation (§9) | **Pending.** No phone or tablet checks done yet |

### Constants as shipped

Every value in §2–§5 is used unchanged: 44 pt resting, 56 pt active, 6/12/9 pt thresholds, 64/60 pt envelopes, 8° hysteresis, 350 ms delay, 12 Hz repeat, 120/100 ms animation. Key size grows with Dynamic Type up to 66 pt. Thresholds scale with it.

### Device-validated adjustments

None recorded yet. After the phone and tablet checks in §9 (repeated direction changes, accidental diagonals, centre pausing, one-handed use, keyboard arrangement changes), record each changed constant here with its old value, new value, device and reason.
