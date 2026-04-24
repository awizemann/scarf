import Testing
import Foundation
@testable import ScarfCore

@Suite("CronScheduleFormatter")
struct CronScheduleFormatterTests {

    private func cron(_ expr: String, display: String? = nil, kind: String = "cron") -> CronSchedule {
        CronSchedule(kind: kind, runAt: nil, display: display, expression: expr)
    }

    // MARK: - Named macros

    @Test func hourlyMacro() {
        #expect(CronScheduleFormatter.humanReadable(from: cron("@hourly")) == "Every hour")
    }

    @Test func dailyMacro() {
        #expect(CronScheduleFormatter.humanReadable(from: cron("@daily")) == "Daily at midnight")
        #expect(CronScheduleFormatter.humanReadable(from: cron("@midnight")) == "Daily at midnight")
    }

    @Test func weeklyMonthlyYearlyMacros() {
        #expect(CronScheduleFormatter.humanReadable(from: cron("@weekly")) == "Weekly (Sunday at midnight)")
        #expect(CronScheduleFormatter.humanReadable(from: cron("@monthly")) == "Monthly (1st at midnight)")
        #expect(CronScheduleFormatter.humanReadable(from: cron("@yearly")) == "Yearly (Jan 1 at midnight)")
        #expect(CronScheduleFormatter.humanReadable(from: cron("@annually")) == "Yearly (Jan 1 at midnight)")
    }

    // MARK: - Every N minutes / hours

    @Test func everyNMinutes() {
        #expect(CronScheduleFormatter.humanReadable(from: cron("*/5 * * * *")) == "Every 5 minutes")
        #expect(CronScheduleFormatter.humanReadable(from: cron("*/15 * * * *")) == "Every 15 minutes")
        #expect(CronScheduleFormatter.humanReadable(from: cron("*/1 * * * *")) == "Every minute")
    }

    @Test func everyHourAtMinute() {
        #expect(CronScheduleFormatter.humanReadable(from: cron("0 * * * *")) == "Every hour")
        #expect(CronScheduleFormatter.humanReadable(from: cron("30 * * * *")) == "Every hour at :30")
        #expect(CronScheduleFormatter.humanReadable(from: cron("5 * * * *")) == "Every hour at :05")
    }

    @Test func everyNHours() {
        #expect(CronScheduleFormatter.humanReadable(from: cron("0 */6 * * *")) == "Every 6 hours")
        #expect(CronScheduleFormatter.humanReadable(from: cron("15 */2 * * *")) == "Every 2 hours at :15")
        #expect(CronScheduleFormatter.humanReadable(from: cron("0 */1 * * *")) == "Every hour")
    }

    // MARK: - Daily at H / Weekdays / Weekends / single weekday

    @Test func dailyAtHour() {
        #expect(CronScheduleFormatter.humanReadable(from: cron("0 9 * * *")) == "Daily at 9 AM")
        #expect(CronScheduleFormatter.humanReadable(from: cron("30 14 * * *")) == "Daily at 2:30 PM")
        #expect(CronScheduleFormatter.humanReadable(from: cron("0 0 * * *")) == "Daily at 12 AM")
        #expect(CronScheduleFormatter.humanReadable(from: cron("0 12 * * *")) == "Daily at 12 PM")
    }

    @Test func weekdaysAtHour() {
        #expect(CronScheduleFormatter.humanReadable(from: cron("0 9 * * 1-5")) == "Weekdays at 9 AM")
    }

    @Test func weekendsAtHour() {
        #expect(CronScheduleFormatter.humanReadable(from: cron("0 10 * * 0,6")) == "Weekends at 10 AM")
        #expect(CronScheduleFormatter.humanReadable(from: cron("0 10 * * 6,7")) == "Weekends at 10 AM")
    }

    @Test func singleWeekdayAtHour() {
        #expect(CronScheduleFormatter.humanReadable(from: cron("0 8 * * 1")) == "Every Monday at 8 AM")
        #expect(CronScheduleFormatter.humanReadable(from: cron("30 17 * * 5")) == "Every Friday at 5:30 PM")
        #expect(CronScheduleFormatter.humanReadable(from: cron("0 9 * * 0")) == "Every Sunday at 9 AM")
    }

    // MARK: - Monthly

    @Test func monthlyOnDayAtHour() {
        #expect(CronScheduleFormatter.humanReadable(from: cron("0 9 1 * *")) == "Monthly on day 1 at 9 AM")
        #expect(CronScheduleFormatter.humanReadable(from: cron("30 14 15 * *")) == "Monthly on day 15 at 2:30 PM")
    }

    // MARK: - Display override (user-set label)

    @Test func displayOverrideWinsWhenNonCron() {
        let s = CronSchedule(
            kind: "cron",
            runAt: nil,
            display: "Pre-standup release check",
            expression: "0 9 * * 1-5"
        )
        #expect(CronScheduleFormatter.humanReadable(from: s) == "Pre-standup release check")
    }

    @Test func displayIgnoredWhenItLooksLikeCron() {
        // Hermes CLI duplicates the cron into display — we should
        // still translate it, not echo it back to the user.
        let s = CronSchedule(
            kind: "cron",
            runAt: nil,
            display: "0 */6 * * *",
            expression: "0 */6 * * *"
        )
        #expect(CronScheduleFormatter.humanReadable(from: s) == "Every 6 hours")
    }

    // MARK: - Unknown shapes fall back gracefully

    @Test func unknownPatternReturnsRaw() {
        let weird = "0,30 9,17 1,15 * *"
        #expect(CronScheduleFormatter.humanReadable(from: cron(weird)) == weird)
    }

    @Test func runAtKindFormatsAsOneOff() {
        let s = CronSchedule(kind: "runAt", runAt: "2026-05-01 09:00", display: nil, expression: nil)
        #expect(CronScheduleFormatter.humanReadable(from: s) == "Once on 2026-05-01 09:00")
    }

    // MARK: - Next-run relative formatter

    @Test func nextRunNilReturnsEmDash() {
        #expect(CronScheduleFormatter.formatNextRun(nil) == "—")
    }

    @Test func nextRunRelativeFormatterProducesNonEmptyString() {
        let inTwoHours = Date().addingTimeInterval(2 * 60 * 60)
        let formatted = CronScheduleFormatter.formatNextRun(inTwoHours)
        #expect(!formatted.isEmpty)
        #expect(formatted != "—")
    }
}
