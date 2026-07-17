# Repository Agent Guidelines

## Runtime-First Debugging Discipline

For SwiftUI/AppKit boundary bugs, native macOS interaction bugs, and other behavior that depends on framework internals, establish the runtime mechanism before adding a fix.

### Prove the code path

- Do not describe a guard-protected or callback-driven implementation as active until runtime evidence shows that the path executed.
- Add temporary DEBUG logging, assertions, breakpoints, or counters at important entry and failure paths.
- When a lookup can return `nil` (toolbar items, view-tree traversal, delegates, accessibility elements, notifications), record the failure branch as well as the success branch.
- Verify the identity and lifetime of discovered framework objects; SwiftUI may rebuild controllers, toolbar items, and views.

### Inspect the real runtime structure

- Do not infer AppKit structure solely from SwiftUI APIs, Accessibility output, screenshots, or comments in existing code.
- Inspect the running view/controller hierarchy, concrete classes, delegates, constraints, frames, toolbar items, and relevant property values with LLDB, Xcode View Debugger, or DEBUG-only instrumentation.
- When two architectural assumptions conflict, resolve them with runtime evidence before editing code.
- Treat previous comments and handoff notes as hypotheses unless they are backed by current runtime observations.

### Measure the complete interaction

- For pointer, drag, resize, scroll, focus, animation, and lifecycle bugs, capture state throughout the complete event sequence—not only before it starts or after it settles.
- Instrument in-process notifications and events when external automation cannot sample the interaction reliably.
- A correct resting frame, Accessibility value, or post-release screenshot does not prove that live interaction was correct.
- If a view moves during a gesture and snaps back afterward, the bug is not fixed.

### Diagnose mechanisms, not symptoms

- Separate visually similar effects that may come from different framework layers, such as AppKit titlebar separators and SwiftUI scroll-edge effects.
- Identify the exact view, controller, item, layer, delegate, or heuristic responsible before choosing an API to change.
- If a correct property later reverts, investigate who resets it and when; do not discard the mechanism solely because a one-time assignment was insufficient.
- Prefer one evidence-backed mechanism change over stacked clamps, timers, event monitors, overlays, and recovery code.
- Stop adding workarounds when the existing approach only restores the final state instead of preventing the invalid transition.

### Keep experiments falsifiable

- State the hypothesis and the runtime observation that would confirm or reject it before each non-trivial attempt.
- Change one mechanism at a time whenever practical.
- Use a minimal reproduction when it is unclear whether behavior comes from the operating system/framework or this application.
- Remove superseded diagnostic and workaround machinery once the root cause is confirmed.

### Verify persistence and acceptance

- Read critical properties back while the failure is visible and after navigation, toolbar updates, window updates, and view reconstruction.
- Exercise intermittent UI problems across repeated navigation, scrolling, resizing, close/reopen, and relevant empty/detail states.
- For physical-pointer defects, require a physical-pointer retest before declaring success when automation cannot reproduce the full gesture faithfully.
- Define acceptance in terms of forbidden intermediate behavior as well as the final state.
- Keep unit tests, but do not use them as substitutes for native UI interaction verification.

### Report with evidence

- Clearly distinguish confirmed facts, unresolved hypotheses, and failed approaches.
- Record the actual runtime objects and values that established the diagnosis.
- Never claim a fix executed, persisted, or passed interaction testing without corresponding evidence.
- If verification is incomplete, say exactly which observation is still missing.

## Working Tree and Git

- Preserve unrelated user changes in a dirty working tree; stage only files that belong to the current task.
- Commit completed, verified changes locally by default with an English commit message.
- Do not push unless the user explicitly asks.
