import Foundation

// MARK: - Manifest (what lives inside the .scarftemplate zip)

/// On-disk manifest for a Scarf project template. Shipped as `template.json`
/// at the root of a `.scarftemplate` (zip) bundle.
///
/// The `contents` block is a claim the author makes about what the bundle
/// ships; the installer verifies the claim against the actual unpacked files
/// before showing the preview sheet so a malicious bundle can't hide extra
/// files from the user.
struct ProjectTemplateManifest: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let id: String
    let name: String
    let version: String
    let minScarfVersion: String?
    let minHermesVersion: String?
    let author: TemplateAuthor?
    let description: String
    let category: String?
    let tags: [String]?
    let icon: String?
    let screenshots: [String]?
    let contents: TemplateContents
    /// Optional configuration schema (added in manifest schemaVersion 2).
    /// When present, the installer presents a form during install and
    /// writes values to `<project>/.scarf/config.json` + the Keychain.
    /// Schema-v1 manifests omit this field entirely — Codable's
    /// optional-field decoding keeps them working unchanged.
    let config: TemplateConfigSchema?

    /// Filesystem-safe slug derived from `id` (`"owner/name"` → `"owner-name"`).
    /// Used for the install directory name, skills namespace, and cron-job tag.
    nonisolated var slug: String {
        let ascii = id.unicodeScalars.map { scalar -> Character in
            let c = Character(scalar)
            if c.isLetter || c.isNumber || c == "-" || c == "_" { return c }
            return "-"
        }
        let collapsed = String(ascii)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "template" : collapsed
    }
}

struct TemplateAuthor: Codable, Sendable, Equatable {
    let name: String
    let url: String?
}

struct TemplateContents: Codable, Sendable, Equatable {
    let dashboard: Bool
    let agentsMd: Bool
    let instructions: [String]?
    let skills: [String]?
    let cron: Int?
    let memory: TemplateMemoryClaim?
    /// Number of configuration fields the template ships (schemaVersion 2+).
    /// Cross-checked against `manifest.config?.fields.count` by the
    /// validator so a bundle can't hide a schema from the preview.
    /// `nil` or `0` means schema-less (v1-compatible behaviour).
    let config: Int?
}

struct TemplateMemoryClaim: Codable, Sendable, Equatable {
    let append: Bool
}

// MARK: - Inspection (what we learn by unpacking the zip)

/// Result of unpacking a `.scarftemplate` into a temp directory and validating
/// it. Callers hand this to `buildInstallPlan` to produce the concrete
/// filesystem plan.
struct TemplateInspection: Sendable {
    let manifest: ProjectTemplateManifest
    /// Absolute path to the temp directory holding the unpacked bundle. The
    /// installer reads files from here; the caller is responsible for
    /// cleaning it up after install (or cancel).
    let unpackedDir: String
    /// Every file found in the unpacked dir, as paths relative to
    /// `unpackedDir`. Verified against the manifest's `contents` claim.
    let files: [String]
    /// Parsed cron jobs (may be empty even if the manifest claims some —
    /// verification catches that mismatch).
    let cronJobs: [TemplateCronJobSpec]
}

/// The subset of a Hermes cron job that a template can ship. Only the fields
/// the `hermes cron create` CLI accepts are included; runtime state
/// (`enabled`, `state`, `next_run_at`, …) is deliberately omitted so a
/// template can't arrive already-running.
struct TemplateCronJobSpec: Codable, Sendable, Equatable {
    let name: String
    let schedule: String
    let prompt: String?
    let deliver: String?
    let skills: [String]?
    let repeatCount: Int?

    enum CodingKeys: String, CodingKey {
        case name, schedule, prompt, deliver, skills
        case repeatCount = "repeat"
    }
}

// MARK: - Install Plan (the preview sheet reads this)

/// Concrete, reviewed-before-apply filesystem operations the installer will
/// perform. Every side effect the installer can cause is represented here so
/// the preview sheet is an honest accounting of what's about to happen.
struct TemplateInstallPlan: Sendable {
    let manifest: ProjectTemplateManifest
    let unpackedDir: String

    /// Absolute path of the new project directory. Installer refuses if this
    /// already exists.
    let projectDir: String
    /// Files that will be created under `projectDir`, keyed by relative path.
    let projectFiles: [TemplateFileCopy]

    /// Absolute path of the skills namespace dir
    /// (`~/.hermes/skills/templates/<slug>/`). Created if skills are present.
    let skillsNamespaceDir: String?
    /// Files that will be created under the skills namespace dir.
    let skillsFiles: [TemplateFileCopy]

    /// Cron job definitions to register via `hermes cron create`. Each job's
    /// name is already prefixed with the template tag. All will be paused
    /// immediately after creation.
    let cronJobs: [TemplateCronJobSpec]

    /// Memory appendix text (already wrapped in begin/end markers). `nil`
    /// means no memory write happens.
    let memoryAppendix: String?
    /// Target memory path (`~/.hermes/memories/MEMORY.md`). Only used when
    /// `memoryAppendix` is non-nil.
    let memoryPath: String

    /// `ProjectEntry.name` that will be appended to the projects registry.
    let projectRegistryName: String

    /// Configuration schema declared by the template (manifest schemaVersion 2).
    /// `nil` means the template is schema-less — the installer skips the
    /// config sheet and writes no `.scarf/config.json` or manifest cache.
    let configSchema: TemplateConfigSchema?

    /// Values the user entered in the configure sheet. Populated by the
    /// VM just before `install()` runs; empty when `configSchema` is nil.
    /// Secrets appear here as `.keychainRef(...)` — the bytes themselves
    /// were routed straight from the form field into the Keychain and
    /// never held in memory past that point.
    var configValues: [String: TemplateConfigValue]

    /// Path at which the installer will stash a copy of `template.json`
    /// so the post-install Configuration editor can render the form
    /// offline. `nil` when `configSchema` is nil.
    let manifestCachePath: String?

    /// Convenience: total number of writes (files + cron jobs + optional
    /// memory append + registry append + optional config.json + one
    /// entry per secret written to the Keychain). Displayed in the
    /// preview sheet.
    nonisolated var totalWriteCount: Int {
        let configFileCount = (configSchema?.isEmpty ?? true) ? 0 : 1
        let secretCount = configValues.values.filter {
            if case .keychainRef = $0 { return true } else { return false }
        }.count
        return projectFiles.count
            + skillsFiles.count
            + cronJobs.count
            + (memoryAppendix == nil ? 0 : 1)
            + 1  // registry entry
            + configFileCount
            + secretCount
    }
}

/// A single file to copy from the unpacked bundle into a target directory.
struct TemplateFileCopy: Sendable, Equatable {
    /// Path inside `unpackedDir`, e.g. `"AGENTS.md"` or
    /// `"skills/timer/SKILL.md"`.
    let sourceRelativePath: String
    /// Absolute path where the file should land.
    let destinationPath: String
}

// MARK: - Lock file (uninstall manifest, dropped into <project>/.scarf/)

/// Dropped at `<project>/.scarf/template.lock.json` after a successful
/// install. Records exactly what was written so a future "Uninstall Template"
/// action can reverse it without guessing.
struct TemplateLock: Codable, Sendable {
    let templateId: String
    let templateVersion: String
    let templateName: String
    let installedAt: String
    let projectFiles: [String]
    let skillsNamespaceDir: String?
    let skillsFiles: [String]
    let cronJobNames: [String]
    let memoryBlockId: String?
    /// Every `keychain://service/account` URI the installer stored in
    /// the Keychain for this project's secret fields. Empty/nil for
    /// schema-less (v1-style) installs. The uninstaller iterates this
    /// list and calls `SecItemDelete` for each entry; absent on older
    /// lock files so Codable's optional decoding keeps pre-2.3 installs
    /// uninstallable.
    let configKeychainItems: [String]?
    /// Field keys the installer wrote to `<project>/.scarf/config.json`.
    /// Informational — the actual removal of config.json rides on
    /// `projectFiles`. Optional for back-compat.
    let configFields: [String]?

    enum CodingKeys: String, CodingKey {
        case templateId = "template_id"
        case templateVersion = "template_version"
        case templateName = "template_name"
        case installedAt = "installed_at"
        case projectFiles = "project_files"
        case skillsNamespaceDir = "skills_namespace_dir"
        case skillsFiles = "skills_files"
        case cronJobNames = "cron_job_names"
        case memoryBlockId = "memory_block_id"
        case configKeychainItems = "config_keychain_items"
        case configFields = "config_fields"
    }
}

// MARK: - Uninstall Plan (the uninstall-preview sheet reads this)

/// Symmetric with `TemplateInstallPlan` but for removal. Built from the
/// `<project>/.scarf/template.lock.json` the installer wrote. The preview
/// sheet lists every path the uninstall would touch; the uninstaller
/// executes the listed ops and nothing else.
struct TemplateUninstallPlan: Sendable {
    /// The parsed lock file that seeded this plan. Kept so the sheet can
    /// display the template id, version, and install timestamp.
    let lock: TemplateLock
    /// The registry entry that will be removed on success.
    let project: ProjectEntry

    /// Lock-tracked files still present on disk that will be removed.
    let projectFilesToRemove: [String]
    /// Lock-tracked files that were already missing (e.g. user deleted them
    /// after install). Shown in the sheet so the user isn't surprised that
    /// a file isn't removed; uninstaller skips these.
    let projectFilesAlreadyGone: [String]
    /// User-added files/dirs in the project dir that are NOT in the lock.
    /// These are preserved — the sheet lists them so the user knows the
    /// project dir stays if any exist.
    let extraProjectEntries: [String]
    /// If `true`, the project dir ends up empty after removal and will be
    /// removed along with its files. `false` means user content lives in
    /// the dir and we leave it.
    let projectDirBecomesEmpty: Bool

    /// Lock-recorded skills namespace dir. `nil` means the template never
    /// installed skills. Uninstaller removes the entire dir recursively.
    let skillsNamespaceDir: String?

    /// Cron jobs that will be removed, as (id, name) pairs. Ids were looked
    /// up at plan time by matching lock names against the live cron list.
    let cronJobsToRemove: [(id: String, name: String)]
    /// Names recorded in the lock that we couldn't find in the current cron
    /// list (user-deleted, renamed, etc.). Shown in the sheet; skipped on
    /// uninstall.
    let cronJobsAlreadyGone: [String]

    /// `true` if MEMORY.md still contains the template's begin/end markers
    /// and those bytes will be stripped on uninstall. `false` means no
    /// memory block was ever installed OR the user removed it by hand.
    let memoryBlockPresent: Bool
    /// Hermes-side path to MEMORY.md. Only touched when
    /// `memoryBlockPresent` is true.
    let memoryPath: String

    nonisolated var totalRemoveCount: Int {
        projectFilesToRemove.count
            + (skillsNamespaceDir == nil ? 0 : 1)
            + cronJobsToRemove.count
            + (memoryBlockPresent ? 1 : 0)
            + 1 // registry entry
    }
}

// MARK: - Errors

enum ProjectTemplateError: LocalizedError, Sendable {
    case unzipFailed(String)
    case manifestMissing
    case manifestParseFailed(String)
    case unsupportedSchemaVersion(Int)
    case requiredFileMissing(String)
    case contentClaimMismatch(String)
    case projectDirExists(String)
    case conflictingFile(String)
    case memoryBlockAlreadyExists(String)
    case cronCreateFailed(job: String, output: String)
    case unsafeZipEntry(String)
    case lockFileMissing(String)
    case lockFileParseFailed(String)

    var errorDescription: String? {
        switch self {
        case .unzipFailed(let s):
            return "Couldn't unpack template archive: \(s)"
        case .manifestMissing:
            return "Template is missing template.json at the archive root."
        case .manifestParseFailed(let s):
            return "Template manifest couldn't be parsed: \(s)"
        case .unsupportedSchemaVersion(let v):
            return "Template uses schemaVersion \(v), which this version of Scarf doesn't understand."
        case .requiredFileMissing(let f):
            return "Template is missing a required file: \(f)"
        case .contentClaimMismatch(let s):
            return "Template manifest doesn't match its contents: \(s)"
        case .projectDirExists(let p):
            return "A directory already exists at \(p). Refusing to overwrite — choose a different parent folder."
        case .conflictingFile(let p):
            return "An existing file would be overwritten at \(p). Refusing to clobber."
        case .memoryBlockAlreadyExists(let id):
            return "A memory block for template '\(id)' already exists in MEMORY.md. Remove it first or install a fresh copy."
        case .cronCreateFailed(let job, let output):
            return "Failed to register cron job '\(job)': \(output)"
        case .unsafeZipEntry(let p):
            return "Template archive contains an unsafe entry: \(p)"
        case .lockFileMissing(let path):
            return "No template.lock.json found at \(path). This project wasn't installed by Scarf's template system — remove it by hand."
        case .lockFileParseFailed(let s):
            return "Couldn't read template.lock.json: \(s)"
        }
    }
}
