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
                // Neither a list nor a string. Hermes does NOT degrade here:
                // `_normalize_skill_list` falls through to `list(skills)`
                // (`cron/jobs.py:391` @ `v2026.9.7`), which raises TypeError
                // on a number or bool and returns the KEYS of a mapping. That
                // raise is unguarded all the way out — `_apply_skill_fields`
                // (`:403`) → `_normalize_job_record` (`:456`) → `list_jobs`
                // (`:1851`) — so `hermes cron list` fails outright on such a
                // record. Scarf deliberately diverges and degrades to
                // skill-less instead of failing the whole file: Scarf is a
                // read-only viewer and a hand-edited jobs.json must not blank
                // the board. The skills it shows for that one job are wrong in
                // the mapping case; nothing Scarf writes back invents them.
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
    /// Flipping `enabled` alone is NOT enough. Since v0.20.1
    /// `is_job_runnable()` (`cron/jobs.py::is_job_runnable`, v2026.9.7
    /// :482-485; its one in-file call site is the claim gate at :2509, and
    /// the scheduler's own scan filter is
    /// `cron/scheduler_provider.py:261`) refuses
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
    /// v0.20.1 (v2026.8.13 — the tag that introduced `_has_pause_marker`,
    /// `cron/jobs.py:482`, called from `is_job_runnable` at `:489`/`:498`;
    /// the name does not occur at v2026.8.3 at all), so these markers are
    /// exactly what every
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
        //
        // The two halves are separate predicates because
        // `recoveryOffer` needs them separately: a TERMINAL one-shot has the
        // `_reject_terminal_activation` door shut, a merely past-deadline one
        // has the `resume_job` door shut, and `rearm_oneshot` opens the second
        // but not the first kind of Resume.
        guard schedule.kind == "once" else { return false }
        return isTerminal || isPastDeadlineOneShot(now: now)
    }

    /// The non-terminal half of `oneShotIsUnresumable`: a `once` job whose
    /// `run_at` is already past Hermes's grace window, so `resume_job` raises
    /// `"Cannot resume: one-shot time … is in the past"` BEFORE `update_job`
    /// (`cron/jobs.py:1991-1996` @ `v2026.9.7`).
    ///
    /// Floor-walked: that `ValueError` first appears at **`v2026.7.7`**
    /// (0.18.1) and is absent from every earlier tag through `v2026.7.1`
    /// (`grep "Cannot resume: one-shot time"` across all 32 `v2026.*` tags).
    /// Pre-refusing on an older host would refuse what the host accepts, so
    /// the offer gates this door on `hasCronPastOneShotResumeRefusal`.
    public nonisolated func isPastDeadlineOneShot(now: Date = Date()) -> Bool {
        guard schedule.kind == "once" else { return false }
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

    /// The schedule a DUPLICATE form should open with — `schedule.editValue`
    /// for everything except a one-shot whose `run_at` is already past
    /// Hermes's grace window, which seeds EMPTY.
    ///
    /// A duplicate carries the source record's fields, and for a spent
    /// one-shot the one field it must NOT carry is the time. `cron create`
    /// refuses it outright: `_next_run_or_reject_past_oneshot`
    /// (`cron/jobs.py:1669-1680` @ `v2026.9.7`, called from the create path
    /// at `:1758`) raises `_oneshot_past_grace_error` (`:1663-1666`) when
    /// `compute_next_run` returns `None` for `kind == "once"`, so the Mac's
    /// copy is a guaranteed exit 1 with the argv already built. iOS's create
    /// is a `jobs.json` rewrite with no CLI in the path, so there the copy
    /// LANDS — permanently "scheduled" and never runnable, because the
    /// misfire backstop refuses to resurrect a one-shot more than
    /// `ONESHOT_GRACE_SECONDS` overdue (`cron/scheduler_provider.py:274-279`).
    ///
    /// Empty is the honest seed on both: the Duplicate hint already says "with
    /// a new time", and an empty schedule field is what makes the user supply
    /// one (the Mac's Save is `.disabled(form.schedule.isEmpty)`; iOS's
    /// `CronEditorView.isValid` refuses a `once` job with no future `run_at`).
    public nonisolated func duplicateSeedSchedule(now: Date = Date()) -> String {
        isPastDeadlineOneShot(now: now) ? "" : schedule.editValue
    }

    /// Drop the UNMODELED top-level `schedule_display` key.
    ///
    /// Hermes DERIVES this field: `_normalize_job_record` stamps
    /// `_schedule_display_for_job(record)` onto every record it reads
    /// (`cron/jobs.py:470` @ `v2026.9.7`), and that function PREFERS the
    /// stored top-level `schedule_display` whenever it is non-empty, only
    /// falling back to `schedule.display` / `value` / `expr` / `run_at`
    /// (`:438-446`). So a stale label does not merely display wrong — it
    /// SHADOWS the schedule it is supposed to describe, for every reader,
    /// until something rewrites it.
    ///
    /// Scarf sweeps it into `extra` (it is not in `CodingKeys`) and
    /// re-encodes `extra` verbatim, so any writer that carries a record's
    /// `extra` across a schedule change carries the OLD schedule's label
    /// onto the NEW schedule. Drop it instead and let Hermes re-derive on
    /// its next read: dropping is always safe, because the field has no
    /// authority Hermes does not re-grant it.
    public nonisolated static func droppingDerivedScheduleDisplay(
        _ extra: [String: JSONValue]
    ) -> [String: JSONValue] {
        var copy = extra
        copy.removeValue(forKey: "schedule_display")
        return copy
    }

    /// A fresh record seeded from this one, for iOS's Duplicate (round-4
    /// decision 5). iOS creates by rewriting `cron/jobs.json` rather than by
    /// shelling `cron create`, so its "ordinary create" is a NEW record —
    /// hence a new `id` and a clean run history.
    ///
    /// Everything that describes the job's CONFIG is carried, including the
    /// keys `extra` holds verbatim (`monitor_script`, `monitor_url`, the
    /// `repeat` spec) — a JSON write has no create-form to squeeze through,
    /// so unlike the Mac's duplicate it loses nothing. Everything that
    /// describes a RUN is dropped: `state` returns to `scheduled`,
    /// `next_run_at`/`last_run_at`/`last_error` and the delivery counters go,
    /// and the pause marker with them, or the copy would be born carrying the
    /// dead job's terminal state (`effective_job_state` preserves
    /// `completed`/`error` regardless of `enabled`, `cron/jobs.py:488-503` @
    /// `v2026.9.7`) and be just as unrunnable as its source.
    ///
    /// A one-shot whose time is already past grace has that time dropped too
    /// — see `duplicateSeedSchedule` for why, and `CronEditorView.isValid`
    /// for the gate that then makes the user supply a new one. The derived
    /// top-level `schedule_display` goes unconditionally: it is the label of
    /// whatever time the SOURCE was on, and the duplicate is about to be
    /// given a different one (`droppingDerivedScheduleDisplay`).
    ///
    /// The NAME gets a `(copy)` suffix (``HermesCronDuplicateName``). Seeding
    /// the source's name verbatim made `hermes cron run <name>` raise
    /// `AmbiguousJobReference` for BOTH jobs the moment the copy was saved
    /// unedited (`cron/jobs.py:1840-1845` @ `v2026.9.7`).
    /// `existingNames` has no default ON PURPOSE (P46b). It is the whole
    /// collision fix: a caller that omits it gets `(copy)` unconditionally
    /// and re-creates the ambiguity on the second duplicate of one job —
    /// which is the shape `resolve_job_ref` raises `AmbiguousJobReference`
    /// for. Pass `[]` explicitly to say "nothing to collide with".
    public nonisolated func duplicatedAsNewJob(
        id newID: String, existingNames: [String], now: Date = Date()
    ) -> HermesCronJob {
        var carried = extra
        for runtimeKey in ["paused_at", "paused_reason", "monitor_state",
                           "last_status", "last_dispatch", "last_delivery_unverified",
                           "latest_execution"] {
            carried.removeValue(forKey: runtimeKey)
        }
        carried = Self.droppingDerivedScheduleDisplay(carried)
        // `repeat.completed` is a run counter on a config field — reset the
        // count, keep the limit, so a duplicate of a job that ran all 3 of
        // its times is a job that will run 3 more.
        if case .object(var repeatObject)? = carried["repeat"] {
            repeatObject["completed"] = .int(0)
            carried["repeat"] = .object(repeatObject)
        }
        // A spent one-shot's time is the one field a duplicate must NOT
        // carry (see `duplicateSeedSchedule`): iOS's create is a `jobs.json`
        // rewrite with no CLI to refuse it, so carrying it verbatim wrote a
        // record that is "scheduled" forever and can never fire
        // (`cron/scheduler_provider.py:274-279` @ `v2026.9.7`). Blank the
        // time and let the editor make the user pick one; `display` goes with
        // it because it is the label OF that dead time.
        let seedSchedule = isPastDeadlineOneShot(now: now)
            ? CronSchedule(kind: schedule.kind, runAt: nil, display: nil,
                           expression: schedule.expression, minutes: schedule.minutes,
                           extra: schedule.extra)
            : schedule
        return HermesCronJob(
            id: newID,
            name: HermesCronDuplicateName.next(for: name, existing: existingNames),
            prompt: prompt, skills: skills, model: model,
            schedule: seedSchedule, enabled: true, state: "scheduled", deliver: deliver,
            nextRunAt: nil, lastRunAt: nil, lastError: nil,
            preRunScript: preRunScript, deliveryFailures: nil,
            lastDeliveryError: nil, timeoutType: timeoutType,
            timeoutSeconds: timeoutSeconds, silent: silent, workdir: workdir,
            contextFrom: contextFrom, noAgent: noAgent,
            attachToSession: attachToSession, extra: carried
        )
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
        let hasPauseMarker = Self.isTruthyPauseMarker(extra["paused_at"])
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

    /// Hermes's `_has_pause_marker` is
    /// `_coerce_job_text(job.get("state")).strip() == "paused" or
    /// bool(job.get("paused_at"))` (`cron/jobs.py:477-479` @ `v2026.9.7`).
    /// This helper ports the SECOND arm only — Python truthiness over
    /// `paused_at` — because `effectiveState` already carries the `state ==
    /// "paused"` arm, so the two together reproduce the whole predicate.
    ///
    /// Under Python truthiness `""`, `0`, `0.0`, `false`, `[]` and `{}` are
    /// NOT markers, and neither is `null`. Scarf used to read any non-`null`
    /// value as one, so a record carrying `paused_at: ""` rendered "paused"
    /// while the host kept firing it — exactly the divergence
    /// `effective_job_state` exists to prevent.
    static nonisolated func isTruthyPauseMarker(_ value: JSONValue?) -> Bool {
        switch value {
        case nil, .null:            return false
        case .bool(let b):          return b
        case .int(let i):           return i != 0
        case .double(let d):        return d != 0
        case .string(let s):        return !s.isEmpty
        case .array(let a):         return !a.isEmpty
        case .object(let o):        return !o.isEmpty
        }
    }

    /// Hermes's `_is_recoverable_error_job` (`cron/jobs.py:509-522` @
    /// `v2026.9.7`): `state == "error"` AND `schedule.kind` in
    /// `{"cron", "interval"}`.
    ///
    /// `state = "error"` is set ONLY when `compute_next_run()` fails for a
    /// recurring job (croniter missing, malformed schedule), so such a job
    /// still has future occurrences once the cause is fixed — treating it as
    /// terminal "would wedge it forever". `_reject_terminal_activation`
    /// exempts it (`:1865-1878`), so plain `hermes cron resume` recovers it.
    ///
    /// **Floor v0.21.0.** The symbol first exists at `v2026.8.31`
    /// (`pyproject.toml version = "0.21.0"`); at `v2026.8.27` (0.20.6) — the
    /// last tag without it — `update_job`'s terminal block is unconditional,
    /// so resume is refused there. Callers gate on
    /// `HermesCapabilities.hasCronRecoverableErrorResume`.
    ///
    /// Read off `effectiveState` for consistency with `isTerminal`, which the
    /// two predicates are always evaluated together with; `effectiveState`
    /// preserves `error` verbatim (`effective_job_state` returns a terminal
    /// stored state unchanged, `:490-491`).
    public nonisolated var isRecoverableErrorJob: Bool {
        effectiveState == "error" && (schedule.kind == "cron" || schedule.kind == "interval")
    }

    /// Whether `hermes cron resume <id> --run-now` / `--at` can succeed at
    /// all: `rearm_oneshot` re-checks the JOB's own schedule inside `apply`
    /// and raises `_REARM_RECURRING_ERROR` — "Cannot re-arm recurring jobs:
    /// re-arm is one-shot-only; use plain resume or cron run." — for
    /// anything but `once` (`cron/jobs.py:2040-2042`, `:2065-2066` @
    /// `v2026.9.7`); `cron_resume` prints it and returns 1
    /// (`hermes_cli/cron.py:691-695`).
    ///
    /// **No flag needed.** The guard is present verbatim inside
    /// `rearm_oneshot` at the function's FIRST tag, `v2026.8.27` (0.20.6,
    /// `cron/jobs.py:2467-2471` on the parsed schedule, `:2490-2494` on the
    /// job's own schedule inside `apply`) and at `v2026.8.31` — i.e. re-arm
    /// has never accepted a recurring job on any host that has re-arm at
    /// all, and that is exactly `hasCronResumeRunNow`'s floor.
    public nonisolated var isRearmableOneShot: Bool { schedule.kind == "once" }

    /// What Scarf may offer this job, given the host's floors. The single
    /// source of truth both platforms' view models delegate to, so the Mac
    /// detail pane, the Bots routines list and the iOS toggle cannot drift
    /// apart again.
    ///
    /// - Parameters:
    ///   - hostRefusesTerminalJobs: `HermesCapabilities.hasCronResumeRunNow`
    ///     (`isV0206OrLater`). Below it neither `update_job` nor
    ///     `trigger_job` refuses a terminal job and `--run-now` does not
    ///     exist, so Scarf pre-refuses nothing and offers no re-arm — the
    ///     rule `refusesTerminalJobLocally` already documented.
    ///   - hostRecoversErrorRecurring:
    ///     `HermesCapabilities.hasCronRecoverableErrorResume`
    ///     (`isV021OrLater`) — the `_is_recoverable_error_job` exemption.
    ///   - hostRefusesPastOneShotResume:
    ///     `HermesCapabilities.hasCronPastOneShotResumeRefusal`
    ///     (`isV0181OrLater`) — `resume_job`'s
    ///     `"Cannot resume: one-shot time … is in the past"` guard.
    public nonisolated func recoveryOffer(
        hostRefusesTerminalJobs: Bool,
        hostRecoversErrorRecurring: Bool,
        hostRefusesPastOneShotResume: Bool,
        now: Date = Date()
    ) -> CronRecoveryOffer {
        guard isTerminal else {
            // A running job is offered Pause, not recovery.
            guard !enabled else { return .none }
            // Third door: a paused one-shot whose deadline has passed. Plain
            // Resume raises inside `resume_job` before `update_job` is
            // reached, so only `--run-now` re-arms it. iOS pre-refused this
            // and the Mac did not — that divergence is what this arm removes.
            if hostRefusesPastOneShotResume, isPastDeadlineOneShot(now: now) {
                return hostRefusesTerminalJobs
                    ? CronRecoveryOffer(canRearm: true)
                    : CronRecoveryOffer(hint: CronRecoveryOffer.pastDeadlineOneShotHint)
            }
            return CronRecoveryOffer(
                canResume: true,
                canRearm: hostRefusesTerminalJobs && isRearmableOneShot
            )
        }
        // Pre-v0.20.6: the host accepts what Scarf would refuse. Let the CLI
        // decide and show no re-arm button (it does not exist there).
        guard hostRefusesTerminalJobs else { return CronRecoveryOffer(canResume: true) }

        if isRecoverableErrorJob {
            return hostRecoversErrorRecurring
                ? CronRecoveryOffer(canResume: true)
                : CronRecoveryOffer(hint: CronRecoveryOffer.errorNeedsNewerHermesHint)
        }
        // Genuinely terminal. Re-arm is the documented escape hatch, and it
        // is one-shot-only.
        return isRearmableOneShot
            ? CronRecoveryOffer(canRearm: true)
            : CronRecoveryOffer(
                hint: CronRecoveryOffer.noFutureOccurrencesHint(repeatTimes: repeatSpec.times))
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

    /// `monitor_script` — monitor mode's cheap source SCRIPT, run each tick
    /// BEFORE the agent; unchanged output (exact-bytes hash) suppresses the
    /// agent run entirely (`hermes cron create --monitor-script`,
    /// `hermes_cli/subcommands/cron.py:51-58` @ `v2026.9.7`). Persisted as a
    /// top-level key on the job record (`cron/jobs.py:1773`).
    public nonisolated var monitorScript: String? {
        Self.nonEmptyString(extra["monitor_script"])
    }

    /// `monitor_url` — the http(s) sibling of `monitorScript`, same
    /// hash-suppression semantics (`hermes_cli/subcommands/cron.py:59-62`,
    /// record key at `cron/jobs.py:1774` @ `v2026.9.7`). Mutually exclusive
    /// with `monitorScript`.
    public nonisolated var monitorURL: String? {
        Self.nonEmptyString(extra["monitor_url"])
    }

    /// The monitor SOURCE, whichever of the two the record carries — Hermes's
    /// own `monitor_source = job.get("monitor_script") or job.get("monitor_url")`
    /// (`hermes_cli/cron.py:190` @ `v2026.9.7`).
    public nonisolated var monitorSource: String? { monitorScript ?? monitorURL }

    /// A monitor job: the agent runs only when the source's output CHANGED.
    /// Recreating one without its source turns it into an ordinary agent job
    /// that runs — and bills — every single tick, which is why the fleet
    /// copier skips these rather than degrading them silently.
    public nonisolated var isMonitorJob: Bool { monitorSource != nil }

    /// `--continuity` — each run wakes with the job's OWN previous output in
    /// its prompt. It is not a field: Hermes stores it by putting `"self"`
    /// into `context_from` (`_apply_continuity`,
    /// `tools/cronjob_job_args.py:313-321` @ `v2026.9.7`), which
    /// `build_prompt` resolves to the job's own id
    /// (`cron/scheduler_prompt.py:77-79`). So read it the same way, and
    /// accept the already-resolved id as well as the literal sentinel.
    public nonisolated var hasRunToRunContinuity: Bool {
        !selfContextRefs.isEmpty
    }

    /// The `context_from` refs that mean "this job's own previous output".
    private nonisolated var selfContextRefs: [String] {
        (contextFrom ?? []).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.lowercased() == "self" || $0 == id }
    }

    /// `context_from` refs naming OTHER jobs — cross-job context, which
    /// `build_prompt` resolves by id (`cron/scheduler_prompt.py:77-79` @
    /// `v2026.9.7`).
    ///
    /// **No CLI can forward these, and no copy should.** `cron create` and
    /// `cron edit` expose only `--continuity`/`--no-continuity`
    /// (`hermes_cli/subcommands/cron.py:76-84`, `:115-120` @ `v2026.9.7`),
    /// which `_apply_continuity` implements purely as "ensure/remove `self`
    /// in `context_from`" and leaves every other ref untouched
    /// (`tools/cronjob_job_args.py:313-323`); there is no `--context-from`
    /// option anywhere in the CLI at that tag. The only setters are the
    /// agent's `cronjob` tool and the web dashboard.
    ///
    /// And even if there were a flag, the ids would not survive a fleet copy:
    /// `_validate_context_from_refs` (`tools/cronjob_job_args.py:326-337`)
    /// rejects any non-`self` ref that `get_job` cannot find in the TARGET
    /// profile, and a fleet copy addresses a different host whose jobs carry
    /// different ids. So the copier SURFACES the loss instead of forwarding
    /// it — the same treatment `--continuity` gets, one line up.
    public nonisolated var crossJobContextRefs: [String] {
        let mine = Set(selfContextRefs)
        return (contextFrom ?? []).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !mine.contains($0) }
    }

    /// Whether this job carries a pre-run script — the `script` field
    /// (`HermesCronJob.preRunScript`) on an AGENT job, i.e. one that is not
    /// `no_agent`.
    ///
    /// **Why the fleet copier surfaces it instead of forwarding it.** The
    /// script's whole behaviour is "run this file each tick and inject its
    /// stdout into the agent's prompt" (`hermes cron create --script`,
    /// `hermes_cli/subcommands/cron.py:41-46` @ `v2026.9.7`). `cron create`
    /// DOES take `--script` — there is no `--pre-run-script` spelling; the
    /// flag is `--script` and `_JOB_ARG_FIELDS` maps it straight onto the
    /// record's `script` key (`hermes_cli/cron.py:540`) — and it validates
    /// NOTHING at create time: the only existence check is `cron doctor`'s
    /// `_script_health_issue` (`:453-465`), run on demand, long after the
    /// fact. So forwarding `--script` across a fleet apply would create a
    /// green "created" job pointing at a path under the SOURCE host's
    /// `~/.hermes/scripts/` that the target does not have, and the failure
    /// would surface as a broken run days later rather than at the apply.
    /// Replicating the script FILE across transports is a real feature
    /// (`t-848d3adc`), not a flag; until it exists the honest answer is a
    /// downgrade note on a job that still copies and still runs its prompt.
    ///
    /// A `no_agent` job is NOT this case: there the script IS the job, so the
    /// copy would be an empty no-op and the copier DECLINES it outright
    /// (`FleetApplyPlan.CronCopySet.scriptOnly`).
    public nonisolated var hasPreRunScript: Bool {
        noAgent != true && !(preRunScript?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
    }

    /// Whether this job pins its own inference — a `--model`, a `--provider`,
    /// or a `--reasoning-effort`. Round-6 decision 8; the sibling of
    /// `hasPreRunScript`, and used the same way: a fleet copy still CREATES
    /// the job, and the note says what did not come with it.
    ///
    /// **Why the copier does not forward the pin.** All three flags exist on
    /// `cron create` at the target tag (`--model` / `--provider`
    /// `hermes_cli/subcommands/cron.py:66-72`, `--reasoning-effort` `:73-77`
    /// @ `v2026.9.7`) and would be ACCEPTED — which is exactly the P50
    /// `--script` trap: an accepted flag is not a copyable field when the
    /// value names something only the source host has. A model id is
    /// resolved against the target's own provider config and credential
    /// pools; forwarding one the target has never heard of lands a green
    /// "created" job that fails on its first run, days later. Dropping the
    /// pin instead lets `_compute_provider_model_snapshots`
    /// (`cron/jobs.py:1599-1620`) resolve the target's own default, which is
    /// the only answer Scarf can stand behind — and the note is what stops
    /// that being a silent change of which model (and whose bill) runs the
    /// user's job.
    ///
    /// Reads `provider` / `reasoning_effort` out of `extra` because Scarf
    /// keeps every unmodeled key verbatim there; `nonEmptyString` is what
    /// makes `""` mean "not set", as Hermes's own
    /// `_normalize_job_optional_text` does (`cron/jobs.py:1522-1527`).
    public nonisolated var hasModelPin: Bool {
        !modelPinFields.isEmpty
    }

    /// The pinned axes, as short human labels — what the downgrade note
    /// names. Empty exactly when `hasModelPin` is false.
    public nonisolated var modelPinFields: [String] {
        var out: [String] = []
        if let model, !model.trimmingCharacters(in: .whitespaces).isEmpty {
            out.append("model")
        }
        if Self.nonEmptyString(extra["provider"]) != nil { out.append("provider") }
        if Self.nonEmptyString(extra["reasoning_effort"]) != nil { out.append("reasoning effort") }
        return out
    }

    /// `extra[key]` as a trimmed non-empty string, or `nil`. Hermes writes
    /// these optional text fields as `None` OR `""` depending on the path
    /// (`_normalize_job_optional_text`, `cron/jobs.py:1583-1584`), and an
    /// empty string means "not set", not "set to nothing".
    nonisolated static func nonEmptyString(_ value: JSONValue?) -> String? {
        guard case .string(let s)? = value else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The `cron create` settings this record carries that Scarf's create
    /// form has no field for — so a Duplicate would silently drop them.
    ///
    /// Round-4 decision 5 makes Duplicate an ORDINARY create pre-filled from
    /// the record, and a create can only carry what the form can express:
    /// name, schedule, prompt, deliver, failure-deliver, repeat, skills,
    /// script, workdir, no-agent. Everything else `hermes cron create` accepts
    /// — `--model`/`--provider` (`hermes_cli/subcommands/cron.py:66-72` @
    /// `v2026.9.7`, record keys `cron/jobs.py:1766-1767`),
    /// `--reasoning-effort` (`:73-77`, record `:1802`), `--monitor-script` /
    /// `--monitor-url` (`:51-62`, record `:1773-1774`) and `--continuity`
    /// (`:76-84`, stored as `"self"` in `context_from`) — has no field, and a
    /// duplicate that quietly loses a model pin or a monitor source is the
    /// same silent degradation the fleet copier was just fixed for.
    ///
    /// So NAME them. The sheet shows this list; it does not pretend the copy
    /// is faithful.
    ///
    /// **`caps` is required because the list is HOST-shaped, not just
    /// record-shaped.** The two call sites (`CronView`'s duplicate sheet,
    /// `BotRoutinesView`'s) already blank `workdir`, `noAgent` and
    /// `failureDeliver` below each flag's floor — `hasCronWorkdir` (v0.12),
    /// `hasCronNoAgent` (v0.13), `hasCronFailureDeliver` (v0.21.1) — before
    /// handing the form to `createJob`. Those are real losses the form CAN
    /// express on a newer host, and the gaps line said nothing about them, so
    /// a `--workdir` job duplicated onto a pre-v0.12 host reported a faithful
    /// copy and produced a job running from the wrong directory. Pass the
    /// TARGET host's capabilities and the list names what that host drops too.
    public nonisolated func settingsACreateFormCannotCarry(
        caps: HermesCapabilities
    ) -> [String] {
        var out: [String] = []
        if let model, !model.trimmingCharacters(in: .whitespaces).isEmpty {
            out.append(String(localized: "model pin (\(model))"))
        }
        if let provider = Self.nonEmptyString(extra["provider"]) {
            out.append(String(localized: "provider (\(provider))"))
        }
        if let effort = Self.nonEmptyString(extra["reasoning_effort"]) {
            out.append(String(localized: "reasoning effort (\(effort))"))
        }
        if let source = monitorSource {
            out.append(String(localized: "monitor source (\(source))"))
        }
        if hasRunToRunContinuity {
            out.append(String(localized: "run-to-run continuity"))
        }
        // Host-gated losses: the form HAS these fields, but the call site
        // blanks each one below its floor rather than handing an older
        // argparse a flag it will exit 2 on. Silent until now.
        if let workdir, !workdir.trimmingCharacters(in: .whitespaces).isEmpty,
           !caps.hasCronWorkdir {
            out.append(String(localized: "working directory (\(workdir)) — host is below v0.12"))
        }
        if noAgent == true, !caps.hasCronNoAgent {
            out.append(String(localized: "script-only (no-agent) mode — host is below v0.13"))
        }
        if let failureDeliver, !failureDeliver.trimmingCharacters(in: .whitespaces).isEmpty,
           !caps.hasCronFailureDeliver {
            out.append(String(localized: "failure delivery (\(failureDeliver)) — host is below v0.21.1"))
        }
        return out
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

    /// The validations `hermes cron edit` performs on a SCHEDULE that the iOS
    /// form has to perform itself — P56, addendum lesson 14.
    ///
    /// iOS never shells `cron edit`: `IOSCronViewModel.saveJobs` rewrites
    /// `cron/jobs.json` through `GuardedJSONStore`, so no argparse and no
    /// `update_job` stands behind the form. Everything `cron edit` would have
    /// refused has to be refused here or it lands on disk. The full
    /// enumeration of `update_job`'s gates at `v2026.9.7` (reached from
    /// `cron_edit` → `_cron_api(action="update")`, `hermes_cli/cron.py:619`),
    /// and where each one lives on iOS:
    ///
    /// | `update_job` gate | `cron/jobs.py` @ `v2026.9.7` | iOS |
    /// |---|---|---|
    /// | `_IMMUTABLE_JOB_FIELDS` (`id`) | `:369`, raised `:1932-1935` | the form never rewrites `id` |
    /// | `_UPDATE_FIELD_NORMALIZERS` (`workdir`, `monitor_script`, `monitor_url`, `reasoning_effort`) | `:1591-1596` | no field for any of them; forwarded verbatim |
    /// | `_reject_terminal_activation` | `:1865-1878` | `CronEditorView.enabledIsLocked` (P50b) |
    /// | `_validate_job_mode_invariants` | `:1944-1949` | no field for `script`/`no_agent`/monitor, so the merged record cannot change |
    /// | `job_payload_is_empty` | `:428-435`, raised `:1950-1951` | `isValid` requires a non-blank prompt — strictly stronger |
    /// | `parse_schedule` cron-expression shape + `croniter(expr)` | `:716-726`, `:755-758` | **here**, `.cronExpressionMissing` / `.cronExpressionMalformed` |
    /// | `parse_schedule` ISO timestamp parse | `:762-780` | **here**, `.oneShotTimeUnparseable` |
    /// | `_interval_schedule` always yields an int `minutes` | `:729-730` | **here**, `.intervalMinutesMissing` |
    /// | `_next_run_or_reject_past_oneshot` / `_fill_missing_next_run` | `:1899-1910`, `:1912-1927` | `CronEditorView.oneShotTimeIsUnusable` (P50 decision 13) |
    ///
    /// The three refused here all produce the same silent shape when they
    /// reach `jobs.json`: `compute_next_run` (`:1096-1123`) answers `nil` for
    /// a `cron` kind with no `expr` (`:1112-1114`) and for an `interval` with
    /// no `minutes` (`:1106-1110`), and `_parse_aware` answers `nil` for an
    /// unreadable `run_at` (`:816-822`), so the due scan's recovery path
    /// (`_recover_missing_next_run`, `:2690-2710`) can never arm the record.
    /// The job sits in the list saying "scheduled" and never fires. A
    /// malformed-but-non-empty `expr` is worse than silent: `compute_next_run`
    /// hands it straight to `croniter(expr, base_time)` (`:1122`) with no
    /// `try`, so it raises inside the tick.
    ///
    /// Shape-only, deliberately. This is `parse_schedule`'s own pre-filter —
    /// five-or-more whitespace fields, each matching `[A-Za-z\d*\-,/]+`
    /// (`:757-758`) — not a croniter reimplementation. Scarf cannot evaluate
    /// a cron expression, and guessing at range validity would refuse
    /// expressions the host accepts; the host still gets the final word.
    ///
    /// `carriedIntervalMinutes` is what the form would actually WRITE (the
    /// existing record's `minutes`, and only while the kind is unchanged) —
    /// not what the record holds. There is no minutes field on the sheet, so
    /// a new `interval` job, or one switched to `interval` from another kind,
    /// has nowhere to get one; naming that beats writing a job that can never
    /// fire. Growing the form a minutes field is `t-b74c65a4`.
    ///
    /// No parameter takes a default: each one IS the fix (addendum lesson 10).
    public nonisolated static func scheduleFormRefusal(
        kind: String,
        expression: String,
        runAt: String,
        carriedIntervalMinutes: Int?
    ) -> CronScheduleFormRefusal? {
        switch kind {
        case "cron":
            let expr = expression.trimmingCharacters(in: .whitespacesAndNewlines)
            if expr.isEmpty { return .cronExpressionMissing }
            return cronExpressionHasParseableShape(expr) ? nil : .cronExpressionMalformed
        case "interval":
            return carriedIntervalMinutes == nil ? .intervalMinutesMissing : nil
        case "once":
            let text = runAt.trimmingCharacters(in: .whitespacesAndNewlines)
            // An EMPTY one-shot time is `oneShotTimeIsUnusable`'s refusal, not
            // this one — two messages for one field would be a worse form.
            if text.isEmpty { return nil }
            if CronScheduleFormatter.isoDate(text) != nil { return nil }
            return parseHermesTimestamp(text) == nil ? .oneShotTimeUnparseable : nil
        default:
            return nil
        }
    }

    /// `parse_schedule`'s cron-expression pre-filter, ported verbatim:
    /// `len(parts) >= 5 and all(re.match(r'^[A-Za-z\d\*\-,/]+$', p) for p
    /// in parts[:5])` (`cron/jobs.py:757-758` @ `v2026.9.7`). Letters are
    /// allowed on purpose — croniter reads `JAN-DEC` / `MON-FRI`.
    nonisolated static func cronExpressionHasParseableShape(_ expr: String) -> Bool {
        let parts = expr.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
        guard parts.count >= 5 else { return false }
        // ASCII-exact, like the Python character class: a full-width digit or
        // an accented letter is NOT a cron field, and `CharacterSet
        // .alphanumerics` would have accepted both.
        return parts.prefix(5).allSatisfy { part in
            !part.isEmpty && part.allSatisfy { ch in
                ch.isASCII && (ch.isLetter || ch.isNumber || "*-,/".contains(ch))
            }
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
    /// `59s`. The clamp is belt-and-braces against a hand-edited
    /// `jobs.json`, not against Hermes: the writer already does
    /// `max(0.0, (now - d.next_run_dt).total_seconds())` before stamping
    /// `lateness_seconds` (`cron/jobs.py:2972` @ `v2026.9.7`), so no
    /// Hermes-authored record carries a negative value. Without the clamp a
    /// negative one would render `-1s late` where the CLI says `0s`.
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

/// One schedule-shape refusal the iOS cron form makes on `hermes cron edit`'s
/// behalf — see `HermesCronJob.scheduleFormRefusal(kind:expression:runAt:carriedIntervalMinutes:)`
/// for the full table of `update_job` gates and which of them each case ports.
///
/// Each `message` says what is missing AND what happens without it, because
/// the failure it prevents is invisible: Hermes accepts the record, the list
/// row reads "scheduled", and the job simply never runs.
public enum CronScheduleFormRefusal: Sendable, Equatable, CaseIterable {
    /// `kind == "cron"` with a blank expression. `compute_next_run` returns
    /// `nil` on `if not expr` (`cron/jobs.py:1112-1114` @ `v2026.9.7`).
    case cronExpressionMissing
    /// `kind == "cron"` with an expression `parse_schedule`'s own pre-filter
    /// would reject (`cron/jobs.py:757-758`). Worse than blank: a non-empty
    /// value reaches `croniter(expr, base_time)` (`:1122`) untried.
    case cronExpressionMalformed
    /// `kind == "interval"` with no `minutes` to write. `_interval_schedule`
    /// (`cron/jobs.py:729-730`) always produces one; the iOS form has no
    /// field for it, so a new or kind-switched interval job would carry none
    /// and `compute_next_run` returns `nil` (`:1106-1110`).
    case intervalMinutesMissing
    /// `kind == "once"` with a `run_at` no reader can parse. `parse_schedule`
    /// raises `Invalid timestamp` (`cron/jobs.py:781` @ `v2026.9.7` — the
    /// `raise ValueError(f"Invalid timestamp '{schedule}': {e}")` under the
    /// `except ValueError` at `:780`); a direct `jobs.json` write instead
    /// leaves `_parse_aware` answering `nil` (`:817-823`) forever.
    case oneShotTimeUnparseable

    public var message: String {
        switch self {
        case .cronExpressionMissing:
            return String(localized: "Enter a cron expression — a cron job without one is saved but never runs.")
        case .cronExpressionMalformed:
            return String(localized: "That isn't a cron expression. Use five or more fields, like \"0 9 * * 1-5\".")
        case .intervalMinutesMissing:
            return String(localized: "Interval jobs need a minutes value this form can't set. Pick \"cron\" or \"once\", or create the job from the Mac app.")
        case .oneShotTimeUnparseable:
            return String(localized: "That isn't a readable timestamp. Use an ISO8601 time, like \"2026-09-20T09:00:00\".")
        }
    }
}
