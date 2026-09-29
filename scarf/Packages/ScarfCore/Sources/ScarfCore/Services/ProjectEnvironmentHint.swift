import Foundation

/// How a project-scoped chat hands Scarf's project context to Hermes, and
/// the disk work each way needs at chat start (#142 P3). Shared by the Mac
/// (`ChatViewModel`) and ScarfGo (`ChatController`) so both platforms gate
/// on the same flag and migrate the same way.
///
/// - `.managedBlock` — hosts below v0.16, or whose version is unknown: the
///   managed block is written into the project's context file, exactly as
///   every earlier release did (charter C1).
/// - `.environmentHint` — `HermesCapabilities.supportsEnvironmentHint`: the
///   short hint rides `HERMES_ENVIRONMENT_HINT` on the `hermes acp` spawn,
///   and the managed block is stripped from the project's files.
public enum ProjectEnvironmentHint {

    public enum Delivery: Equatable, Sendable {
        case managedBlock
        case environmentHint
    }

    /// The gate. `.empty` capabilities (probe failed / not yet known) are
    /// `.managedBlock`, so an undetected host keeps today's behaviour.
    public static func delivery(for capabilities: HermesCapabilities) -> Delivery {
        capabilities.supportsEnvironmentHint ? .environmentHint : .managedBlock
    }

    /// What `prepare` produced: the request to hand the ACP spawn, plus the
    /// strip failure (if any). A failed strip is not fatal — the hint is
    /// still delivered; the stale block just stays in the file until the
    /// next chat start retries.
    public struct Prepared: Sendable {
        public let request: EnvironmentHintRequest
        public let stripError: (any Error)?
    }

    /// Blocking (transport I/O — an SSH round trip per read on a remote).
    /// Call off the main actor and off the cooperative pool (`OffPool`).
    ///
    /// Renders the hint from the same `ProjectStore.agentContextBlockInput`
    /// both platforms already build the block from, reads the user's own
    /// `agent.environment_hint` from the target host's config.yaml so the
    /// composer can keep it, and strips the managed block from the project
    /// directory the chat spawns in (`projectPath`, the registry's path —
    /// the same one the block writer targets; defaults to the record's).
    public static func prepare(
        project: ScarfProject, projectPath: String? = nil, context: ServerContext
    ) -> Prepared {
        let input = ProjectStore(context: context).agentContextBlockInput(for: project)
        let request = EnvironmentHintRequest(
            scarfHint: ProjectContextBlock.renderEnvironmentHint(input),
            configHint: readConfigHint(context: context)
        )
        var stripError: (any Error)?
        do {
            try ProjectContextBlock.stripForEnvironmentHint(
                forProjectAt: projectPath ?? project.rootPath, context: context)
        } catch {
            stripError = error
        }
        return Prepared(request: request, stripError: stripError)
    }

    /// `agent.environment_hint` from `context`'s config.yaml — the remote
    /// host's for an SSH context, since that is the Hermes that reads it.
    /// Nil when the file is missing, unreadable, or the key is unset/blank.
    /// Blocking; see `prepare`.
    public static func readConfigHint(context: ServerContext) -> String? {
        guard let yaml = context.readText(context.paths.configYAML) else { return nil }
        return configHint(fromConfigYAML: yaml)
    }

    /// Pure: `agent.environment_hint` from config.yaml text, as the string
    /// Hermes reads — `str(value).strip()` over what PyYAML loaded
    /// (`agent/prompt_builder.py:1057-1058` @ v0.21.4). Nil only when the key
    /// is absent or blank.
    ///
    /// Why the care: Scarf's `HERMES_ENVIRONMENT_HINT` REPLACES the config
    /// hint, so the composer has to carry this value forward. A misread
    /// value silently rewrites the user's hint; a MISSING one (nil for a key
    /// that is set) silently drops it. So where the exact string is out of
    /// reach this errs towards returning an approximation, never nil:
    ///
    /// - `|` / `>` block scalars (any chomping, explicit indent or odd
    ///   indentation): the parser's rendering is already PyYAML's string, so
    ///   it is only trimmed — never comment-stripped (a `#` in a block body
    ///   is text) or unquoted (a leading `'` is a character).
    /// - Plain and quoted scalars: comment and quotes resolved, and a
    ///   double-quoted body's escapes decoded (`"a\nb"` is two lines).
    /// - A flow map (`agent: {environment_hint: …}`): read from the map.
    /// - A list (block or flow): rendered like Python's `str(list)`,
    ///   `['a', 'b']`. A nested map: `{'k': 'v'}` with keys sorted (the
    ///   parser does not keep map order, so this one is approximate).
    /// - Typed plain scalars stay as written: `yes` is `yes` here where
    ///   Hermes says `True`. Close enough — the user's intent survives.
    public static func configHint(fromConfigYAML yaml: String) -> String? {
        let parsed = HermesYAML.parseNestedYAML(yaml)
        let path = "agent.environment_hint"
        // A flow list or flow map leaves `values[path] == ""` beside its
        // `lists` / `maps` entry, so those are asked first.
        let value: String?
        if let items = parsed.lists[path] {
            value = "[" + items.map { pythonRepr(HermesYAML.unquotedScalar($0)) }
                .joined(separator: ", ") + "]"
        } else if let map = parsed.maps[path], !map.isEmpty {
            value = "{" + map.keys.sorted().map {
                pythonRepr($0) + ": " + pythonRepr(HermesYAML.unquotedScalar(map[$0] ?? ""))
            }.joined(separator: ", ") + "}"
        } else if let raw = parsed.values[path] {
            value = parsed.blockScalarPaths.contains(path) ? raw : HermesYAML.unquotedScalar(raw)
        } else if let raw = parsed.maps["agent"]?["environment_hint"] {
            value = HermesYAML.unquotedScalar(raw)
        } else {
            value = nil
        }
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return EnvironmentHintComposer.isBlank(trimmed) ? nil : trimmed
    }

    /// A string as Python's `repr` quotes it for the common case (single
    /// quotes; backslash and `'` escaped). Only for the list/map
    /// approximation above.
    private static func pythonRepr(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'") + "'"
    }
}

/// A per-chat holder for the hint the next `hermes acp` spawn should carry,
/// keyed by the project cwd it was prepared for. The Mac builds its
/// `ACPClient` before the project prep has run, and the channel is only
/// opened at `start()`, so the spawn reads the slot then. A spawn for any
/// other cwd (or none) gets nil — a hint never leaks across projects.
public final class EnvironmentHintSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var entry: (projectPath: String, request: EnvironmentHintRequest)?

    public init() {}

    public func set(_ request: EnvironmentHintRequest?, forProjectPath projectPath: String) {
        lock.lock(); defer { lock.unlock() }
        entry = request.map { (projectPath, $0) }
    }

    public func request(forProjectCwd cwd: String?) -> EnvironmentHintRequest? {
        lock.lock(); defer { lock.unlock() }
        guard let cwd, let entry, entry.projectPath == cwd else { return nil }
        return entry.request
    }
}
