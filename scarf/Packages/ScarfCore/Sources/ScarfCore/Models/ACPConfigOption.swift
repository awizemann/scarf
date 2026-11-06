import Foundation

/// One of gateway-backed ACP's session config options (`configOptions`):
/// `{id, name, category, type: "select", currentValue, options: [{value, name}]}`
/// (`config_options` / `session_config_options`,
/// acp_adapter/gateway_session_meta.py:83-125 @ v0.23.0).
///
/// It arrives on the session/new|load|resume|fork reply
/// (`_session_fields`, acp_adapter/gateway_server.py:299-322) and, as the
/// FULL list every time, in a `session/update` whose `sessionUpdate` is
/// `config_option_update` (`_project_config`, :1099-1122). The reply to
/// `session/set_config_option` is the refreshed full list too (:582-616).
///
/// Unknown ids, categories, types and values are kept verbatim and simply
/// not rendered; an entry missing `id` is dropped. The in-process ACP
/// server's `set_config_option` is a no-op that returns `[]`
/// (acp_adapter/server.py:1069-1088) — pickers are only ever built from
/// these lists on gateway-backed ACP (`ACPConfigOption.visiblePickers`).
public struct ACPConfigOption: Sendable, Equatable, Identifiable {
    public struct Choice: Sendable, Equatable, Hashable {
        public let value: String
        public let name: String
        public init(value: String, name: String) {
            self.value = value
            self.name = name
        }
    }

    public let id: String
    public let name: String
    public let category: String?
    public let type: String
    public let currentValue: String?
    public let choices: [Choice]

    public init(
        id: String, name: String, category: String? = nil, type: String = "select",
        currentValue: String?, choices: [Choice]
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.type = type
        self.currentValue = currentValue
        self.choices = choices
    }

    // MARK: Known ids (gateway_session_meta.py @ v0.23.0)

    public static let editApprovalPolicyId = "edit_approval_policy"
    public static let modelId = "model"
    public static let reasoningEffortId = "reasoning_effort"
    public static let serviceTierId = "service_tier"

    /// The choice row for `currentValue`, if Hermes listed one.
    public var currentChoice: Choice? {
        guard let currentValue else { return nil }
        return choices.first { $0.value == currentValue }
    }

    // MARK: Parsing

    nonisolated init?(json: Any) {
        guard let dict = json as? [String: Any],
              let id = dict["id"] as? String, !id.isEmpty else { return nil }
        let rows = (dict["options"] as? [Any] ?? []).compactMap { row -> Choice? in
            guard let r = row as? [String: Any], let value = Self.scalar(r["value"]) else { return nil }
            return Choice(value: value, name: (r["name"] as? String) ?? value)
        }
        self.init(
            id: id,
            name: (dict["name"] as? String) ?? id,
            category: dict["category"] as? String,
            type: (dict["type"] as? String) ?? "select",
            currentValue: Self.scalar(dict["currentValue"]),
            choices: rows
        )
    }

    /// Values are strings on the wire; a boolean/number value (a future
    /// option type) is kept in its JSON spelling rather than crashing.
    nonisolated private static func scalar(_ any: Any?) -> String? {
        switch any {
        case let s as String: return s
        case let b as Bool: return b ? "true" : "false"
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    /// Parse a `configOptions` array. `nil` when the value is absent or not
    /// an array (a host without the field: callers keep what they had).
    public nonisolated static func parseList(_ any: Any?) -> [ACPConfigOption]? {
        guard let array = any as? [Any] else { return nil }
        return array.compactMap { ACPConfigOption(json: $0) }
    }

    // MARK: Gating

    /// The chat pickers Scarf draws from `options`, in Hermes's order:
    /// reasoning effort (v0.22.6) and service tier (v0.23.0), on
    /// gateway-backed ACP only. A select with no choices is hidden. The
    /// model and edit-mode options stay on their existing chips.
    public static func visiblePickers(
        _ options: [ACPConfigOption],
        capabilities: HermesCapabilities
    ) -> [ACPConfigOption] {
        guard capabilities.hasGatewayBackedACP, capabilities.hasACPConfigOptions else { return [] }
        return options.filter { option in
            guard option.type == "select", !option.choices.isEmpty else { return false }
            switch option.id {
            case reasoningEffortId: return true
            case serviceTierId: return capabilities.hasACPServiceTierOption
            default: return false
            }
        }
    }
}

extension ACPConfigOption {
    /// The text to show for a refused `session/set_config_option`. A busy
    /// session's idle-only write raises `RequestError(-32603, text)` with
    /// Hermes's explanation as the message (`_idle_control`,
    /// acp_adapter/gateway_server.py:625-642 @ v0.23.0); show that verbatim.
    public static func refusalText(for error: Error) -> String {
        if case let ACPClientError.rpcError(_, message, details) = error {
            let d = details?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let m = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !m.isEmpty, m != "Internal error" { return m }
            if !d.isEmpty { return d }
        }
        return error.localizedDescription
    }
}
