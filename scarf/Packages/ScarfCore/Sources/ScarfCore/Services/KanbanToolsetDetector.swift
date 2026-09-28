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
    /// Scarf's rich chat CANNOT get kanban tools on this host, whatever the
    /// config says. Rich chat is an ACP session, and before 0.21.5
    /// ACP builds its tools from `["hermes-acp"]` alone
    /// (`acp_adapter/session.py:484-485` @ `v2026.9.21`, `:637-638` @
    /// `v2026.8.31`, `:598-599` @ `v2026.5.7`), a composite that has never
    /// listed a `kanban_*` tool (`toolsets.py` `"hermes-acp"` at every tag;
    /// `:424-441` @ `v2026.8.31`). Neither `platform_toolsets.<p>` nor the
    /// top-level `toolsets:` changes that list; only a dispatcher worker
    /// (`HERMES_KANBAN_TASK`) gets kanban added (`model_tools.py:428-440` @
    /// `v2026.8.31`). The board itself works; the UI must not offer
    /// "Enable" or report "enabled" here.
    case unavailableInChat

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

/// What Scarf's chat surfaces (the `/goal` teaching sheet and the board's
/// empty-state banner) should say for a detected state.
public enum KanbanChatToolsetPrompt: Sendable, Equatable {
    /// The chats lack kanban tools and adding `kanban` to
    /// `platform_toolsets.<platform>` would give them some (0.21.5+).
    case offerEnable(platform: String)
    /// The chats cannot get kanban tools on this Hermes at all (before
    /// 0.21.5). No Enable button, and never "enabled".
    case unavailableInChat

    /// `nil` = say nothing: already enabled, or unclassifiable.
    public static func forState(_ state: KanbanToolsetState) -> KanbanChatToolsetPrompt? {
        switch state {
        case .disabled(let platform): return .offerEnable(platform: platform)
        case .unavailableInChat: return .unavailableInChat
        case .enabled, .unknown: return nil
        }
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

    /// The platform whose toolsets Scarf's chats run with on this host, or
    /// `nil` when no config can give them kanban tools.
    ///
    /// Every Scarf chat is an ACP session. From 0.21.5 ACP resolves its
    /// toolsets from `platform_toolsets.acp`, else the `hermes-acp` default,
    /// which has no kanban tools (`acp_adapter/session.py:480-486`,
    /// `toolsets.py:70`, `:202-205` @ `v2026.9.24`). Before that ACP
    /// hard-codes `hermes-acp` and never reads the config
    /// (see ``KanbanToolsetState/unavailableInChat``).
    public nonisolated static func chatPlatform(for capabilities: HermesCapabilities) -> String? {
        capabilities.hasACPPlatformToolsets ? acpPlatform : nil
    }

    /// Whether Scarf's chats will have kanban tools on this host.
    /// `.unknown` until the host's version is known;
    /// `.unavailableInChat` below 0.21.5 without reading the config.
    public func detectForChat(capabilities: HermesCapabilities) async -> KanbanToolsetState {
        guard capabilities.detected else {
            return .unknown(reason: "Hermes version not detected yet")
        }
        guard let platform = Self.chatPlatform(for: capabilities) else {
            return .unavailableInChat
        }
        return await detect(platform: platform)
    }

    public nonisolated static let acpPlatform = "acp"

    /// Inspect the config and return whether the `kanban` toolset is
    /// active for the given platform. Chat surfaces use
    /// `detectForChat(capabilities:)` instead.
    ///
    /// Pure read — no side effects, no caching at this layer (the VM
    /// caches). Cheap enough to call on view appear + on file-change
    /// signals.
    public func detect(platform: String) async -> KanbanToolsetState {
        let context = self.context
        let path = context.paths.configYAML
        let yaml: String? = await OffPool.run {
            context.readText(path)
        }

        guard let yaml, !yaml.isEmpty else {
            return .unknown(reason: "config.yaml is empty or unreadable")
        }

        if platform == Self.acpPlatform {
            return Self.classifyACP(yaml: yaml)
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

    /// Hermes 0.21.5's rule for the `acp` platform, from
    /// `_get_platform_tools` (`hermes_cli/tools_config.py:576-620` @
    /// `v2026.9.24`):
    /// - a saved `platform_toolsets.acp` LIST is authoritative, even an
    ///   empty one: kanban is on only if the list names it;
    /// - with no list (key absent, null, or a non-list scalar) the
    ///   `hermes-acp` default applies, plus kanban when the legacy
    ///   top-level `toolsets:` names it (`:617-620`).
    nonisolated static func classifyACP(yaml: String) -> KanbanToolsetState {
        if case .list(let items) = platformToolsetsEntry(yaml: yaml, platform: acpPlatform) {
            return items.contains("kanban")
                ? .enabled(via: .platform(acpPlatform))
                : .disabled(platform: acpPlatform)
        }
        return parseTopLevelToolsets(yaml: yaml).contains("kanban")
            ? .enabled(via: .topLevelToolset)
            : .disabled(platform: acpPlatform)
    }

    /// What `platform_toolsets.<platform>` holds, as Hermes reads it.
    enum PlatformToolsetsEntry: Equatable {
        /// No `platform_toolsets:` block, or no key for the platform.
        case absent
        /// The key is present with no value (YAML null).
        case null
        /// A list: block items, a flow `[a, b]`, or a string holding a
        /// `[...]` literal (Hermes parses that as a list too,
        /// `hermes_cli/toolset_validation.py:12-30` @ `v2026.9.24`).
        case list([String])
        /// Any other value. Hermes warns and uses the platform default.
        case scalar(String)
    }

    /// Where the platform's key sits in the file, and what it holds. Only
    /// the block-style `platform_toolsets:` section is read; an inline
    /// `platform_toolsets: {…}` reads as absent.
    struct PlatformToolsetsLocation: Equatable {
        /// Index of the `platform_toolsets:` line, when present.
        let blockLine: Int?
        /// Index of the `<platform>:` line, when present.
        let keyLine: Int?
        /// Leading spaces of the platform keys under the block.
        let keyIndent: Int
        /// Leading spaces of the first `- item` under any platform key,
        /// when the block has one (PyYAML writes them at the key's indent).
        let itemIndent: Int?
        /// Index one past the platform key's own lines (its items).
        let keyEnd: Int?
        /// Index one past the whole block's last non-blank line.
        let blockEnd: Int?
        let entry: PlatformToolsetsEntry
    }

    nonisolated static func platformToolsetsEntry(
        yaml: String,
        platform: String
    ) -> PlatformToolsetsEntry {
        locatePlatformToolsets(
            lines: yaml.components(separatedBy: "\n"), platform: platform
        ).entry
    }

    nonisolated static func locatePlatformToolsets(
        lines: [String],
        platform: String
    ) -> PlatformToolsetsLocation {
        func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }
        func isBlankOrComment(_ line: String) -> Bool {
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.isEmpty || t.hasPrefix("#")
        }
        func isTopLevel(_ line: String) -> Bool {
            !isBlankOrComment(line) && indent(line) == 0 && !line.hasPrefix("\t")
        }

        guard let blockLine = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "platform_toolsets:" && indent($0) == 0
        }) else {
            return PlatformToolsetsLocation(
                blockLine: nil, keyLine: nil, keyIndent: 2, itemIndent: nil,
                keyEnd: nil, blockEnd: nil, entry: .absent)
        }

        // The block runs until the next top-level key.
        var blockEnd = blockLine + 1
        var lastContent = blockLine
        var scan = blockLine + 1
        while scan < lines.count, !isTopLevel(lines[scan]) {
            if !isBlankOrComment(lines[scan]) { lastContent = scan }
            scan += 1
        }
        blockEnd = lastContent + 1

        let body = (blockLine + 1)..<blockEnd
        let keyIndent = body.first(where: {
            !isBlankOrComment(lines[$0])
                && !lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("-")
        }).map { indent(lines[$0]) } ?? 2
        let itemIndent = body.first(where: {
            lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("- ")
        }).map { indent(lines[$0]) }

        let keyPrefix = "\(platform):"
        guard let keyLine = body.first(where: {
            let line = lines[$0]
            guard indent(line) == keyIndent else { return false }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed == keyPrefix || trimmed.hasPrefix(keyPrefix + " ")
        }) else {
            return PlatformToolsetsLocation(
                blockLine: blockLine, keyLine: nil, keyIndent: keyIndent,
                itemIndent: itemIndent, keyEnd: nil, blockEnd: blockEnd, entry: .absent)
        }

        let rawValue = lines[keyLine].trimmingCharacters(in: .whitespaces)
            .dropFirst(keyPrefix.count)
            .trimmingCharacters(in: .whitespaces)
        let value = stripTrailingComment(rawValue)

        // The key's own items: `- x` lines at or below its indent that come
        // before the next sibling key.
        var items: [String] = []
        var keyEnd = keyLine + 1
        var cursor = keyLine + 1
        while cursor < blockEnd {
            let line = lines[cursor]
            if isBlankOrComment(line) { cursor += 1; continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- "), indent(line) >= keyIndent else { break }
            items.append(unquote(String(trimmed.dropFirst(2))))
            cursor += 1
            keyEnd = cursor
        }

        let entry: PlatformToolsetsEntry
        if value.isEmpty || value == "null" || value == "~" {
            entry = items.isEmpty ? .null : .list(items)
        } else if let flow = parseFlowList(unquoteIfListLiteral(value)) {
            entry = .list(flow)
        } else {
            entry = .scalar(value)
        }
        return PlatformToolsetsLocation(
            blockLine: blockLine, keyLine: keyLine, keyIndent: keyIndent,
            itemIndent: itemIndent, keyEnd: keyEnd, blockEnd: blockEnd, entry: entry)
    }

    /// `[a, "b", 'c']` → `["a", "b", "c"]`; nil when the text is not a
    /// single-line flow list.
    nonisolated static func parseFlowList(_ text: String) -> [String]? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("["), t.hasSuffix("]") else { return nil }
        let inner = t.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        if inner.isEmpty { return [] }
        return inner.split(separator: ",").map { unquote(String($0)) }
    }

    private nonisolated static func unquote(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
    }

    /// `"[a, b]"` → `[a, b]` (a list literal saved as a string).
    private nonisolated static func unquoteIfListLiteral(_ text: String) -> String {
        guard let first = text.first, first == "\"" || first == "'",
              text.count >= 2, text.last == first else { return text }
        let inner = String(text.dropFirst().dropLast())
        return inner.trimmingCharacters(in: .whitespaces).hasPrefix("[") ? inner : text
    }

    /// Drops a ` # comment` tail from an unquoted scalar or flow value.
    nonisolated static func stripTrailingComment(_ text: String) -> String {
        if text.hasPrefix("#") { return "" }
        guard let first = text.first, first != "\"", first != "'",
              let hash = text.range(of: " #") else { return text }
        return String(text[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
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
            // Flow form, `toolsets: [kanban]` — Hermes reads it the same.
            if !inBlock, line.hasPrefix("toolsets:"),
               let flow = parseFlowList(String(line.dropFirst("toolsets:".count))) {
                return flow
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
