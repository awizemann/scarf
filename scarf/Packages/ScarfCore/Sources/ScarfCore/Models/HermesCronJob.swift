import Foundation
import os

public struct HermesCronJob: Identifiable, Sendable, Codable, Equatable {
    public nonisolated let id: String
    public nonisolated let name: String
    public nonisolated let prompt: String
    public nonisolated let skills: [String]?
    public nonisolated let model: String?
    public nonisolated let schedule: CronSchedule
    public nonisolated let enabled: Bool
    public nonisolated let state: String
    public nonisolated let deliver: String?
    public nonisolated let nextRunAt: String?
    public nonisolated let lastRunAt: String?
    public nonisolated let lastError: String?
    public nonisolated let preRunScript: String?
    public nonisolated let deliveryFailures: Int?
    public nonisolated let lastDeliveryError: String?
    public nonisolated let timeoutType: String?
    public nonisolated let timeoutSeconds: Int?
    public nonisolated let silent: Bool?
    /// Hermes v0.12+ — the directory the job runs from. Hermes injects
    /// AGENTS.md / CLAUDE.md / .cursorrules from this dir and uses it
    /// as cwd for terminal/file/code_exec tools. `nil` preserves the
    /// pre-v0.12 behaviour (no project context files).
    public nonisolated let workdir: String?
    /// Hermes v0.12+ — chain another cron job's last output into this
    /// job's prompt. YAML-only field today (no `--context-from` CLI
    /// flag yet) — Scarf displays it but doesn't write it.
    public nonisolated let contextFrom: [String]?
    /// Hermes v0.13+ — script-only watchdog mode. When `true` the
    /// pre-run script runs but the AI turn is skipped. `nil` means the
    /// jobs.json file is pre-v0.13 (treat as `false`); `false` is the
    /// explicit v0.13+ default. Capability-gated on `hasCronNoAgent`
    /// at all write call sites.
    public nonisolated let noAgent: Bool?
    /// Hermes v0.18+ — optional per-job mirror of the delivery output
    /// into the target chat session's transcript. `nil` = unset (falls
    /// back to the global `cron.mirror_delivery` config; Hermes only
    /// persists the key when explicitly set). Scarf round-trips it but
    /// has no editor UI yet.
    public nonisolated let attachToSession: Bool?
    /// Every jobs.json key this model doesn't declare, preserved verbatim
    /// (including explicit nulls) so a Scarf rewrite can never strip state
    /// the Hermes scheduler owns. v0.18.2 audit: Hermes persists ~15 such
    /// fields today — `enabled_toolsets`, `repeat`, `provider`, `base_url`,
    /// `run_claim`/`fire_claim`, snapshots, … — and the list grows per
    /// release. Generic passthrough kills the whole strip-on-toggle bug
    /// class (workdir/contextFrom/noAgent in v0.18, run_claim in v0.18.2).
    public nonisolated let extra: [String: JSONValue]

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, prompt, skills, model, schedule, enabled, state, deliver, silent
        case nextRunAt = "next_run_at"
        case lastRunAt = "last_run_at"
        case lastError = "last_error"
        // Hermes has only ever persisted the pre-run script as "script"
        // (cron/jobs.py `"script": normalized_script` since v0.11). The
        // "pre_run_script" key Scarf used through v2.15 never existed
        // upstream — decode it as a legacy fallback for jobs.json files
        // Scarf itself wrote, but always encode "script".
        case preRunScript = "script"
        case legacyPreRunScript = "pre_run_script"
        case deliveryFailures = "delivery_failures"
        case lastDeliveryError = "last_delivery_error"
        case timeoutType = "timeout_type"
        case timeoutSeconds = "timeout_seconds"
        case workdir
        case contextFrom = "context_from"
        case noAgent = "no_agent"
        case attachToSession = "attach_to_session"
    }

    /// Memberwise init. Swift doesn't synthesize one for us because
    /// of the hand-written Codable conformance. The iOS Cron editor
    /// uses this to rebuild jobs from user-edited fields.
    public nonisolated init(
        id: String,
        name: String,
        prompt: String,
        skills: [String]? = nil,
        model: String? = nil,
        schedule: CronSchedule,
        enabled: Bool,
        state: String,
        deliver: String? = nil,
        nextRunAt: String? = nil,
        lastRunAt: String? = nil,
        lastError: String? = nil,
        preRunScript: String? = nil,
        deliveryFailures: Int? = nil,
        lastDeliveryError: String? = nil,
        timeoutType: String? = nil,
        timeoutSeconds: Int? = nil,
        silent: Bool? = nil,
        workdir: String? = nil,
        contextFrom: [String]? = nil,
        noAgent: Bool? = nil,
        attachToSession: Bool? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.skills = skills
        self.model = model
        self.schedule = schedule
        self.enabled = enabled
        self.state = state
        self.deliver = deliver
        self.nextRunAt = nextRunAt
        self.lastRunAt = lastRunAt
        self.lastError = lastError
        self.preRunScript = preRunScript
        self.deliveryFailures = deliveryFailures
        self.lastDeliveryError = lastDeliveryError
        self.timeoutType = timeoutType
        self.timeoutSeconds = timeoutSeconds
        self.silent = silent
        self.workdir = workdir
        self.contextFrom = contextFrom
        self.noAgent = noAgent
        self.attachToSession = attachToSession
        self.extra = extra
    }

    public nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id                = try c.decode(String.self, forKey: .id)
        // `name`/`prompt`/`state` are required keys in every jobs.json
        // Hermes writes, but a hand-edited file can carry `null` (or drop
        // the key) — and a hard decode there fails the WHOLE file, taking
        // every other job's list entry down with it. Default instead.
        self.name              = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.prompt            = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        self.skills            = try c.decodeIfPresent([String].self, forKey: .skills)
        self.model             = try c.decodeIfPresent(String.self, forKey: .model)
        // Hermes's own reader is tolerant here (`cron/jobs.py`):
        // `(job.get("schedule") or {})` — schedule may be null or absent —
        // and `job.get("enabled", True)`. Mirror that instead of failing
        // the record (which used to fail the WHOLE file and blank the cron
        // board). A defaulted empty schedule is elided again on encode.
        self.schedule          = try c.decodeIfPresent(CronSchedule.self, forKey: .schedule)
            ?? CronSchedule(kind: "")
        self.enabled           = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.state             = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        self.deliver           = try c.decodeIfPresent(String.self, forKey: .deliver)
        self.nextRunAt         = try c.decodeIfPresent(String.self, forKey: .nextRunAt)
        self.lastRunAt         = try c.decodeIfPresent(String.self, forKey: .lastRunAt)
        self.lastError         = try c.decodeIfPresent(String.self, forKey: .lastError)
        self.preRunScript      = try c.decodeIfPresent(String.self, forKey: .preRunScript)
            ?? c.decodeIfPresent(String.self, forKey: .legacyPreRunScript)
        self.deliveryFailures  = try c.decodeIfPresent(Int.self, forKey: .deliveryFailures)
        self.lastDeliveryError = try c.decodeIfPresent(String.self, forKey: .lastDeliveryError)
        self.timeoutType       = try c.decodeIfPresent(String.self, forKey: .timeoutType)
        self.timeoutSeconds    = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds)
        self.silent            = try c.decodeIfPresent(Bool.self, forKey: .silent)
        self.workdir           = try c.decodeIfPresent(String.self, forKey: .workdir)
        self.contextFrom       = try c.decodeIfPresent([String].self, forKey: .contextFrom)
        self.noAgent           = try c.decodeIfPresent(Bool.self, forKey: .noAgent)
        self.attachToSession   = try c.decodeIfPresent(Bool.self, forKey: .attachToSession)

        // Sweep every key we didn't decode above into `extra`, explicit
        // nulls included, so encode(to:) can put them back untouched.
        let known = Set(
            CodingKeys.allCases.map(\.rawValue)
        )
        let raw = try decoder.container(keyedBy: AnyCodingKey.self)
        var extras: [String: JSONValue] = [:]
        for key in raw.allKeys where !known.contains(key.stringValue) {
            extras[key.stringValue] = try raw.decode(JSONValue.self, forKey: key)
        }
        self.extra = extras
    }

    /// Return a copy with a different `enabled` flag. Used by the iOS
    /// Cron list's toggle. Lives here, next to the field list, so a new
    /// field can't be added to the struct without this copy staring the
    /// author in the face — every field must be forwarded, or a toggle
    /// round-trip silently strips it from jobs.json (workdir/contextFrom/
    /// noAgent were dropped this way until the v0.18 audit caught it).
    ///
    /// Flipping `enabled` alone is NOT enough. Since v0.20.4
    /// `is_job_runnable()` (cron/jobs.py:571–582, claim gate :2862) refuses
    /// to fire whenever `state == "paused"` OR `paused_at` is set —
    /// regardless of `enabled` — so an enable-toggle that forwards the old
    /// pause markers produces a job that looks enabled and never runs.
    /// We therefore mirror Hermes's own `pause_job`/`resume_job`
    /// (cron/jobs.py:2196–2233): disable sets `state = "paused"` +
    /// `paused_at`; enable sets `state = "scheduled"` and clears
    /// `paused_at`/`paused_reason`.
    ///
    /// Deliberately UNGATED (no `hasCronPauseMarkerGate` check). Those two
    /// Hermes functions are byte-identical at v0.20.0 (v2026.8.3) and
    /// v0.20.4 (v2026.8.18), so these markers are exactly what every
    /// supported host already writes for itself; older hosts simply ignore
    /// them in the runnable check. Gating would also be awkward here — the
    /// capability store is a service, unreachable from the model layer —
    /// and an always-correct write beats a version-conditional one.
    ///
    /// `now` is injectable for deterministic tests only.
    public nonisolated func withEnabled(_ newEnabled: Bool, now: Date = Date()) -> HermesCronJob {
        // Pause markers live in `extra` (Scarf doesn't model them as
        // fields); clearing means removing the keys — Hermes reads them
        // via `.get()`, so absent and null are equivalent.
        var newExtra = extra
        if newEnabled {
            newExtra.removeValue(forKey: "paused_at")
            newExtra.removeValue(forKey: "paused_reason")
        } else {
            newExtra["paused_at"] = .string(Self.pauseTimestampFormatter.string(from: now))
        }
        // Unconditional, matching pause_job/resume_job: a toggled job is
        // by definition no longer in whatever terminal state it held.
        let newState = newEnabled ? "scheduled" : "paused"
        return HermesCronJob(
            id: id,
            name: name,
            prompt: prompt,
            skills: skills,
            model: model,
            schedule: schedule,
            enabled: newEnabled,
            state: newState,
            deliver: deliver,
            nextRunAt: nextRunAt,
            lastRunAt: lastRunAt,
            lastError: lastError,
            preRunScript: preRunScript,
            deliveryFailures: deliveryFailures,
            lastDeliveryError: lastDeliveryError,
            timeoutType: timeoutType,
            timeoutSeconds: timeoutSeconds,
            silent: silent,
            workdir: workdir,
            contextFrom: contextFrom,
            noAgent: noAgent,
            attachToSession: attachToSession,
            extra: newExtra
        )
    }

    /// ISO 8601 UTC with fractional seconds omitted — the shape
    /// `datetime.isoformat()` produces for Hermes's own `paused_at`.
    private static let pauseTimestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    public nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(prompt, forKey: .prompt)
        try c.encodeIfPresent(skills, forKey: .skills)
        try c.encodeIfPresent(model, forKey: .model)
        // A schedule defaulted from a null/absent record (see init(from:)) is
        // NOT written back — encoding `{"kind": ""}` would put a key on disk
        // Hermes never wrote.
        if !schedule.isDecodedPlaceholder {
            try c.encode(schedule, forKey: .schedule)
        }
        try c.encode(enabled, forKey: .enabled)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(deliver, forKey: .deliver)
        try c.encodeIfPresent(nextRunAt, forKey: .nextRunAt)
        try c.encodeIfPresent(lastRunAt, forKey: .lastRunAt)
        try c.encodeIfPresent(lastError, forKey: .lastError)
        try c.encodeIfPresent(preRunScript, forKey: .preRunScript)
        try c.encodeIfPresent(deliveryFailures, forKey: .deliveryFailures)
        try c.encodeIfPresent(lastDeliveryError, forKey: .lastDeliveryError)
        try c.encodeIfPresent(timeoutType, forKey: .timeoutType)
        try c.encodeIfPresent(timeoutSeconds, forKey: .timeoutSeconds)
        try c.encodeIfPresent(silent, forKey: .silent)
        try c.encodeIfPresent(workdir, forKey: .workdir)
        try c.encodeIfPresent(contextFrom, forKey: .contextFrom)
        try c.encodeIfPresent(noAgent, forKey: .noAgent)
        try c.encodeIfPresent(attachToSession, forKey: .attachToSession)

        var raw = encoder.container(keyedBy: AnyCodingKey.self)
        for (key, value) in extra {
            try raw.encode(value, forKey: AnyCodingKey(stringValue: key))
        }
    }

    /// Hermes's `ONESHOT_GRACE_SECONDS` (cron/jobs.py:118) — how late a
    /// one-shot may be and still be eligible to fire.
    public static let oneShotGraceSeconds: TimeInterval = 120

    /// Whether re-enabling this job would produce a state Hermes's own CLI
    /// refuses to write.
    ///
    /// `resume_job` (cron/jobs.py:2212-2233) recomputes `next_run_at` via
    /// `compute_next_run` and RAISES when the result is `None` for a
    /// `kind == "once"` schedule — i.e. the deadline has passed (beyond the
    /// grace window) or the one-shot already ran. Resuming such a job would
    /// leave an `enabled` record that can never fire; Scarf refuses at the
    /// UI instead of writing it.
    ///
    /// Mirrors `_recoverable_oneshot_run_at` (cron/jobs.py:838-865), which
    /// is what `compute_next_run` delegates to for `kind == "once"`.
    public nonisolated func oneShotIsUnresumable(now: Date = Date()) -> Bool {
        guard schedule.kind == "once" else { return false }
        // `last_run_at` set → "already run, never eligible again".
        if let lastRunAt, !lastRunAt.isEmpty { return true }
        guard let runAt = schedule.runAt, !runAt.isEmpty else { return true }
        guard let deadline = Self.parseHermesTimestamp(runAt) else { return true }
        return deadline < now.addingTimeInterval(-Self.oneShotGraceSeconds)
    }

    /// Lenient parse of a Hermes `datetime.isoformat()` string. Handles the
    /// offset-bearing spellings via `CronScheduleFormatter.isoDate`, plus the
    /// naive (offset-less) spelling older Hermes builds persisted — read as
    /// UTC, matching `_ensure_aware`.
    nonisolated static func parseHermesTimestamp(_ iso: String) -> Date? {
        if let d = CronScheduleFormatter.isoDate(iso) { return d }
        let naive = DateFormatter()
        naive.locale = Locale(identifier: "en_US_POSIX")
        naive.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss"] {
            naive.dateFormat = format
            if let d = naive.date(from: iso) { return d }
        }
        return nil
    }

    /// Copy of this job with `next_run_at` cleared, for the JSON-write
    /// fallback path when the `hermes cron resume` CLI is unreachable.
    ///
    /// Scarf can't evaluate a cron expression, so it can't reproduce
    /// `resume_job`'s recomputed `next_run_at` locally. It doesn't have to:
    /// `_get_due_jobs_locked` (cron/jobs.py:3210-3231) treats a missing
    /// `next_run_at` as a recovery case and recomputes it from the schedule
    /// via `compute_next_run(schedule, now)` for `cron`/`interval` kinds
    /// (and `_recoverable_oneshot_run_at` for one-shots), then persists it.
    /// Clearing the field therefore hands the recomputation to Hermes and
    /// gets exactly the "next future run from now" that `resume_job` would
    /// have written — while a STALE past `next_run_at` would instead trigger
    /// a spurious catch-up fire that consumes one of `repeat.times`.
    public nonisolated func clearingNextRunAt() -> HermesCronJob {
        HermesCronJob(
            id: id, name: name, prompt: prompt, skills: skills, model: model,
            schedule: schedule, enabled: enabled, state: state, deliver: deliver,
            nextRunAt: nil, lastRunAt: lastRunAt, lastError: lastError,
            preRunScript: preRunScript, deliveryFailures: deliveryFailures,
            lastDeliveryError: lastDeliveryError, timeoutType: timeoutType,
            timeoutSeconds: timeoutSeconds, silent: silent, workdir: workdir,
            contextFrom: contextFrom, noAgent: noAgent,
            attachToSession: attachToSession, extra: extra
        )
    }

    /// Operator-facing state, ported from Hermes's `effective_job_state`
    /// (cron/jobs.py:585–602).
    ///
    /// The scheduler honours `enabled`, not `state` — so a job with
    /// `enabled == true` must NEVER display as paused. That divergence was
    /// the 07-30 outage failure mode upstream: the list looked frozen while
    /// the fleet kept running. Terminal states (`completed` / `error`) are
    /// preserved regardless of `enabled`.
    ///
    /// The pause marker Hermes checks (`_has_pause_marker`) is `paused_at`,
    /// which Scarf carries verbatim in `extra` (see `withEnabled`).
    public nonisolated var effectiveState: String {
        let stored = state.trimmingCharacters(in: .whitespaces)
        if stored == "completed" || stored == "error" { return stored }
        let hasPauseMarker: Bool = {
            guard let marker = extra["paused_at"] else { return false }
            if case .null = marker { return false }
            return true
        }()
        if !enabled {
            if hasPauseMarker || stored == "paused" { return "paused" }
            return stored.isEmpty ? "paused" : stored
        }
        // enabled == true is authoritative: never claim paused.
        if stored == "paused" || hasPauseMarker { return "scheduled" }
        return stored.isEmpty ? "scheduled" : stored
    }

    /// Human-readable state for list rows and detail headers. Always the
    /// effective state — never the raw stored one.
    public nonisolated var stateDisplay: String { effectiveState }

    /// Terminal per Hermes's `is_terminal_job` — the states from which
    /// `update_job` refuses re-activation ("Cannot activate terminal cron
    /// job …", cron/jobs.py:2593/2694). `cron resume --run-now` / `--at`
    /// is the documented escape hatch.
    public nonisolated var isTerminal: Bool {
        let s = effectiveState
        return s == "completed" || s == "error"
    }

    // MARK: - repeat (unmodeled; lives in `extra`)

    /// `repeat` normalized to `(times, completed)`.
    ///
    /// Hermes persists `{"times": n|null, "completed": n}`, but as of
    /// **v0.21.0** every entry point funnels user/agent input through
    /// `normalize_repeat_value` (cron/jobs.py:798-825), so a hand-edited
    /// or tool-written `jobs.json` legitimately carries a BARE value:
    /// `"forever"`/`"infinite"`/`"inf"`/`"none"`/`""` → infinite (nil),
    /// `"once"`/`"one"`/`"1x"` → 1, a number (or numeric string) → itself,
    /// with `<= 0` folding to infinite. (The normalizer is v0.21.0-only,
    /// but this reader is version-independent by design: it interprets what
    /// is already on disk, and a pre-0.21 store can hold exactly the same
    /// bare values — nothing here needs capability gating.) Scarf keeps `repeat` verbatim in
    /// `extra` (so a rewrite never normalizes on Hermes's behalf) and
    /// reads it through here.
    public nonisolated var repeatSpec: (times: Int?, completed: Int) {
        guard let raw = extra["repeat"] else { return (nil, 0) }
        if case .object(let o) = raw {
            var completed = 0
            if case .int(let c)? = o["completed"] { completed = c }
            return (Self.normalizeRepeatValue(o["times"]), completed)
        }
        return (Self.normalizeRepeatValue(raw), 0)
    }

    /// Port of `cron/jobs.py::normalize_repeat_value`. Returns `nil` for
    /// "run forever" (including unparseable input, matching Hermes's
    /// `<= 0 -> None` fold rather than raising into a UI read path).
    public nonisolated static func normalizeRepeatValue(_ value: JSONValue?) -> Int? {
        guard let value else { return nil }
        switch value {
        case .null:
            return nil
        case .int(let i):
            return i <= 0 ? nil : i
        case .double(let d):
            let i = Int(d)
            return i <= 0 ? nil : i
        case .bool, .array, .object:
            return nil
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespaces).lowercased()
            if ["forever", "infinite", "inf", "none", ""].contains(t) { return nil }
            if ["once", "one", "1x"].contains(t) { return 1 }
            guard let i = Int(t) else { return nil }
            return i <= 0 ? nil : i
        }
    }

    public nonisolated var stateIcon: String {
        switch effectiveState {
        case "scheduled": return "clock"
        case "running": return "play.circle"
        case "completed": return "checkmark.circle"
        // `error` is the live terminal state Hermes persists and that
        // effective_job_state() preserves (cron/jobs.py:585–602); `failed`
        // is Scarf-era legacy kept for older jobs.json files.
        case "error", "failed": return "xmark.circle"
        case "paused": return "pause.circle"
        default: return "questionmark.circle"
        }
    }

    public nonisolated var deliveryDisplay: String? {
        guard let deliver, !deliver.isEmpty else { return nil }
        // v0.9.0 extends Discord routing to threads: `discord:<chat>:<thread>`.
        if deliver.hasPrefix("discord:") {
            let parts = deliver.dropFirst("discord:".count).split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 {
                return "Discord thread \(parts[1]) in \(parts[0])"
            }
            if parts.count == 1 {
                return "Discord \(parts[0])"
            }
        }
        return deliver
    }
}

public struct CronSchedule: Sendable, Codable, Equatable {
    public nonisolated let kind: String
    public nonisolated let runAt: String?
    public nonisolated let display: String?
    /// Cron expression for `kind == "cron"`. Hermes persists this as
    /// `expr` (cron/jobs.py parse_schedule); the `expression` key Scarf
    /// wrote through v2.15 is decoded as a legacy fallback only — current
    /// Hermes reads `schedule["expr"]` unconditionally, so encoding
    /// anything else produces a job the scheduler can't run.
    public nonisolated let expression: String?
    /// Interval length for `kind == "interval"` — required by the Hermes
    /// scheduler; dropping it on rewrite breaks every recurring job.
    public nonisolated let minutes: Int?
    /// Unmodeled schedule keys, preserved verbatim (see HermesCronJob.extra).
    public nonisolated let extra: [String: JSONValue]

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case runAt = "run_at"
        case display
        case expression = "expr"
        case legacyExpression = "expression"
        case minutes
    }

    public nonisolated init(
        kind: String,
        runAt: String? = nil,
        display: String? = nil,
        expression: String? = nil,
        minutes: Int? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.kind = kind
        self.runAt = runAt
        self.display = display
        self.expression = expression
        self.minutes = minutes
        self.extra = extra
    }

    /// True when this value is the empty placeholder `init(from:)` fabricates
    /// for a record whose `schedule` was null/absent (Hermes tolerates both).
    /// `encode(to:)` elides such a schedule so it never lands on disk.
    public nonisolated var isDecodedPlaceholder: Bool {
        kind.isEmpty && runAt == nil && display == nil
            && expression == nil && minutes == nil && extra.isEmpty
    }

    /// The schedule string that round-trips back through
    /// `hermes cron edit --schedule` — **never** the human display label.
    ///
    /// Hermes stores a one-shot as
    /// `{"kind": "once", "run_at": "<ISO>", "display": "once at 2026-02-03 14:00"}`
    /// (`cron/jobs.py::parse_schedule`, verified at tag `v2026.8.31`).
    /// `parse_schedule` can read the `run_at` ISO timestamp back, but it has
    /// no branch that understands `"once at 2026-02-03 14:00"`: the phrase is
    /// not an `every …` form, not a 5-field cron expression, does not start
    /// with `\d{4}-\d{2}-\d{2}` and contains no `T`, so it falls through to
    /// `parse_duration` and the edit dies with `Invalid schedule`. Editing any
    /// one-shot job was therefore impossible while the sheet seeded itself
    /// from `display`.
    ///
    /// Intervals prefer the stored `minutes` (the field the scheduler
    /// actually runs on) re-rendered as `every Nm`, which `parse_schedule`
    /// round-trips exactly; cron kinds use `expr`.
    public nonisolated var editValue: String {
        switch kind.lowercased() {
        case "once", "runat", "run_at":
            if let runAt, !runAt.isEmpty { return runAt }
        case "interval":
            if let minutes { return "every \(minutes)m" }
        case "cron":
            if let expression, !expression.isEmpty { return expression }
        default:
            break
        }
        return expression ?? display ?? ""
    }

    public nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Tolerant like Hermes's reader: a schedule dict without `kind`
        // (or with `kind: null`) reads as an unknown/empty kind rather than
        // failing the record.
        self.kind       = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        self.runAt      = try c.decodeIfPresent(String.self, forKey: .runAt)
        self.display    = try c.decodeIfPresent(String.self, forKey: .display)
        self.expression = try c.decodeIfPresent(String.self, forKey: .expression)
            ?? c.decodeIfPresent(String.self, forKey: .legacyExpression)
        self.minutes    = try c.decodeIfPresent(Int.self, forKey: .minutes)

        let known = Set(CodingKeys.allCases.map(\.rawValue))
        let raw = try decoder.container(keyedBy: AnyCodingKey.self)
        var extras: [String: JSONValue] = [:]
        for key in raw.allKeys where !known.contains(key.stringValue) {
            extras[key.stringValue] = try raw.decode(JSONValue.self, forKey: key)
        }
        self.extra = extras
    }

    public nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // Don't fabricate `kind: ""` for a record that never carried one.
        if !kind.isEmpty { try c.encode(kind, forKey: .kind) }
        try c.encodeIfPresent(runAt, forKey: .runAt)
        try c.encodeIfPresent(display, forKey: .display)
        try c.encodeIfPresent(expression, forKey: .expression)
        try c.encodeIfPresent(minutes, forKey: .minutes)

        var raw = encoder.container(keyedBy: AnyCodingKey.self)
        for (key, value) in extra {
            try raw.encode(value, forKey: AnyCodingKey(stringValue: key))
        }
    }
}

// Hand-written `init(from:)` / `encode(to:)` so Swift 6 doesn't synthesize a
// MainActor-isolated Codable conformance — `HermesFileService.loadCronJobs`
// is nonisolated and needs to decode this from a background task.
public struct CronJobsFile: Sendable, Codable {
    public nonisolated let jobs: [HermesCronJob]
    public nonisolated let updatedAt: String?

    public enum CodingKeys: String, CodingKey {
        case jobs
        case updatedAt = "updated_at"
    }

    public nonisolated init(jobs: [HermesCronJob], updatedAt: String?) {
        self.jobs = jobs
        self.updatedAt = updatedAt
    }

    public nonisolated init(from decoder: any Decoder) throws {
        // Hermes v0.20.6+ `load_jobs()` (cron/jobs.py:1648-1727) tolerates
        // three on-disk shapes and auto-repairs the two odd ones back to
        // `{"jobs": [...]}` on the next save. Scarf must READ all three or
        // it renders an empty board (and, worse, its own rewrite would
        // clobber a store Hermes would have repaired):
        //
        //   1. `{"jobs": [ {...}, ... ]}`          — canonical
        //   2. `{"jobs": {"<id>": {...}, ...}}`    — id-keyed map, written by
        //      external tools / hand edits. Flattened with an id-preserving
        //      merge: an inline `"id"` wins, otherwise the map key is adopted.
        //      Non-dict values are junk and are skipped, not fatal.
        //   3. `[ {...}, ... ]`                    — bare top-level array.
        if let c = try? decoder.container(keyedBy: CodingKeys.self), c.contains(.jobs) {
            if let raw = try? c.decode([JSONValue].self, forKey: .jobs) {
                self.jobs = Self.decodeJobsTolerantly(raw)
            } else if let map = try? c.decode([String: JSONValue].self, forKey: .jobs) {
                self.jobs = try Self.flattenIDKeyedJobs(map)
            } else {
                // Neither array nor map — decode strictly so the thrown
                // error describes the real shape problem for the banner.
                self.jobs = try c.decode([HermesCronJob].self, forKey: .jobs)
            }
            self.updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
            return
        }
        // Bare array root.
        let raw = try decoder.singleValueContainer().decode([JSONValue].self)
        self.jobs = Self.decodeJobsTolerantly(raw)
        self.updatedAt = nil
    }

    /// Per-record tolerant decode of the jobs array. Hermes's own reader
    /// (`_normalize_job_record` / `list_jobs`, cron/jobs.py) is read-tolerant
    /// and skips malformed records with a warning rather than failing the
    /// file; hand edits are documented as supported, so one bad record must
    /// not blank the whole cron board. A record irrecoverable even under
    /// the tolerant field defaults (e.g. no `id` at all) is skipped and
    /// logged, never fatal.
    private nonisolated static func decodeJobsTolerantly(
        _ raw: [JSONValue]
    ) -> [HermesCronJob] {
        var out: [HermesCronJob] = []
        for (index, value) in raw.enumerated() {
            guard case .object = value else {
                flattenLogger.warning(
                    "jobs.json: skipping non-object jobs[\(index, privacy: .public)]"
                )
                continue
            }
            do {
                let data = try JSONEncoder().encode(value)
                out.append(try JSONDecoder().decode(HermesCronJob.self, from: data))
            } catch {
                flattenLogger.warning(
                    "jobs.json: skipping undecodable jobs[\(index, privacy: .public)]: \(String(describing: error), privacy: .public)"
                )
            }
        }
        return out
    }

    /// Flatten `{"<id>": {job}}` to `[job]`, adopting the map key as `id`
    /// when the value has no (non-empty) inline `id`. Mirrors
    /// `cron/jobs.py`'s `{**v, "id": v.get("id") or k}`. Non-object values
    /// are skipped — a flattened record wouldn't be a job.
    ///
    /// Tolerant like the array path (`decodeJobsTolerantly`): a bad entry is
    /// skipped and logged, and the rest of the board still renders — the
    /// behavior Hermes's own `list_jobs` has for malformed records. The
    /// `decodeFailed` banner is reserved for a file that isn't a jobs store
    /// at all.
    private nonisolated static let flattenLogger = Logger(subsystem: "com.scarf", category: "HermesCronJob")

    private nonisolated static func flattenIDKeyedJobs(
        _ map: [String: JSONValue]
    ) throws -> [HermesCronJob] {
        var out: [HermesCronJob] = []
        // Stable order: the map is unordered, and an arbitrary list order
        // would make the Cron board shuffle between reloads.
        for key in map.keys.sorted() {
            guard case .object(var fields)? = map[key] else { continue }
            let inlineID: String? = {
                if case .string(let s)? = fields["id"], !s.isEmpty { return s }
                return nil
            }()
            fields["id"] = .string(inlineID ?? key)
            let data = try JSONEncoder().encode(JSONValue.object(fields))
            // A single junk entry shouldn't blank the whole board — but a
            // silent drop is how "my job vanished" bugs get filed, so say so.
            do {
                out.append(try JSONDecoder().decode(HermesCronJob.self, from: data))
            } catch {
                flattenLogger.warning(
                    "jobs.json: skipping undecodable id-keyed entry \(key, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
        return out
    }

    public nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jobs, forKey: .jobs)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }
}
