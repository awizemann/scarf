import Foundation

struct HermesSkillCategory: Identifiable, Sendable {
    let id: String
    let name: String
    let skills: [HermesSkill]
}

struct HermesSkill: Identifiable, Sendable {
    let id: String
    let name: String
    let category: String
    let path: String
    let files: [String]
}
