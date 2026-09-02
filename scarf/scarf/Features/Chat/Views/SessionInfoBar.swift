import SwiftUI
import ScarfCore
import ScarfDesign

struct SessionInfoBar: View {
    let session: HermesSession?
    let isWorking: Bool
    /// Fallback token counts from ACP prompt results (DB may have zeros for ACP sessions).
    var acpInputTokens: Int = 0
    var acpOutputTokens: Int = 0
    var acpThoughtTokens: Int = 0
    /// Number of context compactions Hermes has run on this session. v0.13+
    /// surface — capability-gated by the bar so pre-v0.13 hosts never see
    /// the chip even if a stale value somehow trickles through. Defaults
    /// to 0 so existing callers and previews don't need to be updated.
    var acpCompressionCount: Int = 0
    /// Name of the Scarf project this session is attributed to, when
    /// applicable. Nil for plain global chats. Drives the folder-chip
    /// indicator rendered before the session title. Resolved by
    /// `ChatViewModel.currentProjectName` — the view just passes it
    /// through.
    var projectName: String? = nil
    /// Current git branch of the project's working directory, when
    /// resolved (v2.5). Renders as a tinted chip after the project
    /// name. Nil for non-project chats and for projects that aren't
    /// git repos.
    var gitBranch: String? = nil
    /// Active locked goal (Hermes v0.13 `/goal`). Nil hides the pill.
    /// Optimistic — set by `RichChatViewModel.recordActiveGoal(text:)`
    /// when the user sends `/goal …`.
    var activeGoal: HermesActiveGoal? = nil
    /// Invoked when the user picks "Clear goal" from the goal pill's
    /// context menu. Caller dispatches `/goal --clear` so the optimistic
    /// pill clear and the server-side authoritative state stay in sync.
    var onClearGoal: (() -> Void)? = nil
    /// Active subgoals layered onto the goal via `/subgoal` (Hermes v0.14).
    /// Empty list renders as just the goal pill; populated list adds a
    /// trailing count badge inside the pill with the full list in the
    /// tooltip. Optimistic mirror lives on `RichChatViewModel.activeSubgoals`.
    var activeSubgoals: [String] = []
    /// Hermes config's `approvals.mode`. v0.14 surfaces a warning when
    /// this is `"yolo"` so users notice they've opted out of dangerous-
    /// command approvals. Pre-v0.14 hosts can still set the mode but
    /// Scarf doesn't render the badge (no `hasYOLOWarning` flag).
    var approvalMode: String = "manual"
    /// Local mirror of prompts queued via `/queue …` (Hermes v0.13).
    /// Empty list hides the chip.
    var queuedPrompts: [HermesQueuedPrompt] = []
    /// Capability snapshot for v0.13+ surfaces. Defaulted so previews and
    /// pre-v0.13 hosts render the v2.7.5 layout unchanged. Coordinated
    /// with WS-2 — both WSes add `capabilities` to this view.
    var capabilities: HermesCapabilities = .empty
    /// Live count of running + blocked tasks for the chat's tenant
    /// scope (or global, for non-project chats). Polled by
    /// `KanbanChatBadgeViewModel` every 5s. Nil while polling hasn't
    /// produced a result yet (or the host pre-dates kanban) — chip
    /// renders without a badge in that case. Zero renders without a
    /// badge too, so an idle board doesn't render a "0" pill.
    var kanbanLiveCount: Int? = nil
    /// Tap handler for the Kanban chip — typically wired by
    /// `ChatTranscriptPane` to resolve the project's tenant + post a
    /// `KanbanHandoff` to `AppCoordinator`. Nil hides the chip.
    var onOpenKanban: (() -> Void)? = nil

    /// Model preset currently applied to the session via
    /// `session/set_model` (or nil when the session is running on the
    /// config.yaml default). Drives the model badge in the bar — tap
    /// opens a popover with the preset list. Capability-gated by the
    /// chip itself on `capabilities.hasACPSetSessionModel`.
    var modelPreset: ModelPreset? = nil

    /// Mid-chat model switch handler. Tap on the model badge presents
    /// the preset popover; selecting a preset (or "Use global default"
    /// — encoded as `nil`) fires this callback. Nil hides the popover
    /// entirely, so the badge stays read-only on pre-v0.13 hosts or
    /// when the caller doesn't wire it.
    var onSwitchModel: ((ModelPreset?) -> Void)? = nil

    /// Live ACP session edit auto-approval mode (Hermes v0.15+
    /// `session/set_mode`). Drives the per-session approval chip. This
    /// is distinct from the global `approvals.mode` / YOLO surface
    /// above — it loosens or tightens how often Hermes prompts for file
    /// edits within just this session. Defaulted so previews and
    /// pre-v0.15 hosts render unchanged.
    var approvalSessionMode: ACPApprovalMode = .default

    /// Tap handler for the approval-mode chip — selecting a mode fires
    /// this callback (wired to `ChatViewModel.switchApprovalMode`). Nil
    /// hides the chip entirely, so it stays absent on pre-v0.15 hosts or
    /// when the caller doesn't wire it (also gated on
    /// `capabilities.hasSessionEditAutoApproval`).
    var onSwitchApprovalMode: ((ACPApprovalMode) -> Void)? = nil

    /// Active Hermes profile name (issue #50). Resolved on each body
    /// re-evaluation; the resolver caches for 5s so this is cheap.
    /// Chip renders only when not "default" so existing (non-profile)
    /// installations see no change in the bar.
    private var activeProfile: String {
        HermesProfileResolver.activeProfileName()
    }

    var body: some View {
        HStack(spacing: 16) {
            if let session {
                // Profile chip leftmost — surfaces which Hermes profile
                // Scarf is reading (issue #50). Without this users couldn't
                // tell whether the visible session list came from the
                // profile they thought they switched to.
                if activeProfile != "default" {
                    Label(activeProfile, systemImage: "person.crop.square")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.warning)
                        .lineLimit(1)
                        .help("Scarf is reading from Hermes profile \"\(activeProfile)\". Switch profiles with `hermes profile use <name>` and relaunch Scarf.")
                }
                // Project indicator first — visually anchors the session
                // as "scoped to project X" before the working dot and
                // title. Hidden for non-project chats so the bar looks
                // identical to v2.2.1 behavior.
                if let projectName {
                    Label(projectName, systemImage: "folder.fill")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.accent)
                        .lineLimit(1)
                        .help("Chat is scoped to Scarf project \"\(projectName)\"")
                    if let gitBranch {
                        Label(gitBranch, systemImage: "arrow.triangle.branch")
                            .scarfStyle(.caption)
                            .foregroundStyle(ScarfColor.accent)
                            .lineLimit(1)
                            .help("Project's current git branch")
                    }
                }

                // Goal pill (v2.8 / Hermes v0.13). `.info` keeps it
                // visually decodable from the rust accent (project /
                // branch) and the warning amber (queue chip). The
                // pill renders only when `activeGoal` is non-nil —
                // pre-v0.13 hosts can't reach the `/goal` send path
                // through the slash menu (it's filtered out in
                // `availableCommands`), so the pill stays absent there
                // by transitive impossibility.
                // v0.14 — YOLO mode warning badge. Renders only when
                // the user has explicitly opted in via
                // `approvals.mode = yolo` AND the connected host is on
                // v0.14+. Older Hermes versions also accept the mode
                // but don't surface a warning of their own — Scarf
                // matches v0.14's posture by gating on the flag.
                if capabilities.hasYOLOWarning, approvalMode == "yolo" {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("YOLO")
                    }
                    .scarfStyle(.captionUppercase)
                    .padding(.horizontal, ScarfSpace.s2)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(ScarfColor.warning.opacity(0.18)))
                    .foregroundStyle(ScarfColor.warning)
                    .help("YOLO mode is on — dangerous commands run without approval. Toggle via `/yolo` or change approvals.mode in Settings → Agent.")
                }

                if let activeGoal {
                    HStack(spacing: 4) {
                        Image(systemName: "scope")
                        Text(Self.truncatedGoal(activeGoal.text))
                        if !activeSubgoals.isEmpty {
                            // v0.14 — surface the active subgoal count as
                            // a compact "+N" badge inside the goal pill.
                            // Full list shows in the tooltip below so the
                            // chrome stays one-line at chat-bar height.
                            Text("+\(activeSubgoals.count)")
                                .scarfStyle(.captionUppercase)
                                .padding(.horizontal, 4)
                                .background(Capsule().fill(ScarfColor.info.opacity(0.28)))
                        }
                    }
                    .scarfStyle(.caption)
                    .padding(.horizontal, ScarfSpace.s2)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(ScarfColor.info.opacity(0.16)))
                    .foregroundStyle(ScarfColor.info)
                    .help(Self.goalTooltip(goal: activeGoal.text, subgoals: activeSubgoals))
                    .contextMenu {
                        if let onClearGoal {
                            Button("Clear goal", role: .destructive, action: onClearGoal)
                        }
                    }
                }

                // Model badge — renders the active preset name when
                // session/set_model was used to override the global
                // default. Tap opens a popover for mid-chat switching.
                // Capability-gated on `hasACPSetSessionModel` so
                // pre-v0.13 hosts neither see a stale chip nor get a
                // popover that wouldn't actually switch the session.
                if capabilities.hasACPSetSessionModel, modelPreset != nil || onSwitchModel != nil {
                    ChatModelBadge(
                        preset: modelPreset,
                        onSwitch: onSwitchModel
                    )
                }

                // Per-session edit auto-approval chip (v0.15 / Hermes ACP
                // `session/set_mode`). Renders only when (a) the host
                // advertises the per-session mode RPC and (b) there's a
                // live-session switch handler. Distinct from the global
                // YOLO chip above — this loosens/tightens approvals just
                // for this session. Sensitive paths always still prompt.
                if capabilities.hasSessionEditAutoApproval, let onSwitchApprovalMode {
                    ChatApprovalModeBadge(
                        mode: approvalSessionMode,
                        onSwitch: onSwitchApprovalMode
                    )
                }

                // Kanban chip — renders only when (a) the host stamps an
                // ACP session_id on tasks so the board can scope precisely
                // by `--session` (v0.15+) and (b) the host has a callback
                // for the chip. Tap handler is owned upstream so it can
                // post the chat's session id to AppCoordinator. The badge
                // surfaces this chat's running + blocked task counts so the
                // user sees agent activity at a glance without leaving chat.
                if capabilities.hasKanbanSessionFilter, let onOpenKanban {
                    Button(action: onOpenKanban) {
                        HStack(spacing: 4) {
                            Image(systemName: "rectangle.split.3x1")
                            Text("Kanban")
                            if let count = kanbanLiveCount, count > 0 {
                                Text("\(count)")
                                    .scarfStyle(.captionStrong)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(
                                        Capsule().fill(ScarfColor.accent.opacity(0.22))
                                    )
                            }
                        }
                        .scarfStyle(.caption)
                        .padding(.horizontal, ScarfSpace.s2)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(ScarfColor.accent.opacity(0.12)))
                        .foregroundStyle(ScarfColor.accent)
                    }
                    .buttonStyle(.plain)
                    .help("Open the Kanban board for this chat")
                }

                // Queue chip (v2.8 / Hermes v0.13). Local mirror only —
                // Hermes is the authoritative owner of the actual
                // queue. Per-entry deletion isn't exposed (Hermes has
                // no remove-by-id verb), and the v2.8.0 plan drops the
                // global "Clear all" button to avoid lying about
                // server-side state. The popover is read-only.
                if !queuedPrompts.isEmpty {
                    ChatQueueIndicator(queuedPrompts: queuedPrompts)
                }

                HStack(spacing: 4) {
                    Circle()
                        .fill(isWorking ? ScarfColor.success : ScarfColor.foregroundFaint)
                        .frame(width: 6, height: 6)
                        .opacity(isWorking ? 1 : 0.6)
                    if isWorking {
                        Text("Working")
                            .scarfStyle(.caption)
                            .foregroundStyle(ScarfColor.success)
                    }
                }

                if let title = session.title, !title.isEmpty {
                    Text(title)
                        .scarfStyle(.captionStrong)
                        .foregroundStyle(ScarfColor.foregroundPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if let model = session.model {
                    Label(model, systemImage: "cpu")
                }

                let inputToks = session.inputTokens > 0 ? session.inputTokens : acpInputTokens
                let outputToks = session.outputTokens > 0 ? session.outputTokens : acpOutputTokens
                Label("\(formatTokens(inputToks)) in / \(formatTokens(outputToks)) out", systemImage: "number")
                    .contentTransition(.numericText())

                let reasonToks = session.reasoningTokens > 0 ? session.reasoningTokens : acpThoughtTokens
                if reasonToks > 0 {
                    Label("\(formatTokens(reasonToks)) reasoning", systemImage: "brain")
                }

                // v0.13: Hermes surfaces a running count of automatic
                // context compactions. Render only when the host is on
                // v0.13+ AND the count is non-zero, so a pre-v0.13 host
                // (which always reports 0) sees no chip, and a v0.13 host
                // sees the chip the first time the agent compacts.
                if capabilities.hasContextCompressionCount && acpCompressionCount > 0 {
                    Label(
                        "×\(acpCompressionCount)",
                        systemImage: "arrow.down.right.and.arrow.up.left"
                    )
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .help("Hermes auto-compacted this session's context ^[\(acpCompressionCount) time](inflect: true)")
                }

                if let cost = session.displayCostUSD {
                    let formattedCost = cost.formatted(.currency(code: "USD").precision(.fractionLength(4)))
                    Label(session.costIsActual ? formattedCost : "\(formattedCost) est.", systemImage: "dollarsign.circle")
                        .contentTransition(.numericText())
                }

                if let start = session.startedAt {
                    Label {
                        Text(start, style: .relative)
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: "clock")
                    }
                }

                Spacer()

                Label(session.source, systemImage: session.sourceIcon)
            } else {
                Text("No active session")
                    .foregroundStyle(ScarfColor.foregroundFaint)
                Spacer()
            }
        }
        .scarfStyle(.caption)
        .foregroundStyle(ScarfColor.foregroundMuted)
        .padding(.horizontal, ScarfSpace.s4)
        .padding(.vertical, 6)
        .background(ScarfColor.backgroundSecondary)
        .overlay(
            Rectangle().fill(ScarfColor.border).frame(height: 1),
            alignment: .bottom
        )
    }

    private func formatTokens(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    /// Cap goal text in the chip to keep the SessionInfoBar from
    /// wrapping when the user locks a long goal. Full goal text is
    /// available in the tooltip via `.help(...)`.
    static func truncatedGoal(_ text: String) -> String {
        text.count <= 36 ? text : String(text.prefix(33)) + "…"
    }

    /// Build the help-tooltip body for the goal pill. Includes the
    /// goal text plus a numbered list of any active subgoals so the
    /// user can hover-read the full state without opening a sheet.
    static func goalTooltip(goal: String, subgoals: [String]) -> String {
        if subgoals.isEmpty { return "Goal locked: \(goal)" }
        let lines = subgoals.enumerated().map { idx, s in "  \(idx + 1). \(s)" }
        return "Goal locked: \(goal)\nSubgoals:\n" + lines.joined(separator: "\n")
    }
}
