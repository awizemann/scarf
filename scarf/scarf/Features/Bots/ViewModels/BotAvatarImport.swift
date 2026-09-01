import AppKit
import Foundation
import ScarfCore

/// Turns a user-chosen image file into PNG bytes that fit Hermes' avatar
/// ceiling.
///
/// The gateway's `set_asset` rejects anything over 2MB outright (error 4069),
/// and an avatar is rendered at roster/detail sizes — so "your picture is too
/// big" is a bad answer when downscaling is both lossless-enough and
/// automatic. The importer therefore re-encodes to PNG at progressively
/// smaller edge lengths until the bytes fit, and only gives up when even the
/// smallest step is over the cap (which a real photograph never is).
enum BotAvatarImport {

    /// Edge lengths tried in order. 512 is already generous for a 96pt detail
    /// avatar on a 2x display; the smaller steps exist so a pathological
    /// input (a huge PNG of noise, which barely compresses) still converges.
    static let edgeSteps: [CGFloat] = [512, 384, 256, 192, 128]

    enum Failure: Error, Equatable {
        /// The file isn't an image AppKit can decode.
        case unreadable
        /// Re-encoding failed at every step — see ``edgeSteps``.
        case cannotFit
    }

    /// Load, downscale if needed, and return PNG bytes under the cap.
    static func pngData(fromFileAt url: URL) throws -> Data {
        guard let image = NSImage(contentsOf: url) else { throw Failure.unreadable }
        return try pngData(from: image)
    }

    /// The testable half: no filesystem, just image → bounded PNG bytes.
    static func pngData(from image: NSImage) throws -> Data {
        // An image that already fits at its natural size is re-encoded once
        // rather than passed through: the source may be a JPEG or a WebP, and
        // the canonical asset Scarf writes is always `avatar.png`.
        for edge in edgeSteps {
            guard let data = encodePNG(image, maxEdge: edge) else { continue }
            if data.count <= HermesBotAvatar.maxBytes { return data }
        }
        throw Failure.cannotFit
    }

    /// Render `image` into a square-bounded bitmap whose longest edge is at
    /// most `maxEdge` (never upscaling), and encode it as PNG.
    private static func encodePNG(_ image: NSImage, maxEdge: CGFloat) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxEdge / max(size.width, size.height))
        let target = NSSize(
            width: max(1, (size.width * scale).rounded()),
            height: max(1, (size.height * scale).rounded())
        )
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(target.width),
            pixelsHigh: Int(target.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = target

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: target),
            from: NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction: 1
        )
        ctx.flushGraphics()
        return rep.representation(using: .png, properties: [:])
    }
}
