import Foundation
import os

/// Enumerates `~/.hermes/skill-bundles/*.yaml` and parses each into a
/// `HermesSkillBundle`. Hermes v0.15 stores bundle definitions as YAML
/// files in that directory; Scarf reads them directly rather than
/// parsing `hermes bundles list` text output, so the surface works
/// identically over a remote SSH transport.
///
/// Same transport pattern as `SkillsScanner` — the directory walk goes
/// through `transport.listDirectory` + `transport.readFile`, and a missing
/// directory returns `[]` (a fresh install or a pre-v0.15 host) rather
/// than an error.
///
/// Synchronous + transport-backed: callers on the MainActor should wrap
/// in `Task.detached` (the iOS / `SkillsViewModel.load` pattern) since
/// SFTP `listDirectory` / `readFile` calls block.
public enum SkillBundlesScanner: Sendable {
    private static let logger = Logger(subsystem: "com.scarf", category: "SkillBundlesScanner")

    public static func scan(
        context: ServerContext,
        transport: any ServerTransport
    ) -> [HermesSkillBundle] {
        let dir = context.paths.skillBundlesDir
        // Fresh install or pre-v0.15 host: skill-bundles/ may not exist
        // yet — return [] without logging an error.
        guard transport.fileExists(dir) else { return [] }
        guard let entries = try? transport.listDirectory(dir) else { return [] }

        return entries
            .filter { !$0.hasPrefix(".") }
            .filter { $0.hasSuffix(".yaml") || $0.hasSuffix(".yml") }
            .sorted()
            .compactMap { fileName -> HermesSkillBundle? in
                let filePath = dir + "/" + fileName
                guard let data = try? transport.readFile(filePath),
                      let content = String(data: data, encoding: .utf8)
                else { return nil }
                let stem = fileName
                    .replacingOccurrences(of: ".yaml", with: "")
                    .replacingOccurrences(of: ".yml", with: "")
                return HermesSkillBundle.parse(yaml: content, stem: stem)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
