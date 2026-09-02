import Foundation
import SwiftUI

/// Per-connection cache of avatar bytes and the decoded `Image` made from
/// them, keyed by path + size + mtime (audit A1-M4).
///
/// Two costs it removes, both on paths the user feels:
///
/// 1. **Bytes.** Every roster reload used to re-read every avatar over the
///    transport — and every metadata save ends in a reload, so pinning a bot
///    re-transferred up to 12 × 2MB of images to change one boolean. A hit
///    here transfers nothing.
/// 2. **Decode.** `NSImage(data:)` ran inside `BotAvatarView.body`, i.e. once
///    per row per SwiftUI evaluation. Decoded `Image`s are memoized against
///    the same key.
///
/// ## Not a singleton, on purpose
///
/// Avatar paths are absolute and *not* unique across hosts:
/// `/home/me/.hermes/profiles/ops/assets/avatar.png` names a different picture
/// on every server. A process-wide cache would show one host's avatars on
/// another after a server switch. This is owned by `BotsViewModel`, which is
/// coordinator-cached and therefore rebuilt per server binding — the same
/// reasoning that keeps `BotsViewModel` free of static state.
///
/// ## Why the write path still invalidates
///
/// A remote `stat` reports mtime in whole seconds. Two avatar writes inside
/// one second whose PNGs happen to be the same byte count produce the same
/// key, and the second would render as the first. So `setAvatar` calls
/// ``invalidate(profileName:)`` explicitly; the key is the fast path, not the
/// correctness argument.
@MainActor
public final class BotAvatarCache {

    /// Identity of one cached avatar. `profileName` is part of the key so a
    /// rename (which moves the directory) can never resolve to the old
    /// profile's picture through a coincidentally equal path.
    public struct Key: Hashable, Sendable {
        public let profileName: String
        public let path: String
        public let size: Int64
        public let mtime: Int64

        public init(profileName: String, stat: BotAvatarStat) {
            self.profileName = profileName
            self.path = stat.path
            self.size = stat.size
            self.mtime = stat.mtime
        }
    }

    /// How the bytes become an `Image`. Injectable so tests can count decodes
    /// without a window server.
    private let decoder: @MainActor (Data) -> Image?

    private var bytes: [Key: HermesBotAvatar] = [:]
    private var images: [Key: Image] = [:]

    /// Test instrumentation: how many times `decoder` actually ran.
    public private(set) var decodeCount = 0

    public init(decoder: @escaping @MainActor (Data) -> Image? = BotAvatarCache.platformDecode) {
        self.decoder = decoder
    }

    /// The cached bytes for a key, or nil — the caller then reads them.
    public func avatar(for key: Key) -> HermesBotAvatar? { bytes[key] }

    public func store(_ avatar: HermesBotAvatar, for key: Key) {
        bytes[key] = avatar
    }

    /// The decoded image, decoding at most once per key.
    public func image(for key: Key) -> Image? {
        if let existing = images[key] { return existing }
        guard let data = bytes[key]?.data else { return nil }
        decodeCount += 1
        guard let image = decoder(data) else { return nil }
        images[key] = image
        return image
    }

    /// Drop everything for one profile — every key, whatever its stat.
    ///
    /// Called on the avatar write path. Keyed by profile rather than by path
    /// because a write also *deletes* the stale `avatar.jpg`/`.webp` siblings,
    /// so the entry to evict is not necessarily the one about to be written.
    public func invalidate(profileName: String) {
        bytes = bytes.filter { $0.key.profileName != profileName }
        images = images.filter { $0.key.profileName != profileName }
    }

    public func removeAll() {
        bytes.removeAll()
        images.removeAll()
    }

    public var count: Int { bytes.count }

    public static func platformDecode(_ data: Data) -> Image? {
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
