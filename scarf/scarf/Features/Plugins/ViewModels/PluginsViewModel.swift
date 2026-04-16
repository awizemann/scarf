import Foundation
import os

struct HermesPlugin: Identifiable, Sendable, Equatable {
    var id: String { name }
    let name: String
    let source: String      // Git URL or `owner/repo` (read from plugin manifest if present)
    let enabled: Bool       // True unless a `.disabled` marker exists
    let version: String     // From plugin.json / manifest if present
    let path: String        // Absolute directory path
}

@Observable
final class PluginsViewModel {
    private let logger = Logger(subsystem: "com.scarf", category: "PluginsViewModel")
    private let fileService = HermesFileService()

    var plugins: [HermesPlugin] = []
    var isLoading = false
    var message: String?

    private var pluginsDir: String { HermesPaths.home + "/plugins" }

    /// Source of truth is the `~/.hermes/plugins/` directory. Each plugin is a
    /// subdirectory — we read its `plugin.json` (if present) for source/version
    /// metadata. Parsing `hermes plugins list` box-drawn output is fragile.
    func load() {
        isLoading = true
        defer { isLoading = false }

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: pluginsDir) else {
            plugins = []
            return
        }
        var result: [HermesPlugin] = []
        for entry in entries.sorted() where !entry.hasPrefix(".") {
            let path = pluginsDir + "/" + entry
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }

            let manifest = Self.readManifest(path: path)
            let disabled = fm.fileExists(atPath: path + "/.disabled")
            result.append(HermesPlugin(
                name: entry,
                source: manifest.source,
                enabled: !disabled,
                version: manifest.version,
                path: path
            ))
        }
        plugins = result
    }

    /// Best-effort manifest read. Supports both plugin.json and plugin.yaml shapes.
    private static func readManifest(path: String) -> (source: String, version: String) {
        let fm = FileManager.default
        let jsonPath = path + "/plugin.json"
        if fm.fileExists(atPath: jsonPath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: jsonPath)),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let source = (obj["source"] as? String) ?? (obj["repository"] as? String) ?? (obj["url"] as? String) ?? ""
            let version = (obj["version"] as? String) ?? ""
            return (source, version)
        }
        let yamlPath = path + "/plugin.yaml"
        if fm.fileExists(atPath: yamlPath),
           let yaml = try? String(contentsOfFile: yamlPath, encoding: .utf8) {
            let parsed = HermesFileService.parseNestedYAML(yaml)
            let source = HermesFileService.stripYAMLQuotes(parsed.values["source"] ?? parsed.values["repository"] ?? parsed.values["url"] ?? "")
            let version = HermesFileService.stripYAMLQuotes(parsed.values["version"] ?? "")
            return (source, version)
        }
        return ("", "")
    }

    func install(_ identifier: String) {
        isLoading = true
        message = "Installing \(identifier)…"
        Task.detached { [fileService] in
            let result = fileService.runHermesCLI(args: ["plugins", "install", identifier], timeout: 180)
            await MainActor.run {
                self.isLoading = false
                self.message = result.exitCode == 0 ? "Installed" : "Install failed"
                self.load()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.message = nil
                }
            }
        }
    }

    func update(_ plugin: HermesPlugin) {
        runAndReload(["plugins", "update", plugin.name], success: "Updated")
    }

    func remove(_ plugin: HermesPlugin) {
        runAndReload(["plugins", "remove", plugin.name], success: "Removed")
    }

    func enable(_ plugin: HermesPlugin) {
        runAndReload(["plugins", "enable", plugin.name], success: "Enabled")
    }

    func disable(_ plugin: HermesPlugin) {
        runAndReload(["plugins", "disable", plugin.name], success: "Disabled")
    }

    private func runAndReload(_ args: [String], success: String) {
        Task.detached { [fileService] in
            let result = fileService.runHermesCLI(args: args, timeout: 60)
            await MainActor.run {
                self.message = result.exitCode == 0 ? success : "Failed"
                self.load()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.message = nil
                }
            }
        }
    }
}
