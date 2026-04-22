import AppKit
import SwiftUI

/// Makes the enclosing `NSSplitView` remember its divider positions across
/// app launches. `NavigationSplitView` is backed by `NSSplitViewController`,
/// whose split view honours `autosaveName` — AppKit writes the divider
/// offsets to `UserDefaults` on drag and restores them on the next launch.
///
/// Usage: attach `.splitViewAutosaveName("…")` to a child of the split view
/// (the sidebar is a good choice). The modifier installs an invisible helper
/// that walks up the view hierarchy on first layout, finds the `NSSplitView`,
/// and assigns its autosave name. Subsequent launches restore the divider
/// positions before the window appears.
///
/// The name is also used to key the entry in `UserDefaults` (AppKit stores
/// it as `NSSplitView Subview Frames <name>`), so changing the name resets
/// the remembered width. Pick a stable string and leave it alone.
struct SplitViewAutosaveFinder: NSViewRepresentable {
    let autosaveName: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // Defer the hierarchy walk until after SwiftUI has attached this
        // view to its host window — at makeNSView time the view has no
        // superview yet, so we can't find the split view above us.
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            SplitViewAutosaveFinder.apply(autosaveName, startingFrom: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private static func apply(_ name: String, startingFrom view: NSView) {
        var current: NSView? = view
        while let node = current {
            if let split = node as? NSSplitView {
                // Only set once — reassigning clobbers AppKit's restore path.
                if split.autosaveName != NSSplitView.AutosaveName(name) {
                    split.autosaveName = NSSplitView.AutosaveName(name)
                }
                return
            }
            current = node.superview
        }
    }
}

extension View {
    /// Persist the enclosing `NavigationSplitView` / `NSSplitView` divider
    /// positions to `UserDefaults` under `autosaveName`. Attach to any child
    /// of the split view (the sidebar works well).
    func splitViewAutosaveName(_ autosaveName: String) -> some View {
        background(SplitViewAutosaveFinder(autosaveName: autosaveName))
    }
}
