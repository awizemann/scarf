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
    let context: ServerContext
    private let fileService: HermesFileService

    init(context: ServerContext = .local) {
        self.context = context
        self.fileService = HermesFileService(context: context)
    }

    var plugins: [HermesPlugin] = []
    var isLoading = false
    var message: String?

    private var pluginsDir: String { context.paths.pluginsDir }

    /// Source of truth is the `~/.hermes/plugins/` directory. Each plugin is a
    /// subdirectory — we read its `plugin.json` (if present) for source/version
    /// metadata. Parsing `hermes plugins list` box-drawn output is fragile.
    func load() {
        isLoading = true
        let dir = pluginsDir
        let ctx = context
        // listDirectory + (stat × N entries) + (readManifest × N) is a lot
        // of sync transport ops on remote — definitively a beach ball if
        // run on main. Detach the whole walk.
        Task.detached { [weak self] in
            // Build `result` as an immutable before the MainActor hop, so the
            // cross-closure capture is a value, not a mutated `var` (Swift 6
            // concurrent-capture rule).
            let result: [HermesPlugin] = {
                let transport = ctx.makeTransport()
                var out: [HermesPlugin] = []
                if let entries = try? transport.listDirectory(dir) {
                    for entry in entries.sorted() where !entry.hasPrefix(".") {
                        let path = dir + "/" + entry
                        guard transport.stat(path)?.isDirectory == true else { continue }
                        let manifest = Self.readManifestStatic(path: path, context: ctx)
                        let disabled = transport.fileExists(path + "/.disabled")
                        out.append(HermesPlugin(
                            name: entry,
                            source: manifest.source,
                            enabled: !disabled,
                            version: manifest.version,
                            path: path
                        ))
                    }
                }
                return out
            }()
            await MainActor.run { [weak self] in
                self?.plugins = result
                self?.isLoading = false
            }
        }
    }

    /// Static form of readManifest used by the detached load task. The
    /// instance form delegates to this so both call paths share logic.
    nonisolated fileprivate static func readManifestStatic(path: String, context: ServerContext) -> (source: String, version: String) {
        let jsonPath = path + "/plugin.json"
        if let data = context.readData(jsonPath),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let source = (obj["source"] as? String) ?? (obj["repository"] as? String) ?? (obj["url"] as? String) ?? ""
            let version = (obj["version"] as? String) ?? ""
            return (source, version)
        }
        let yamlPath = path + "/plugin.yaml"
        if let yaml = context.readText(yamlPath) {
            let parsed = HermesFileService.parseNestedYAML(yaml)
            let source = HermesFileService.stripYAMLQuotes(parsed.values["source"] ?? parsed.values["repository"] ?? parsed.values["url"] ?? "")
            let version = HermesFileService.stripYAMLQuotes(parsed.values["version"] ?? "")
            return (source, version)
        }
        return ("", "")
    }

    // (readManifestStatic above is the new implementation; the instance
    // version was removed because the only caller was the load() walk,
    // which now runs detached and uses the static form.)

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
