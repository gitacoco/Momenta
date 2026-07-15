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
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: month.start(in: timeZone))
    }

    /// Signed delta like "+2.1h" / "-$310".
    static func signedHours(_ value: Decimal) -> String {
        (value >= 0 ? "+" : "\u{2212}") + hours(abs(value))
    }

    static func signedCurrency(_ value: Decimal, code: String = "USD") -> String {
        (value >= 0 ? "+" : "\u{2212}") + currency(abs(value), code: code)
    }
}
