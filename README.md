# Momenta

Native macOS menu bar app that turns Toggl Track time entries into clear
monthly hours and revenue progress for hourly-based freelance work.

- **Menu bar**: goal progress at a glance for Day / Week / Month. Show the
  aggregate, individual clients, or both, rendered as compact rings or
  waterlines. Cross-client aggregation is always revenue-based.
- **Popover**: one card per enabled client with a planned-vs-actual chart
  (weekday or calendar-day pacing), ahead/behind status, and the remaining
  daily pace needed to hit the goal. Historical months can be reviewed
  against the goals recorded for those months.
- **Toggl is the source of truth**: Momenta is read-only over Toggl data and
  never starts, stops, or edits entries.

## Status

M1–M4 feature-complete, pending real-account end-to-end validation (BON-17).

- **Connect**: Settings → Account, paste your Toggl API token (Toggl Track →
  Profile → API Token). The token lives only in the macOS Keychain.
- **Configure**: Settings → Clients lists every client from all your Toggl
  workspaces (grouped by workspace). Enable the ones to track and set an
  hourly rate plus a monthly goal (hours and revenue stay in sync; the side
  you edited last is authoritative). Goals are versioned per month —
  editing affects this month onward unless you explicitly confirm a
  retroactive rewrite.
- **Read**: the menu bar shows aggregate progress, per-client progress, or
  both for the chosen period (Day/Week/Month) as rings or waterlines; the
  popover shows per-client planned-vs-actual charts, pace metrics, and
  historical months.
- **Trust**: data refreshes only when the popover opens (throttled) or on
  manual refresh; the last snapshot stays visible offline with a stale
  indicator. Momenta is read-only over Toggl. Before a Toggl account is
  connected the app runs on deterministic demo data.

## Requirements

- macOS 26+
- Xcode 26+

## Build

```sh
xcodebuild build -project Momenta.xcodeproj -scheme Momenta -configuration Release
```

## Test

```sh
xcodebuild test -project Momenta.xcodeproj -scheme Momenta -destination 'platform=macOS'
```

## Project layout

```
Momenta/
  App/     — app entry point and observable app state
  Models/  — YearMonth, ClientConfig, MonthlyGoal, TimeEntry, DisplaySettings
  Data/    — DataProvider protocol + deterministic MockDataProvider (M1)
  Engine/  — pure ProgressCalculator (planned line, pacing, aggregation)
  UI/      — menu bar label, popover dashboard, settings window
MomentaTests/ — unit tests for models, calculator, and mock provider
```
