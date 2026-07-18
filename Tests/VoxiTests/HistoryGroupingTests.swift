import Foundation
import Testing
@testable import Voxi

@Suite("History day grouping")
struct HistoryGroupingTests {
    // Fixed clock: 2026-07-12 10:00 UTC in a UTC calendar, so titles are
    // deterministic regardless of the machine's timezone.
    let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()
    let now = Date(timeIntervalSince1970: 1_783_850_400)  // 2026-07-12 10:00 UTC

    private func entry(hoursAgo: Double) -> HistoryEntry {
        HistoryEntry(
            createdAt: now.addingTimeInterval(-hoursAgo * 3600),
            rawTranscript: "raw",
            finalText: "final",
            engineID: "parakeet",
            modelID: "m",
            refinerID: nil,
            targetAppBundleID: nil,
            durationSeconds: 1
        )
    }

    @Test("newest-first entries bucket into Today / Yesterday / dated sections")
    func buckets() {
        let entries = [
            entry(hoursAgo: 1),    // today 09:00
            entry(hoursAgo: 9),    // today 01:00
            entry(hoursAgo: 20),   // yesterday 14:00
            entry(hoursAgo: 60),   // 2026-07-09 22:00
            entry(hoursAgo: 65),   // 2026-07-09 17:00
        ]
        let sections = HistoryDayGrouping.sections(entries, now: now, calendar: calendar)
        #expect(sections.map(\.title)
            == ["Today — Sunday 12 July", "Yesterday — Saturday 11 July", "9 July 2026"])
        #expect(sections.map(\.entries.count) == [2, 1, 2])
    }

    @Test("order is preserved within each section")
    func orderPreserved() {
        let a = entry(hoursAgo: 1), b = entry(hoursAgo: 2), c = entry(hoursAgo: 3)
        let sections = HistoryDayGrouping.sections([a, b, c], now: now, calendar: calendar)
        #expect(sections.count == 1)
        #expect(sections[0].entries.map(\.id) == [a, b, c].map(\.id))
    }

    @Test("empty input yields no sections")
    func emptyInput() {
        #expect(HistoryDayGrouping.sections([], now: now, calendar: calendar).isEmpty)
    }

    @Test("only adjacent same-day entries merge — relevance-ordered input stays split")
    func nonAdjacentDaysStaySplit() {
        // Simulates why search results must not be grouped: same day, split
        // by an entry from another day.
        let entries = [entry(hoursAgo: 1), entry(hoursAgo: 30), entry(hoursAgo: 2)]
        let sections = HistoryDayGrouping.sections(entries, now: now, calendar: calendar)
        #expect(sections.map(\.title) == [
            "Today — Sunday 12 July", "Yesterday — Saturday 11 July", "Today — Sunday 12 July",
        ])
    }

    @Test("titles pin to the calendar day, not 24-hour windows")
    func calendarDayNotWindow() {
        // 11 hours ago is 23:00 *yesterday* even though it's within 24h.
        let sections = HistoryDayGrouping.sections(
            [entry(hoursAgo: 11)], now: now, calendar: calendar)
        #expect(sections.map(\.title) == ["Yesterday — Saturday 11 July"])
    }
}
