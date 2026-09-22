import SwiftUI
import ScarfCore
import ScarfDesign

struct SessionInfoBar: View {
    let session: HermesSession?
    let isWorking: Bool
    /// Fallback token counts from ACP prompt results.
    ///
    /// state.db has carried ACP token counts since Hermes v2026.7.1, and the
    /// bar prefers the DB value whenever it is non-zero. These stay for the
    /// two windows the DB cannot fill: MID-TURN (state.db is written only at
    /// turn boundaries) and pre-v2026.7.1 hosts, whose ACP rows were zero.
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
    // The goal pill (`activeGoal` / `onClearGoal` / `activeSubgoals`) lived
    // here until P55. It rendered an OPTIMISTIC mirror of `/goal` and
    // `/subgoal` — names the ACP adapter has never dispatched at any tag
    // (`acp_adapter/commands.py:44-66` @ `v2026.9.7`), so the pill was
    // Scarf-invented state, on every host. Round-6 decision 3 dropped it;
    // `RichChatViewModel.acpUnhandledSlashNotice(name:)` is what the chat
    // says now.
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
    /// Live count of this chat's tasks that are `running`, `blocked` or
    /// in `review` (`KanbanChatBadgeState.liveStatuses`, which cites the
    /// Hermes status vocabulary). Polled by
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
    /// opens a popover with the preset list. Ungated — `session/set_model`
    /// exists at every supported adapter tag.
    var modelPreset: ModelPreset? = nil

    /// Mid-chat model switch handler. Tap on the model badge presents
    /// the preset popover; selecting a preset (or "Use global default"
    /// — encoded as `nil`) fires this callback. Nil hides the popover
    /// entirely, so the badge stays read-only when the caller doesn't
    /// wire it.
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

    // Transcript density, toggled straight from the bar. Same AppStorage
    // keys the Settings → Display pickers own; the bar buttons flip
    // between "hidden" and the last non-hidden style so a user who
    // prefers compact chips gets compact back, not full.
    @AppStorage(ChatDensityKeys.toolCardStyle)
    private var toolCardStyleRaw: String = ToolCardStyle.full.rawValue
    @AppStorage(ChatDensityKeys.reasoningStyle)
    private var reasoningStyleRaw: String = ReasoningStyle.disclosure.rawValue
    @AppStorage(ChatDensityKeys.toolCardStyleBeforeHide)
    private var toolCardStyleBeforeHide: String = ToolCardStyle.full.rawValue
    @AppStorage(ChatDensityKeys.reasoningStyleBeforeHide)
    private var reasoningStyleBeforeHide: String = ReasoningStyle.disclosure.rawValue

    private var toolCallsVisible: Bool { toolCardStyleRaw != ToolCardStyle.hidden.rawValue }
    private var reasoningVisible: Bool { reasoningStyleRaw != ReasoningStyle.hidden.rawValue }

    private func toggleToolCalls() {
        if toolCallsVisible {
            toolCardStyleBeforeHide = toolCardStyleRaw
            toolCardStyleRaw = ToolCardStyle.hidden.rawValue
        } else {
            let restored = toolCardStyleBeforeHide
            toolCardStyleRaw = restored == ToolCardStyle.hidden.rawValue
                ? ToolCardStyle.full.rawValue : restored
        }
    }

    private func toggleReasoning() {
        if reasoningVisible {
            reasoningStyleBeforeHide = reasoningStyleRaw
            reasoningStyleRaw = ReasoningStyle.hidden.rawValue
        } else {
            let restored = reasoningStyleBeforeHide
            reasoningStyleRaw = restored == ReasoningStyle.hidden.rawValue
                ? ReasoningStyle.disclosure.rawValue : restored
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            identityRow
            if session != nil { statsRow }
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

    /// Row 1: who and where — profile, project, mode chips, working
    /// state, and the session title.
    private var identityRow: some View {
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

                // Model badge — renders the active preset name when
                // session/set_model was used to override the global
                // default. Tap opens a popover for mid-chat switching.
                // Ungated: `session/set_model` exists in the adapter at
                // every supported tag (`acp_adapter/server.py:482` @
                // v2026.3.30 = 0.6.0; `:929` @ v2026.9.7). P49.
                if modelPreset != nil || onSwitchModel != nil {
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
                // surfaces this chat's running, blocked and in-review task
                // count so the user sees at a glance both what the agent is
                // doing and what is waiting on them, without leaving chat.
                // The badge's label must keep naming exactly those three
                // statuses — see `KanbanChatBadgeState.liveStatuses`.
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
                                    // Verbless noun phrase on purpose: no
                                    // locale has to agree an adjective or a
                                    // verb with the count, so no plural
                                    // inflection markup is needed.
                                    .help("Running, blocked or in review: \(count)")
                                    .accessibilityLabel("Running, blocked or in review: \(count)")
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
                    .accessibilityIdentifier("chat.kanbanChip")
                    // The count as its OWN readable string. The number
                    // lives in a `Text` inside the button's label, and
                    // AppKit flattens a `.plain` Button's children, so
                    // there is no element carrying just the digit. "0"
                    // and "" are deliberately different: "" means the
                    // first poll for this chat has not landed yet, "0"
                    // means it landed and the board is idle — which is
                    // exactly the distinction the badge-reset fix is
                    // about, and a test that cannot see it would pass on
                    // a badge that simply never updated.
                    .accessibilityValue(Text(kanbanLiveCount.map(String.init) ?? ""))
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

                Spacer()

                Label(session.source, systemImage: session.sourceIcon)
            } else {
                Text("No active session")
                    .foregroundStyle(ScarfColor.foregroundFaint)
                Spacer()
            }
        }
    }

    /// Row 2: session telemetry — model, tokens, reasoning, compactions,
    /// cost, elapsed — plus the transcript visibility toggles. The
    /// numeric labels keep their intrinsic width; the model name is the
    /// one item allowed to truncate, so the counts never wrap or clip.
    @ViewBuilder
    private var statsRow: some View {
        if let session {
            HStack(spacing: 16) {
                if let model = session.model {
                    Label(model, systemImage: "cpu")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(-1)
                        .help(model)
                }

                let inputToks = session.inputTokens > 0 ? session.inputTokens : acpInputTokens
                let outputToks = session.outputTokens > 0 ? session.outputTokens : acpOutputTokens
                Label("\(formatTokens(inputToks)) in / \(formatTokens(outputToks)) out", systemImage: "number")
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .fixedSize()

                let reasonToks = session.reasoningTokens > 0 ? session.reasoningTokens : acpThoughtTokens
                if reasonToks > 0 {
                    Label("\(formatTokens(reasonToks)) reasoning", systemImage: "brain")
                        .lineLimit(1)
                        .fixedSize()
                }

                // Context-compaction chip. NO Hermes tag sends a compaction
                // count under `acp_adapter/`: the adapter builds `Usage` from
                // `prompt_tokens`, `completion_tokens`, `total_tokens`,
                // `reasoning_tokens` and `cache_read_tokens`/`cached_tokens`
                // only — `acp_adapter/server.py:1050-1059` @ v2026.5.7
                // (0.13.0, the flag's nominal floor) and `:917-924` @
                // v2026.9.7 (0.21.1) — and `_build_usage_update` carries none
                // either. So `acpCompressionCount` is 0 on EVERY host, v0.13+
                // included, and the `> 0` test — not the capability flag — is
                // what hides the chip. Both are kept as the landing pad for a
                // future gateway/`session/update` field.
                if capabilities.hasContextCompressionCount && acpCompressionCount > 0 {
                    Label(
                        "×\(acpCompressionCount)",
                        systemImage: "arrow.down.right.and.arrow.up.left"
                    )
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .fixedSize()
                    .help("Hermes auto-compacted this session's context ^[\(acpCompressionCount) time](inflect: true)")
                }

                // `costDisplay` is the one shared rule (ScarfCore
                // `SessionCostDisplay`): Hermes stores an UNKNOWN cost as the
                // placeholder 0.0, so this bar used to assert "$0.0000 est."
                // where Hermes had said "n/a". Only a host BELOW the v0.7
                // schema — which has no `cost_status` column at all — lands
                // in `.legacy` and renders exactly as before (charter C1); a
                // NULL status on a host that HAS the column is `.unknown`.
                switch session.costDisplay {
                case .amount(let cost, let isActual):
                    let formattedCost = cost.formatted(.currency(code: "USD").precision(.fractionLength(4)))
                    Label(isActual ? formattedCost : "\(formattedCost) est.", systemImage: "dollarsign.circle")
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .fixedSize()
                case .includedFree:
                    // A genuine zero on a subscription-included route — a
                    // real figure, so no " est." marker.
                    Label(
                        Double.zero.formatted(.currency(code: "USD").precision(.fractionLength(4))),
                        systemImage: "dollarsign.circle"
                    )
                    .lineLimit(1)
                    .fixedSize()
                case .unknown:
                    Label("—", systemImage: "dollarsign.circle")
                        .lineLimit(1)
                        .fixedSize()
                        .help("Hermes recorded no cost for this session")
                        .accessibilityLabel(Text("cost unknown"))
                case .legacy(let amount, let isActual):
                    if let amount {
                        let formattedCost = amount.formatted(.currency(code: "USD").precision(.fractionLength(4)))
                        Label(isActual ? formattedCost : "\(formattedCost) est.", systemImage: "dollarsign.circle")
                            .contentTransition(.numericText())
                            .lineLimit(1)
                            .fixedSize()
                    }
                }

                if let start = session.startedAt {
                    Label {
                        Text(start, style: .relative)
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: "clock")
                    }
                    .lineLimit(1)
                    .fixedSize()
                }

                Spacer()

                visibilityToggle(
                    isOn: toolCallsVisible,
                    systemImage: "wrench.and.screwdriver",
                    onLabel: "Hide tool calls in the transcript",
                    offLabel: "Show tool calls in the transcript",
                    action: toggleToolCalls
                )
                visibilityToggle(
                    isOn: reasoningVisible,
                    systemImage: "brain",
                    onLabel: "Hide reasoning in the transcript",
                    offLabel: "Show reasoning in the transcript",
                    action: toggleReasoning
                )
            }
        }
    }

    /// A compact eye-style toggle for the stats row. Filled/tinted when
    /// the channel is visible, slashed and muted when hidden.
    private func visibilityToggle(
        isOn: Bool,
        systemImage: String,
        onLabel: LocalizedStringKey,
        offLabel: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: systemImage)
                Image(systemName: isOn ? "eye" : "eye.slash")
                    .imageScale(.small)
            }
            .padding(.horizontal, ScarfSpace.s2)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(isOn ? ScarfColor.accent.opacity(0.12) : ScarfColor.foregroundFaint.opacity(0.10))
            )
            .foregroundStyle(isOn ? ScarfColor.accent : ScarfColor.foregroundFaint)
        }
        .buttonStyle(.plain)
        .help(isOn ? onLabel : offLabel)
        .accessibilityLabel(isOn ? onLabel : offLabel)
    }

    private func formatTokens(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

}
