import Foundation
import Testing
@testable import scarf

/// Keeps `scarf/scarfUITests/Resources/Sections.json` — the section list the
/// XCUITest bundle sweeps — in lockstep with `SidebarSection.allCases`.
///
/// ## Why a file and not an import
///
/// `scarfUITests` links neither the app module nor ScarfCore (XCUITest bundles
/// drive the app as a black box), so it cannot say `SidebarSection.allCases`.
/// The section list therefore crosses the target boundary as a JSON resource.
/// A duplicated list rots silently, so this test is the guard: add a
/// `SidebarSection` case without updating the JSON and the *unit* run fails —
/// fast, before anyone waits on a UI run.
///
/// The JSON is located by `#filePath` (the same trick the other scan tests in
/// this bundle use, e.g. `HermesFileServiceConfigParityTests`) rather than by
/// bundle resource lookup: the file belongs to the UI-test target's bundle, not
/// this one, and these scan tests only ever run from a source checkout.
@Suite("Section catalog parity")
struct SectionCatalogTests {

    struct CatalogEntry: Decodable {
        let rawValue: String
        let live: Bool
        let gated: Bool
    }

    struct Catalog: Decodable {
        let sections: [CatalogEntry]
    }

    /// `<repo>/scarf/scarfUITests/Resources/Sections.json`, from
    /// `<repo>/scarf/scarfTests/SectionCatalogTests.swift`.
    static var catalogURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // scarfTests/
            .deletingLastPathComponent()   // scarf/
            .appendingPathComponent("scarfUITests/Resources/Sections.json")
    }

    static func loadCatalog() throws -> Catalog {
        let data = try Data(contentsOf: catalogURL)
        return try JSONDecoder().decode(Catalog.self, from: data)
    }

    @Test("Sections.json lists exactly SidebarSection.allCases, in declaration order")
    func catalogMatchesAllCases() throws {
        let catalog = try Self.loadCatalog()
        let fromJSON = catalog.sections.map(\.rawValue)
        let fromEnum = SidebarSection.allCases.map(\.rawValue)

        let missing = Set(fromEnum).subtracting(fromJSON).sorted()
        let extra = Set(fromJSON).subtracting(fromEnum).sorted()
        #expect(
            missing.isEmpty,
            """
            Sections.json is missing \(missing). Add an entry for each new \
            SidebarSection case to scarf/scarfUITests/Resources/Sections.json \
            so SectionSweepUITests covers it, and give its routed view a \
            `<rawValue>.root` identifier (ContentView applies this \
            automatically at the switch — nothing to do unless you route the \
            section somewhere else).
            """
        )
        #expect(
            extra.isEmpty,
            "Sections.json lists \(extra), which are not SidebarSection cases — remove them."
        )
        // Order too: the sweep walks the JSON top-to-bottom and the file is
        // meant to read like the enum, so drift in order is drift.
        #expect(fromJSON == fromEnum, "Sections.json order diverged from SidebarSection declaration order.")
    }

    @Test("Every catalog rawValue is a real SidebarSection with a matching id")
    func rawValuesResolve() throws {
        for entry in try Self.loadCatalog().sections {
            let section = SidebarSection(rawValue: entry.rawValue)
            #expect(section != nil, "\(entry.rawValue) is not a SidebarSection rawValue")
            // The sweep builds both the sidebar identifier
            // (`sidebar.section.<id>`) and the root identifier
            // (`<id>.root`) from this string, and `id` is defined as
            // `rawValue` — assert that identity holds so a future
            // `var id` change can't silently break every UI selector.
            #expect(section?.id == entry.rawValue)
        }
    }

}
