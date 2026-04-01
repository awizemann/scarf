import SwiftUI

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
