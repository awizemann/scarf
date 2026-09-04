import Foundation
#if canImport(os)
import os
#endif

/// Discovers and loads mini-apps under `<project>/.scarf/miniapps/<id>/`.
///
/// Transport-based (Mac reads local disk, ScarfGo over SFTP), mirroring
/// `ProjectSlashCommandService`. Read-only in this layer — installing /
/// generating mini-apps is owned by the template installer and the agent's
/// file tools; this service just finds what's on disk and parses each
/// `miniapp.json`. Failures are logged, never thrown, for the `load*` /
/// `discover*` paths — a malformed mini-app is skipped, not fatal.
///
/// The directory name is the canonical mini-app id: the decoded
/// `MiniAppManifest.id` is forced to match the dir so a manifest can't
/// claim an id that points the host's `scarf-miniapp://` handler at a
/// different directory.
public struct MiniAppService: Sendable {
    #if canImport(os)
    private static let logger = Logger(subsystem: "com.scarf", category: "MiniAppService")
    #endif

    /// Manifests are tiny; anything past this is corrupt/hostile and is
    /// treated as missing. Mirrors `ProjectStore.maxJSONBytes` intent.
    public static let maxManifestBytes = 1 * 1024 * 1024

    public let context: ServerContext

    public nonisolated init(context: ServerContext = .local) {
        self.context = context
    }

    // MARK: - Path helpers

    /// `<project>/.scarf/miniapps` — same on Mac + iOS.
    public nonisolated static func miniAppsDir(forProjectPath projectPath: String) -> String {
        let trimmed = projectPath.hasSuffix("/") ? String(projectPath.dropLast()) : projectPath
        return trimmed + "/.scarf/miniapps"
    }

    /// `<project>/.scarf/miniapps/<id>` — the directory the
    /// `scarf-miniapp://` scheme handler is scoped to for this mini-app.
    public nonisolated static func miniAppDir(forProjectPath projectPath: String, id: String) -> String {
        miniAppsDir(forProjectPath: projectPath) + "/" + id
    }

    public nonisolated static func manifestPath(forProjectPath projectPath: String, id: String) -> String {
        miniAppDir(forProjectPath: projectPath, id: id) + "/miniapp.json"
    }

    /// A mini-app id must be a single, conservative path component:
    /// `[A-Za-z0-9._-]`, non-empty, ≤64 chars, no leading dot. Discovery
    /// already yields bare directory names (no `/` or `..`), so this is
    /// defense-in-depth that makes the locator's safety self-evident rather
    /// than relying on transport listing behavior — an unusual id never flows
    /// into a `scarf-miniapp://` base dir, a store path, or a grant key.
    public nonisolated static func isValidMiniAppId(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 64, !id.hasPrefix(".") else { return false }
        for scalar in id.unicodeScalars {
            let c = Character(scalar)
            let ok = ("a"..."z").contains(c) || ("A"..."Z").contains(c)
                || ("0"..."9").contains(c) || c == "-" || c == "_" || c == "."
            if !ok { return false }
        }
        return true
    }

    // MARK: - Load

    /// Load + parse `<project>/.scarf/miniapps/<id>/miniapp.json`. Returns
    /// `nil` when absent, oversize, or unparseable (logged). The returned
    /// manifest's `id` is forced to `id` (the dir name) regardless of what
    /// the file claims — the dir is the locator.
    public nonisolated func loadManifest(projectPath: String, id: String) -> MiniAppManifest? {
        guard Self.isValidMiniAppId(id) else { return nil }
        let path = Self.manifestPath(forProjectPath: projectPath, id: id)
        let transport = context.makeTransport()
        // One probe: absent and unreadable are the same `nil` to this
        // caller, so the extra `fileExists` round-trip bought nothing.
        guard let data = try? transport.readFile(path) else { return nil }
        if data.count > Self.maxManifestBytes {
            #if canImport(os)
            Self.logger.warning("miniapp.json for \(id, privacy: .public) is \(data.count) bytes (cap \(Self.maxManifestBytes)); treating as missing")
            #endif
            return nil
        }
        do {
            var manifest = try JSONDecoder().decode(MiniAppManifest.self, from: data)
            manifest.id = id  // dir name is canonical
            return manifest
        } catch {
            #if canImport(os)
            Self.logger.warning("failed to decode miniapp.json for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            #endif
            return nil
        }
    }

    // MARK: - Discover

    /// Every mini-app whose `miniapp.json` parses, sorted by id. `[]` when
    /// the project has no `miniapps/` directory yet (the default state).
    public nonisolated func discover(projectPath: String) -> [MiniAppManifest] {
        let dir = Self.miniAppsDir(forProjectPath: projectPath)
        let transport = context.makeTransport()
        guard transport.fileExists(dir) else { return [] }

        let entries: [String]
        do {
            entries = try transport.listDirectory(dir)
        } catch {
            #if canImport(os)
            Self.logger.warning("listDirectory failed at \(dir, privacy: .public): \(error.localizedDescription, privacy: .public)")
            #endif
            return []
        }

        var manifests: [MiniAppManifest] = []
        for entry in entries {
            // A mini-app is a subdirectory containing miniapp.json; entries
            // without a parseable manifest (stray files, dotfiles) drop out.
            if let manifest = loadManifest(projectPath: projectPath, id: entry) {
                manifests.append(manifest)
            }
        }
        return manifests.sorted { $0.id < $1.id }
    }

    /// Discovered mini-apps as lightweight `ScarfProject.MiniAppRef`s for
    /// the portable registry (`ScarfProject.miniApps`).
    public nonisolated func discoverRefs(projectPath: String) -> [ScarfProject.MiniAppRef] {
        discover(projectPath: projectPath).map {
            ScarfProject.MiniAppRef(id: $0.id, generated: $0.generated)
        }
    }
}
