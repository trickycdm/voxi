import Foundation

/// Pure day-bucketing for the History list, unit-tested in
/// HistoryGroupingTests. Only adjacent same-day entries merge, so a
/// newest-first list yields one section per day with order preserved.
/// Search results are relevance-ranked, so callers must not group them.
enum HistoryDayGrouping {
    struct DaySection: Equatable {
        let title: String
        var entries: [HistoryEntry]
    }

    static func sections(
        _ entries: [HistoryEntry],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [DaySection] {
        var result: [DaySection] = []
        var currentDay: Date?
        for entry in entries {
            let day = calendar.startOfDay(for: entry.createdAt)
            if day == currentDay, !result.isEmpty {
                result[result.count - 1].entries.append(entry)
            } else {
                currentDay = day
                result.append(DaySection(
                    title: title(for: day, now: now, calendar: calendar),
                    entries: [entry]
                ))
            }
        }
        return result
    }

    static func title(for day: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) { return "Yesterday" }
        return day.formatted(date: .long, time: .omitted)
    }
}
