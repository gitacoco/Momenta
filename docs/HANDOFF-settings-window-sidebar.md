# Settings Window Sidebar and Toolbar Handoff

Last updated: 2026-07-16

Repository: `gitacoco/Momenta`

Branch: `main`

Current HEAD while writing this handoff: `c865253` (`Lock native settings sidebar divider`)

## Executive status

**RESOLVED at `9b93a2a` (2026-07-16).** Both defects were root-caused with in-process instrumentation and fixed; the user confirmed the fix with a physical mouse. See "Resolution" at the end of this document. The sections below are preserved as the historical record of the failed attempts.

Original status: the settings-window work was **not complete**. The user retested the installed app with a physical mouse after the latest rebuild and confirmed that both remaining visual/interaction defects still reproduced:

1. A horizontal separator under the top toolbar/heading still appears intermittently.
2. The primary sidebar returns to its fixed width after a drag, but the titlebar/sidebar intersection can still enter a live resize interaction. During that interaction the layout can stretch into a severely broken state before snapping back on mouse release.

Do not treat the current implementation as a successful fix. In particular, screenshots showing the normal resting state, an Accessibility splitter value of 180, or a correct width after mouse-up do not prove that the titlebar drag path is disabled.

The user's physical-mouse observation is the acceptance authority for these bugs.

## Required final behavior

The settings window should preserve the macOS 26 native appearance while meeting all of the following:

- The traffic-light controls remain inside the rounded primary sidebar panel.
- The primary sidebar remains 180 pt wide.
- The sidebar cannot be collapsed or hidden.
- The pointer never changes to a horizontal resize cursor at any point along the sidebar/detail boundary, including the titlebar intersection.
- Dragging that boundary causes **zero live movement**. There should be no intermediate stretch and therefore no snap-back on release.
- Sidebar items remain left-aligned and clipped within the panel.
- No persistent or intermittent horizontal separator appears below the top heading/toolbar.
- The client selector remains a fixed-width in-page selector. It must not return to a secondary `NavigationSplitView` column.
- Account, Clients, and Display continue to share one persistent primary navigation structure, so changing destinations does not rebuild or reset the sidebar.

## User-visible reproductions

### A. Intermittent horizontal separator

Observed as a thin horizontal line spanning the detail area directly below the heading/toolbar. It may be absent in one state and return after navigation, scrolling, resizing, or reopening.

Relevant session screenshots (temporary local paths; they may not survive a reboot):

- `/var/folders/xg/trtdwj1x62b70x5kfncp6n880000gn/T/codex-clipboard-22cdf22e-f05e-4dd3-98f1-28f75ddd2e94.png`
- `/var/folders/xg/trtdwj1x62b70x5kfncp6n880000gn/T/codex-clipboard-cbabf7b7-f485-4cc7-baa6-41cb4518263b.png`

Minimum reproduction matrix:

1. Open `momenta://settings`.
2. Cycle Account -> Clients -> Display -> Account.
3. In Clients, test both the blank state and a selected client.
4. Scroll detail content to the top and away from the top.
5. Resize the window, close it, reopen it, and repeat.
6. Repeat the cycle at least ten times; the failure is intermittent.

### B. Live titlebar/sidebar resize

The content portion of the primary boundary often appears locked while idle. The remaining failure is most obvious at the top intersection where the sidebar boundary meets the titlebar/toolbar.

1. Move the physical pointer over the top of the primary sidebar's right edge.
2. Find the region that presents the resize affordance.
3. Press and drag left or right without releasing.
4. Observe that the panel can stretch during the drag, sometimes into a catastrophically broken layout.
5. Release the mouse. The width may snap back to 180 pt. That snap-back is evidence of the bug, not evidence of a fix.

Relevant session screenshots:

- Resize hit region: `/var/folders/xg/trtdwj1x62b70x5kfncp6n880000gn/T/codex-clipboard-5c873e97-91bb-43e3-a0f3-baa53ad35114.png`
- Broken live-drag state: `/var/folders/xg/trtdwj1x62b70x5kfncp6n880000gn/T/codex-clipboard-9820a41f-3a6b-4aae-aaa9-27231a9c29a2.png`

## Current architecture

### Window scene

[`Momenta/App/MomentaApp.swift`](../Momenta/App/MomentaApp.swift), lines 7-20:

- Uses a real SwiftUI `Window("Momenta Settings", id: "settings")`.
- Applies `.windowResizability(.contentMinSize)`.
- Applies `.windowToolbarStyle(.automatic)`.
- Opens through `momenta://settings` and suppresses automatic launch.

### Persistent settings navigation

[`Momenta/UI/SettingsView.swift`](../Momenta/UI/SettingsView.swift), lines 46-73 and 116-132:

- Uses one persistent two-column `NavigationSplitView` for Account / Clients / Display.
- `primarySidebarWidth` is 180 pt.
- The primary list uses `.navigationSplitViewColumnWidth(min: 180, ideal: 180, max: 180)`.
- `columnVisibility` is forced back to `.all` if SwiftUI changes it.
- The native sidebar toggle is removed.
- `.boundedPrimarySidebarResizeHandle(minimumWidth: 180, maximumWidth: 180)` installs the custom boundary behavior.

[`Momenta/UI/SettingsView.swift`](../Momenta/UI/SettingsView.swift), lines 75-114:

- The stable page host owns `.navigationTitle`, the back/forward toolbar, and `.scrollEdgeEffectHidden(true, for: .top)`.
- Clients uses a normal `HStack` with a 240 pt fixed-width selector and a flexible detail area.
- There is intentionally no secondary navigation column.

### Current sidebar boundary implementation

[`Momenta/UI/BoundedNavigationSplitColumn.swift`](../Momenta/UI/BoundedNavigationSplitColumn.swift):

- An anchor preference records the primary sidebar's rendered bounds.
- A 12 pt `NSViewRepresentable` overlay is positioned over the content-area divider.
- When min and max are equal, that overlay displays the arrow cursor rather than the resize cursor.
- The overlay reads and writes the first Accessibility splitter and runs delayed clamp attempts at 0, 0.05, 0.15, 0.5, 1, 2, and 4 seconds.
- The latest implementation searches the toolbar for an `NSTrackingSeparatorToolbarItem` whose identifier is `.sidebarTrackingSeparator`.
- It uses that toolbar item's public `splitView` and `dividerIndex`, finds the matching `NSSplitViewItem`, and applies:
  - `canCollapse = false`
  - `canCollapseFromWindowResize = false`
  - `minimumThickness = 180`
  - `maximumThickness = 180`
  - `automaticMaximumThickness = 180`
  - `holdingPriority = .required`
- It also calls `setPosition` if the resolved divider is not at the target position.
- `configureTrackedSplitView()` only runs during the seven scheduled attempts in the first four seconds after `updateNSView`/`viewDidMoveToWindow`. It does not continuously observe toolbar-item recreation or split-view resize notifications.

This is sufficient to restore the final resting width in many cases. It is **not** sufficient to disable the titlebar's live drag interaction.

## What has already been tried

### `7b45044` — Lock settings primary sidebar

Kept the native SwiftUI `NavigationSplitView` and inserted an AppKit probe behind the sidebar. The probe attempted to find the containing native `NSSplitViewItem`, set fixed width/collapse constraints, and replace the split view's delegate with a proxy that returned a fixed divider position. Replacing a split view controller's delegate was unsafe and unreliable.

### `9db06ca` — Fix primary sidebar width lock

Removed the proxy delegate and instead found the owning `NSSplitViewController`, then relied on `NSSplitViewItem` minimum/maximum thickness, collapse flags, and holding priority. Those are substantially the same final-layout constraints used again in `c865253`; they still did not remove the complete live titlebar interaction.

### `5c65e7d` — Enforce fixed primary sidebar width

Still used the native SwiftUI `NavigationSplitView` with the AppKit probe. It added pane-frame observation and called `NSSplitView.setPosition` whenever the sidebar moved. This restored the width after movement but did not prevent the native drag from starting and was visually unstable.

### `bc689f3` — Keep native settings chrome while locking sidebar

Removed the AppKit probe/frame-observer approach and introduced a narrow overlay intended to block or own pointer interaction at the native divider. This kept the native `NavigationSplitView` chrome, but the content overlay did not own every titlebar tracking region.

### `a0225ef` — Bound settings sidebar resizing

Introduced the current overlay-based boundary handle plus Accessibility splitter control. This improved behavior in the content region but did not own the titlebar tracking region.

### `69b642e` — Lock primary settings sidebar width

Set min and max width to the same value and added delayed clamp attempts. The final width became stable, but a live titlebar drag can still begin and then snap back.

### `adc631c` — Adopt automatic settings toolbar styling

Changed the window to `.windowToolbarStyle(.automatic)`. The horizontal separator was absent in some sampled states but later returned. This was not a deterministic fix.

### `d147aa4` — Stabilize settings window dividers

Attempted both:

- `NSWindow.titlebarSeparatorStyle = .none`
- A window-local `NSEvent` monitor for mouse-down, drag, mouse-up, and cursor-update events around the boundary

The user confirmed that both problems still existed. The event monitor did not reliably intercept the native titlebar interaction and this approach was removed by the next commit.

### `c865253` — Lock native settings sidebar divider

Replaced the window-event approach with:

- `.scrollEdgeEffectHidden(true, for: .top)` on the stable page host
- Direct constraints on the split view exposed by `NSTrackingSeparatorToolbarItem`

Automated/Accessibility inspection looked normal, and screenshots captured after the interaction showed a correct 180 pt resting width. The user then retested the installed app with a physical mouse and confirmed that both defects remain. Therefore this commit must be treated as another incomplete attempt.

## Why prior verification was insufficient

- The computer-control drag could not provide trustworthy sampling during the actual drag. State polling began hundreds of milliseconds later and may have observed only the post-release snap-back.
- An Accessibility splitter value of 180 only proves the sampled final value.
- A normal screenshot after the drag does not reveal whether an ugly intermediate state occurred.
- The separator is intermittent, so one or two screenshots without it are not meaningful coverage.
- Unit tests exercise application/domain behavior, not AppKit titlebar tracking regions or SwiftUI scroll-edge rendering.

Do not claim success without a physical-mouse retest or instrumentation that records the live frames throughout mouse-down -> drag -> mouse-up.

## Confirmed build and installed-app state

The latest attempt was rebuilt with Xcode 26 and installed into `/Applications/Momenta.app`:

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcodebuild -quiet \
  -project Momenta.xcodeproj \
  -scheme Momenta \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build

codesign --force --deep --sign - \
  --entitlements Momenta/Momenta.entitlements \
  .build/DerivedData/Build/Products/Debug/Momenta.app

pkill -x Momenta
ditto .build/DerivedData/Build/Products/Debug/Momenta.app /Applications/Momenta.app
open momenta://settings
```

At the time of the final retest:

- The running process path was `/Applications/Momenta.app/Contents/MacOS/Momenta`.
- The installed executable and build artifact had the same SHA-256:
  `f76871d8eac1d82035f72ac3bb666610b1081e5e51d214cb5ae1efdeab581a51`.
- The Xcode test suite passed.

This rules out a stale app copy for the user's latest report. Rebuilding the same code again is not expected to change the outcome.

## Relevant macOS 26 APIs

The Xcode 26 SDK exposes the following APIs used or considered here:

- SwiftUI `View.scrollEdgeEffectHidden(_:for:)`
- SwiftUI `View.scrollEdgeEffectStyle(_:for:)`
- AppKit `NSTrackingSeparatorToolbarItem.splitView`
- AppKit `NSTrackingSeparatorToolbarItem.dividerIndex`
- `NSToolbarItem.Identifier.sidebarTrackingSeparator`
- `NSWindow.titlebarSeparatorStyle`
- `NSSplitViewItem.minimumThickness` / `maximumThickness` / `automaticMaximumThickness`
- `NSSplitViewItem.canCollapse` / `canCollapseFromWindowResize` / `holdingPriority`
- `NSSplitView.setPosition(_:ofDividerAt:)`

Notes:

- `NSWindow.titlebarSeparatorStyle` controls the horizontal separator between a window's titlebar and its content. It does not control the vertical `NSTrackingSeparatorToolbarItem`, and it does not necessarily control a SwiftUI scroll-edge effect.
- `NSToolbar.showsBaselineSeparator` is deprecated/no longer supported on current macOS and should not be used as the primary solution.
- `NSTrackingSeparatorToolbarItem` gives the most precise public reference found so far for the split view tracked by the titlebar item, but constraining its `NSSplitViewItem` has not disabled all live interaction in this app.

Apple references:

- <https://developer.apple.com/documentation/swiftui/view/scrolledgeeffecthidden(_:for:)>
- <https://developer.apple.com/documentation/appkit/nstrackingseparatortoolbaritem>

## Open technical questions

### Separator source is not yet identified

The visible line may be produced by one or more independent mechanisms:

1. A SwiftUI `Form`/`List` top scroll-edge effect.
2. A toolbar or titlebar section separator.
3. A separator created by `NavigationSplitView` during toolbar reconfiguration.
4. A layer belonging to an internal AppKit scroll view or hosting view.

The fact that `.scrollEdgeEffectHidden(true, for: .top)` did not eliminate every occurrence suggests either that the modifier does not reach the actual scroll view in every destination/state, or that at least one occurrence is not a scroll-edge effect.

### Titlebar tracking may not be the configured object

Possible explanations for the remaining resize behavior include:

- SwiftUI recreates the tracking toolbar item after the last delayed configuration pass.
- More than one tracking separator or split view exists during navigation changes.
- The top cursor/drag region is owned by a different AppKit view than the content overlay and the discovered toolbar item.
- `NSSplitViewItem` min/max constraints govern the final layout but do not prevent temporary tracking visuals or intermediate frames on macOS 26.
- The first Accessibility splitter is not always the same divider as `trackingItem.dividerIndex`.
- The WindowServer/AppKit titlebar path begins before a window-local event monitor can cancel it.

These are hypotheses, not confirmed diagnoses.

## Recommended next investigation

Start from `c865253`, but do not add another blind delayed clamp. First identify the exact objects responsible for both failures.

### 1. Add DEBUG-only live instrumentation

Log or display, continuously during mouse-down -> drag -> mouse-up:

- Every toolbar item's identifier, class, and object identity.
- Every `NSTrackingSeparatorToolbarItem` identity, `splitView` identity, and `dividerIndex`.
- Every `NSSplitView` subview frame and each corresponding `NSSplitViewItem` constraint.
- `NSSplitView.willResizeSubviewsNotification` and `NSSplitView.didResizeSubviewsNotification` timestamps and widths.
- Toolbar item add/remove/recreation notifications.
- Current window `titlebarSeparatorStyle`, toolbar style, and relevant scroll offsets.

The goal is to answer two questions with evidence:

1. Which exact view or split item changes width during the top drag?
2. Is the configured tracking item the same object for the entire interaction and after every navigation change?

### 2. Use Xcode's View Debugger while the defects are visible

Pause while the horizontal line is on screen and identify the exact `NSView` or `CALayer` that draws it. Repeat while the pointer is over the top resize region and inspect the view that owns the cursor/tracking area.

Do not infer the source from appearance alone.

### 3. Build a minimal macOS 26 reproduction

Create a separate minimal sample containing only:

- A SwiftUI `Window`
- A two-column `NavigationSplitView`
- A `.sidebar` list
- `.toolbar(removing: .sidebarToggle)`
- Fixed equal min/ideal/max sidebar widths
- The same navigation title and toolbar placement

This will determine whether the titlebar live-resize behavior is an OS/SwiftUI limitation or is introduced by Momenta's modifiers/layout.

### 4. Isolate separator mechanisms one at a time

Once the drawing view/layer is known, test one change at a time in a reproducible state:

- Apply `scrollEdgeEffectHidden` directly to the exact scroll container rather than only through `pageHost`.
- Replace one `Form` with a plain container in the minimal reproduction.
- Temporarily remove navigation title/toolbar content.
- Inspect whether the line follows scroll position, toolbar configuration, or split-view recreation.

### 5. Choose the least invasive architecture after diagnosis

If native SwiftUI titlebar tracking cannot be disabled cleanly:

- Consider replacing only the outer primary split controller with a carefully scoped `NSSplitViewController` wrapper while preserving native toolbar/sidebar styling.
- Alternatively, consider removing or replacing the tracking separator toolbar item only after confirming the visual/layout consequences in a minimal sample.

Do not reintroduce a three-column structure. Do not move the traffic lights outside the primary sidebar panel. Do not rebuild the whole settings window with custom non-native chrome merely to block the divider.

## Acceptance checklist

No implementation should be handed back as complete until all of these pass in the rebuilt `/Applications/Momenta.app`:

### Primary sidebar

- [ ] Pointer remains an arrow along the full boundary, including the titlebar intersection.
- [ ] Dragging left at the top boundary causes zero live movement.
- [ ] Dragging right at the top boundary causes zero live movement.
- [ ] Mouse release causes no snap-back because no movement occurred.
- [ ] Sidebar remains exactly 180 pt wide.
- [ ] Sidebar cannot collapse or hide through drag, window resize, or destination changes.
- [ ] Items stay left-aligned and inside the rounded panel.
- [ ] Traffic lights remain inside the primary panel.

### Heading and separator

- [ ] No horizontal line on Account.
- [ ] No horizontal line on Display.
- [ ] No horizontal line on Clients with no selected client.
- [ ] No horizontal line on Clients with a selected client.
- [ ] No line appears at scroll top or after scrolling down/up.
- [ ] No line appears after switching destinations repeatedly.
- [ ] No line appears after window resize, close/reopen, or at least ten navigation cycles.

### Regression coverage

- [ ] Client selector remains fixed and non-collapsible.
- [ ] Client detail scrolls vertically.
- [ ] Empty client state is vertically centered.
- [ ] Navigation history controls still work.
- [ ] Switching primary destinations does not rebuild or flash the sidebar.
- [ ] Existing unit tests pass.

## Working-tree and history guidance

- The working tree was clean before this handoff file was added.
- The incomplete attempts are already committed. Do not rewrite history unless explicitly requested.
- It is safe to supersede or remove the current boundary implementation after the actual event/view ownership is diagnosed.
- Preserve unrelated application behavior and the in-page client selector refactor.
- Commit verified changes locally; do not push unless the user explicitly asks.

## Resolution (2026-07-16, commit `9b93a2a`)

Diagnosed by attaching lldb to the running installed app: split-resize
notification loggers plus synthetic NSEvents posted to the app's own event
queue reproduced the titlebar drag with millisecond frame sampling — the
"instrumentation that records the live frames throughout mouse-down -> drag ->
mouse-up" this document asked for.

### Bug B (titlebar live resize) — root cause

- macOS 26 NavigationSplitView IS backed by a real vertical `NSSplitView`
  whose delegate is `SwiftUI.NavigationSplitViewController`
  (an `NSSplitViewController`).
- `navigationSplitViewColumnWidth(min:ideal:max:)` is never propagated to the
  `NSSplitViewItem`: the sidebar item ran with `minimumThickness = 140`,
  `maximumThickness = -1` (unbounded). The AppKit divider drag was therefore
  free above 140 pt; SwiftUI reasserted 180 only after mouse-up.
- The titlebar declines hits in a ~12 pt band around the divider, so a
  mouse-down there reaches the `NSSplitView` and starts native divider
  tracking. The old 12 pt overlay stopped at the content area's top and never
  covered that band.
- `configureTrackedSplitView()` in `c865253` was dead code: SwiftUI never
  creates an `NSTrackingSeparatorToolbarItem` in this window, so the guard
  always failed and no constraint was ever applied.
- Live validation: pinning the sidebar item to `min == max == 180` in the
  running process reduced the same synthetic titlebar drag to zero movement
  (wrapper fixed at 188 pt through the whole down -> drag -> up sequence).
  Note the thickness semantics: item thickness measures the SwiftUI content
  width (180); the `_NSSplitViewItemViewWrapper` adds an 8 pt gutter on top
  (wrapper = 188). Pinning 188 instead grows the pane to 196.

### Bug A (intermittent separator) — root cause

- The line is the AppKit titlebar separator in `.automatic` mode, drawn
  per split section (detail section only — matching the screenshots), and
  toggled by AppKit's scroll-under-titlebar heuristics as navigation state
  changes. `scrollEdgeEffectHidden` controls SwiftUI's separate scroll-edge
  effect and cannot remove this AppKit separator.
- `NSWindow.titlebarSeparatorStyle = .none` overrides all per-item
  preferences (documented). The `d147aa4` attempt assigned it once in
  `viewDidMoveToWindow` and was reverted 22 minutes later without
  investigation of persistence.

### Fix (all public API, in `BoundedNavigationSplitColumn.swift`)

`HandleView` now owns window-level enforcement, re-run via a
compare-before-write pass on `NSWindow.didUpdateNotification`:

1. Pins the sidebar `NSSplitViewItem` (found by walking the window's view
   tree to the vertical `NSSplitView`, delegate cast to
   `NSSplitViewController`): `canCollapse = false`,
   `canCollapseFromWindowResize = false`, `min == max == automaticMax == 180`.
2. Installs a transparent `TitlebarDividerGuardView` as the topmost subview
   of the split view over the titlebar pass-through band (divider x ± 6,
   titlebar height): arrow cursor, `acceptsFirstMouse`, swallows the whole
   click-drag sequence.
3. Holds `window.titlebarSeparatorStyle = .none`.

The tracking-item lookup, accessibility-splitter machinery, and the seven
delayed clamp attempts were deleted. Unit tests: 114 passed. The user
confirmed both defects gone with a physical mouse on the rebuilt
`/Applications/Momenta.app`.

### Known follow-up

Navigating to Clients momentarily shifts the sidebar panel and the detail
toolbar/title left by a few pixels (transient). Under investigation; not a
regression of the two resolved defects.
