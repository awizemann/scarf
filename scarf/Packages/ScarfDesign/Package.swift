// swift-tools-version: 6.0
// Scarf Design System — typed token bridge + SwiftUI component primitives
// for the macOS and iOS apps.
//
// Ships color tokens (rust/amber brand, surfaces, foregrounds, semantic, tool
// kinds) as an Xcode asset catalog and a thin Swift API
// (`ScarfColor`, `ScarfFont`, `ScarfSpace`, `ScarfRadius`, `ScarfShadow`,
//  `ScarfPrimaryButton`, `ScarfCard`, `ScarfBadge`, `ScarfTextField`,
//  `ScarfSectionHeader`, `ScarfDivider`).
//
// Both app targets (`scarf`, `scarf mobile`) link this package and `import
// ScarfDesign`. The asset catalog is bundled as a `.process` resource so the
// `Color(name, bundle: .module)` lookups in `ScarfTheme.swift` resolve at
// runtime regardless of which app is hosting the bundle.
//
// Platform minimums match the rest of the workspace: macOS 14 + iOS 18.

import PackageDescription

let package = Package(
    name: "ScarfDesign",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
        .iOS(.v18),
    ],
    products: [
        .library(
            name: "ScarfDesign",
            targets: ["ScarfDesign"]
        ),
    ],
    targets: [
        .target(
            name: "ScarfDesign",
            path: "Sources/ScarfDesign",
            resources: [
                .process("ScarfBrand.xcassets"),
            ],
            swiftSettings: [
                // Match ScarfCore / ScarfIOS — Swift 5 language mode pending
                // the workspace-wide bump to strict Swift 6 concurrency.
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
