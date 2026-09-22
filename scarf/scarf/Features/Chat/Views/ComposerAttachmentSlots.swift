import Foundation
import ScarfCore

/// The chat composer's image-attachment cap, held ACROSS the async
/// encode window.
///
/// The bug this exists for: the composer checked `attachments.count`
/// against the cap, then handed the bytes to an asynchronous encode that
/// appended on completion. Two quick drops (or a drop plus a paste, or a
/// multi-file drop landing while an earlier one was still encoding) both
/// passed the check against the same pre-encode count, and the composer
/// ended up with more attachments than the cap allows — which Hermes'
/// vision aux model is not sized for.
///
/// So a slot is RESERVED synchronously, at the instant a drop or paste is
/// accepted, and released when that item's encode lands (`commit`) or
/// fails (`release`). `free` is therefore the truth about what the NEXT
/// drop may take, whatever is still in flight.
///
/// Main-actor isolated because it is the composer's view state; the
/// encode itself runs off-main and only its RESULT comes back here.
@MainActor
@Observable
final class ComposerAttachmentSlots {

    /// Hard cap matching what Hermes' vision aux model swallows
    /// comfortably in one prompt. Going higher costs tokens without a
    /// quality gain.
    nonisolated static let defaultCapacity = 5

    let capacity: Int

    /// Encoded attachments, in the order they landed.
    private(set) var attachments: [ChatImageAttachment] = []

    /// Slots handed out to in-flight encodes that have not yet landed.
    private(set) var reserved: Int = 0

    init(capacity: Int = ComposerAttachmentSlots.defaultCapacity) {
        self.capacity = capacity
    }

    /// Attached plus in-flight — what the cap is measured against.
    var used: Int { attachments.count + reserved }

    /// How many more items may be accepted right now.
    var free: Int { max(0, capacity - used) }

    var isFull: Bool { free == 0 }

    /// True while at least one encode is in flight. Drives the composer's
    /// "your drop landed" spinner.
    var isEncoding: Bool { reserved > 0 }

    /// Take up to `requested` slots and return how many were granted —
    /// zero when the composer is already at the cap. The caller must
    /// follow every granted slot with exactly one `commit` or `release`.
    @discardableResult
    func reserve(upTo requested: Int) -> Int {
        let granted = min(max(0, requested), free)
        reserved += granted
        return granted
    }

    /// An encode landed: its reservation becomes a real attachment.
    func commit(_ attachment: ChatImageAttachment) {
        release()
        attachments.append(attachment)
    }

    /// An encode failed, or the dropped item carried nothing usable —
    /// hand the slot back so the next drop can have it.
    func release() {
        reserved = max(0, reserved - 1)
    }

    /// The user removed an attachment chip.
    func remove(id: ChatImageAttachment.ID) {
        attachments.removeAll { $0.id == id }
    }

    /// Hand the attachments to a send and clear them. In-flight
    /// reservations are deliberately left alone: an encode still running
    /// belongs to the NEXT message, and its `commit` lands there.
    func drain() -> [ChatImageAttachment] {
        let taken = attachments
        attachments.removeAll()
        return taken
    }
}
