import SwiftUI

/// Map a server-supplied color name to a SwiftUI `Color`. iOS twin of
/// the Mac helper at `scarf/Features/Projects/Views/Widgets/WidgetHelpers.swift`.
/// Unknown names default to `.blue` to keep dashboards visually
/// consistent across platforms.
func parseColor(_ name: String?) -> Color {
    switch name?.lowercased() {
    case "red": return .red
    case "orange": return .orange
    case "yellow": return .yellow
    case "green": return .green
    case "blue": return .blue
    case "purple": return .purple
    case "pink": return .pink
    case "teal", "cyan": return .teal
    case "indigo": return .indigo
    case "mint": return .mint
    case "brown": return .brown
    case "gray", "grey": return .gray
    default: return .blue
    }
}
