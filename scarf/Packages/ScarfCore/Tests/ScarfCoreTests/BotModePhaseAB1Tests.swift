import Testing
import Foundation
import SwiftUI
@testable import ScarfCore

/// B1 of the Bot Mode Phase A cycle — `BotAvatarGenerator`'s deterministic
/// fallback (name → shape, name → sigil geometry, name/seed → PRNG stream).
///
/// The PRNG and `defaultShapeFor` vectors below are pinned against a literal
/// re-implementation of `sigilRng`/`defaultShapeFor`/`sigilGeometry`
/// (`apps/desktop/src/plugins/hermes-bots/avatar.tsx:29-115`, audited tag
/// v2026.8.31 / Hermes 0.21.0) run under real Node, not hand arithmetic —
/// see the values' provenance note on each test. Any future edit to
/// `BotAvatarGenerator`'s integer semantics that drifts from JS's `>>> 0` /
/// `Math.imul` truncation would change these numbers.
@Suite struct BotModePhaseAB1Tests {

    // MARK: - defaultShapeFor determinism + JS-pinned vectors

    @Test func sameNameProducesSameShapeAcrossCalls() {
        let a = BotAvatarGenerator.shape(forName: "Athena")
        let b = BotAvatarGenerator.shape(forName: "Athena")
        #expect(a == b)
    }

    @Test func distinctNamesProduceDistinctShapesSpotSet() {
        // Not a mathematical guarantee (7 buckets, pigeonhole applies
        // eventually) — just confirms the hash isn't degenerate (e.g.
        // collapsing every name to the same bucket).
        let names = ["agent", "Scout", "my-bot-42", "Athena", "Curator", "Watchdog", "Sable"]
        let shapes = Set(names.map { BotAvatarGenerator.shape(forName: $0) })
        #expect(shapes.count > 1)
    }

    /// Pinned against `node`: `hash = (hash*31 + ch.charCodeAt(0)) >>> 0` per
    /// `for...of` code-point step, then `AVATAR_SHAPES[hash % 7]` with
    /// `AVATAR_SHAPES = ['circle','squircle','pill','triangle','hexagon','cloud','drop']`.
    @Test func defaultShapeForMatchesJSVectors() {
        #expect(BotAvatarGenerator.shape(forName: "agent") == .pill)
        #expect(BotAvatarGenerator.shape(forName: "Scout") == .cloud)
        #expect(BotAvatarGenerator.shape(forName: "my-bot-42") == .triangle)
        // Astral-plane character (🤖 U+1F916): exercises the surrogate-pair
        // charCodeAt(0)-is-the-high-surrogate edge case.
        #expect(BotAvatarGenerator.shape(forName: "🤖bot") == .drop)
    }

    // MARK: - sigilRng determinism + JS-pinned vectors

    @Test func sameSeedProducesSamePRNGStreamAcrossCalls() {
        let rngA = BotAvatarGenerator.sigilRNG("Athena::0")
        let rngB = BotAvatarGenerator.sigilRNG("Athena::0")
        let seqA = (0..<5).map { _ in rngA() }
        let seqB = (0..<5).map { _ in rngB() }
        #expect(seqA == seqB)
    }

    @Test func distinctSeedsProduceDistinctPRNGStreams() {
        let rngA = BotAvatarGenerator.sigilRNG("Athena::0")
        let rngB = BotAvatarGenerator.sigilRNG("Athena::1")
        #expect(rngA() != rngB())
    }

    /// Pinned against `node` (`sigilRng("agent::0")`, `sigilRng("Scout::0")`,
    /// `sigilRng("my-bot-42::0")`, `sigilRng("🤖bot::0")`), first 4 draws.
    /// Tolerance is exact — both sides are float64, and the underlying state
    /// is 32-bit integer arithmetic with no rounding.
    @Test func sigilRNGMatchesJSVectors() {
        let agent = BotAvatarGenerator.sigilRNG("agent::0")
        #expect(agent() == 0.8524834462441504)
        #expect(agent() == 0.48937184223905206)
        #expect(agent() == 0.8707650396972895)
        #expect(agent() == 0.6002290805336088)

        let scout = BotAvatarGenerator.sigilRNG("Scout::0")
        #expect(scout() == 0.020272824447602034)
        #expect(scout() == 0.836593824904412)
        #expect(scout() == 0.4924558138009161)
        #expect(scout() == 0.8463463929947466)

        let myBot = BotAvatarGenerator.sigilRNG("my-bot-42::0")
        #expect(myBot() == 0.7469162761699408)
        #expect(myBot() == 0.483204607386142)
        #expect(myBot() == 0.3283941918052733)
        #expect(myBot() == 0.4512074454687536)

        // Astral-plane seed text: same surrogate-pair edge case as above,
        // now flowing through the FNV-1a hash instead of the *31 hash.
        let emoji = BotAvatarGenerator.sigilRNG("🤖bot::0")
        #expect(emoji() == 0.3060082506854087)
        #expect(emoji() == 0.43472728272899985)
        #expect(emoji() == 0.9107941302936524)
        #expect(emoji() == 0.7609019172377884)
    }

    // MARK: - sigilGeometry determinism + JS-pinned vectors

    @Test func sameNameAndSeedProducesSameGeometryAcrossCalls() {
        let a = BotAvatarGenerator.sigilGeometry(name: "Athena", seed: 3)
        let b = BotAvatarGenerator.sigilGeometry(name: "Athena", seed: 3)
        #expect(a == b)
    }

    @Test func distinctSeedsProduceDistinctGeometry() {
        let a = BotAvatarGenerator.sigilGeometry(name: "Athena", seed: 0)
        let b = BotAvatarGenerator.sigilGeometry(name: "Athena", seed: 1)
        #expect(a != b)
    }

    /// Pinned against `node`'s `sigilGeometry("agent", 0)`: 6 body segments
    /// (`4 + floor(rng()*3)`), no ring. Spot-checks segment count, the first
    /// stroke pair (main + mirror), the trailing spine stroke every variant
    /// gets, and the ring flag.
    @Test func sigilGeometryMatchesJSVectorAgentSeed0() {
        let g = BotAvatarGenerator.sigilGeometry(name: "agent", seed: 0)

        #expect(g.hasRing == false)
        #expect(g.ringCorners.isEmpty)

        // 6 segments: 2 strokes each (main+mirror) plus a tie whenever
        // rng() > 0.6 rolled true, plus 1 trailing spine stroke.
        // JS trace: 14 total strokes for this seed.
        #expect(g.strokes.count == 14)

        #expect(g.strokes[0] == BotAvatarGenerator.SigilStroke(x1: 13, y1: 32, x2: 20, y2: 32))
        #expect(g.strokes[1] == BotAvatarGenerator.SigilStroke(x1: 27, y1: 32, x2: 20, y2: 32))

        // The spine is always the second-to-last stroke (before the ring
        // flag is rolled), from (20, gy(0)) to (20, gy(4)) = (20,8)-(20,32).
        #expect(g.strokes.last == BotAvatarGenerator.SigilStroke(x1: 20, y1: 8, x2: 20, y2: 32))
    }

    /// Pinned against `node`'s `sigilGeometry("Scout", 3)`: 5 body segments,
    /// ring present (rng() > 0.45 rolled true).
    @Test func sigilGeometryMatchesJSVectorScoutSeed3() {
        let g = BotAvatarGenerator.sigilGeometry(name: "Scout", seed: 3)

        #expect(g.hasRing == true)
        #expect(g.ringCorners.map(\.x) == [20, 36, 20, 4])
        #expect(g.ringCorners.map(\.y) == [4, 20, 36, 20])

        #expect(g.strokes.count == 12)
        #expect(g.strokes[0] == BotAvatarGenerator.SigilStroke(x1: 20, y1: 8, x2: 20, y2: 14))
        #expect(g.strokes.last == BotAvatarGenerator.SigilStroke(x1: 20, y1: 8, x2: 20, y2: 32))
    }

    // MARK: - Blobatar shape-string mapping (non-portable, documented decision)

    @Test func pinnedBlobKindMapsToDocumentedGeometricShape() {
        #expect(BotAvatarGenerator.geometricShape(forBlobKind: "round") == .circle)
        #expect(BotAvatarGenerator.geometricShape(forBlobKind: "organic") == .drop)
        #expect(BotAvatarGenerator.geometricShape(forBlobKind: "boxy") == .squircle)
        #expect(BotAvatarGenerator.geometricShape(forBlobKind: "capsule") == .pill)
        #expect(BotAvatarGenerator.geometricShape(forBlobKind: "cloud") == .cloud)
        #expect(BotAvatarGenerator.geometricShape(forBlobKind: "droplet") == .drop)
        #expect(BotAvatarGenerator.geometricShape(forBlobKind: "hexagon") == .hexagon)
        #expect(BotAvatarGenerator.geometricShape(forBlobKind: "sun") == .triangle)
        #expect(BotAvatarGenerator.geometricShape(forBlobKind: "triangle") == .triangle)
    }

    @Test func pinnedBlobShapeStringUsesKindMapping() {
        let appearance = BotAvatarGenerator.appearance(
            forShape: "blobatar:abc123:hexagon", color: nil, displayName: "Athena"
        )
        #expect(appearance.shape == .hexagon)
        #expect(appearance.sigilSeed == nil)
    }

    @Test func unrecognizedBlobKindFallsBackToNameDerivedShapeLikeParseBlobShapeDoes() {
        // parseBlobShape (avatar.tsx:175) only treats parts[2] as pinned
        // when it's a member of BLOB_KINDS; an unrecognized segment (typo,
        // future kind Scarf doesn't know) must NOT collapse to a fixed
        // shape — it degrades to the name-derived default, same as no kind
        // at all.
        let appearance = BotAvatarGenerator.appearance(
            forShape: "blobatar:abc123:not-a-real-kind", color: nil, displayName: "agent"
        )
        #expect(appearance.shape == .pill)
    }

    @Test func bareBlobatarFallsBackToNameDerivedShapeLikeBotFaceDoes() {
        // Mirrors avatar.tsx:996-997 — no blob renderer means the legacy
        // math face, i.e. defaultShapeFor(name).
        let appearance = BotAvatarGenerator.appearance(forShape: "blobatar", color: nil, displayName: "agent")
        #expect(appearance.shape == .pill)
    }

    // MARK: - appearance(forShape:color:displayName:) precedence

    @Test func explicitShapeStringWinsOverNameDerivedDefault() {
        let appearance = BotAvatarGenerator.appearance(forShape: "hexagon", color: nil, displayName: "agent")
        // "agent" alone would derive .pill (see defaultShapeForMatchesJSVectors).
        #expect(appearance.shape == .hexagon)
    }

    @Test func sigilShapeStringSetsSigilSeed() {
        let appearance = BotAvatarGenerator.appearance(forShape: "sigil-7", color: nil, displayName: "agent")
        #expect(appearance.sigilSeed == 7)
    }

    @Test func nilShapeStringFallsBackToNameDerivedShape() {
        let appearance = BotAvatarGenerator.appearance(forShape: nil, color: nil, displayName: "Scout")
        #expect(appearance.shape == .cloud)
        #expect(appearance.sigilSeed == nil)
    }

    @Test func unrecognizedShapeStringFallsBackToNameDerivedShape() {
        // e.g. a platonic solid ("cube") — not modeled, falls back rather
        // than crashing or rendering nothing.
        let appearance = BotAvatarGenerator.appearance(forShape: "cube", color: nil, displayName: "agent")
        #expect(appearance.shape == .pill)
    }

    // MARK: - Color

    @Test func explicitColorHexWinsOverFallback() {
        let appearance = BotAvatarGenerator.appearance(forShape: nil, color: "#336699", displayName: "agent")
        #expect(appearance.color == Color(hexOrNil: "#336699"))
    }

    @Test func malformedColorHexFallsBackToNameDerivedColor() {
        let withMalformed = BotAvatarGenerator.appearance(forShape: nil, color: "not-a-color", displayName: "agent")
        let withNil = BotAvatarGenerator.appearance(forShape: nil, color: nil, displayName: "agent")
        #expect(withMalformed.color == withNil.color)
    }

    @Test func sameNameProducesSameFallbackColorAcrossCalls() {
        let a = BotAvatarGenerator.fallbackColor(forName: "Athena")
        let b = BotAvatarGenerator.fallbackColor(forName: "Athena")
        #expect(a == b)
    }
}
