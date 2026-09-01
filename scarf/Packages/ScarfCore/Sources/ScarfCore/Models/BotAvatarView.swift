import SwiftUI

/// Renders a bot's avatar: the real photo (`assets/avatar.{png,jpg,webp}`,
/// loaded by `BotsService`/``HermesBotAvatar``) when present, else the
/// deterministic ``BotAvatarGenerator`` fallback. Resolution-independent —
/// the fallback is drawn with `Canvas`/`Path`, never rasterized, so it stays
/// crisp at any `size`.
///
/// No roster/list UI here (that's Phase A's B2 work package) — this is just
/// the one view every future roster row, dialog, and tile can render a bot
/// with, mirroring how `BotFace` (avatar.tsx:951) is Hermes Desktop's single
/// avatar entry point.
public struct BotAvatarView: View {
    private let displayName: String
    private let shapeString: String?
    private let colorHex: String?
    private let imageData: Data?
    private let size: CGFloat
    private let cornerStyle: CornerStyle

    /// Squircle-ish rounding vs. a full circle. `BotFace`'s photo path uses
    /// a `22%` corner radius (avatar.tsx:963); the generated-shape path
    /// (`shapeNode`, avatar.tsx:231+) draws each shape's own silhouette, so
    /// Scarf's shape fallback ignores this and always fills its own outline.
    public enum CornerStyle: Sendable, Equatable {
        case circle
        case rounded
    }

    /// - Parameters:
    ///   - displayName: The bot's resolved display name (`resolvedTitle`).
    ///     Drives both the accessibility label and the name-derived
    ///     fallback shape/color/sigil-mirror when nothing is pinned.
    ///   - shapeString: `HermesBotIdentity.shape`, verbatim.
    ///   - colorHex: `HermesBotIdentity.color`, verbatim.
    ///   - imageData: Avatar bytes from ``HermesBotAvatar``, when B0's
    ///     loader found one. `nil` renders the generated fallback.
    ///   - size: Edge length in points (square).
    ///   - cornerStyle: Only affects the photo path; see ``CornerStyle``.
    public init(
        displayName: String,
        shapeString: String?,
        colorHex: String?,
        imageData: Data?,
        size: CGFloat = 36,
        cornerStyle: CornerStyle = .rounded
    ) {
        self.displayName = displayName
        self.shapeString = shapeString
        self.colorHex = colorHex
        self.imageData = imageData
        self.size = size
        self.cornerStyle = cornerStyle
    }

    /// Convenience initializer driven directly by B0's models.
    public init(
        identity: HermesBotIdentity,
        avatar: HermesBotAvatar?,
        size: CGFloat = 36,
        cornerStyle: CornerStyle = .rounded
    ) {
        self.init(
            displayName: identity.resolvedTitle,
            shapeString: identity.shape,
            colorHex: identity.color,
            imageData: avatar?.data,
            size: size,
            cornerStyle: cornerStyle
        )
    }

    public var body: some View {
        Group {
            if let imageData, let platformImage = Self.image(from: imageData) {
                platformImage
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(clipShape)
            } else {
                GeneratedFallback(displayName: displayName, shapeString: shapeString, colorHex: colorHex, size: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(displayName)
        .accessibilityAddTraits(.isImage)
    }

    private var clipShape: AnyShape {
        switch cornerStyle {
        case .circle:
            return AnyShape(Circle())
        case .rounded:
            // 22% matches BotFace's photo path (avatar.tsx:963).
            return AnyShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        }
    }

    private static func image(from data: Data) -> Image? {
        #if canImport(AppKit)
        guard let nsImage = NSImage(data: data) else { return nil }
        return Image(nsImage: nsImage)
        #elseif canImport(UIKit)
        guard let uiImage = UIImage(data: data) else { return nil }
        return Image(uiImage: uiImage)
        #else
        return nil
        #endif
    }
}

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Type-erased `Shape` so ``BotAvatarView/clipShape`` can return either
/// `Circle` or `RoundedRectangle` from one `@ViewBuilder` property.
private struct AnyShape: Shape {
    private let makePath: @Sendable (CGRect) -> Path
    init<S: Shape>(_ shape: S) { makePath = { rect in shape.path(in: rect) } }
    func path(in rect: CGRect) -> Path { makePath(rect) }
}

/// The generated fallback: fills ``BotAvatarGenerator/Appearance``'s shape
/// (or draws the sigil geometry) in the resolved color, scaled from the
/// 40×40 box the ported Hermes math uses to `size`.
private struct GeneratedFallback: View {
    let displayName: String
    let shapeString: String?
    let colorHex: String?
    let size: CGFloat

    private var appearance: BotAvatarGenerator.Appearance {
        BotAvatarGenerator.appearance(forShape: shapeString, color: colorHex, displayName: displayName)
    }

    var body: some View {
        let appearance = appearance
        Canvas { context, canvasSize in
            let scale = canvasSize.width / 40
            context.scaleBy(x: scale, y: scale)

            if let seed = appearance.sigilSeed {
                drawSigil(in: &context, seed: seed, color: appearance.color)
            } else {
                drawShape(appearance.shape, in: &context, color: appearance.color)
            }
        }
        .background(appearance.color.opacity(appearance.sigilSeed != nil ? 0.12 : 0))
    }

    private func drawShape(_ shape: BotAvatarGenerator.Shape, in context: inout GraphicsContext, color: Color) {
        let path = Self.path(for: shape)
        context.fill(path, with: .color(color))
    }

    private func drawSigil(in context: inout GraphicsContext, seed: Int, color: Color) {
        let geometry = BotAvatarGenerator.sigilGeometry(name: displayName, seed: seed)

        if geometry.hasRing, geometry.ringCorners.count == 4 {
            var ring = Path()
            let pts = geometry.ringCorners
            ring.move(to: CGPoint(x: pts[0].x, y: pts[0].y))
            for p in pts.dropFirst() { ring.addLine(to: CGPoint(x: p.x, y: p.y)) }
            ring.closeSubpath()
            context.stroke(ring, with: .color(color.opacity(0.5)), lineWidth: 1.2)
        }

        var strokes = Path()
        for stroke in geometry.strokes {
            strokes.move(to: CGPoint(x: stroke.x1, y: stroke.y1))
            strokes.addLine(to: CGPoint(x: stroke.x2, y: stroke.y2))
        }
        context.stroke(strokes, with: .color(color), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
    }

    /// Silhouettes for the seven flat shapes, geometry lifted from
    /// `shapeNode`'s legacy-shape cases (avatar.tsx:334-353) — same 40×40
    /// box, same control points, ported to `Path` instead of an SVG string.
    private static func path(for shape: BotAvatarGenerator.Shape) -> Path {
        var path = Path()
        switch shape {
        case .circle:
            path.addEllipse(in: CGRect(x: 2.5, y: 2.5, width: 35, height: 35))
        case .squircle:
            path.addRoundedRect(in: CGRect(x: 3, y: 3, width: 34, height: 34), cornerSize: CGSize(width: 11, height: 11))
        case .pill:
            path.addRoundedRect(in: CGRect(x: 2, y: 7, width: 36, height: 26), cornerSize: CGSize(width: 13, height: 13))
        case .triangle:
            path.move(to: CGPoint(x: 20, y: 5.5))
            path.addLine(to: CGPoint(x: 36, y: 33.5))
            path.addLine(to: CGPoint(x: 4, y: 33.5))
            path.closeSubpath()
        case .hexagon:
            path.move(to: CGPoint(x: 20, y: 3.5))
            path.addLine(to: CGPoint(x: 34.5, y: 11.75))
            path.addLine(to: CGPoint(x: 34.5, y: 28.25))
            path.addLine(to: CGPoint(x: 20, y: 36.5))
            path.addLine(to: CGPoint(x: 5.5, y: 28.25))
            path.addLine(to: CGPoint(x: 5.5, y: 11.75))
            path.closeSubpath()
        case .cloud:
            path.move(to: CGPoint(x: 11, y: 32))
            path.addRelativeArc(center: CGPoint(x: 11, y: 24.5), radius: 7.5, startAngle: .degrees(90), delta: .degrees(-118))
            path.addRelativeArc(center: CGPoint(x: 19.5, y: 12.5), radius: 9.5, startAngle: .degrees(208), delta: .degrees(-142))
            path.addRelativeArc(center: CGPoint(x: 23, y: 25), radius: 7, startAngle: .degrees(246), delta: .degrees(-120))
            path.closeSubpath()
        case .drop:
            path.move(to: CGPoint(x: 20, y: 3))
            path.addCurve(to: CGPoint(x: 6, y: 27), control1: CGPoint(x: 20, y: 3), control2: CGPoint(x: 6, y: 20))
            path.addRelativeArc(center: CGPoint(x: 20, y: 27), radius: 14, startAngle: .degrees(180), delta: .degrees(180))
            path.addCurve(to: CGPoint(x: 20, y: 3), control1: CGPoint(x: 34, y: 20), control2: CGPoint(x: 20, y: 3))
            path.closeSubpath()
        }
        return path
    }
}
