import Testing
import Foundation
import ScarfCore
@testable import scarf

/// v2.3 grew `ProjectEntry` with `folder` and `archived` fields.
/// Both are optional/defaulted at the decoder so v2.2-era
/// `~/.hermes/scarf/projects.json` files still parse cleanly, and
/// v2.3-written files are forward-compatible with v2.2 readers
/// (which ignore unknown keys). These tests lock in both ends of
/// that contract.
///
/// No disk or Hermes dependency — we work entirely with in-memory
/// `Data`, so the `TestRegistryLock` from `ProjectTemplateTests` isn't
/// needed. Safe to run in parallel with every other test suite.
@Suite struct ProjectRegistryMigrationTests {

    @Test func decodesV22RegistryWithoutNewFields() throws {
        // v2.2-era file: just name + path. No folder, no archived.
        let json = """
        {
          "projects": [
            { "name": "Legacy", "path": "/Users/x/legacy" },
            { "name": "Another", "path": "/Users/x/another" }
          ]
        }
        """.data(using: .utf8)!

        let registry = try JSONDecoder().decode(ProjectRegistry.self, from: json)

        #expect(registry.projects.count == 2)
        #expect(registry.projects[0].name == "Legacy")
        #expect(registry.projects[0].path == "/Users/x/legacy")
        // Defaults hydrate for absent v2.3 fields.
        #expect(registry.projects[0].folder == nil)
        #expect(registry.projects[0].archived == false)
    }

    @Test func decodesV23RegistryWithFolderAndArchived() throws {
        let json = """
        {
          "projects": [
            { "name": "Client A", "path": "/Users/x/a", "folder": "Clients" },
            { "name": "Client B", "path": "/Users/x/b", "folder": "Clients", "archived": true },
            { "name": "Personal", "path": "/Users/x/p" }
          ]
        }
        """.data(using: .utf8)!

        let registry = try JSONDecoder().decode(ProjectRegistry.self, from: json)

        #expect(registry.projects.count == 3)
        #expect(registry.projects[0].folder == "Clients")
        #expect(registry.projects[0].archived == false)
        #expect(registry.projects[1].folder == "Clients")
        #expect(registry.projects[1].archived == true)
        #expect(registry.projects[2].folder == nil)
        #expect(registry.projects[2].archived == false)
    }

    @Test func encodeOmitsDefaultedFields() throws {
        // A top-level, non-archived project should encode with ONLY
        // name + path keys. This keeps v2.3-written registries
        // loadable by v2.2 Scarf (which ignores unknown keys), and
        // keeps the file clean for the common case.
        let entry = ProjectEntry(name: "Plain", path: "/Users/x/plain")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(entry)
        let s = try #require(String(data: data, encoding: .utf8))
        #expect(s == #"{"name":"Plain","path":"\/Users\/x\/plain"}"#)
    }

    @Test func encodeIncludesFolderWhenPresent() throws {
        let entry = ProjectEntry(name: "Acme", path: "/a", folder: "Clients")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(entry)
        let s = try #require(String(data: data, encoding: .utf8))
        #expect(s.contains(#""folder":"Clients""#))
        // archived still omitted when false — cleanliness matters.
        #expect(!s.contains(#""archived""#))
    }

    @Test func encodeIncludesArchivedOnlyWhenTrue() throws {
        let archived = ProjectEntry(name: "Old", path: "/o", archived: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(archived)
        let s = try #require(String(data: data, encoding: .utf8))
        #expect(s.contains(#""archived":true"#))

        let active = ProjectEntry(name: "New", path: "/n", archived: false)
        let data2 = try encoder.encode(active)
        let s2 = try #require(String(data: data2, encoding: .utf8))
        #expect(!s2.contains(#""archived""#))
    }

    @Test func roundTripPreservesAllFields() throws {
        let original = ProjectRegistry(projects: [
            ProjectEntry(name: "Top", path: "/t"),
            ProjectEntry(name: "InFolder", path: "/f", folder: "Work"),
            ProjectEntry(name: "ArchivedTop", path: "/a", archived: true),
            ProjectEntry(name: "ArchivedInFolder", path: "/af", folder: "Work", archived: true)
        ])

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProjectRegistry.self, from: encoded)

        #expect(decoded.projects.count == 4)
        #expect(decoded.projects[0].folder == nil && decoded.projects[0].archived == false)
        #expect(decoded.projects[1].folder == "Work" && decoded.projects[1].archived == false)
        #expect(decoded.projects[2].folder == nil && decoded.projects[2].archived == true)
        #expect(decoded.projects[3].folder == "Work" && decoded.projects[3].archived == true)
    }

    @Test func identityStaysKeyedOnName() throws {
        // ProjectEntry.id should remain `name`, so selecting by id
        // across a folder-move or archive-flip still works without
        // a reselection step.
        let a = ProjectEntry(name: "Foo", path: "/p")
        let b = ProjectEntry(name: "Foo", path: "/p", folder: "Clients")
        let c = ProjectEntry(name: "Foo", path: "/p", archived: true)
        #expect(a.id == "Foo")
        #expect(b.id == "Foo")
        #expect(c.id == "Foo")
        #expect(a.id == b.id)
        #expect(a.id == c.id)
    }
}
