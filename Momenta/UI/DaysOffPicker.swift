import SwiftUI

/// Date-specific exceptions to one client's recurring pacing schedule.
/// Each click persists through the parent binding, like the other settings.
struct DaysOffPicker: View {
    @Binding var daysOff: Set<CalendarDay>
    let timeZone: TimeZone
    let today: Date
    @State private var month: YearMonth

    init(daysOff: Binding<Set<CalendarDay>>, month: YearMonth, timeZone: TimeZone, today: Date) {
        _daysOff = daysOff
        _month = State(initialValue: month)
        self.timeZone = timeZone
        self.today = today
    }

    private var calendar: Calendar { YearMonth.calendar(in: timeZone) }
    private var leadingEmptyCells: Int {
        (calendar.component(.weekday, from: month.start(in: timeZone)) + 5) % 7
    }
    private var rowCount: Int { (leadingEmptyCells + month.dayCount(in: timeZone) + 6) / 7 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(Format.monthTitle(month, timeZone: timeZone))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Previous month", systemImage: "chevron.left") { month = month.previous }
                Button("Next month", systemImage: "chevron.right") { month = month.next }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)

            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                GridRow {
                    ForEach(0..<7, id: \.self) { index in
                        Text(["M", "T", "W", "T", "F", "S", "S"][index])
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 22)
                            .accessibilityHidden(true)
                    }
                }
                ForEach(0..<rowCount, id: \.self) { row in
                    GridRow {
                        ForEach(0..<7, id: \.self) { column in
                            let day = row * 7 + column - leadingEmptyCells + 1
                            if (1...month.dayCount(in: timeZone)).contains(day) {
                                dayButton(day)
                            } else {
                                Color.clear.frame(width: 32, height: 32)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                }
            }

            Text("Select dates to mark or clear days off. Changes save immediately for this client.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 248)
        .padding(16)
    }

    private func dayButton(_ day: Int) -> some View {
        let date = CalendarDay(year: month.year, month: month.month, day: day)
        let isOff = daysOff.contains(date)
        let isToday = date == CalendarDay(containing: today, timeZone: timeZone)
        return Button {
            if isOff { daysOff.remove(date) } else { daysOff.insert(date) }
        } label: {
            Text(day.formatted())
                .font(.callout.weight(isOff || isToday ? .semibold : .regular))
                .foregroundStyle(isOff ? Color.white : Color.primary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(isOff ? Color.accentColor : .clear))
                .overlay(Circle().strokeBorder(isToday ? Color.primary.opacity(0.5) : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Format.dayTitle(date.date(in: timeZone), timeZone: timeZone))
        .accessibilityValue(isOff ? "Day off" : "Follows pacing schedule")
        .accessibilityHint(isOff ? "Remove this day off" : "Mark this date as a day off")
        .accessibilityAddTraits(isOff ? [.isSelected] : [])
    }
}
