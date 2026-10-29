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

    /// Bumped by `reset()`. An encode reserved under an older generation
    /// belongs to a draft that was thrown away (the chat moved to another
    /// conversation): its `commit` / `release` is ignored, so the image
    /// can't land in the next conversation's composer.
    private(set) var generation = 0

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
    /// `generation`: the one current when the slot was reserved (nil: now).
    func commit(_ attachment: ChatImageAttachment, generation: Int? = nil) {
        guard isCurrent(generation) else { return }
        release()
        attachments.append(attachment)
    }

    /// An encode failed, or the dropped item carried nothing usable —
    /// hand the slot back so the next drop can have it.
    func release(generation: Int? = nil) {
        guard isCurrent(generation) else { return }
        reserved = max(0, reserved - 1)
    }

    /// Throw everything away, in-flight encodes included: they land
    /// nowhere (`generation`).
    func reset() {
        attachments.removeAll()
        reserved = 0
        generation &+= 1
    }

    private func isCurrent(_ reservedUnder: Int?) -> Bool {
        reservedUnder.map { $0 == generation } ?? true
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

    /// Put back attachments a send never delivered (`ChatSession`'s
    /// unsent-message restore), ahead of anything attached since, up to the
    /// cap. Returns how many didn't fit.
    @discardableResult
    func restore(_ unsent: [ChatImageAttachment]) -> Int {
        let fitting = Array(unsent.prefix(free))
        attachments.insert(contentsOf: fitting, at: 0)
        return unsent.count - fitting.count
    }
}

/// One chat's unsent composer state — the typed text and the attachment
/// slots (parallel chats P1). Owned by `ChatSession`, not the composer view,
/// so a draft survives moving to another chat and back, and a chat the
/// budget released keeps it. The composer binds to the focused chat's.
@MainActor
@Observable
final class ComposerDraft {
    var text = ""
    let slots: ComposerAttachmentSlots

    init(capacity: Int = ComposerAttachmentSlots.defaultCapacity) {
        slots = ComposerAttachmentSlots(capacity: capacity)
    }

    /// Something typed or attached that hasn't been sent.
    var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !slots.attachments.isEmpty
    }

    /// Forget the draft (a session boundary: the chat is reused for
    /// another conversation). Encodes still in flight are dropped when they
    /// land, so an image can't follow into the other conversation.
    func clear() {
        text = ""
        slots.reset()
    }

    /// Put back a message that was never sent: its text above anything
    /// typed since, its images ahead of anything attached since.
    func restoreUnsent(text unsent: String, images: [ChatImageAttachment]) {
        let current = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = current.isEmpty ? unsent : unsent + "\n\n" + text
        slots.restore(images)
    }
}
