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

    /// `_normalize_skill_list(job.get("skill"), job.get("skills"))` in Swift:
    /// trims, drops blanks, de-duplicates preserving order. Returns `nil`
    /// only when NEITHER key is present, so "no skills key at all" stays
    /// distinguishable from "explicitly empty".
    ///
    /// The legacy `skill` key is read through its OWN key type rather than
    /// being added to `CodingKeys`: `CodingKeys.allCases` is what decides
    /// which keys get swept into `extra` and re-emitted verbatim, so listing
    /// it there would silently STRIP `skill` from every jobs.json Scarf
    /// writes back. Left in `extra` it round-trips, and Hermes re-derives it
    /// from `skills` on its next load anyway (`_apply_skill_fields`).
    private enum LegacySkillKey: String, CodingKey { case skill }

    private nonisolated static func decodeSkills(
        from c: KeyedDecodingContainer<CodingKeys>,
        legacy l: KeyedDecodingContainer<LegacySkillKey>
    ) throws -> [String]? {
        let raw: [String]?
        // `skills: null` is `skills is None` in Python, which is the arm that
        // falls back to `skill` — so it counts as ABSENT here, not as empty.
        let skillsPresent = c.contains(.skills) && !((try? c.decodeNil(forKey: .skills)) ?? true)
        if skillsPresent {
            if let list = try? c.decode([String].self, forKey: .skills) {
                raw = list
            } else if let single = try? c.decode(String.self, forKey: .skills) {
                raw = [single]                    // `isinstance(skills, str)`
            } else {
                // Neither a list nor a string (a number, an object): Hermes's
                // `list(skills)` raises and the record is treated as
                // skill-less rather than failing the whole file.
                raw = []
            }
        } else if let legacy = try? l.decodeIfPresent(String.self, forKey: .skill) {
            raw = [legacy]
        } else {
            raw = nil
        }
        guard let raw else { return nil }
        var out: [String] = []
        for item in raw {
            let text = item.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty, !out.contains(text) { out.append(text) }
        }
        return out
    }

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
        // `skills` mirrors `cron/jobs.py::_normalize_skill_list` (v2026.9.7
        // :384-397), because Scarf reads `cron/jobs.json` DIRECTLY — the
        // normalisation `list_jobs` applies (`_normalize_job_record` →
        // `_apply_skill_fields`, :456/:400) never runs on this path, so the
        // record arrives raw:
        //   * `skills` PRESENT wins outright, even when empty;
        //   * a bare STRING `skills` is a one-element list (`isinstance(
        //     skills, str)`), not a decode failure — and a decode failure
        //     here fails the WHOLE file;
        //   * `skills` ABSENT falls back to the legacy singular `skill`,
        //     which is what every pre-multi-skill job still carries and what
        //     `cron edit` will compute its own `existing_skills` from.
        // Getting the last one wrong meant the skill-edit diff saw no
        // existing skills, emitted no `--remove-skill`, and the job kept a
        // skill the user had just unticked.
        self.skills            = try Self.decodeSkills(
            from: c, legacy: decoder.container(keyedBy: HermesCronJob.LegacySkillKey.self))
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
    /// `is_job_runnable()` (`cron/jobs.py::is_job_runnable`, v2026.9.7 :482-485;
    /// claim gate `_evaluate_due_job` :2910, roster filter :3009) refuses
    /// to fire whenever `state == "paused"` OR `paused_at` is set —
    /// regardless of `enabled` — so an enable-toggle that forwards the old
    /// pause markers produces a job that looks enabled and never runs.
    /// We therefore mirror Hermes's own `pause_job`/`resume_job`
    /// (`cron/jobs.py::pause_job` / `::resume_job`, v2026.9.7 :1973-2003):
    /// disable sets `state = "paused"` +
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

    /// Hermes's `ONESHOT_GRACE_SECONDS` (`cron/jobs.py`, v2026.9.7 :96) — how late a
    /// one-shot may be and still be eligible to fire.
    public static let oneShotGraceSeconds: TimeInterval = 120

    /// Whether re-enabling this job would produce a state Hermes's own CLI
    /// refuses to write.
    ///
    /// `resume_job` (`cron/jobs.py::resume_job`, v2026.9.7 :1986-2003)
    /// recomputes `next_run_at` via
    /// `compute_next_run` and RAISES when the result is `None` for a
    /// `kind == "once"` schedule — i.e. the deadline has passed (beyond the
    /// grace window) or the one-shot already ran. Resuming such a job would
    /// leave an `enabled` record that can never fire; Scarf refuses at the
    /// UI instead of writing it.
    ///
    /// Mirrors `_recoverable_oneshot_run_at` (`cron/jobs.py::_recoverable_oneshot_run_at`, v2026.9.7 :841-853), which
    /// is what `compute_next_run` delegates to for `kind == "once"`.
    public nonisolated func oneShotIsUnresumable(now: Date = Date()) -> Bool {
        guard schedule.kind == "once" else { return false }
        // NOT "`last_run_at` is set". `_recoverable_oneshot_run_at` does have
        // an "already run, never eligible again" arm (`cron/jobs.py:841-853`,
        // v2026.9.7), but `resume_job` reaches it through
        // `compute_next_run(job["schedule"])` with `last_run_at` left at its
        // `None` default (:1991 → :1103), so that arm NEVER fires on the
        // resume path. A one-shot re-armed by `rearm_oneshot` keeps its old
        // `last_run_at` (:2036-2055 clears `repeat.completed`, the claims and
        // the schedule — not the timestamp), so pausing and re-enabling such a
        // job hit a refusal the host would never have produced.
        //
        // What Hermes DOES refuse is re-activating a terminal record:
        // `update_job` arms `_reject_terminal_activation`
        // (:1865-1878, called from :1941/:1965), which is also the state a
        // genuinely spent one-shot ends in — `_advance_after_run` calls
        // `_complete_job_record` for every `kind == "once"` with no next run.
        if isTerminal { return true }
        guard let runAt = schedule.runAt, !runAt.isEmpty else { return true }
        // An offset-bearing `run_at` names one instant — compare directly.
        if let exact = CronScheduleFormatter.isoDate(runAt) {
            return exact < now.addingTimeInterval(-Self.oneShotGraceSeconds)
        }
        // A naive `run_at` is resolved by Hermes in the configured zone
        // (`cron/jobs.py::_ensure_aware`, v2026.9.7 :807-814), which Scarf
        // cannot know; `parseHermesTimestamp` reads it as UTC. The latest
        // instant it can actually denote is `T + 12h` (UTC−12), so refuse
        // only when it is past-grace in EVERY zone — the same conservative
        // window `oneShotScheduleIsPastGrace` uses. Without it, a job whose
        // deadline is still in the future for the host was refused locally
        // with a message the host would never have produced.
        guard let naive = Self.parseHermesTimestamp(runAt) else { return true }
        return naive.addingTimeInterval(12 * 3600) < now.addingTimeInterval(-Self.oneShotGraceSeconds)
    }

    /// Lenient parse of a Hermes `datetime.isoformat()` string. Handles the
    /// offset-bearing spellings via `CronScheduleFormatter.isoDate`, plus the
    /// naive (offset-less) spelling older Hermes builds persisted.
    ///
    /// **A naive value is read as UTC here, and that is NOT what Hermes
    /// does.** `cron/jobs.py::_ensure_aware` (v2026.9.7 :807-814) stamps a
    /// naive datetime with the *system-local* zone of the process reading
    /// it and then converts to the *configured Hermes* zone — it never
    /// treats one as UTC. Scarf cannot reproduce either zone: the system
    /// zone is the HOST's (which for an SSH server is not this Mac's) and
    /// the configured zone is not exposed. UTC is therefore a deliberate
    /// stand-in, and every caller must be tolerant of being off by up to
    /// ±12h — `oneShotScheduleIsPastGrace` and `oneShotIsUnresumable` each
    /// widen their window by 12h for exactly that reason. Do not "fix"
    /// this to `.current`: that would make the answer depend on the Mac's
    /// zone rather than being uniformly conservative.
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
    /// `_get_due_jobs_locked` (`cron/jobs.py::_get_due_jobs_locked`,
    /// v2026.9.7 :2985, via `_evaluate_due_job` :2910-2926) treats a missing
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
    /// (`cron/jobs.py::effective_job_state`, v2026.9.7 :488-503).
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
    /// job …", `cron/jobs.py::_reject_terminal_activation` v2026.9.7 :1865-1878,
    /// armed from `update_job` :1941 and :1965; the predicate itself is
    /// `::is_terminal_job` :504-506). `cron resume --run-now` / `--at`
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
    /// `normalize_repeat_value` (`cron/jobs.py::normalize_repeat_value`,
    /// v2026.9.7 :591-617), so a hand-edited
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

    /// `repeat` as the edit form's "Repeat" field should be seeded — the
    /// read-side sibling of `CronSchedule.editValue`.
    ///
    /// `nil` times means "run forever" (`cron/jobs.py::create_job`,
    /// v2026.9.7 :1779 — `"repeat": {"times": repeat, "completed": 0}`,
    /// `times None = forever`), and the empty field is exactly how the
    /// editor spells that, so both map to `""`. `completed` is Hermes's
    /// counter and is never edited: `_normalize_job_updates`
    /// (`cron/jobs.py` :1887-1896) carries the existing `completed` across a
    /// scalar `--repeat`, so re-sending the seeded value is idempotent.
    public nonisolated var repeatEditValue: String {
        repeatSpec.times.map(String.init) ?? ""
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
        // effective_job_state() preserves
        // (`cron/jobs.py::effective_job_state`, v2026.9.7 :488-503); `failed`
        // is Scarf-era legacy kept for older jobs.json files.
        case "error", "failed": return "xmark.circle"
        case "paused": return "pause.circle"
        default: return "questionmark.circle"
        }
    }

    // MARK: - v0.21.1 fields (read through `extra`, never modeled as stored)
    //
    // `failure_deliver`, `last_dispatch` and `last_delivery_unverified` are
    // deliberately NOT `CodingKeys` members. Modeling them would make Scarf
    // responsible for re-encoding them on every `withEnabled` rewrite, and
    // two of the three have shapes Scarf cannot faithfully round-trip: the
    // dispatch stamp grows keys per release, and `last_delivery_unverified`
    // is a list in Hermes's writer (`cron/scheduler_delivery.py::_record_unverified_delivery`, v2026.9.7
    // :1000-1008) but
    // is rendered scalar-tolerantly by the CLI (`_unverified_targets`,
    // `hermes_cli/cron.py::_unverified_targets`, v2026.9.7 :133). Reading
    // through `extra` gives the UI every
    // field while the generic passthrough keeps the bytes verbatim — the
    // same rule `repeatSpec` already follows.

    /// `failure_deliver` — the v0.21.1 override target for FAILURE notices
    /// only (`cron/jobs.py::_normalize_failure_deliver`, resolved at
    /// `cron/scheduler_delivery.py`; normalised at
    /// `cron/jobs.py::_normalize_failure_deliver` v2026.9.7 :1546, wired into
    /// the update normalisers at :1589). Absent means failures follow
    /// `deliver`; `local` suppresses failure notices entirely while run
    /// state stays visible in `cron list`.
    public nonisolated var failureDeliver: String? {
        guard case .string(let s)? = extra["failure_deliver"] else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `last_dispatch` — scheduled-vs-actual timing for the last fire
    /// (`cron/jobs.py::_evaluate_due_job`, v2026.9.7 :2971-2981). Recurring jobs only; a manual trigger and
    /// an expired one-shot never write one.
    public nonisolated var lastDispatch: CronDispatchStamp? {
        CronDispatchStamp(extra["last_dispatch"])
    }

    /// `last_delivery_unverified` — targets a live adapter acked without a
    /// `message_id`/`raw_response` (Slack/Matrix/Mattermost shape). Accepted
    /// as delivered, but unproven. Empty when the key is absent or null.
    ///
    /// Hermes writes a list; the CLI's `_unverified_targets` also tolerates a
    /// bare scalar, so this does too.
    public nonisolated var lastDeliveryUnverifiedTargets: [String] {
        switch extra["last_delivery_unverified"] {
        case .array(let items)?:
            return items.compactMap(Self.plainText).filter { !$0.isEmpty }
        case .string(let s)? where !s.isEmpty:
            return [s]
        default:
            return []
        }
    }

    /// The unverified-delivery note, or `nil` when there is nothing to
    /// say. Mirrors `_job_warnings`' "adapter acked … without
    /// message_id/raw_response" line; in the view so a test can hold the
    /// rendering against the CLI's own wording.
    public nonisolated var deliveryUnverifiedNote: String? {
        let targets = lastDeliveryUnverifiedTargets
        guard !targets.isEmpty else { return nil }
        return "Delivery unverified: \(targets.joined(separator: ", ")) acked without a message id"
    }

    private nonisolated static func plainText(_ value: JSONValue) -> String? {
        switch value {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        case .null, .array, .object: return nil
        }
    }

    /// Whether `schedule` — as typed into the create form — is an absolute
    /// one-shot Hermes v0.21.1 would REJECT outright
    /// (`cron/jobs.py::_next_run_or_reject_past_oneshot`, v2026.9.7 :1669,
    /// armed on edit at :1908: a `kind == "once"`
    /// whose `run_at` is more than `ONESHOT_GRACE_SECONDS` in the past exits
    /// non-zero instead of storing a ghost job).
    ///
    /// Only the ISO-timestamp form of `parse_schedule` (`cron/jobs.py::parse_schedule`, v2026.9.7 :765-778)
    /// can be in the past — `in 30m` is computed from now, and intervals and
    /// cron expressions always have a future occurrence — so nothing else is
    /// inspected.
    ///
    /// **Naive timestamps.** Hermes resolves an offset-less timestamp in the
    /// *configured Hermes timezone*, which Scarf cannot know. Guessing would
    /// refuse a schedule the host would have accepted, so a naive value is
    /// only refused when it is past-grace in EVERY timezone: the latest
    /// instant it can denote is `T + 12h` (UTC−12, the westernmost offset).
    public nonisolated static func oneShotScheduleIsPastGrace(
        _ schedule: String, now: Date = Date()
    ) -> Bool {
        let text = schedule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains("T") || text.range(of: "^\\d{4}-\\d{2}-\\d{2}", options: .regularExpression) != nil
        else { return false }
        let cutoff = now.addingTimeInterval(-oneShotGraceSeconds)
        // An explicit offset (or `Z`) names one instant — compare it directly.
        if let exact = CronScheduleFormatter.isoDate(text) { return exact < cutoff }
        guard let naive = parseHermesTimestamp(text) else { return false }
        return naive.addingTimeInterval(12 * 3600) < cutoff
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
    /// (`cron/jobs.py::parse_schedule`, v2026.9.7 :733-802).
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
        // Hermes v0.20.6+ `load_jobs()` (`cron/jobs.py::load_jobs`, v2026.9.7 :1237-1285) tolerates
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

/// `last_dispatch` — Hermes v0.21.1's scheduled-vs-actual stamp for a
/// recurring job's last fire (`cron/jobs.py::_evaluate_due_job`, v2026.9.7 :2971-2981, issue #99879).
///
/// Read-only diagnostics, decoded by FIELD PRESENCE rather than by version
/// (charter C4): a host that doesn't write the stamp simply has no key, and
/// `hermes_cli/cron.py::_dispatch_display` itself renders nothing unless
/// `scheduled_at`, `dispatched_at` and `kind` are all present — so this
/// mirrors that requirement instead of inventing a partial reading.
public struct CronDispatchStamp: Sendable, Equatable {
    /// `on_time` (within ticker slack), `late` (> 300s but within the
    /// catch-up grace window), or `catch_up` (beyond grace — accumulated
    /// misses were skipped and the job executed once now).
    /// `cron/jobs.py::_classify_dispatch_lateness` (v2026.9.7 :874).
    public enum Kind: String, Sendable, Equatable {
        case onTime = "on_time"
        case late
        case catchUp = "catch_up"
    }

    public let scheduledAt: String
    public let dispatchedAt: String
    public let kind: Kind
    public let latenessSeconds: Double

    public init(scheduledAt: String, dispatchedAt: String, kind: Kind, latenessSeconds: Double) {
        self.scheduledAt = scheduledAt
        self.dispatchedAt = dispatchedAt
        self.kind = kind
        self.latenessSeconds = latenessSeconds
    }

    /// `nil` for an absent, non-object, or incomplete stamp — including a
    /// `kind` spelling a future Hermes introduces, which must degrade to
    /// "no diagnostics" rather than to a wrong badge.
    public init?(_ value: JSONValue?) {
        guard case .object(let o)? = value,
              case .string(let scheduled)? = o["scheduled_at"], !scheduled.isEmpty,
              case .string(let dispatched)? = o["dispatched_at"], !dispatched.isEmpty,
              case .string(let rawKind)? = o["kind"],
              let kind = Kind(rawValue: rawKind)
        else { return nil }
        self.scheduledAt = scheduled
        self.dispatchedAt = dispatched
        self.kind = kind
        switch o["lateness_seconds"] {
        case .double(let d)?: self.latenessSeconds = d
        case .int(let i)?: self.latenessSeconds = Double(i)
        default: self.latenessSeconds = 0
        }
    }

    public var isLate: Bool { kind != .onTime }

    /// One line per `_dispatch_display`'s three shapes. Lives here rather
    /// than in the view so a test can hold it against the CLI's own text.
    public var summary: String {
        switch kind {
        case .onTime:
            return "Dispatch: on time (scheduled \(scheduledAt))"
        case .late:
            return "Late: scheduled \(scheduledAt), ran \(dispatchedAt) (\(latenessDisplay) late)"
        case .catchUp:
            return "Catch-up after missed fire: scheduled \(scheduledAt), ran \(dispatchedAt) (\(latenessDisplay) late)"
        }
    }

    /// Port of `hermes_cli/cron.py::_format_lateness` (`45s`, `2h 5m`,
    /// `1d 3h`, `0m`) so the number Scarf shows matches `cron list`.
    ///
    /// `max(0, int(seconds))` is Hermes's own first line
    /// (`hermes_cli/cron.py::_format_lateness`, v2026.9.7 :88-91): it
    /// TRUNCATES (Python `int()`), it does not round, and it CLAMPS. Scarf
    /// rounded and never clamped, so `59.7s` read `1m` where the CLI says
    /// `59s`, and an EARLY dispatch — a scheduler that fires a second
    /// ahead of `scheduled_at`, which the catch-up path can produce —
    /// rendered `-1s late` where the CLI says `0s`.
    public var latenessDisplay: String {
        // `Int(_: Double)` TRAPS on NaN/±inf, and `lateness_seconds` is
        // whatever the JSON carried. Hermes's own `except (TypeError,
        // ValueError): return "?"` arm is the same admission that the field
        // is not trusted; a hand-edited `jobs.json` must not crash the UI.
        guard latenessSeconds.isFinite,
              latenessSeconds < Double(Int.max), latenessSeconds > Double(Int.min)
        else { return "?" }
        let seconds = max(0, Int(latenessSeconds))
        if seconds < 60 { return "\(seconds)s" }
        let totalMinutes = seconds / 60
        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = days > 0 ? 0 : totalMinutes % 60
        let parts = [(days, "d"), (hours, "h"), (minutes, "m")]
            .filter { $0.0 > 0 }
            .map { "\($0.0)\($0.1)" }
        return parts.isEmpty ? "0m" : parts.joined(separator: " ")
    }
}
