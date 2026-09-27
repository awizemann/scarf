import Foundation

/// When a silent ACP channel counts as dead (ScarfGo's stall detector,
/// `ChatController.startHealthMonitor`).
///
/// iOS over Tailscale can lose the SSH socket without the OS noticing for
/// minutes, so the chat treats a long silence during a turn as a dead
/// channel and reconnects. But Hermes is legitimately silent in two cases,
/// and a reconnect there tears down the turn the user is waiting on
/// (S01-F2):
///
/// - **A permission prompt is open.** The agent thread blocks on the
///   answer with no output until `approvals.timeout` (300 s by default)
///   runs out (`acp_adapter/permissions.py:89-125`,
///   `tools/approval_context.py:239-247` @ v2026.9.24). When it does,
///   Hermes denies the tool itself and carries on without telling the
///   client, so the sheet can outlive the wait. The prompt gets the same
///   long ceiling as a tool call rather than an exemption: a live Hermes
///   has spoken again long before it, and a socket that died behind an
///   unanswered sheet is still caught.
/// - **A tool call is running.** The adapter reports only a tool's start
///   and its completion (`make_tool_progress_cb`,
///   `acp_adapter/events.py:119-153`), so a two-minute build is silent.
///   The terminal tool runs a foreground command for at most 600 s
///   (`FOREGROUND_MAX_TIMEOUT`, `tools/terminal_tool.py:75`) before it
///   moves it to the background, so a tool call gets a much longer
///   ceiling rather than none — a socket that dies mid-tool is still
///   caught, just later.
public enum ACPStallPolicy {
    /// Silence tolerated while the agent streams a turn outside a tool.
    public static let streamingSeconds: TimeInterval = 75
    /// Silence tolerated while a tool call is open or a permission prompt
    /// waits: the terminal tool's 600 s foreground cap (and three times
    /// the default approval timeout) plus headroom.
    public static let toolCallSeconds: TimeInterval = 900

    /// True when the silence means the channel is dead.
    ///
    /// - Parameters:
    ///   - idleSeconds: time since the last byte from Hermes.
    ///   - secondsSincePermissionAnswered: time since the user last
    ///     answered a permission prompt, if they have. The silence spent
    ///     waiting on the user doesn't count against Hermes: the clock
    ///     restarts at the answer, or a slow answer would trip the
    ///     detector the moment the sheet closed.
    public static func isStalled(
        idleSeconds: TimeInterval,
        secondsSincePermissionAnswered: TimeInterval? = nil,
        isAgentWorking: Bool,
        permissionPending: Bool,
        toolCallInFlight: Bool
    ) -> Bool {
        guard isAgentWorking else { return false }
        let silence = min(idleSeconds, secondsSincePermissionAnswered ?? .infinity)
        let limit = (toolCallInFlight || permissionPending) ? toolCallSeconds : streamingSeconds
        return silence > limit
    }
}
