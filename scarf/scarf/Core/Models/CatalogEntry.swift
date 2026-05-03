import Foundation
import ScarfCore
import os

/// One template entry as exposed by `awizemann.github.io/scarf/templates/catalog.json`.
/// Mirrors the per-template shape `tools/build-catalog.py` emits — the
/// validator is the source of truth on the schema, this struct is the
/// Swift consumer. **Do not add fields here that aren't in `catalog.json`
/// today.** Keeping the surface 1:1 means we can't accidentally render
/// something the catalog doesn't actually carry.
///
/// Most fields are required-from-the-validator's-perspective but
/// expressed as optionals here so a single-template typo on the
/// website doesn't bring down the whole list — we drop the malformed
/// entry and keep going (handled by the decoder in `CatalogService`).
struct CatalogEntry: Codable, Sendable, Identifiable, Hashable {

    // Hashable + Equatable conformance is identity-based on `id` —
    // `TemplateConfigSchema` only conforms to Equatable, so we can't
    // synthesize Hashable, and a content-based equality wouldn't be
    // useful anyway (the same template re-fetched from cache vs. fresh
    // is "the same entry" even if a description was edited upstream).
    static func == (lhs: CatalogEntry, rhs: CatalogEntry) -> Bool {
        lhs.id == rhs.id
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }


    /// Stable identifier — `<author>/<template-name>`, e.g.
    /// `awizemann/hackernews-digest`. Matches the value in
    /// `template.json`'s `id` field.
    let id: String

    /// Human-readable name shown in the catalog list.
    let name: String

    /// Semver. Compared against the installed version from
    /// `InstalledTemplatesIndex` to detect "Update available".
    let version: String

    let description: String?
    let category: String?
    let tags: [String]

    let author: Author
    let minScarfVersion: String?
    let minHermesVersion: String?

    /// HTTPS URL the install flow consumes.
    /// `TemplateInstallerViewModel.openRemoteURL(_:)` accepts this
    /// directly. The catalog itself only ships HTTPS URLs (validator
    /// enforced).
    let installUrl: String

    /// Bundle metadata for size warnings and integrity checks. Optional
    /// because pre-v2 catalogs didn't carry these.
    let bundleSize: Int?
    let bundleSha256: String?

    /// Slug used by the static-site generator for detail-page URLs.
    /// Reused as a stable accessibility-ID suffix so XCUITest can find
    /// rows even if the human-readable id contains slashes.
    let detailSlug: String?

    /// What's inside the bundle, mirrored from `template.json`'s
    /// `contents` claim. Drives the "what will be installed" preview
    /// on the detail page.
    let contents: Contents?

    /// Config schema + model recommendation if the template declares
    /// one. Using the existing `TemplateConfigSchema` decoder keeps
    /// parsing aligned with the install sheet's config form.
    let config: TemplateConfigSchema?

    struct Author: Codable, Sendable, Equatable {
        let name: String
        let url: String?
    }

    /// `template.json`'s `contents` object. All counts are optional —
    /// `nil` means "not declared," which the catalog renders as zero.
    struct Contents: Codable, Sendable, Equatable {
        let dashboard: Bool?
        let agentsMd: Bool?
        let cron: Int?
        let config: Int?
        let memory: Bool?
        let skills: [String]?
    }
}

/// Top-level shape of `catalog.json`. Only carries what the Swift
/// catalog browser actually uses — `templates` is the list itself,
/// `schemaVersion` lets us reject incompatible future formats.
///
/// **The validator's `generated` field is intentionally NOT decoded.**
/// It ships as a boolean (`true`) per `tools/build-catalog.py`'s
/// "human reminder; a timestamp would churn the diff every run"
/// comment. The catalog UI uses the cache file's `fetchedAt` for the
/// "last refreshed" string, not anything from `catalog.json`.
///
/// **Per-element fault tolerance.** `templates` is decoded entry by
/// entry through an unkeyed container — a single malformed entry
/// (missing `tags`, `author`, etc.) is dropped with a logged warning
/// rather than failing the whole catalog decode. Honors the contract
/// the per-entry doc-comment promises.
struct Catalog: Codable, Sendable {
    let schemaVersion: Int?
    let templates: [CatalogEntry]

    init(schemaVersion: Int?, templates: [CatalogEntry]) {
        self.schemaVersion = schemaVersion
        self.templates = templates
    }

    /// Custom decoder that drops every key other than `schemaVersion`
    /// and `templates`. Without this, `generated: true` would surface
    /// as a typeMismatch on `String?`.
    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case templates
    }

    private static let decodeLogger = Logger(subsystem: "com.scarf", category: "CatalogDecoder")

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)

        var entries: [CatalogEntry] = []
        if container.contains(.templates) {
            var unkeyed = try container.nestedUnkeyedContainer(forKey: .templates)
            entries.reserveCapacity(unkeyed.count ?? 0)
            while !unkeyed.isAtEnd {
                do {
                    entries.append(try unkeyed.decode(CatalogEntry.self))
                } catch {
                    Self.decodeLogger.warning("dropping malformed catalog entry at index \(unkeyed.currentIndex - 1): \(error.localizedDescription, privacy: .public)")
                    // Advance past the bad element so the loop terminates.
                    // Decoding into a permissive `JSONValue` placeholder
                    // would also work, but Foundation's Decoder API has
                    // no built-in skip — `_Skip` consumes one element.
                    _ = try? unkeyed.decode(_Skip.self)
                }
            }
        }
        self.templates = entries
    }

    /// Placeholder type used to consume a malformed array element after
    /// the real decode threw. Decodes anything by ignoring it.
    private struct _Skip: Decodable {
        init(from decoder: Decoder) throws {
            _ = try decoder.singleValueContainer()
        }
    }
}
