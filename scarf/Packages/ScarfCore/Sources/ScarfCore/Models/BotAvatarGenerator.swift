import Foundation
import SwiftUI

/// Deterministic fallback avatar generator for Bot Mode.
///
/// Ports the **legacy geometric** avatar path from Hermes Desktop's
/// `apps/desktop/src/plugins/hermes-bots/avatar.tsx` (audited tag v2026.8.31,
/// Hermes 0.21.0) — `sigilRng` (:29-47, FNV-1a offset `2166136261` / prime
/// `16777619`, then an xorshift 13/17/5 PRNG), `defaultShapeFor` (:107-115,
/// `hash*31 >>> 0 % AVATAR_SHAPES.length`), and `sigilGeometry` (:61-91, the
/// angular hermetic sigil strokes).
///
/// **Not ported: `blobatar@2.0.0` soft-body faces.** `avatar.tsx:16` sources
/// the blob faces from an external npm package (`sdk.blobatarSvg`) that ships
/// no algorithm in the audited source — only its call sites. There is nothing
/// to port; Scarf cannot reproduce those exact pixels. A pinned blobatar
/// shape string (`"blobatar:<seed>:<kind>"`) is instead mapped to the nearest
/// geometric treatment by ``BotAvatarGenerator/geometricShape(forBlobKind:)``
/// — see that function for the mapping table. This mirrors the JS itself:
/// `BotFace` (avatar.tsx:996-997) falls back to `defaultShapeFor(name)` when
/// the blobatar export isn't available, i.e. Hermes's own code already
/// treats "no blob renderer" as "use the geometric shape."
public enum BotAvatarGenerator {

    // MARK: - Shapes

    /// Mirrors `AVATAR_SHAPES` (avatar.tsx:26). Order matters: it is indexed
    /// by `hash % AVATAR_SHAPES.length` in ``shape(forName:)``.
    public enum Shape: String, CaseIterable, Sendable, Equatable {
        case circle, squircle, pill, triangle, hexagon, cloud, drop
    }

    private static let shapeOrder: [Shape] = [.circle, .squircle, .pill, .triangle, .hexagon, .cloud, .drop]

    /// Mirrors `BLOB_KINDS` (avatar.tsx:128-139) — used to validate a
    /// pinned blobatar kind segment before mapping it, the same way
    /// `parseBlobShape` (avatar.tsx:175) only accepts a `parts[2]` that's a
    /// member of this list and otherwise treats the kind as unpinned.
    private static let blobKinds: Set<String> = [
        "round", "organic", "boxy", "capsule", "nub", "cloud", "droplet", "hexagon", "sun", "triangle",
    ]

    /// Every silhouette the blobatar picker can pin (`BLOB_KINDS`,
    /// avatar.tsx:128-139), mapped to the nearest geometric treatment.
    /// There's no principled equivalence — blob silhouettes and the flat
    /// shape set are different vocabularies — so this is a deliberate,
    /// documented, deterministic choice rather than a derived one:
    ///
    /// - `round` → `circle` (closest shape, no rounding difference)
    /// - `organic` → `drop` (both irregular/teardrop-ish, no straight edges)
    /// - `boxy` → `squircle` (both rounded-rectangle family)
    /// - `capsule` → `pill` (identical concept, different name)
    /// - `nub` → `squircle` (small rounded-rect silhouette)
    /// - `cloud` → `cloud` (exact name match)
    /// - `droplet` → `drop` (exact concept match)
    /// - `hexagon` → `hexagon` (exact name match)
    /// - `sun` → `triangle` (radiating/angular, closest angular shape)
    /// - `triangle` → `triangle` (exact name match)
    public static func geometricShape(forBlobKind kind: String) -> Shape {
        switch kind {
        case "round": return .circle
        case "organic": return .drop
        case "boxy": return .squircle
        case "capsule": return .pill
        case "nub": return .squircle
        case "cloud": return .cloud
        case "droplet": return .drop
        case "hexagon": return .hexagon
        case "sun": return .triangle
        case "triangle": return .triangle
        default: return .circle
        }
    }

    /// Every UTF-16 "lead unit" of `name`, one per JS `for...of` iteration
    /// step. JS's `for (const ch of text)` walks Unicode **code points**
    /// (surrogate pairs count once), and `ch.charCodeAt(0)` reads only the
    /// first UTF-16 code unit of that step — the *high* surrogate for an
    /// astral character, not the full code point. Swift's `String` has no
    /// direct equivalent, so this walks `unicodeScalars` and, for a
    /// supplementary-plane scalar (`value > 0xFFFF`), reproduces the same
    /// high-surrogate value `charCodeAt(0)` would have returned.
    static func jsCharCodeSequence(_ text: String) -> [UInt32] {
        text.unicodeScalars.map { scalar in
            let v = scalar.value
            if v > 0xFFFF {
                // UTF-16 surrogate pair encoding (Unicode 3.7): high surrogate.
                return 0xD800 + ((v - 0x10000) >> 10)
            }
            return v
        }
    }

    /// Ports `defaultShapeFor` (avatar.tsx:107-115) exactly: `hash = (hash*31
    /// + charCode) >>> 0` per JS `for...of` step, `AVATAR_SHAPES[hash %
    /// length]`. All arithmetic is `UInt32` with wraparound (`&*`, `&+`),
    /// matching JS's `>>> 0` truncation-to-uint32 after every step (JS
    /// number arithmetic is float64, but `>>> 0` forces the result back to
    /// uint32 before the next multiply, so per-step truncation is exact).
    public static func shape(forName name: String) -> Shape {
        var hash: UInt32 = 0
        for code in jsCharCodeSequence(name) {
            hash = (hash &* 31) &+ code
        }
        return shapeOrder[Int(hash % UInt32(shapeOrder.count))]
    }

    // MARK: - Deterministic PRNG (sigilRng)

    /// Ports `sigilRng` (avatar.tsx:29-47): seed an FNV-1a-style hash from
    /// `text`, then drive a 32-bit xorshift (13/17/5) PRNG from it. Returns
    /// a closure producing the same `[0, 1)` sequence as the JS generator,
    /// call for call.
    ///
    /// `Math.imul(h, 16777619)` is JS's 32-bit truncating multiply (the low
    /// 32 bits of the product, independent of operand signedness) — exactly
    /// what Swift's `UInt32` `&*` computes, so keeping `h`/`state` as
    /// `UInt32` throughout reproduces the same bit pattern JS's `h >>> 0`
    /// would yield without a separate normalization step.
    static func sigilRNG(_ text: String) -> () -> Double {
        var h: UInt32 = 2166136261
        for code in jsCharCodeSequence(text) {
            h ^= code
            h = h &* 16777619
        }
        var state: UInt32 = h != 0 ? h : 88675123

        return {
            state ^= state << 13
            state ^= state >> 17   // JS `>>>` is a logical (unsigned) shift;
                                    // Swift's `>>` on UInt32 already is.
            state ^= state << 5
            return Double(state) / 4294967296.0
        }
    }

    // MARK: - Sigil geometry (sigilGeometry)

    /// One line segment in the 40×40 sigil box, in the same coordinate
    /// space as `sigilGeometry`'s SVG path strings (avatar.tsx:61-91).
    public struct SigilStroke: Sendable, Equatable {
        public let x1: Double
        public let y1: Double
        public let x2: Double
        public let y2: Double
    }

    /// A generated sigil's geometry — every stroke, plus the diamond ring
    /// when the roll picked one.
    public struct SigilGeometry: Sendable, Equatable {
        public let strokes: [SigilStroke]
        public let hasRing: Bool
        /// The four corners of the diamond ring (`M20 4 L36 20 L20 36 L4 20
        /// Z`, avatar.tsx:85), present only when ``hasRing`` is `true`.
        public let ringCorners: [(x: Double, y: Double)]

        public static func == (lhs: SigilGeometry, rhs: SigilGeometry) -> Bool {
            lhs.strokes == rhs.strokes && lhs.hasRing == rhs.hasRing
                && lhs.ringCorners.map(\.x) == rhs.ringCorners.map(\.x)
                && lhs.ringCorners.map(\.y) == rhs.ringCorners.map(\.y)
        }
    }

    /// Ports `sigilGeometry` (avatar.tsx:61-91) exactly: same grid, same
    /// `rng()` call order (segment count, then per-segment x1/y1/x2/y2/tie,
    /// then the spine, then the ring roll), same clamping.
    public static func sigilGeometry(name: String, seed: Int) -> SigilGeometry {
        let rng = sigilRNG("\(name)::\(seed)")
        func gx(_ i: Int) -> Double { 6 + Double(i) * 7 }
        func gy(_ j: Int) -> Double { 8 + Double(j) * 6 }

        var strokes: [SigilStroke] = []
        let segments = 4 + Int(rng() * 3)

        for _ in 0..<segments {
            let x1 = Int(rng() * 3)
            let y1 = Int(rng() * 5)
            let x2 = min(2, max(0, x1 + (rng() > 0.5 ? 1 : -1)))
            let y2 = min(4, max(0, y1 + Int(rng() * 3) - 1))
            strokes.append(SigilStroke(x1: gx(x1), y1: gy(y1), x2: gx(x2), y2: gy(y2)))
            // mirror (col i → col 4-i)
            strokes.append(SigilStroke(x1: gx(4 - x1), y1: gy(y1), x2: gx(4 - x2), y2: gy(y2)))

            if rng() > 0.6 {
                strokes.append(SigilStroke(x1: gx(x2), y1: gy(y2), x2: gx(4 - x2), y2: gy(y2)))
            }
        }

        // spine down the axis grounds every variant
        strokes.append(SigilStroke(x1: 20, y1: gy(0), x2: 20, y2: gy(4)))
        let hasRing = rng() > 0.45
        let ringCorners: [(x: Double, y: Double)] = hasRing
            ? [(20, 4), (36, 20), (20, 36), (4, 20)]
            : []

        return SigilGeometry(strokes: strokes, hasRing: hasRing, ringCorners: ringCorners)
    }

    // MARK: - Color

    /// Deterministic fallback hue, used only when neither `identity.color`
    /// nor a picked-shape color is set. This is Scarf's own formula, **not**
    /// a port of Hermes's `profileColor` — that helper lives in
    /// `@hermes/plugin-sdk`, an external package with no algorithm in the
    /// audited desktop source (same non-portability as blobatar; see the
    /// type-level doc comment). Deterministic in the same sense (same name →
    /// same color, stable across runs/platforms), built from the same FNV-1a
    /// seed so it needs no extra dependency.
    public static func fallbackColor(forName name: String) -> Color {
        var h: UInt32 = 2166136261
        for code in jsCharCodeSequence(name) {
            h ^= code
            h = h &* 16777619
        }
        let hue = Double(h % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.78)
    }

    // MARK: - Resolved appearance

    /// What ``BotAvatarView`` should draw when there's no photo: a shape
    /// (or sigil), a color, and — for a sigil — the seed that drives its
    /// geometry.
    public struct Appearance: Sendable, Equatable {
        public let shape: Shape
        public let color: Color
        /// Non-nil (and takes precedence over ``shape``) when the identity
        /// pinned a `sigil-<n>` treatment.
        public let sigilSeed: Int?

        public static func == (lhs: Appearance, rhs: Appearance) -> Bool {
            lhs.shape == rhs.shape && lhs.sigilSeed == rhs.sigilSeed
        }
    }

    /// Resolves the fallback appearance for a bot, honoring
    /// ``HermesBotIdentity``'s stored `color` / `shape` when set, else
    /// deriving both from `displayName` — mirroring `botAppearance`
    /// (avatar.tsx:1091-1114): an explicit pick always wins over the
    /// name-derived default.
    ///
    /// Shape-string handling, in priority order:
    /// 1. `sigil-<n>` → sigil geometry seeded by `<n>` (avatar.tsx:232-234).
    /// 2. `blobatar`, `blobatar:<seed>`, `blobatar:<seed>:<kind>` → parsed
    ///    per `parseBlobShape` (avatar.tsx:172-182): a pinned `<kind>` maps
    ///    through ``geometricShape(forBlobKind:)``; with no kind, this falls
    ///    back to `defaultShapeFor(name)` exactly like `BotFace` does when
    ///    the blob renderer is unavailable (avatar.tsx:996-997).
    /// 3. One of the seven flat ``Shape`` names → used directly.
    /// 4. Anything else (a platonic solid, an unrecognized string, `nil`) →
    ///    `defaultShapeFor(displayName)`. Phase A does not attempt the
    ///    platonic-solid wireframe treatment; an unmapped legacy pick reads
    ///    as the name-derived shape instead of losing the bot's identity to
    ///    a rendering error.
    public static func appearance(forShape shapeString: String?, color: String?, displayName: String) -> Appearance {
        let resolvedColor: Color = color.flatMap(Color.init(hexOrNil:)) ?? fallbackColor(forName: displayName)

        guard let shapeString, !shapeString.isEmpty else {
            return Appearance(shape: shape(forName: displayName), color: resolvedColor, sigilSeed: nil)
        }

        if shapeString.hasPrefix("sigil-") {
            // JS: `Number(shape.slice(6)) || 0` — accepts any numeric
            // string (including fractional/negative) and NaN/0 fall back to
            // 0. Scarf only ever writes an integer seed here, so `Int(...)`
            // covers every value Scarf itself can produce; a fractional
            // seed written by a future desktop would degrade to 0 instead
            // of matching JS's fractional interpolation into the RNG's seed
            // string — an acceptable gap given Phase A never writes shape
            // strings, only reads them.
            let seed = Int(shapeString.dropFirst("sigil-".count)) ?? 0
            return Appearance(shape: shape(forName: displayName), color: resolvedColor, sigilSeed: seed)
        }

        if shapeString == "blobatar" || shapeString.hasPrefix("blobatar:") {
            let parts = shapeString.split(separator: ":", omittingEmptySubsequences: false)
            let rawKind = parts.count > 2 ? String(parts[2]) : ""
            // Only a member of BLOB_KINDS counts as pinned (parseBlobShape,
            // avatar.tsx:175) — an unrecognized parts[2] is NOT an error,
            // it just means the kind reads as unpinned, same as JS.
            if blobKinds.contains(rawKind) {
                return Appearance(shape: geometricShape(forBlobKind: rawKind), color: resolvedColor, sigilSeed: nil)
            }
            return Appearance(shape: shape(forName: displayName), color: resolvedColor, sigilSeed: nil)
        }

        if let known = Shape(rawValue: shapeString) {
            return Appearance(shape: known, color: resolvedColor, sigilSeed: nil)
        }

        return Appearance(shape: shape(forName: displayName), color: resolvedColor, sigilSeed: nil)
    }
}

extension Color {
    /// Parses a `#RRGGBB` / `#RRGGBBAA` hex string as stored by
    /// `HermesBotIdentity.color`. Returns `nil` for anything else, so a
    /// malformed stored value falls back to the name-derived color instead
    /// of rendering black.
    init?(hexOrNil hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: Double
        if s.count == 8 {
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        } else {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        }
        self.init(red: r, green: g, blue: b, opacity: a)
    }
}
