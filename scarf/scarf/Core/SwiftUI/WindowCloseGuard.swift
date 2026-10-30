import AppKit
import ObjectiveC
import SwiftUI

/// Asks before a window with working chats closes (parallel chats P2).
///
/// AppKit has one place to refuse a close, the window delegate's
/// `windowShouldClose`, and SwiftUI's `AppKitWindowController` is that
/// delegate. So this proxy takes the slot and passes everything through:
/// `responds(to:)` and `forwardingTarget(for:)` hand every selector it doesn't
/// implement to SwiftUI's delegate, and a close nobody objects to still asks
/// SwiftUI's `windowShouldClose`, once. ⌘W and File ▸ Close (`performClose:`),
/// the close button (`_close:`) and Close All (`closeAll:`) all arrive here;
/// checked against a real `WindowGroup` window.
@MainActor
final class WindowCloseDelegateProxy: NSObject, NSWindowDelegate {
    /// SwiftUI's delegate. Weak: the window's controller owns it, and it may
    /// own the window, which owns this proxy.
    private weak var inner: NSWindowDelegate?

    /// What the current root would ask, nil for nothing. Each root (a profile
    /// switch builds a new one in the same window) takes this over.
    var prompt: (() -> ChatClosePolicy.Prompt?)?
    /// Who set `prompt`, so an old root going away after its successor
    /// arrived leaves the successor's in place.
    private(set) weak var owner: AnyObject?

    /// The confirm. `decide(true)`: the user chose to close.
    var present: (NSWindow, ChatClosePolicy.Prompt, @escaping (Bool) -> Void) -> Void = { window, prompt, decide in
        let alert = ChatClosePolicy.alert(for: prompt, confirmTitle: String(localized: "Close Anyway"))
        alert.beginSheetModal(for: window) { response in
            // The sheet is still attached while this runs, and a window with
            // a sheet refuses `performClose`.
            DispatchQueue.main.async { decide(response == ChatClosePolicy.confirmResponse) }
        }
    }

    /// Whether Scarf is quitting with the user's agreement: that confirm has
    /// spoken for every window. Set by `AppQuitGuard`.
    var isQuitApproved: () -> Bool = { AppQuitGuard.shared.isApproved }

    /// The user said Close Anyway: the close that follows doesn't ask again.
    private var closeConfirmed = false
    /// A confirm is up: a second ⌘W doesn't stack another.
    private var isAsking = false

    private init(wrapping inner: NSWindowDelegate?) {
        self.inner = inner
    }

    private static var associationKey: UInt8 = 0

    /// The window's proxy, installed on first use. A delegate that SwiftUI
    /// set again since is wrapped anew.
    static func install(on window: NSWindow) -> WindowCloseDelegateProxy {
        let existing = objc_getAssociatedObject(window, &associationKey) as? WindowCloseDelegateProxy
        if let existing, window.delegate === existing { return existing }
        let proxy = existing ?? WindowCloseDelegateProxy(wrapping: window.delegate)
        proxy.inner = window.delegate
        // The window holds its delegate weakly; the proxy lives as long as
        // the window does.
        objc_setAssociatedObject(window, &associationKey, proxy, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        window.delegate = proxy
        return proxy
    }

    func setPrompt(owner: AnyObject, _ prompt: @escaping () -> ChatClosePolicy.Prompt?) {
        self.owner = owner
        self.prompt = prompt
    }

    func clearPrompt(owner: AnyObject) {
        guard self.owner === owner else { return }
        self.owner = nil
        prompt = nil
    }

    // MARK: - Forwarding

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || inner?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if let inner, inner.responds(to: selector) { return inner }
        return super.forwardingTarget(for: selector)
    }

    // MARK: - The close

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Ours first: SwiftUI's delegate hears only of a close that goes on.
        let confirmed = closeConfirmed
        closeConfirmed = false
        if !confirmed, !isQuitApproved(), let prompt = prompt?() {
            ask(prompt, about: sender)
            return false
        }
        return inner?.windowShouldClose?(sender) ?? true
    }

    private func ask(_ prompt: ChatClosePolicy.Prompt, about window: NSWindow) {
        guard !isAsking else { return }
        isAsking = true
        present(window, prompt) { [weak self, weak window] confirmed in
            guard let self else { return }
            self.isAsking = false
            guard confirmed, let window else { return }
            self.closeConfirmed = true
            window.performClose(nil)
            // A refused close (a sheet attached) never reached
            // `windowShouldClose`: the next one asks again.
            self.closeConfirmed = false
        }
    }
}

/// Finds its window and points the window's close proxy at `prompt`.
private struct WindowCloseGuard: NSViewRepresentable {
    let prompt: () -> ChatClosePolicy.Prompt?

    final class Coordinator {
        weak var proxy: WindowCloseDelegateProxy?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        let prompt = prompt
        // The hosting window isn't attached on the first pass.
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            let proxy = WindowCloseDelegateProxy.install(on: window)
            proxy.setPrompt(owner: coordinator, prompt)
            coordinator.proxy = proxy
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.proxy?.clearPrompt(owner: coordinator)
    }
}

extension View {
    /// Ask before this view's window closes, when `prompt` has something to
    /// ask. See `WindowCloseDelegateProxy`.
    func confirmsWindowClose(_ prompt: @escaping () -> ChatClosePolicy.Prompt?) -> some View {
        background(WindowCloseGuard(prompt: prompt))
    }
}
