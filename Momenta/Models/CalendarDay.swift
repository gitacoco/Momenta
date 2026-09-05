import Foundation

/// A civil date, stored without a time zone so a day off never moves when
/// the user travels or changes the app's display time zone.
struct CalendarDay: Hashable, Codable, Comparable, Sendable {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(containing date: Date, timeZone: TimeZone) {
        let parts = YearMonth.calendar(in: timeZone).dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    var yearMonth: YearMonth { YearMonth(year: year, month: month) }

    func date(in timeZone: TimeZone) -> Date {
        YearMonth.calendar(in: timeZone).date(from: DateComponents(year: year, month: month, day: day))
            ?? yearMonth.start(in: timeZone)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}
