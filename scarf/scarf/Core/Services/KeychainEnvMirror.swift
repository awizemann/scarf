import Foundation
import os
import ScarfCore

/// Mirrors a project's resolved Keychain secrets into a managed region
/// of `~/.hermes/.env` so Hermes cron jobs (and any other agent
/// process Hermes spawns) can use them via `os.environ`.
///
/// **Why this exists.** Hermes has no `keychain://` URI resolver. When
/// a cron prompt says *"read config.json, get values.api_token, call
/// the API,"* Hermes reads the literal `keychain://...` string and
/// forwards it as the token — producing 401s. By mirroring resolved
/// values into `~/.hermes/.env` (which the cron scheduler reloads
/// fresh on every tick at `cron/scheduler.py:897-903`), the agent can
/// reference them via shell expansion (`$SCARF_<SLUG>_<FIELD>`) when
/// it invokes the terminal or code_exec tool.
///
/// **Source of truth stays in the Keychain.** This service derives
/// content; it never accepts plaintext values from callers. config.json
/// continues to store `keychain://` URIs unchanged.
///
/// **Marker contract.** One block per project, slug-namespaced:
/// `# scarf-secrets:begin <slug>` / `# scarf-secrets:end <slug>`. The
/// splice logic lives in ScarfCore's `SecretsEnvBlock`. Other slugs'
/// blocks and user-authored content outside any block are preserved
/// byte-identically.
///
/// **Trust boundary.** Mode 0600 on `~/.hermes/.env` is enforced by
/// `LocalTransport.writeFile`'s heuristic for `.env` paths. Plaintext
/// on disk matches the existing trust model for `ANTHROPIC_API_KEY`
/// and other Hermes-side credentials in the same file.
struct KeychainEnvMirror: Sendable {
    private nonisolated static let logger = Logger(subsystem: "com.scarf", category: "KeychainEnvMirror")

    let context: ServerContext

    nonisolated init(context: ServerContext = .local) {
        self.context = context
    }

    // MARK: - Public

    /// Resolve every `secret`-typed config field for `project` and
    /// splice the result into `~/.hermes/.env` under a marker-bounded
    /// block keyed by the template's slug. No-op when the project
    /// has no cached manifest (schema-less project) or no secret
    /// fields.
    nonisolated func mirror(project: ProjectEntry) throws {
        guard let resolved = try resolveSecrets(for: project) else {
            // No manifest cache or no secret fields — nothing to mirror.
            // Don't write an empty block; that would leave dangling
            // markers if a project briefly had secrets and then dropped
            // them. Use unmirror() in that path instead.
            return
        }
        try mirror(
            slug: resolved.slug,
            entries: resolved.entries,
            envPath: context.paths.envFile
        )
    }

    /// Splice-only seam: takes pre-resolved entries and writes the
    /// block to `envPath`. Used by `mirror(project:)` after Keychain
    /// resolution; also exposed for unit tests that don't want to
    /// touch the user's real Keychain or `~/.hermes/.env`.
    ///
    /// - Empty `entries` removes the block (idempotent — no error
    ///   when block isn't there). This is the single sentinel for
    ///   "project briefly had secrets, no longer does."
    /// - Path is checked for `.env`-suffix before writing so the
    ///   `LocalTransport` mode-0600 heuristic kicks in.
    /// - No-op when the rewritten output equals the existing file —
    ///   avoids file-watcher churn from idempotent reconciles.
    nonisolated func mirror(
        slug: String,
        entries: [(key: String, value: String)],
        envPath: String
    ) throws {
        guard Self.isMirrorableSlug(slug) else {
            Self.logger.warning("refusing to mirror block for malformed slug \(slug, privacy: .public)")
            return
        }
        let transport = context.makeTransport()
        if entries.isEmpty {
            try unmirrorBlock(slug: slug, envPath: envPath, transport: transport)
            return
        }
        let block = SecretsEnvBlock.renderBlock(slug: slug, entries: entries)
        let existing = try readExisting(at: envPath, transport: transport)
        let rewritten = SecretsEnvBlock.applyBlock(block, forSlug: slug, to: existing)
        try writeIfChanged(path: envPath, existing: existing, rewritten: rewritten, transport: transport)
    }

    /// Strip the project's block from `~/.hermes/.env`. Reads the
    /// project's cached manifest to recover its slug — the slug is
    /// the only key the env file knows. When the manifest is absent
    /// (uninstall path may have deleted it before we run), we fall
    /// back to `derivedSlug(forProject:)`.
    /// **The slug is agent-written, so it is checked before it is obeyed.**
    /// `~/.hermes/.env` is a shared file whose blocks are keyed by slug, and
    /// the slug comes from `<project>/.scarf/manifest.json` — which the
    /// agent working in THIS project can write. Setting it to another
    /// registered project's slug turned "uninstall my template" into "delete
    /// that project's secrets from the environment": a cross-project denial
    /// of service, one file edit and one user click away, with no error
    /// anywhere (the other project's cron jobs simply start 401-ing).
    ///
    /// So: strip the block only when this project is the ONLY registered
    /// project that claims the slug. A slug two projects claim is either an
    /// attack or two installs of one template sharing a block — and in both
    /// cases removing it is wrong, because in the honest case the other
    /// install still needs the values. Refusal is logged and non-fatal: a
    /// stale block in `.env` is benign (its keys reference secrets whose
    /// Keychain items the uninstall deletes anyway), while deleting the
    /// wrong one is not recoverable from inside Scarf.
    nonisolated func unmirror(project: ProjectEntry) throws {
        let slug = cachedSlug(for: project) ?? Self.derivedSlug(forProject: project)
        if let claimant = otherProjectClaiming(slug: slug, excluding: project) {
            Self.logger.error(
                "refusing to strip .env block for slug \(slug, privacy: .public): \(claimant, privacy: .public) claims it too"
            )
            return
        }
        try unmirror(slug: slug, envPath: context.paths.envFile)
    }

    /// The name of another registered project whose own slug is `slug`, or
    /// `nil` when this project's claim is uncontested. Compares against both
    /// the cached-manifest slug and the name-derived fallback, because
    /// `unmirror` uses the same two sources — a check of one would miss the
    /// case the other produced.
    ///
    /// Rows are matched out by normalized PATH, not by name: the display
    /// name is renameable and non-unique, so a name compare would let a
    /// project exclude a rival by copying its name.
    nonisolated private func otherProjectClaiming(
        slug: String,
        excluding project: ProjectEntry
    ) -> String? {
        let mine = ProjectIdentity.normalizedPath(project.path)
        let rows = ProjectDashboardService(context: context).loadRegistry().projects
        for row in rows where ProjectIdentity.normalizedPath(row.path) != mine {
            let candidates = [cachedSlug(for: row), Self.derivedSlug(forProject: row)]
            if candidates.contains(where: { $0 == slug }) { return row.name }
        }
        return nil
    }

    /// Splice-only unmirror: strips the block for `slug` from `envPath`.
    /// Symmetric with `mirror(slug:entries:envPath:)` — no Keychain
    /// access, suitable for unit tests.
    nonisolated func unmirror(slug: String, envPath: String) throws {
        let transport = context.makeTransport()
        try unmirrorBlock(slug: slug, envPath: envPath, transport: transport)
    }

    /// Walk the project registry and call `mirror(project:)` on each
    /// entry. Idempotent — projects whose blocks are already current
    /// produce no write. Used at app launch to catch the case where
    /// the user upgraded from a pre-mirror Scarf version.
    nonisolated func reconcileAll() throws {
        let registry = ProjectDashboardService(context: context).loadRegistry()
        for project in registry.projects {
            do {
                try mirror(project: project)
            } catch {
                Self.logger.warning(
                    "reconcile failed for \(project.name, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    // MARK: - Resolution

    private struct ResolvedSecrets {
        let slug: String
        let entries: [(key: String, value: String)]
    }

    /// Read the project's cached manifest + config, resolve every
    /// secret field's Keychain value, return KEY=VALUE pairs ready
    /// for `SecretsEnvBlock.renderBlock`. Nil when the project has
    /// no manifest cache or no secret-typed fields in its schema.
    nonisolated private func resolveSecrets(
        for project: ProjectEntry
    ) throws -> ResolvedSecrets? {
        let configService = ProjectConfigService(context: context)
        guard let manifest = try configService.loadCachedManifest(project: project) else {
            return nil
        }
        guard let schema = manifest.config else { return nil }
        let secretFields = schema.fields.filter { $0.type == .secret }
        guard !secretFields.isEmpty else { return nil }

        let configFile = try configService.load(project: project)
        let values = configFile?.values ?? [:]

        var entries: [(key: String, value: String)] = []
        for field in secretFields {
            guard let value = values[field.key] else { continue }
            let resolved: Data?
            do {
                // Project-bound resolution: the manifest and config.json
                // that named this ref are agent-writable, so a ref that
                // isn't in Scarf's namespace or belongs to a DIFFERENT
                // project resolves to nil and is skipped. Without this,
                // `reconcileAll()` would happily copy project B's secret
                // into project A's block in ~/.hermes/.env on every
                // launch.
                resolved = try configService.resolveSecret(ref: value, for: project)
            } catch {
                Self.logger.warning(
                    "couldn't resolve secret \(field.key, privacy: .public) for \(project.name, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                continue
            }
            guard let data = resolved,
                  let str = String(data: data, encoding: .utf8) else {
                continue
            }
            let key = SecretsEnvBlock.envKeyName(slug: manifest.slug, fieldKey: field.key)
            entries.append((key: key, value: str))
        }
        return ResolvedSecrets(slug: manifest.slug, entries: entries)
    }

    /// The block markers carry the slug verbatim on their own line, and
    /// the manifest that supplies it is agent-writable — so a slug with a
    /// newline (or a `=`) in it could forge markers and inject arbitrary
    /// `KEY=value` lines into `~/.hermes/.env`, outside any block we'd
    /// ever rewrite. Admit only the shape `ProjectScaffolder.suggestedSlug`
    /// mints.
    nonisolated static func isMirrorableSlug(_ slug: String) -> Bool {
        guard !slug.isEmpty, slug.count <= 128 else { return false }
        return slug.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
    }

    // MARK: - File I/O

    nonisolated private func unmirrorBlock(
        slug: String,
        envPath: String,
        transport: any ServerTransport
    ) throws {
        guard transport.fileExists(envPath) else { return }
        let existing = try readExisting(at: envPath, transport: transport)
        let rewritten = SecretsEnvBlock.removeBlock(forSlug: slug, from: existing)
        try writeIfChanged(path: envPath, existing: existing, rewritten: rewritten, transport: transport)
    }

    nonisolated private func readExisting(
        at path: String,
        transport: any ServerTransport
    ) throws -> String {
        guard transport.fileExists(path) else { return "" }
        let data = try transport.readFile(path)
        return String(data: data, encoding: .utf8) ?? ""
    }

    nonisolated private func writeIfChanged(
        path: String,
        existing: String,
        rewritten: String,
        transport: any ServerTransport
    ) throws {
        guard rewritten != existing else { return }
        guard let outData = rewritten.data(using: .utf8) else {
            throw NSError(
                domain: "com.scarf.keychain-env-mirror",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Couldn't UTF-8 encode env file"]
            )
        }
        // LocalTransport's writeFile preserves 0600 for paths that match
        // `.env` conventions (see ServerTransport.writeFile docstring).
        // The hermes home is ensured by Hermes itself; we don't mkdir
        // here.
        try transport.writeFile(path, data: outData)
        Self.logger.info("rewrote \(path, privacy: .public) — \(outData.count) bytes")
    }

    // MARK: - Slug helpers

    /// Read the project's cached manifest to recover its slug. Used
    /// by `unmirror` since the slug is the only key the env file
    /// knows. Nil when the manifest cache is absent (schema-less
    /// project, or uninstall path that already deleted it).
    nonisolated private func cachedSlug(for project: ProjectEntry) -> String? {
        let configService = ProjectConfigService(context: context)
        guard let manifest = try? configService.loadCachedManifest(project: project) else {
            return nil
        }
        return manifest.slug
    }

    /// Fallback slug derivation when the cached manifest is gone.
    /// Mirrors `ProjectScaffolder.suggestedSlug` so a from-scratch
    /// project has a stable slug shape too — though scratch
    /// projects don't have schemas so they shouldn't reach the
    /// mirror path in practice.
    nonisolated static func derivedSlug(forProject project: ProjectEntry) -> String {
        let lowered = project.name.lowercased()
        var slug = ""
        var lastWasDash = false
        for scalar in lowered.unicodeScalars {
            let c = Character(scalar)
            if c.isLetter || c.isNumber {
                slug.append(c)
                lastWasDash = false
            } else if !slug.isEmpty && !lastWasDash {
                slug.append("-")
                lastWasDash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "project" : slug
    }
}
