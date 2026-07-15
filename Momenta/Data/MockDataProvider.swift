import Foundation

/// Deterministic mock data source: same month in, same data out, across
/// launches. Covers all client states plus uncategorized and running entries.
struct MockDataProvider: DataProvider {
    /// Number of past months (besides the current one) that have data.
    private let historyDepth = 2

    func loadClients() async throws -> [ClientConfig] {
        let thisMonth = YearMonth(containing: Date(), timeZone: .current)
        let lastMonth = thisMonth.previous

        return [
            ClientConfig(
                id: 1,
                workspaceID: 101,
                workspaceName: "Freelance",
                togglName: "Acme Corp",
                displayNameOverride: nil,
                colorHex: "#5B8DEF",
                isEnabled: true,
                isArchivedInToggl: false,
                pacing: .weekdays,
                goalHistory: [
                    lastMonth.previous: MonthlyGoal(hourlyRate: 110, input: .hours(70)),
                    thisMonth: MonthlyGoal(hourlyRate: 120, input: .hours(80)),
                ]
            ),
            ClientConfig(
                id: 2,
                workspaceID: 101,
                workspaceName: "Freelance",
                togglName: "Northwind Traders",
                displayNameOverride: "Northwind",
                colorHex: "#F2994A",
                isEnabled: true,
                isArchivedInToggl: false,
                pacing: .calendarDays,
                goalHistory: [
                    lastMonth.previous: MonthlyGoal(hourlyRate: 95, input: .revenue(5500)),
                ]
            ),
            ClientConfig(
                id: 3,
                workspaceID: 101,
                workspaceName: "Freelance",
                togglName: "Initech",
                displayNameOverride: nil,
                colorHex: "#9B51E0",
                isEnabled: true,
                isArchivedInToggl: false,
                pacing: .weekdays,
                goalHistory: [:] // enabled but needs setup
            ),
            ClientConfig(
                id: 4,
                workspaceID: 102,
                workspaceName: "Side Projects",
                togglName: "Globex",
                displayNameOverride: nil,
                colorHex: "#27AE60",
                isEnabled: false,
                isArchivedInToggl: false,
                pacing: .weekdays,
                goalHistory: [:]
            ),
            ClientConfig(
                id: 5,
                workspaceID: 102,
                workspaceName: "Side Projects",
                togglName: "Umbrella",
                displayNameOverride: nil,
                colorHex: "#828282",
                isEnabled: false,
                isArchivedInToggl: true,
                pacing: .weekdays,
                goalHistory: [
                    lastMonth.previous.previous: MonthlyGoal(hourlyRate: 100, input: .hours(40)),
                ]
            ),
        ]
    }

    func availableMonths(asOf now: Date, timeZone: TimeZone) async throws -> [YearMonth] {
        let current = YearMonth(containing: now, timeZone: timeZone)
        var months = [current]
        for _ in 0..<historyDepth {
            months.append(months.last!.previous)
        }
        return months.reversed()
    }

    func loadSnapshot(for month: YearMonth, timeZone: TimeZone, now: Date) async throws -> TimeEntrySnapshot {
        var rng = SeededGenerator(seed: UInt64(month.year * 100 + month.month))
        let calendar = YearMonth.calendar(in: timeZone)
        let currentMonth = YearMonth(containing: now, timeZone: timeZone)
        let dayCount = month.dayCount(in: timeZone)

        var entries: [TimeEntry] = []
        var entryID = month.month * 100_000

        for day in 1...dayCount {
            guard let dayStart = calendar.date(byAdding: .day, value: day - 1, to: month.start(in: timeZone)) else { continue }
            // No data for the future.
            if dayStart >= now { break }
            let weekday = calendar.component(.weekday, from: dayStart)
            let isWeekend = weekday == 1 || weekday == 7
            let isToday = calendar.isDate(dayStart, inSameDayAs: now) && month == currentMonth

            // Acme Corp: weekday work, 1–2 blocks totaling roughly 3–6h.
            if !isWeekend {
                let blocks = rng.int(in: 1...2)
                var cursor = dayStart.addingTimeInterval(9 * 3600)
                for _ in 0..<blocks {
                    let hours = rng.double(in: 1.5...3.0)
                    if let entry = makeEntry(id: entryID + 1, clientID: 1, start: cursor, hours: hours, now: now) {
                        entryID += 1
                        entries.append(entry)
                    }
                    cursor = cursor.addingTimeInterval(hours * 3600 + 1800)
                }
            }

            // Northwind: light daily work, ~1–2.5h including some weekends.
            if !isWeekend || rng.double(in: 0...1) > 0.6 {
                let hours = rng.double(in: 1.0...2.5)
                let start = dayStart.addingTimeInterval(15 * 3600)
                if let entry = makeEntry(id: entryID + 1, clientID: 2, start: start, hours: hours, now: now) {
                    entryID += 1
                    entries.append(entry)
                }
            }

            // Initech is enabled but lacks a goal: its hours wait for setup.
            if day % 3 == 0 {
                let start = dayStart.addingTimeInterval(20 * 3600)
                if let entry = makeEntry(id: entryID + 1, clientID: 3, start: start, hours: 0.8, now: now) {
                    entryID += 1
                    entries.append(entry)
                }
            }

            // Occasional uncategorized entry (no client).
            if day % 5 == 0 {
                let hours = rng.double(in: 0.4...1.2)
                let start = dayStart.addingTimeInterval(13 * 3600)
                if let entry = makeEntry(id: entryID + 1, clientID: nil, start: start, hours: hours, now: now) {
                    entryID += 1
                    entries.append(entry)
                }
            }

            // A little work under the disabled client, to prove it stays excluded.
            if day % 7 == 0 {
                let start = dayStart.addingTimeInterval(18 * 3600)
                if let entry = makeEntry(id: entryID + 1, clientID: 4, start: start, hours: 1.0, now: now) {
                    entryID += 1
                    entries.append(entry)
                }
            }

            // One running entry for today in the current month.
            if isToday {
                entryID += 1
                let start = now.addingTimeInterval(-rng.double(in: 0.5...1.5) * 3600)
                entries.append(TimeEntry(id: entryID, clientID: 1, start: start, stop: nil))
            }
        }

        // Entries that would end after `now` get clamped by makeEntry, so the
        // snapshot never contains future work.
        return TimeEntrySnapshot(month: month, fetchedAt: now, entries: entries)
    }

    /// Returns nil for entries that would start in the future; entries in
    /// progress at `now` are clamped so the snapshot never contains future time.
    private func makeEntry(id: Int, clientID: Int?, start: Date, hours: Double, now: Date) -> TimeEntry? {
        guard start < now else { return nil }
        let stop = min(start.addingTimeInterval(hours * 3600), now)
        return TimeEntry(id: id, clientID: clientID, start: start, stop: stop)
    }
}

/// Small deterministic linear congruential generator.
struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x4d595df4d0f33173 : seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }

    mutating func double(in range: ClosedRange<Double>) -> Double {
        let unit = Double(next() >> 11) / Double(1 << 53)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        Int(double(in: Double(range.lowerBound)...Double(range.upperBound)).rounded())
    }
}
