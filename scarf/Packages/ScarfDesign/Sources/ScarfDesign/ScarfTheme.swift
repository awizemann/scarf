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

    // Brand — the identity color (logo, brand mark, gradients, decorative
    // fills). Not for buttons, links, selection or text: light-mode
    // BrandRust (#C25A2A) is only 4.4:1 against white, below WCAG AA.
    public static let brandRust         = asset("Brand/BrandRust")
    public static let brandRustHover    = asset("Brand/BrandRustHover")
    public static let brandRustActive   = asset("Brand/BrandRustActive")
    public static let brandAmber        = asset("Brand/BrandAmber")
    public static let brandRustDeep     = asset("Brand/BrandRustDeep")

    /// Semantic UI accent: buttons, links, tints, selection, accent text.
    /// Use this in component code, not `brandRust`. Light mode sits one
    /// step darker on the brand scale than the brand color (brand-600
    /// #A6481E / 700 / 800) so white labels and accent text clear AA;
    /// dark mode matches the brand's dark values (#E89360 / #F0A879 /
    /// #D87844) and pairs with a dark `onAccent` (brand-900 #3B1608).
    /// Mirrored in design/static-site/colors_and_type.css and the site
    /// stylesheets; tools/check-design-tokens.py fails on drift.
    ///
    /// The apps' own AccentColor.colorset (the SYSTEM tint for checkboxes,
    /// switches, default buttons) matches this in light but is #D87844
    /// (accentActive dark) in dark, not #E89360: the system draws WHITE
    /// glyphs on its tint, and white on #E89360 is 2.39:1. No color can give
    /// white 4.5:1 and also be 4.5:1 text on the dark page, so the tint clears
    /// the 3:1 non-text bar (3.14:1) and stays 5.9:1 as text. Our own filled
    /// buttons use ScarfPrimaryButton (onAccent), never the system tint.
    public static let accent       = asset("Accent/Accent")
    public static let accentHover  = asset("Accent/AccentHover")
    public static let accentActive = asset("Accent/AccentActive")

    /// Tinted accent for hover halos, selection backgrounds — the semantic
    /// accent's RGB at 0.10 / 0.18 alpha (light) and 0.10 / 0.24 (dark),
    /// matching --accent-tint / --accent-tint-strong in the CSS.
    public static let accentTint       = asset("Accent/AccentTint")
    public static let accentTintStrong = asset("Accent/AccentTintStrong")

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

    // Semantic status colors: TEXT and icons, on any surface and on their
    // own `*Tint`. Light mode sits on the 700 step of each hue so the color
    // itself is text-safe: success #186D4C, warning #8A5A12, info #1B6396,
    // danger #A33430 (5.25-6.79:1 on backgroundPrimary / Secondary /
    // Tertiary); dark keeps the lighter hues (#3DBE89 / #F4BE71 / #5BAFE3,
    // danger #EA7F7B, 6.04-11.0:1). A status dot or icon is the same color.
    // A filled danger surface uses `dangerFill` + `onDanger` (white on the
    // dark danger is under 3:1).
    public static let success = asset("Semantic/SemanticSuccess")
    public static let danger  = asset("Semantic/SemanticDanger")
    public static let warning = asset("Semantic/SemanticWarning")
    public static let info    = asset("Semantic/SemanticInfo")

    /// Filled danger surface (destructive buttons, stop controls): red-600
    /// #B83C38 in both appearances, so the white `onDanger` label is 5.61:1.
    /// Mirrored as --danger-fill / --on-danger in colors_and_type.css;
    /// tools/check-design-tokens.py fails on drift or a contrast regression.
    public static let dangerFill = asset("Danger/DangerFill")
    public static let onDanger   = asset("Danger/OnDanger")

    /// The wash behind status text: badges, pills, status strips and tiles.
    /// Each keeps the ORIGINAL, lighter hue of its kind (green-500, orange-500,
    /// blue-500, red-600 in light) at 0.16 (warning 0.18), so a tint reads
    /// as color, not mud. The status color is >= 4.5:1 on its tint over
    /// backgroundPrimary, Secondary and Tertiary in both appearances; for a
    /// lighter banner wash use `warningTint.opacity(0.5)`, which only raises
    /// contrast. Don't wash with `ScarfColor.warning.opacity(...)`: that is
    /// the darker text hue and drops text under AA (4.12:1 at 0.18 on
    /// tertiary). Mirrored as --<kind>-tint; tools/check-design-tokens.py
    /// checks drift and contrast and fails a view that puts a status color
    /// on a wash of itself.
    public static let successTint = asset("Status/SuccessTint")
    public static let warningTint = asset("Status/WarningTint")
    public static let infoTint    = asset("Status/InfoTint")
    public static let dangerTint  = asset("Status/DangerTint")

    /// The wash behind muted (neutral) text: ink at 0.06, so it shows on
    /// every surface, backgroundTertiary included (a backgroundTertiary fill
    /// vanished there). foregroundMuted on it is >= 4.5:1 everywhere.
    public static let neutralTint = asset("Status/NeutralTint")

    /// The ORIGINAL, lighter status hues, opaque: for borders, hairlines,
    /// halos and chart marks that sit at a stronger opacity than a tint can
    /// carry (`warningHue.opacity(0.3)` for a banner stroke). Never text, and
    /// never a wash under text (use `*Tint`): light warningHue is 1.9:1 on the
    /// page.
    public static let successHue = asset("Status/SuccessHue")
    public static let warningHue = asset("Status/WarningHue")
    public static let infoHue    = asset("Status/InfoHue")
    public static let dangerHue  = asset("Status/DangerHue")

    // Tool kinds (chat message decorations). Read / edit / execute use the
    // status colors (success / info / warning; see ScarfToolTone); web fetch
    // and browser have their own.
    public enum Tool {
        /// Text-safe like the status colors: #3F4FB8 / #8C99E8 and #6E3FA6 /
        /// #B48FDC (>= 4.5:1 on every surface and on their tint, both
        /// appearances). `searchTint` / `webTint` are the chip washes, in the
        /// original lighter hue at 0.16.
        public static let search = ScarfColor.asset("Tool/ToolSearch")
        public static let web    = ScarfColor.asset("Tool/ToolWeb")
        public static let searchTint = ScarfColor.asset("Tool/ToolSearchTint")
        public static let webTint    = ScarfColor.asset("Tool/ToolWebTint")
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
