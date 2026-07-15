# Momenta

Native macOS menu bar app that turns Toggl Track time entries into clear
monthly hours and revenue progress for hourly-based freelance work.

- **Menu bar**: total goal progress at a glance, aggregated by day / week /
  month, optionally split per client. Cross-client aggregation is always
  revenue-based.
- **Popover**: one card per enabled client with a planned-vs-actual chart
  (weekday or calendar-day pacing), ahead/behind status, and the remaining
  daily pace needed to hit the goal. Historical months can be reviewed
  against the goals recorded for those months.
- **Toggl is the source of truth**: Momenta is read-only over Toggl data and
  never starts, stops, or edits entries.

## Status

M1 (mock-driven shell) — the full UI runs against a deterministic mock data
provider. Toggl connectivity lands with M2.

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
