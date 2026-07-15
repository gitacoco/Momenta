import Foundation

/// A calendar month in a specific year, independent of any time zone.
/// Time-zone-dependent boundaries are computed explicitly via the `in:` methods.
struct YearMonth: Hashable, Codable, Comparable, CustomStringConvertible, Sendable {
    var year: Int
    /// 1...12
    var month: Int

    init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    init(containing date: Date, timeZone: TimeZone) {
        let calendar = Self.calendar(in: timeZone)
        let components = calendar.dateComponents([.year, .month], from: date)
        self.init(year: components.year ?? 1970, month: components.month ?? 1)
    }

    var next: YearMonth {
        month == 12 ? YearMonth(year: year + 1, month: 1) : YearMonth(year: year, month: month + 1)
    }

    var previous: YearMonth {
        month == 1 ? YearMonth(year: year - 1, month: 12) : YearMonth(year: year, month: month - 1)
    }

    static func < (lhs: YearMonth, rhs: YearMonth) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }

    /// First instant of this month in the given time zone.
    func start(in timeZone: TimeZone) -> Date {
        let calendar = Self.calendar(in: timeZone)
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = 1
        return calendar.date(from: components) ?? .distantPast
    }

    /// First instant of the following month in the given time zone (exclusive upper bound).
    func end(in timeZone: TimeZone) -> Date {
        next.start(in: timeZone)
    }

    func dayCount(in timeZone: TimeZone) -> Int {
        let calendar = Self.calendar(in: timeZone)
        return calendar.range(of: .day, in: .month, for: start(in: timeZone))?.count ?? 30
    }

    func contains(_ date: Date, in timeZone: TimeZone) -> Bool {
        date >= start(in: timeZone) && date < end(in: timeZone)
    }

    var description: String {
        String(format: "%04d-%02d", year, month)
    }

    static func calendar(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2 // Monday
        return calendar
    }
}
