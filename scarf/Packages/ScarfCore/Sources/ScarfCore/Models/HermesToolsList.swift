import Foundation

/// Parser for `hermes tools list --platform <p>` stdout.
///
/// Lifted verbatim out of the app target's `ToolsViewModel` (which now calls
/// this) so the per-bot Agent surface can read a bot's toolsets through the
/// **same** parse the root Tools screen uses. Reading them any other way would
/// have meant guessing: a bot's `config.yaml` only ever pins
/// `platform_toolsets.<platform>` when the user has changed something, and
/// Hermes computes the default set at read time (`_get_platform_tools`), so
/// the pinned list alone can never enumerate what the agent actually loads.
/// `tools list` prints the effective set with a ✓/✗ per row, which is exactly
/// the truth a toggle needs.
public enum HermesToolsList {

    /// Parse the ✓/✗ rows. Lines that are not a toolset row (headers, blank
    /// lines, hints) are skipped rather than guessed at.
    public static func parse(_ output: String) -> [HermesToolset] {
        var tools: [HermesToolset] = []
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isEnabled: Bool
            if trimmed.hasPrefix("✓ enabled") {
                isEnabled = true
            } else if trimmed.hasPrefix("✗ disabled") {
                isEnabled = false
            } else {
                continue
            }
            let rest = trimmed
                .replacingOccurrences(of: "✓ enabled", with: "")
                .replacingOccurrences(of: "✗ disabled", with: "")
                .trimmingCharacters(in: .whitespaces)

            let parts = rest.split(separator: " ", maxSplits: 1)
            guard let namePart = parts.first else { continue }
            let name = String(namePart)
            let rawDesc = parts.count > 1 ? String(parts[1]) : name

            let icon = extractEmoji(from: rawDesc)
            let description = rawDesc
                .unicodeScalars.filter { !$0.properties.isEmoji || $0.isASCII }
                .map { String($0) }.joined()
                .trimmingCharacters(in: .whitespaces)

            tools.append(HermesToolset(name: name, description: description, icon: icon, enabled: isEnabled))
        }
        return tools
    }

    public static func extractEmoji(from text: String) -> String {
        for scalar in text.unicodeScalars where scalar.properties.isEmoji && !scalar.isASCII {
            return String(scalar)
        }
        return "🔧"
    }
}
