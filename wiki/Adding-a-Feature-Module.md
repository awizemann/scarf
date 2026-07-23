---
title: Adding-a-Feature-Module
type: note
permalink: scarf-wiki/adding-a-feature-module
created: 2026-05-29
updated: 2026-05-29
---

# Adding a Feature Module

The MVVM-F recipe. Adding a Mac feature touches 4 existing files and creates 2 new ones; iOS additions are simpler since each tab is its own module.

> **Should the ViewModel live in ScarfCore or the Mac/iOS target?** Per [ScarfCore Package](ScarfCore-Package): if the VM does I/O against Hermes (transport reads, parsing, attribution lookups, formatting), it belongs in [`Packages/ScarfCore/Sources/ScarfCore/ViewModels/`](https://github.com/awizemann/scarf/tree/main/scarf/Packages/ScarfCore/Sources/ScarfCore/ViewModels) so iOS can reuse it. If the VM owns Mac- or iOS-specific UI state (toolbar items, keyboard shortcut bindings), keep it in the target.

## Directory shape (Mac)

```
scarf/scarf/scarf/Features/MyFeature/
  Views/
    MyFeatureView.swift
  ViewModels/
    MyFeatureViewModel.swift           ← target-local, only if Mac-specific UI state
```

Both subdirectories are conventional — even features that only have one view of each follow this shape so file discovery is consistent.

If the ViewModel is shared, the Mac feature module only contains the View(s) and reaches into `ScarfCore.MyFeatureViewModel`.

## Directory shape (iOS)

```
scarf/Scarf iOS/MyFeature/
  MyFeatureView.swift
  MyFeatureView+Components.swift  (optional split for compositional sub-views)
```

iOS feature modules are flatter — no Views/ViewModels/ subdirectories. Each tab in [`ScarfGoTabRoot`](https://github.com/awizemann/scarf/blob/main/scarf/Scarf%20iOS/App/ScarfGoTabRoot.swift) wires the feature view directly. Adding a *primary* tab is rare in v2.5; secondary screens just push onto the parent tab's `NavigationStack`.

## Step 1: Create the ViewModel

```swift
import Observation

@Observable
final class MyFeatureViewModel {
    let context: ServerContext
    private let fileService: HermesFileService

    init(context: ServerContext) {
        self.context = context
        self.fileService = HermesFileService(context: context)
    }

    var items: [MyModel] = []
    var loadError: String?

    func load() async {
        do {
            items = try await fetchItems()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}
```

Conventions:

- Always take `ServerContext` in `init` so the feature works against any window's bound server.
- Construct any services inside `init`; don't hand them in.
- Use `@Observable` (Swift macro), not `ObservableObject`.
- Public state is `var` properties; mutate them on `MainActor`. Async work runs `nonisolated` and assigns the final value back on the main actor.

## Step 2: Create the View

```swift
struct MyFeatureView: View {
    @State private var viewModel: MyFeatureViewModel
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(HermesFileWatcher.self) private var fileWatcher

    init(context: ServerContext) {
        _viewModel = State(initialValue: MyFeatureViewModel(context: context))
    }

    var body: some View {
        List(viewModel.items) { item in /* … */ }
            .navigationTitle("My Feature")
            .task { await viewModel.load() }
            .task(id: fileWatcher.lastChangeDate) {
                // Re-load when ~/.hermes/ changes
                await viewModel.load()
            }
    }
}
```

Conventions:

- View takes `ServerContext` in its `init`; it's the only initializer parameter.
- `@State private var viewModel: MyFeatureViewModel` — `@State` is the right wrapper for `@Observable` classes inside views.
- Read coordinator and watcher from `@Environment`.
- Use `.task(id:)` for reactive reloads — make sure you include every dependency in the id, or changes to a missing one won't trigger reload.

## Step 3: Add the SidebarSection case

In [`Navigation/AppCoordinator.swift`](https://github.com/awizemann/scarf/blob/main/scarf/scarf/Navigation/AppCoordinator.swift):

```swift
enum SidebarSection: String, CaseIterable, Identifiable {
    // … existing cases …
    case myFeature = "My Feature"

    var icon: String {
        switch self {
        // … existing icons …
        case .myFeature: return "star.fill"   // pick an SF Symbol
        }
    }
}
```

## Step 4: Register in SidebarView

In [`Navigation/SidebarView.swift`](https://github.com/awizemann/scarf/blob/main/scarf/scarf/Navigation/SidebarView.swift), add the case to the right `Section` array. The current shape uses a `[Section]` declaration; add your case to the matching items list:

```swift
Section(title: "Interact", items: [.chat, .memory, .skills, .myFeature]),
```

Pick the section thematically — Monitor for views, Projects for project-scoped surfaces, Interact for talking-to-Hermes, Configure for setup, Manage for operational. See [Sidebar & Navigation](Sidebar-and-Navigation) for the canonical 5-group structure (22 cases as of v2.5).

## Step 5: Wire routing

In `ContentView.swift`'s `detailView` switch:

```swift
switch coordinator.selectedSection {
// … existing cases …
case .myFeature: MyFeatureView(context: serverContext)
}
```

## Step 6: (If your feature uses a new service)

If you needed a new service to back this feature, decide between [`ScarfCore`](ScarfCore-Package) (shared with iOS) and Mac-only `Core/Services/`, then inject any shared instance in `ContextBoundRoot` via `.environment(...)`. See [Adding a Service](Adding-a-Service).

## Step 7: (If the feature should also be on iOS)

Mac and iOS share data + view-models via ScarfCore but have separate views. To bring `MyFeature` to ScarfGo:

1. Add `Scarf iOS/MyFeature/MyFeatureView.swift` consuming the same ScarfCore ViewModel.
2. Add a row, sub-tab, or tab to the appropriate parent in [`ScarfGoTabRoot.swift`](https://github.com/awizemann/scarf/blob/main/scarf/Scarf%20iOS/App/ScarfGoTabRoot.swift). Most additions push onto an existing tab's `NavigationStack` — not a new tab. New tabs in v2.5+ require Coordinator + product-design review (5-tab cap on iPhone today).
3. Apply ScarfDesign tokens — see [Design System](Design-System). Heads-up: iOS uses semantic Dynamic Type tokens (`.font(.body)` etc.) for body copy and `ScarfFont` only for chrome/badges/intentional fixed-size; Mac uses `ScarfFont` everywhere.
4. Re-test against the iOS simulator. Verify multi-server switching doesn't leak feature state.

## Cross-feature rules

The hard rules ([CLAUDE.md](https://github.com/awizemann/scarf/blob/main/CLAUDE.md)):

- **Features never import sibling features.** If `MyFeature` needs data another feature also uses, the data lives in a service, not in that other feature.
- **Cross-feature navigation goes through `AppCoordinator`.** Set `coordinator.selectedSection = .otherFeature` and (if needed) `coordinator.selectedSessionId = ...`.

## Files touched (Mac)

- ✏️ `Navigation/AppCoordinator.swift` — 1 enum case, 1 icon line.
- ✏️ `Navigation/SidebarView.swift` — add to the right `Section` items array.
- ✏️ `ContentView.swift` — 1 switch case.
- ✏️ `scarfApp.swift` — only if you needed to inject a new shared service.
- ✨ `Features/MyFeature/Views/MyFeatureView.swift` — new.
- ✨ `Features/MyFeature/ViewModels/MyFeatureViewModel.swift` OR `Packages/ScarfCore/.../ViewModels/MyFeatureViewModel.swift` — new (location depends on whether iOS will share it).

Total: ~5–10 lines across 4 existing files, plus 1–2 new files.

## Files touched (iOS, optional)

- ✏️ `Scarf iOS/App/ScarfGoTabRoot.swift` — only if adding a primary tab.
- ✏️ Whichever existing tab pushes the new view onto its `NavigationStack`.
- ✨ `Scarf iOS/MyFeature/MyFeatureView.swift` — new.

iOS feature additions usually skip the AppCoordinator step — the iOS coordinator (`ScarfGoCoordinator`) handles cross-tab signalling, not per-view dispatch.

---
_Last updated: 2026-04-25 — Scarf v2.5.0 (added ScarfCore VM placement guidance + iOS step + 5-group sidebar reference)_