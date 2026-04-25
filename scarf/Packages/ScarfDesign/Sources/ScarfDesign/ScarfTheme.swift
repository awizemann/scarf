//
//  ScarfTheme.swift
//  Scarf Design System — Swift token bridge
//
//  Mirrors colors_and_type.css. All colors resolve from ScarfBrand.xcassets,
//  so light/dark variants come from the asset catalog automatically.
//
//  Usage:
//    Text("Hello").foregroundStyle(ScarfColor.foregroundPrimary)
//    RoundedRectangle(cornerRadius: ScarfRadius.lg)
//        .fill(ScarfColor.backgroundSecondary)
//        .overlay(RoundedRectangle(cornerRadius: ScarfRadius.lg)
//            .strokeBorder(ScarfColor.border, lineWidth: 1))
//
//  Drop-in: add this file + ScarfBrand.xcassets to your target. Nothing else.
//

import SwiftUI

// MARK: - Colors

/// All Scarf brand colors. Resolves from ScarfBrand.xcassets (light + dark).
public enum ScarfColor {
    fileprivate static func asset(_ name: String) -> Color {
        Color(name, bundle: .module)
    }

    // Brand
    public static let brandRust         = asset("Brand/BrandRust")
    public static let brandRustHover    = asset("Brand/BrandRustHover")
    public static let brandRustActive   = asset("Brand/BrandRustActive")
    public static let brandAmber        = asset("Brand/BrandAmber")
    public static let brandRustDeep     = asset("Brand/BrandRustDeep")

    /// Semantic alias: the "primary" accent. Use this in component code,
    /// not `brandRust` directly — it lets you re-skin without a refactor.
    public static var accent: Color        { brandRust }
    public static var accentHover: Color   { brandRustHover }
    public static var accentActive: Color  { brandRustActive }

    /// Tinted accent for hover halos, selection backgrounds.
    public static var accentTint: Color { brandRust.opacity(0.10) }
    public static var accentTintStrong: Color { brandRust.opacity(0.18) }

    // Surfaces
    public static let backgroundPrimary   = asset("Surface/BackgroundPrimary")
    public static let backgroundSecondary = asset("Surface/BackgroundSecondary")
    public static let backgroundTertiary  = asset("Surface/BackgroundTertiary")

    /// Use at low alpha (0.04–0.10) for subtle fills/dividers.
    public static var border: Color       { asset("Surface/Border").opacity(0.08) }
    public static var borderStrong: Color { asset("Surface/BorderStrong").opacity(0.14) }

    // Foreground
    public static let foregroundPrimary = asset("Foreground/ForegroundPrimary")
    public static let foregroundMuted   = asset("Foreground/ForegroundMuted")
    public static let foregroundFaint   = asset("Foreground/ForegroundFaint")
    public static let onAccent          = asset("Foreground/OnAccent")

    // Semantic
    public static let success = asset("Semantic/SemanticSuccess")
    public static let danger  = asset("Semantic/SemanticDanger")
    public static let warning = asset("Semantic/SemanticWarning")
    public static let info    = asset("Semantic/SemanticInfo")

    // Tool kinds (chat message decorations)
    public enum Tool {
        public static let bash   = ScarfColor.asset("Tool/ToolBash")
        public static let edit   = ScarfColor.asset("Tool/ToolEdit")
        public static let search = ScarfColor.asset("Tool/ToolSearch")
        public static let web    = ScarfColor.asset("Tool/ToolWeb")
        public static let think  = ScarfColor.asset("Tool/ToolThink")
    }
}

// MARK: - Gradients

public enum ScarfGradient {
    /// Tri-stop amber → rust → deep rust. Used on app icon, hero buttons, brand splashes.
    public static let brand = LinearGradient(
        colors: [
            Color(red: 0.910, green: 0.576, blue: 0.376), // #E89360
            Color(red: 0.761, green: 0.353, blue: 0.165), // #C25A2A
            Color(red: 0.478, green: 0.180, blue: 0.078)  // #7A2E14
        ],
        startPoint: .topLeading,
        endPoint:   .bottomTrailing
    )

    /// Soft amber wash for empty states, onboarding moments.
    public static let brandSoft = LinearGradient(
        colors: [
            Color(red: 0.965, green: 0.878, blue: 0.796), // #F6E0CB
            Color(red: 0.937, green: 0.773, blue: 0.620)  // #EFC59E
        ],
        startPoint: .topLeading,
        endPoint:   .bottomTrailing
    )
}

// MARK: - Radii / spacing / shadow

public enum ScarfRadius {
    public static let sm:   CGFloat = 4
    public static let md:   CGFloat = 6
    public static let lg:   CGFloat = 8
    public static let xl:   CGFloat = 12
    public static let xxl:  CGFloat = 14
    public static let pill: CGFloat = 999
}

public enum ScarfSpace {
    public static let s1:  CGFloat = 4
    public static let s2:  CGFloat = 8
    public static let s3:  CGFloat = 12
    public static let s4:  CGFloat = 16
    public static let s5:  CGFloat = 20
    public static let s6:  CGFloat = 24
    public static let s8:  CGFloat = 32
    public static let s10: CGFloat = 40
}

public struct ScarfShadow {
    public let color: Color
    public let radius: CGFloat
    public let x: CGFloat
    public let y: CGFloat

    public static let sm = ScarfShadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
    public static let md = ScarfShadow(color: .black.opacity(0.07), radius: 12, x: 0, y: 4)
    public static let lg = ScarfShadow(color: .black.opacity(0.10), radius: 24, x: 0, y: 8)
    public static let xl = ScarfShadow(color: .black.opacity(0.14), radius: 40, x: 0, y: 16)
}

public extension View {
    func scarfShadow(_ s: ScarfShadow) -> some View {
        self.shadow(color: s.color, radius: s.radius, x: s.x, y: s.y)
    }
}

// MARK: - Motion

public enum ScarfDuration {
    public static let fast: Double = 0.12
    public static let base: Double = 0.20
    public static let slow: Double = 0.30
}

public enum ScarfAnimation {
    /// "Smooth" spring matching the cubic-bezier(0.32, 0.72, 0, 1) easing in CSS.
    public static let smooth = Animation.spring(response: 0.35, dampingFraction: 0.85)
    public static let fast   = Animation.easeOut(duration: ScarfDuration.fast)
    public static let base   = Animation.easeOut(duration: ScarfDuration.base)
}
