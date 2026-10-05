// swift-tools-version: 6.0
// iOS-specific support library: Keychain-backed key storage,
// UserDefaults-backed server config, Citadel-backed SSH connection
// testing + key generation. Consumed by the `scarf-ios` app target.
//
// Not built on Linux CI — Citadel's runtime is Apple-only, and
// `Security.framework` (for iOS Keychain) ships in the Apple SDKs
// only. The testable state-machine logic for onboarding lives in
// `ScarfCore/Security/` so Linux `swift test` still exercises the
// core transitions via `MockSSHConnectionTester` and
// `InMemorySSHKeyStore`.

import PackageDescription

let package = Package(
    name: "ScarfIOS",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v18),
        // macOS is included so that (a) Xcode's indexer is happy on a
        // Mac-only developer workstation while the iOS target compiles
        // against the same source tree, (b) `swift test` can run the
        // package's unit tests on the host, and (c) future Mac-catalyst /
        // Designed-for-iPad scenarios work without surgery. Running
        // `scarf-ios` on the Mac is not a supported product today. v15 (not
        // v14) because the iOS sources call macOS-15 APIs — e.g. Citadel's
        // `withExec(_:environment:perform:)` in `SSHExecACPChannel` — that
        // must still type-check when the tree is built for macOS.
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "ScarfIOS",
            targets: ["ScarfIOS"]
        ),
    ],
    dependencies: [
        .package(path: "../ScarfCore"),
        // Pinned tight to the 0.12 minor line. Citadel pre-1.0 has
        // changed its authentication-method variant names between
        // minor versions (0.7 → 0.9 → 0.12) — letting the version
        // float to 0.13+ without a code review risks a silent build
        // break in `PinnedSSHConnect.connect(...)` (PinnedHostKeyValidator.swift). When
        // bumping the minor, smoke test onboarding against:
        //   (a) a real host with 1Password SSH agent
        //   (b) a real host with a hand-edited `authorized_keys`
        .package(url: "https://github.com/orlandos-nl/Citadel", .upToNextMinor(from: "0.12.0")),
    ],
    targets: [
        .target(
            name: "ScarfIOS",
            dependencies: [
                .product(name: "ScarfCore", package: "ScarfCore"),
                .product(
                    name: "Citadel",
                    package: "Citadel",
                    // Don't attempt to link Citadel on Linux — SPM won't
                    // build this target on Linux anyway (iOS-only), but
                    // this keeps the resolution graph clean if ScarfIOS
                    // ever ends up as a transitive dep from something
                    // that DOES target Linux.
                    condition: .when(platforms: [.iOS, .macOS])
                ),
            ],
            path: "Sources/ScarfIOS",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "ScarfIOSTests",
            dependencies: ["ScarfIOS"],
            path: "Tests/ScarfIOSTests"
        ),
    ]
)
