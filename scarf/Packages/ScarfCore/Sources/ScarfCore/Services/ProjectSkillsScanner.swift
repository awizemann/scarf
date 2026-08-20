import Foundation

/// Repo-local ("project") skills, introduced by Hermes v0.20.4.
///
/// A checkout can carry its own skills under `./.hermes/skills` or
/// `./.agents/skills`. Hermes only loads them for sessions started
/// inside that repo, and only once the repo root is **trusted** — listed
/// under `skills.trusted_project_dirs` in `~/.hermes/config.yaml`, which
/// `hermes skills trust <path>` / `untrust <path>` maintains
/// (`hermes_cli/main.py:_cmd_skills_trust`).
///
/// This scanner is the read side of that feature: given a project root,
/// it reports which candidate dirs exist, what skills they hold, and
/// whether the root is currently trusted. It never writes — trust
/// changes go through the CLI so Hermes owns the config file.
///
/// Synchronous + transport-backed, matching `SkillsScanner`: call it
/// from a detached task since SFTP `stat`/`listDirectory` block.
public enum ProjectSkillsScanner: Sendable {

    /// Candidate repo-local skill dirs, relative to the project root, in
    /// Hermes's own precedence order (`PROJECT_SKILLS_SUBDIRS`).
    public static let subdirectories = [".hermes/skills", ".agents/skills"]

    /// Scan one project root. `isTrusted` is read from the host's
    /// `config.yaml`; `skills` lists every skill found on disk whether
    /// or not the repo is trusted — an untrusted repo showing its
    /// (currently inert) skills is exactly the prompt the user needs to
    /// decide about trusting it.
    public static func scan(
        projectRoot: String,
        context: ServerContext,
        transport: any ServerTransport
    ) -> ProjectSkillsSnapshot {
        let root = normalizedRoot(projectRoot)
        let trusted = trustedProjectRoots(context: context).contains(root)

        var skills: [ProjectSkill] = []
        for subdir in subdirectories {
            let dir = root + "/" + subdir
            guard transport.stat(dir)?.isDirectory == true else { continue }
            skills.append(contentsOf: scanSkillsDir(dir, source: subdir, transport: transport))
        }
        return ProjectSkillsSnapshot(root: root, isTrusted: trusted, skills: skills)
    }

    /// Skills directly under `dir`, plus one level of category nesting —
    /// mirrors `SkillsScanner`'s `<category>/<name>/` layout while also
    /// accepting the flat `<name>/SKILL.md` most repos use.
    private static func scanSkillsDir(
        _ dir: String,
        source: String,
        transport: any ServerTransport
    ) -> [ProjectSkill] {
        guard let entries = try? transport.listDirectory(dir) else { return [] }
        var found: [ProjectSkill] = []
        for entry in entries.filter({ !$0.hasPrefix(".") }).sorted() {
            let path = dir + "/" + entry
            guard transport.stat(path)?.isDirectory == true else { continue }
            if transport.fileExists(path + "/SKILL.md") {
                found.append(ProjectSkill(name: entry, path: path, source: source))
                continue
            }
            // Category directory: one more level down.
            guard let nested = try? transport.listDirectory(path) else { continue }
            for child in nested.filter({ !$0.hasPrefix(".") }).sorted() {
                let childPath = path + "/" + child
                guard transport.stat(childPath)?.isDirectory == true,
                      transport.fileExists(childPath + "/SKILL.md")
                else { continue }
                found.append(ProjectSkill(name: child, path: childPath, source: source))
            }
        }
        return found
    }

    /// Resolved set of trusted project roots from the host's config.
    public static func trustedProjectRoots(context: ServerContext) -> Set<String> {
        guard let yaml = context.readText(context.paths.configYAML) else { return [] }
        return Set(parseTrustedProjectDirs(yaml).map(normalizedRoot))
    }

    /// Parse `skills.trusted_project_dirs` out of `config.yaml`. Accepts
    /// both the block form PyYAML writes and the inline-array form, the
    /// same two shapes `SkillsViewModel.readDisabledSkillNames` handles.
    /// Empty on any older host — the key simply isn't there.
    public static func parseTrustedProjectDirs(_ yaml: String) -> [String] {
        var inSkillsBlock = false
        var listIndent: Int?
        var collected: [String] = []
        let key = "trusted_project_dirs:"

        for raw in yaml.components(separatedBy: "\n") {
            if raw.hasPrefix("skills:") {
                inSkillsBlock = true
                continue
            }
            guard inSkillsBlock else { continue }
            // A new top-level block ends the `skills:` scope.
            if !raw.hasPrefix(" ") && !raw.hasPrefix("\t") && raw.contains(":") { break }
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(key) {
                let after = trimmed.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
                if after.hasPrefix("[") && after.hasSuffix("]") {
                    let body = after.dropFirst().dropLast()
                    for part in body.split(separator: ",") {
                        let value = String(part).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                        if !value.isEmpty { collected.append(value) }
                    }
                    return collected
                }
                listIndent = raw.prefix { $0 == " " || $0 == "\t" }.count
                continue
            }
            if let baseIndent = listIndent {
                let leading = raw.prefix { $0 == " " || $0 == "\t" }.count
                if !trimmed.isEmpty {
                    if leading < baseIndent { break }
                    if leading == baseIndent && !trimmed.hasPrefix("- ") { break }
                }
                if trimmed.hasPrefix("- ") {
                    let value = trimmed.dropFirst(2)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                    if !value.isEmpty { collected.append(String(value)) }
                }
            }
        }
        return collected
    }

    /// Trailing-slash-insensitive path key. Hermes resolves both sides
    /// with `Path.resolve()`; we can't resolve symlinks over a transport,
    /// so we normalize the one difference that actually shows up between
    /// a config entry and a project's stored root path.
    static func normalizedRoot(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespaces)
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// `hermes skills trust <path>` / `hermes skills untrust <path>`.
    /// The path is always passed explicitly — the CLI's cwd-relative
    /// default would resolve against wherever Scarf happens to run.
    public static func trustArgs(_ root: String, trusted: Bool) -> [String] {
        ["skills", trusted ? "trust" : "untrust", root]
    }
}

// MARK: - Models

/// One repo-local skill.
public struct ProjectSkill: Identifiable, Sendable, Equatable {
    public var id: String { path }
    public let name: String
    public let path: String
    /// Which candidate dir it came from (`.hermes/skills` / `.agents/skills`).
    public let source: String

    public init(name: String, path: String, source: String) {
        self.name = name
        self.path = path
        self.source = source
    }
}

/// Result of scanning one project root.
public struct ProjectSkillsSnapshot: Sendable, Equatable {
    public let root: String
    public let isTrusted: Bool
    public let skills: [ProjectSkill]

    public init(root: String, isTrusted: Bool, skills: [ProjectSkill]) {
        self.root = root
        self.isTrusted = isTrusted
        self.skills = skills
    }

    /// True when the repo carries skills that are on disk but inert.
    public var hasUntrustedSkills: Bool { !isTrusted && !skills.isEmpty }
}
