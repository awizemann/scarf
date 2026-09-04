// swift-tools-version: 6.0
// Platform-neutral core for the Scarf app family (macOS and iOS).
//
// `ScarfCore` holds types that do not depend on AppKit, UIKit, or any
// platform-specific system service. The macOS and iOS app targets each link
// this package and provide their own platform shells (Sparkle + SwiftTerm on
// macOS; Citadel-based SSH transport on iOS).
//
// Minimums are chosen to match the Mac app (macOS 14.6) and the locked
// v1 iOS decision (iOS 18). Raising iOS later is free; lowering is not —
// the ViewModels on `@Observable` / `NavigationStack` are iOS 17+ features
// and we standardize on iOS 18 for feature parity with the Mac codebase.

import PackageDescription

let package = Package(
    name: "ScarfCore",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
        .iOS(.v18),
    ],
    products: [
        .library(
            name: "ScarfCore",
            targets: ["ScarfCore"]
        ),
        // The MCP server Scarf.app bundles in Contents/Helpers and
        // registers into the local Hermes config. It lives here, in the
        // package that owns the project services, so every tool wraps the
        // SAME writers the UI uses instead of a second implementation.
        .executable(
            name: "scarf-projects-mcp",
            targets: ["scarf-projects-mcp"]
        ),
    ],
    targets: [
        .target(
            name: "ScarfCore",
            path: "Sources/ScarfCore",
            swiftSettings: [
                // Swift 5 language mode mirrors the Mac app target's
                // `SWIFT_VERSION = 5.0` build setting. Moving to strict
                // Swift 6 concurrency is a real refactor — several types
                // (`ACPEvent.availableCommands` carrying `[[String: Any]]`,
                // `ACPToolCallEvent.rawInput: [String: Any]?`) claim
                // `Sendable` without being strictly-Sendable. A follow-up
                // phase will replace those with typed payloads, then this
                // setting can bump to `.v6`.
                .swiftLanguageMode(.v5),
            ]
        ),
        // Protocol + tool handlers, split out of the executable so they
        // can be `@testable import`ed. An executable target cannot be,
        // and the handlers are the half worth testing.
        .target(
            name: "ScarfProjectsMCPKit",
            dependencies: ["ScarfCore"],
            path: "Sources/ScarfProjectsMCPKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Thin shell: resolve the Hermes home, run the stdio loop.
        .executableTarget(
            name: "scarf-projects-mcp",
            dependencies: ["ScarfCore", "ScarfProjectsMCPKit"],
            path: "Sources/scarf-projects-mcp",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                // Xcode builds ScarfCore as a DYNAMIC framework for the app
                // and embeds it at `Scarf.app/Contents/Frameworks`. Without
                // this rpath the copy of the helper inside the bundle links
                // against `…/Build/Products/…/PackageFrameworks` — a path
                // that exists only on the machine that built it, so the
                // shipped binary dies at dyld before it reads a byte of
                // stdin. Harmless for `swift build`, which links the
                // package statically and never consults it.
                .unsafeFlags(
                    ["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"],
                    .when(platforms: [.macOS])
                ),
            ]
        ),
        .testTarget(
            name: "ScarfCoreTests",
            dependencies: ["ScarfCore"],
            path: "Tests/ScarfCoreTests"
        ),
        .testTarget(
            name: "ScarfProjectsMCPKitTests",
            // The executable is a dependency so `swift test` BUILDS it
            // into the products directory — without it the stdio smoke
            // test has nothing to spawn and silently skips, which is a
            // smoke test that never smokes.
            dependencies: ["ScarfProjectsMCPKit", "ScarfCore", "scarf-projects-mcp"],
            path: "Tests/ScarfProjectsMCPKitTests"
        ),
    ]
)
