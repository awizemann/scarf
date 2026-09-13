import Foundation
#if canImport(os)
import os
#endif

/// Whether Hermes will register the `kanban_*` tool surface inside the
/// agent loop for a given chat platform. Distinct from
/// `HermesCapabilities.hasKanban`, which only asks "does this Hermes
/// version know about kanban at all?" — the kanban toolset is opt-in
/// per platform/profile, so capability-positive hosts can still ship
/// chats whose agent has zero kanban tools.
public enum KanbanToolsetState: Sendable, Equatable {
    /// Tools will register. The associated source explains where the
    /// gating signal came from so callers can show a precise hint
    /// ("enabled via the cli platform" vs "enabled via top-level
    /// toolsets") when surfacing the state in UI.
    case enabled(via: Source)
    /// Tools will NOT register on the named platform. The board stays
    /// empty for chats on that platform until the user adds `kanban`
    /// to either the platform's toolset list or the top-level toolset
    /// list.
    case disabled(platform: String)
    /// Detector couldn't classify — config file unreadable, missing,
    /// or malformed. Treat as "don't show the disabled banner" rather
    /// than as a hard error: the rest of the app shouldn't grind to a
    /// halt because the YAML is briefly weird mid-edit.
    case unknown(reason: String)

    public enum Source: Sendable, Equatable {
        case platform(String)
        case topLevelToolset
        /// `HERMES_KANBAN_TASK` is set in the spawning environment —
        /// only ever true inside a dispatcher-launched worker, never
        /// in a Scarf-driven ACP chat. Included for completeness so
        /// the detector's contract is exhaustive even though Scarf
        /// itself never observes this branch.
        case dispatcherWorker
    }

    public var isEnabled: Bool {
        if case .enabled = self { return true }
        return false
    }
}

/// Read-only inspector for "will the agent in a given chat platform
/// have access to kanban tools?". Reads `~/.hermes/config.yaml` via
/// the transport's `readText` so it works against local, SSH, and any
/// future remote backend.
///
/// **Why this lives at the ScarfCore layer.** Both Mac and iOS need
/// to render the gating signal (Mac in the chat header sheet on first
/// `/goal`, iOS for read-only status). A view model `@MainActor`
/// surface owns the cached state; this actor owns the I/O.
public actor KanbanToolsetDetector {
    #if canImport(os)
    private static let logger = Logger(
        subsystem: "com.scarf",
        category: "KanbanToolsetDetector"
    )
    #endif

    private let context: ServerContext

    public init(context: ServerContext) {
        self.context = context
    }

    /// Inspect the config and return whether the `kanban` toolset is
    /// active for the given platform (default `cli`, which is the
    /// platform Hermes uses for ACP chats and `hermes chat`).
    ///
    /// Pure read — no side effects, no caching at this layer (the VM
    /// caches). Cheap enough to call on view appear + on file-change
    /// signals.
    public func detect(platform: String = "cli") async -> KanbanToolsetState {
        let context = self.context
        let path = context.paths.configYAML
        let yaml: String? = await OffPool.run {
            context.readText(path)
        }

        guard let yaml, !yaml.isEmpty else {
            return .unknown(reason: "config.yaml is empty or unreadable")
        }

        let topLevel = Self.parseTopLevelToolsets(yaml: yaml)
        if topLevel.contains("kanban") {
            return .enabled(via: .topLevelToolset)
        }

        let platformList = Self.parsePlatformToolsets(yaml: yaml, platform: platform)
        if platformList.contains("kanban") {
            return .enabled(via: .platform(platform))
        }

        return .disabled(platform: platform)
    }

    /// Small line-oriented scan for `toolsets:` block at column 0. The
    /// repo's bigger `HermesConfig+YAML` parser would also work, but
    /// it doesn't currently surface the top-level `toolsets:` field
    /// (only `platform_toolsets.<name>`). A 12-line sniff keeps the
    /// detector self-contained and avoids growing the larger model.
    nonisolated static func parseTopLevelToolsets(yaml: String) -> [String] {
        var inBlock = false
        var items: [String] = []
        for rawLine in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line == "toolsets:" {
                inBlock = true
                continue
            }
            if inBlock {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("- ") {
                    let value = trimmed.dropFirst(2).trimmingCharacters(
                        in: CharacterSet(charactersIn: "\"' ")
                    )
                    if !value.isEmpty {
                        items.append(value)
                    }
                    continue
                }
                if line.first == " " || line.first == "\t" {
                    continue
                }
                break
            }
        }
        return items
    }

    /// Pull the named platform's list out of `platform_toolsets.<name>`.
    /// Mirrors the dotted-path → list flattening that
    /// `HermesConfig+YAML` does, but inline so the detector doesn't
    /// pull a full config parse.
    nonisolated static func parsePlatformToolsets(
        yaml: String,
        platform: String
    ) -> [String] {
        let lines = yaml.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var inPlatformToolsets = false
        var inTargetPlatform = false
        var items: [String] = []
        for line in lines {
            if line == "platform_toolsets:" {
                inPlatformToolsets = true
                continue
            }
            if inPlatformToolsets {
                if line.hasPrefix("\(platform):") || line == "  \(platform):" {
                    inTargetPlatform = true
                    continue
                }
                if inTargetPlatform {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("- ") {
                        let value = trimmed.dropFirst(2).trimmingCharacters(
                            in: CharacterSet(charactersIn: "\"' ")
                        )
                        if !value.isEmpty {
                            items.append(value)
                        }
                        continue
                    }
                    if line.first == " " || line.first == "\t" {
                        if line.hasSuffix(":") && !line.hasPrefix("    ") {
                            inTargetPlatform = false
                        }
                        continue
                    }
                    break
                }
                if line.first != " " && line.first != "\t" && !line.isEmpty {
                    break
                }
            }
        }
        return items
    }
}
