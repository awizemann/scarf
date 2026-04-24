import Foundation

/// Human-readable rendering for `CronSchedule` values.
///
/// Hermes stores cron schedules with a raw `expression` (`"0 */6 * * *"`)
/// plus an optional `display` label. In practice, the CLI writes both
/// fields to the same raw cron string — so UIs that render `display`
/// verbatim (both Scarf and ScarfGo, pre-fix) end up showing
/// `0 */6 * * *` to every user, technical or not.
///
/// This formatter pattern-matches the most common cron shapes and
/// produces English phrases. Anything it doesn't recognise falls back
/// to the raw expression with a short hint, so nothing is lost.
///
/// Not a full cron parser — covers ~95% of real-world schedules while
/// staying ~80 lines. Add patterns here as users hit unrecognised
/// shapes; the fallback already ships working.
public enum CronScheduleFormatter {

    /// Primary entry point. Returns a phrase suitable for the row
    /// subtitle in Mac + ScarfGo cron lists.
    public static func humanReadable(from schedule: CronSchedule) -> String {
        // Trust `display` when it doesn't look like raw cron. Users
        // CAN set descriptive labels via `hermes cron set-display`;
        // we don't want to overwrite that.
        if let display = schedule.display,
           !display.isEmpty,
           !looksLikeCron(display)
        {
            return display
        }

        // Use whatever raw expression we have (preferring `expression`,
        // falling back to `display` since Hermes sometimes writes the
        // cron into both fields).
        let expr = schedule.expression ?? schedule.display ?? ""
        if !expr.isEmpty, let phrase = translate(cronExpression: expr) {
            return phrase
        }

        // Non-cron kinds (runAt, interval) get their own branches.
        switch schedule.kind.lowercased() {
        case "runat", "run_at":
            if let runAt = schedule.runAt, !runAt.isEmpty {
                return "Once on \(runAt)"
            }
            return "One-off"
        case "interval":
            return schedule.display ?? schedule.expression ?? "Interval"
        default:
            break
        }

        // Final fallback: show whatever raw string we have.
        return expr.isEmpty ? schedule.kind : expr
    }

    /// Relative next-run phrase (`"in 4 hours"`, `"tomorrow at 9 AM"`).
    /// `nil` date → `"—"`. Used by both Mac + ScarfGo cron rows.
    public static func formatNextRun(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let style = Date.RelativeFormatStyle(
            presentation: .numeric,
            unitsStyle: .wide
        )
        return date.formatted(style)
    }

    /// Same as `formatNextRun(_:)` but accepts the ISO8601 string
    /// Hermes stores in `jobs.json`. Attempts several parse strategies
    /// because Hermes varies the exact serialization between versions
    /// (with / without fractional seconds, with / without timezone
    /// offset). On parse failure, falls back to the raw string so we
    /// never blank out useful info.
    public static func formatNextRun(iso: String?, now: Date = Date()) -> String {
        guard let iso, !iso.isEmpty else { return "—" }
        if let date = Self.isoDate(iso) {
            return formatNextRun(date, now: now)
        }
        return iso
    }

    nonisolated static func isoDate(_ iso: String) -> Date? {
        let formatters: [ISO8601DateFormatter] = {
            let f1 = ISO8601DateFormatter()
            f1.formatOptions = [.withInternetDateTime]
            let f2 = ISO8601DateFormatter()
            f2.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return [f1, f2]
        }()
        for f in formatters {
            if let d = f.date(from: iso) { return d }
        }
        return nil
    }

    // MARK: - Implementation

    /// True when the string starts with a typical cron token
    /// (`<digit>`, `*`, `@`). Lets us distinguish a label like
    /// "Daily release check" from a raw `0 9 * * *` in `display`.
    nonisolated static func looksLikeCron(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return false }
        if first == "@" { return true }           // @hourly, @daily, @weekly
        if first == "*" { return true }           // wildcard in minute
        if first.isNumber {                        // "0 ..." etc.
            // Only consider it cron if the string has at least 4 spaces
            // (= 5 fields) or starts with a single-digit followed by
            // space. Short strings like "2:00pm" should stay as labels.
            let spaces = trimmed.filter { $0 == " " }.count
            return spaces >= 4
        }
        return false
    }

    /// Translate a raw cron expression into English. Returns nil when
    /// no pattern matches — caller falls back to the raw string.
    nonisolated static func translate(cronExpression raw: String) -> String? {
        let expr = raw.trimmingCharacters(in: .whitespaces)

        // Named macros Hermes / crontab accept as synonyms.
        switch expr.lowercased() {
        case "@hourly":  return "Every hour"
        case "@daily", "@midnight": return "Daily at midnight"
        case "@weekly":  return "Weekly (Sunday at midnight)"
        case "@monthly": return "Monthly (1st at midnight)"
        case "@yearly", "@annually": return "Yearly (Jan 1 at midnight)"
        default: break
        }

        let fields = expr.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count == 5 else { return nil }
        let (min, hr, dom, mon, dow) = (fields[0], fields[1], fields[2], fields[3], fields[4])

        // Every N minutes: */N * * * *
        if min.hasPrefix("*/"), hr == "*", dom == "*", mon == "*", dow == "*",
           let n = Int(min.dropFirst(2))
        {
            return n == 1 ? "Every minute" : "Every \(n) minutes"
        }

        // Every hour on minute M: M * * * *   (M is a single number)
        if let _ = Int(min), hr == "*", dom == "*", mon == "*", dow == "*" {
            return min == "0" ? "Every hour" : "Every hour at :\(zeroPad(min))"
        }

        // Every N hours at minute M: M */N * * *
        if let _ = Int(min), hr.hasPrefix("*/"), dom == "*", mon == "*", dow == "*",
           let n = Int(hr.dropFirst(2))
        {
            let minute = min == "0" ? "" : " at :\(zeroPad(min))"
            return n == 1 ? "Every hour\(minute)" : "Every \(n) hours\(minute)"
        }

        // Daily at H:MM: MM H * * *
        if let _ = Int(min), let h = Int(hr), dom == "*", mon == "*", dow == "*" {
            return "Daily at \(formatClock(hour: h, minute: min))"
        }

        // Weekdays at H:MM: MM H * * 1-5
        if let _ = Int(min), let h = Int(hr), dom == "*", mon == "*", dow == "1-5" {
            return "Weekdays at \(formatClock(hour: h, minute: min))"
        }

        // Weekends at H:MM: MM H * * 0,6  or 6,0
        if let _ = Int(min), let h = Int(hr), dom == "*", mon == "*",
           (dow == "0,6" || dow == "6,0" || dow == "6,7")
        {
            return "Weekends at \(formatClock(hour: h, minute: min))"
        }

        // Single weekday at H:MM: MM H * * <D>
        if let _ = Int(min), let h = Int(hr), dom == "*", mon == "*",
           let d = Int(dow), (0...7).contains(d)
        {
            return "Every \(weekdayName(d)) at \(formatClock(hour: h, minute: min))"
        }

        // Monthly on day D at H:MM: MM H D * *
        if let _ = Int(min), let h = Int(hr), let d = Int(dom), mon == "*", dow == "*" {
            return "Monthly on day \(d) at \(formatClock(hour: h, minute: min))"
        }

        return nil
    }

    private static func zeroPad(_ s: String) -> String {
        s.count == 1 ? "0" + s : s
    }

    /// Return "H:MM AM/PM" — 12-hour with no leading zero on the hour,
    /// to match how iOS natively displays times in most list contexts.
    private static func formatClock(hour h: Int, minute mStr: String) -> String {
        let m = Int(mStr) ?? 0
        var h12 = h % 12
        if h12 == 0 { h12 = 12 }
        let suffix = (h < 12) ? "AM" : "PM"
        if m == 0 {
            return "\(h12) \(suffix)"
        }
        let mm = m < 10 ? "0\(m)" : "\(m)"
        return "\(h12):\(mm) \(suffix)"
    }

    private static func weekdayName(_ d: Int) -> String {
        // Cron convention: 0 and 7 are both Sunday; 1..6 are Mon..Sat.
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        return names[max(0, min(7, d))]
    }
}
