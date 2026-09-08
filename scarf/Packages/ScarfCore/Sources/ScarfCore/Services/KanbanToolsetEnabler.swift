import Foundation
#if canImport(os)
import os
#endif

/// Mutates the `kanban` toolset on/off for a given Hermes platform.
///
/// **Why this writes YAML directly instead of shelling out to
/// `hermes tools enable`.** Hermes's `tools enable` CLI deliberately
/// rejects `kanban` because the toolset is designed for
/// dispatcher-spawned workers, not interactive chat — see
/// `CONFIGURABLE_TOOLSETS` in `hermes_cli/tools_config.py`. The CLI
/// prints `✗ Unknown toolset 'kanban'` AND exits 0, which both blocks
/// the legitimate "I want kanban tools in chat" workflow AND tricks
/// callers that only check exit codes into thinking they succeeded.
/// `hermes config set platform_toolsets.cli kanban` is even worse:
/// it stringifies the value, clobbering the entire list with a bare
/// `cli: kanban` scalar.
///
/// The gating in `tools/kanban_tools.py` honors the toolset *being in*
/// `platform_toolsets.<platform>` regardless of how it got there — so
/// writing the YAML directly is the supported (and only) path.
///
/// **Why a separate actor from `KanbanToolsetDetector`.** Read paths
/// run on every chat appear; mutation paths run once per onboarding
/// flow. Keeping them as separate actors means the detector's read
/// loop never blocks on a write txn.
public actor KanbanToolsetEnabler {
    #if canImport(os)
    private static let logger = Logger(
        subsystem: "com.scarf",
        category: "KanbanToolsetEnabler"
    )
    #endif

    public enum EnableResult: Sendable, Equatable {
        /// `kanban` is now present in the platform's toolset list — either
        /// because we just wrote it, or because it was already there. Both
        /// cases collapse to the same UI outcome (banner dismissed; ask
        /// the user to restart their chat to pick up the new schema).
        case enabled
        /// Mutation refused. `message` is human-readable and surfaces
        /// inline rather than via a generic toast — the caller is
        /// expected to render the string verbatim so the user can
        /// diagnose (e.g. corrupted YAML shape, unreadable file).
        case failed(message: String)
    }

    /// Internal classification of "what kind of mutation does this YAML
    /// need?" Drives the write path. Public-visible callers only see
    /// `EnableResult`.
    enum MutationPlan: Equatable {
        /// `kanban` is already in the right place. No write needed.
        case alreadyPresent
        /// New YAML to write. Caller is responsible for persisting it.
        case rewrite(String)
        /// We can't safely mutate (corrupted shape, missing block, etc.).
        /// `reason` surfaces to the user verbatim.
        case refuse(reason: String)
    }

    private let context: ServerContext

    public init(context: ServerContext) {
        self.context = context
    }

    /// Add `kanban` to the platform's toolset list, write the file
    /// atomically, then confirm the detector sees the change. Default
    /// `cli` matches what ACP chats run under, so the common path is
    /// `enabler.enable()` with no args.
    ///
    /// Idempotent: if `kanban` is already in the right place (either
    /// the platform's list or the top-level `toolsets:`), returns
    /// `.enabled` without touching the file.
    public func enable(platform: String = "cli") async -> EnableResult {
        let context = self.context
        let path = context.paths.configYAML

        // Short-circuit when the detector already classifies as enabled.
        // Saves a needless read/write round-trip if a sibling caller
        // wrote first, or the user manually added `kanban` between the
        // banner render and the click.
        let detector = KanbanToolsetDetector(context: context)
        let preState = await detector.detect(platform: platform)
        if case .enabled = preState {
            return .enabled
        }

        // Read + mutate off the main actor; the YAML scan is line-bounded
        // and cheap (~6 KB file in practice) but the load may hit SSH
        // on remote contexts.
        //
        // Read, plan and write are ONE detached hop because they are one
        // lock hold (GW-F3). They used to be two `Task.detached`s, which is
        // not merely a window: `RegistryWriteLock`'s reentrancy is
        // THREAD-LOCAL, so a hold taken on the load's thread could not have
        // covered a write running on another.
        let outcome = await Self.applyPlan(context: context, path: path) {
            Self.planEnable(yaml: $0, platform: platform)
        }
        switch outcome {
        case .failed(let message):
            return .failed(message: message)
        case .noChange:
            return .enabled
        case .wrote:
            // Trust-but-verify. The kanban gating in Hermes is exact
            // string membership; if our write went in correctly the
            // detector must see `.enabled` on the next read. Anything
            // else means we mutated the wrong file or didn't actually
            // produce a list-containing-kanban shape — surface that
            // rather than gaslighting the user with a false "Enabled."
            let postState = await detector.detect(platform: platform)
            if case .enabled = postState {
                #if canImport(os)
                Self.logger.info("kanban toolset enabled on \(platform, privacy: .public) via direct YAML write")
                #endif
                return .enabled
            }
            return .failed(message:
                "Wrote kanban into platform_toolsets.\(platform) but the detector still reports it disabled. The config file may be in an unexpected shape — open ~/.hermes/config.yaml and add `kanban` to platform_toolsets.\(platform) manually."
            )
        }
    }

    public func disable(platform: String = "cli") async -> EnableResult {
        let context = self.context
        let path = context.paths.configYAML
        // One lock hold over read + plan + write, as `enable` does.
        // `alreadyPresent` here means "wasn't there in the first place" —
        // a no-op success.
        switch await Self.applyPlan(context: context, path: path, plan: {
            Self.planDisable(yaml: $0, platform: platform)
        }) {
        case .failed(let message): return .failed(message: message)
        case .noChange, .wrote: return .enabled
        }
    }

    // MARK: - Guarded, serialized config.yaml I/O

    private enum PlanOutcome {
        case wrote
        case noChange
        case failed(message: String)
    }

    /// Read `config.yaml` with proof, run `plan` over its text, and publish
    /// the rewrite — the whole thing inside ONE hold of config.yaml's write
    /// lock, on ONE detached thread (GW-F3 / DI H4).
    ///
    /// `~/.hermes/config.yaml` is hand-authored and irreplaceable, and this
    /// actor is one of five writers of it. All of them go through
    /// `GuardedTextFile` so the "is this file damaged or just absent" answer
    /// is computed once, in one place — before, each writer had its own
    /// `readText(path) ?? ""`, and one dropped SSH round-trip published a
    /// config containing nothing but the section being edited. Since GW-F3
    /// they also share its LOCK, so two of those writers can no longer each
    /// build a whole file from a read the other is about to invalidate.
    ///
    /// A refusal, an absent file, a rejected plan and a lost lock race all
    /// come back as `.failed` with the message the UI already shows.
    private static func applyPlan(
        context: ServerContext,
        path: String,
        plan: @escaping @Sendable (String) -> MutationPlan
    ) async -> PlanOutcome {
        await Task.detached(priority: .utility) {
            let file = GuardedTextFile(context: context, label: "config.yaml")
            do {
                var outcome = PlanOutcome.noChange
                try file.mutate(path) { loaded in
                    guard loaded.exists else {
                        outcome = .failed(message: "Couldn't read \(path)")
                        return nil
                    }
                    switch plan(loaded.text) {
                    case .alreadyPresent:
                        outcome = .noChange
                        return nil
                    case .refuse(let reason):
                        outcome = .failed(message: reason)
                        return nil
                    case .rewrite(let newYaml):
                        outcome = .wrote
                        return newYaml
                    }
                }
                return outcome
            } catch {
                return .failed(message: error.localizedDescription)
            }
        }.value
    }

    // MARK: - Pure mutation planning (unit-testable)

    /// Pure function: given a YAML string + a platform name, return the
    /// plan to add `kanban` to that platform's toolset list. Does NOT
    /// look at the file system. The actor's `enable` method composes
    /// this with the I/O around it.
    ///
    /// Cases:
    /// - Top-level `toolsets:` contains `kanban` → `.alreadyPresent`
    ///   (top-level gating short-circuits everything else in Hermes).
    /// - `platform_toolsets.<platform>` already contains `kanban` →
    ///   `.alreadyPresent`.
    /// - `platform_toolsets.<platform>` is a list missing `kanban` →
    ///   `.rewrite` with `- kanban` inserted alphabetically.
    /// - `platform_toolsets.<platform>` is a scalar value (e.g. the
    ///   post-`hermes config set` corruption shape `cli: kanban`) →
    ///   `.refuse` with a description so the user can fix it.
    /// - `platform_toolsets.<platform>` is missing entirely (block
    ///   exists but no key) → `.refuse`. We could add it but the user
    ///   probably wanted SOMETHING for the platform; better to be safe.
    /// - `platform_toolsets:` block is missing → `.refuse`.
    static func planEnable(
        yaml: String,
        platform: String
    ) -> MutationPlan {
        // Top-level toolsets short-circuit.
        let topLevel = KanbanToolsetDetector.parseTopLevelToolsets(yaml: yaml)
        if topLevel.contains("kanban") {
            return .alreadyPresent
        }

        let lines = yaml.components(separatedBy: "\n")
        guard let blockIdx = lines.firstIndex(of: "platform_toolsets:") else {
            return .refuse(reason:
                "`platform_toolsets:` section not found in config. Open ~/.hermes/config.yaml and add the section + a `\(platform):` list containing `kanban`."
            )
        }

        // Locate `<platform>:` under platform_toolsets (2-space indent).
        let platformKey = "  \(platform):"
        var platformLineIdx: Int?
        var i = blockIdx + 1
        while i < lines.count {
            let line = lines[i]
            // Exit the block on any top-level (no-indent) key.
            if !line.isEmpty && !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                break
            }
            if line == platformKey || line.hasPrefix("\(platformKey) ") {
                platformLineIdx = i
                break
            }
            i += 1
        }

        guard let platformIdx = platformLineIdx else {
            return .refuse(reason:
                "`platform_toolsets.\(platform):` key not found. Open ~/.hermes/config.yaml and add `kanban` to the `\(platform):` list under `platform_toolsets:`."
            )
        }

        // Check whether the platform key carries a scalar value on its
        // own line — the "post-`hermes config set` corruption" shape.
        let platformLine = lines[platformIdx]
        if let colonIdx = platformLine.firstIndex(of: ":") {
            let afterColon = platformLine[platformLine.index(after: colonIdx)...]
                .trimmingCharacters(in: .whitespaces)
            if !afterColon.isEmpty {
                return .refuse(reason:
                    "`platform_toolsets.\(platform)` has a scalar value `\(afterColon)` instead of a list. This usually means `hermes config set` was run against it and clobbered the original list. Open ~/.hermes/config.yaml and convert it back to a list of toolset names."
                )
            }
        }

        // Collect existing list items + their line indices. Items are
        // `  - <name>` lines at any indent > 2 spaces.
        var listItems: [(line: Int, value: String)] = []
        var scan = platformIdx + 1
        while scan < lines.count {
            let line = lines[scan]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") {
                let value = String(trimmed.dropFirst(2))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                listItems.append((line: scan, value: value))
                scan += 1
                continue
            }
            // Empty line inside the list is tolerated (rare but legal).
            if trimmed.isEmpty {
                scan += 1
                continue
            }
            // Non-list line means we left the list. Could be another
            // platform key (e.g. `  discord:`) or a top-level key.
            break
        }

        if listItems.contains(where: { $0.value == "kanban" }) {
            return .alreadyPresent
        }

        // Determine the list-item indent from the first existing item.
        // If the list is empty, fall back to 2 spaces (matches Hermes's
        // own output).
        let listItemIndent: String
        if let firstItem = listItems.first {
            let prefix = lines[firstItem.line].prefix { $0 == " " }
            listItemIndent = String(prefix)
        } else {
            listItemIndent = "  "
        }
        let newItem = "\(listItemIndent)- kanban"

        // Insert alphabetically — most existing Hermes-written lists are
        // sorted, so an alphabetical insert keeps the file diff-clean.
        // If the existing list is unsorted, we still insert at the
        // first position whose existing value is > "kanban" lexically,
        // falling back to the end. The detector doesn't care about
        // order, so worst case the file just has one out-of-order item.
        var insertAt = scan  // default: end of the list
        for item in listItems where item.value > "kanban" {
            insertAt = item.line
            break
        }

        var newLines = lines
        newLines.insert(newItem, at: insertAt)
        return .rewrite(newLines.joined(separator: "\n"))
    }

    /// Disable mirror of `planEnable` — removes `kanban` from the
    /// platform's list if present. Top-level `toolsets:` is left alone
    /// (we don't try to mutate it from the chat surface; that's the
    /// user's territory).
    static func planDisable(
        yaml: String,
        platform: String
    ) -> MutationPlan {
        let lines = yaml.components(separatedBy: "\n")
        guard let blockIdx = lines.firstIndex(of: "platform_toolsets:") else {
            return .alreadyPresent
        }
        let platformKey = "  \(platform):"
        var platformLineIdx: Int?
        var i = blockIdx + 1
        while i < lines.count {
            let line = lines[i]
            if !line.isEmpty && !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                break
            }
            if line == platformKey || line.hasPrefix("\(platformKey) ") {
                platformLineIdx = i
                break
            }
            i += 1
        }
        guard let platformIdx = platformLineIdx else {
            return .alreadyPresent
        }
        var scan = platformIdx + 1
        var removalIdx: Int?
        while scan < lines.count {
            let line = lines[scan]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") {
                let value = String(trimmed.dropFirst(2))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                if value == "kanban" {
                    removalIdx = scan
                    break
                }
                scan += 1
                continue
            }
            if trimmed.isEmpty {
                scan += 1
                continue
            }
            break
        }
        guard let removalIdx else {
            return .alreadyPresent
        }
        var newLines = lines
        newLines.remove(at: removalIdx)
        return .rewrite(newLines.joined(separator: "\n"))
    }
}
