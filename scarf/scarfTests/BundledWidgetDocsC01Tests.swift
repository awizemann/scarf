import Foundation
import Testing
import ScarfCore
@testable import scarf

/// S03-F2: the bundled `/scarf-widget`, `/scarf-dashboard` and `/scarf-help`
/// prompts listed widget kinds Scarf never had (`sqlite_query`,
/// `command_output`, …) under a `kind` field. Every backticked widget name in
/// them must be a real `DashboardWidgetCatalog` type, and each must list the
/// whole catalog.
@Suite("Bundled widget docs match the catalog (S03-F2)")
struct BundledWidgetDocsC01Tests {

    static let bundleDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scarf/Resources/BuiltinSlashCommands.bundle")

    static let retired = ["sqlite_query", "command_output", "file_glob", "recent_messages", "`markdown`", "`kind`"]

    @Test(arguments: ["scarf-widget.md", "scarf-dashboard.md", "scarf-help.md"])
    func promptListsExactlyTheCatalog(file: String) throws {
        let text = try String(contentsOf: Self.bundleDir.appendingPathComponent(file), encoding: .utf8)
        for name in Self.retired {
            #expect(!text.contains(name), "\(file) still mentions \(name)")
        }
        for type in DashboardWidgetCatalog.knownTypes {
            #expect(text.contains("`\(type)`") || text.contains("**\(type)**"),
                    "\(file) doesn't list the \(type) widget")
        }
        // A bumped version is what makes the bootstrap replace installed copies.
        #expect(text.contains("version: 1.1.0"))
    }
}

/// S06-F1: the proxy help card named `hermes login <provider>`, which has no
/// provider positional; Hermes's own hint is `hermes auth add …`.
@Suite("Proxy sign-in hint (S06-F1)")
struct ProxySignInHintC01Tests {
    @Test func matchesHermesAuthHints() {
        #expect(HermesProxyView.signInCommand(for: "nous") == "hermes auth add nous")
        #expect(HermesProxyView.signInCommand(for: "xai") == "hermes auth add xai-oauth --type oauth")
        #expect(!HermesProxyView.signInCommand(for: "nous").contains("login"))
    }
}
