import Foundation

/// Bot Mode's canonical-conversation contract, source-verified against
/// Hermes tag v2026.8.31 (0.21.0).
///
/// A bot's forever-chat has exactly ONE identity: the session in that
/// profile's `state.db` titled **exactly** `"Bot Chat"`. There is no
/// session-id pointer anywhere on disk — every surface (the desktop
/// plugin, `hermes peer dm`, the DM tool's `hermes -p <name> chat -c
/// "Bot Chat"` transport) re-resolves the conversation by exact-title
/// lookup on every open. `hermes_state.SessionDB.CANONICAL_BOT_CHAT_TITLE`
/// (:10066) is the definition; `SessionDB._set_session_title` (:10210)
/// refuses to rename a *hidden* row holding it precisely because the name
/// IS the identity.
///
/// The same title is the gate for the bot-mode protocol prompt:
/// `agent/system_prompt.py` (:737-747) injects the teammate protocol
/// section **only** when the session's title equals this string. Open the
/// wrong session — or mint a differently-titled one — and the agent on the
/// other end is not a bot at all, just an ordinary Hermes session.
public enum BotChatSession {

    /// The canonical title. Exact, case-sensitive, never localized: it is a
    /// wire value Hermes matches with `==`, not a label.
    public static let canonicalTitle = "Bot Chat"

    /// The `@handle` a profile is addressed by in Bot Mode.
    /// `tools/bot_mode_dm.py:210` — `_handle(name) = "hermes" if name ==
    /// "default" else name`. The default profile is "hermes" because
    /// "@default" reads as a setting rather than a teammate.
    public static func handle(forProfile profileName: String) -> String {
        profileName == HermesProfileScope.defaultProfileName ? "hermes" : profileName
    }

    /// Whether renaming a session away from `currentTitle` needs a
    /// confirmation first.
    ///
    /// **Why Scarf has to ask, when Hermes already refuses.**
    /// `SessionDB._set_session_title` (:10210) blocks the rename only for a
    /// session that is BOTH titled `"Bot Chat"` AND `hidden`. Hermes Desktop
    /// mints its canonical chats hidden, so the guard always fires there.
    /// Scarf's can only be created through the CLI, which never sets
    /// `hidden` (see `BotConversationViewModel.createCanonicalBotChat`) — so
    /// for a Scarf-created Bot Chat the server-side guard never fires and
    /// the rename SUCCEEDS, orphaning the bot's whole conversation history:
    /// every surface re-resolves the chat by exact title, so a renamed one
    /// is simply gone and the next message mints a fresh empty one.
    /// (go/no-go blocking condition 3, A2-F8/A3-F1/A4-C3.)
    ///
    /// The check is deliberately a plain exact-title comparison and is NOT
    /// scoped to bot-managed profiles: the caller renaming from a Sessions
    /// list has no profile context, the title is the identity in every
    /// profile, and a user who titled an ordinary session `"Bot Chat"` by
    /// hand is exactly the person who benefits from being told what that
    /// name means. Renaming to the SAME title is a no-op, so it never asks.
    public static func renameNeedsConfirmation(currentTitle: String?, newTitle: String) -> Bool {
        guard currentTitle == canonicalTitle else { return false }
        return newTitle.trimmingCharacters(in: .whitespacesAndNewlines) != canonicalTitle
    }

    /// The one sentence shown in that confirmation. Kept next to the rule it
    /// explains so the two can't drift.
    public static let renameWarning =
        "“Bot Chat” is how Hermes finds a bot's conversation — there is no other pointer to it. "
        + "Renaming it detaches the bot's entire history: the bot's pane will look empty and its "
        + "next message starts a brand-new chat."
}

/// A teammate-attributed message: the server-side prefix Hermes stamps on
/// every agent-to-agent DM, split back into its sender and its body.
///
/// `tools/bot_mode_dm.py:292` builds it as, literally:
///
///     f"Message from 🤖 {sender_handle} (@{sender_handle}): "
///
/// and prepends it to the message body before delivery. It is applied
/// server-side, so the receiving profile's `state.db` holds the prefix as
/// part of an ordinary user-role message row — there is no column, flag, or
/// metadata distinguishing a teammate DM from something the human typed.
/// Recovering the sender therefore means parsing the text, which is exactly
/// why this parser is deliberately strict about the parts that carry
/// meaning and tolerant only about whitespace.
public struct BotMessageAttribution: Sendable, Equatable {

    /// The sending bot's handle, WITHOUT the `@`.
    public let handle: String

    /// The message with the attribution prefix removed.
    public let body: String

    public init(handle: String, body: String) {
        self.handle = handle
        self.body = body
    }

    /// The literal opening of the prefix. The robot is U+1F916; it is part
    /// of the wire format, not decoration.
    private static let opening = "Message from \u{1F916} "

    /// Parse `content` as an attributed teammate message, or return `nil`
    /// when it is an ordinary message.
    ///
    /// **Why the handle must appear twice.** The prefix names the sender in
    /// two places — bare, then again inside `(@…)`. Requiring both to be
    /// present *and equal* is what makes a false positive essentially
    /// impossible: a human who happens to open a message with "Message from
    /// 🤖 someone: " does not also produce the parenthesized repeat with a
    /// matching handle. A looser parser (prefix-only, or `@`-only) would
    /// re-attribute an ordinary message to a bot that never sent it, and
    /// strip real content off the front of it — a silent corruption of the
    /// transcript, which is worse than showing a DM unattributed.
    ///
    /// Tolerances, and only these:
    /// - leading whitespace/newlines before the prefix are ignored;
    /// - the separating space and the trailing `": "` may carry extra
    ///   spaces (a hand-rolled sender, an older prompt-injected transport,
    ///   or a reflow somewhere in the pipeline);
    /// - the handle is any non-empty run that contains no newline and no
    ///   parenthesis or `@`. Profile ids are `[a-z0-9_-]` today
    ///   (`hermes_cli/profiles._PROFILE_ID_RE`), but peer handles arrive
    ///   from another host's roster and the prompt-injected legacy
    ///   transport never validated them, so the parser does not impose the
    ///   local regex on a name it did not generate. Unicode handles parse.
    ///
    /// The body is returned verbatim after the prefix — never trimmed. A
    /// DM whose body legitimately begins with whitespace (a code block, a
    /// diff) keeps it.
    public static func parse(_ content: String) -> BotMessageAttribution? {
        // Only leading whitespace is skipped; everything after the prefix
        // is the body exactly as stored.
        var cursor = content.startIndex
        while cursor < content.endIndex, content[cursor].isWhitespace {
            cursor = content.index(after: cursor)
        }
        guard content[cursor...].hasPrefix(opening) else { return nil }
        var rest = content[content.index(cursor, offsetBy: opening.count)...]

        // A hand-rolled sender may have padded the separator.
        while let first = rest.first, first == " " {
            rest = rest.dropFirst()
        }

        // Bare handle, up to the " (@" marker.
        guard let markerStart = rest.range(of: " (@") else { return nil }
        let bare = String(rest[..<markerStart.lowerBound])
        guard isPlausibleHandle(bare) else { return nil }

        // Parenthesized repeat, up to the closing ")".
        let afterMarker = rest[markerStart.upperBound...]
        guard let closeParen = afterMarker.firstIndex(of: ")") else { return nil }
        let mentioned = String(afterMarker[..<closeParen])
        guard mentioned == bare else { return nil }

        // Trailing ":" then at least one space.
        var tail = afterMarker[afterMarker.index(after: closeParen)...]
        guard tail.first == ":" else { return nil }
        tail = tail.dropFirst()
        guard tail.first == " " else { return nil }
        while let first = tail.first, first == " " {
            tail = tail.dropFirst()
        }

        return BotMessageAttribution(handle: bare, body: String(tail))
    }

    /// A handle is anything non-empty that cannot be confused with the
    /// prefix's own punctuation. Newlines are excluded so a multi-line
    /// message can never have its second line pulled into the handle.
    private static func isPlausibleHandle(_ candidate: String) -> Bool {
        guard !candidate.isEmpty, candidate.count <= 128 else { return false }
        for character in candidate {
            if character.isNewline { return false }
            if character == "(" || character == ")" || character == "@" { return false }
        }
        return true
    }
}

public extension HermesMessage {
    /// Teammate attribution recovered from this message's content, or `nil`
    /// for an ordinary message. See `BotMessageAttribution.parse`.
    ///
    /// Only USER-role rows are considered. A teammate DM is delivered as
    /// input to the receiving agent, so it is always persisted with role
    /// `user`; an assistant row that quotes the prefix back (an agent
    /// recapping "you got: Message from 🤖 …") is the agent's own words and
    /// must render as such.
    var botAttribution: BotMessageAttribution? {
        guard role == "user" else { return nil }
        return BotMessageAttribution.parse(content)
    }
}
