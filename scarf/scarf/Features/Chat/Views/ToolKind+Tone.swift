import ScarfCore
import ScarfDesign

extension ToolKind {
    /// The kind's chip colors (`color` for icon and label, `wash` behind
    /// them), from ScarfDesign so every chip uses the verified pairs.
    var tone: ScarfToolTone {
        switch self {
        case .read:    return .read
        case .edit:    return .edit
        case .execute: return .execute
        case .fetch:   return .fetch
        case .browser: return .browser
        case .other:   return .other
        }
    }
}
