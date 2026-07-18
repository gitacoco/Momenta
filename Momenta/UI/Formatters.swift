import Foundation

enum Format {
    static func hours(_ value: Decimal) -> String {
        value.doubleValue.formatted(.number.precision(.fractionLength(1))) + "h"
    }

    static func currency(_ value: Decimal, code: String = "USD") -> String {
        value.doubleValue.formatted(.currency(code: code).precision(.fractionLength(0)))
    }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    static func monthTitle(_ month: YearMonth, timeZone: TimeZone) -> String {
        formatted(month.start(in: timeZone), format: "MMMM yyyy", timeZone: timeZone)
    }

    /// Bare month name for the Overall label, e.g. "July".
    static func monthName(_ month: YearMonth, timeZone: TimeZone) -> String {
        formatted(month.start(in: timeZone), format: "MMMM", timeZone: timeZone)
    }

    /// Popover day-navigation title, e.g. "Fri, Jul 17".
    static func dayTitle(_ date: Date, timeZone: TimeZone) -> String {
        formatted(date, format: "EEE, MMM d", timeZone: timeZone)
    }

    /// Compact day for the Overall label of a past day, e.g. "Jul 17".
    static func dayShort(_ date: Date, timeZone: TimeZone) -> String {
        formatted(date, format: "MMM d", timeZone: timeZone)
    }

    /// Popover week-navigation title. Same month: "Jul 13 – 19"; straddling a
    /// boundary: "Jun 29 – Jul 5".
    static func weekRange(_ reference: Date, timeZone: TimeZone) -> String {
        let calendar = YearMonth.calendar(in: timeZone)
        guard let week = calendar.dateInterval(of: .weekOfYear, for: reference) else {
            return dayShort(reference, timeZone: timeZone)
        }
        let start = week.start
        let end = calendar.date(byAdding: .day, value: 6, to: start) ?? start
        let sameMonth = calendar.component(.month, from: start) == calendar.component(.month, from: end)
            && calendar.component(.year, from: start) == calendar.component(.year, from: end)
        let startText = formatted(start, format: "MMM d", timeZone: timeZone)
        let endText = formatted(end, format: sameMonth ? "d" : "MMM d", timeZone: timeZone)
        return "\(startText) – \(endText)"
    }

    private static func formatted(_ date: Date, format: String, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    /// Signed delta like "+2.1h" / "-$310".
    static func signedHours(_ value: Decimal) -> String {
        (value >= 0 ? "+" : "\u{2212}") + hours(abs(value))
    }

    static func signedCurrency(_ value: Decimal, code: String = "USD") -> String {
        (value >= 0 ? "+" : "\u{2212}") + currency(abs(value), code: code)
    }
}
