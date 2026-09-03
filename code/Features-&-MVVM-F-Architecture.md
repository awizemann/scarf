---
created: 2026-09-03
updated: 2026-09-03
source_sha: 7b1be630ce477231a804649efe75285f95c410b5
source_paths: scarf/scarf/Features, scarf/scarf/Navigation
source_paths_inferred: false
---

# Features & MVVM-F Architecture

Scarf uses the **MVVM-Feature** (MVVM-F) pattern: each feature is a self-contained module under `Features/` with `Views/` and `ViewModels/` subdirectories, no cross-feature imports.

## Feature Isolation

**Rule: Features never import sibling features.** The sidebar has Chat, Bots, Projects, Settings, etc. — each is independent. Cross-feature navigation goes exclusively through `AppCoordinator` (`Navigation/AppCoordinator.swift:162`).

Example:
```swift
// ✗ FORBIDDEN
import Features.Bots
struct ChatView { let botVM = BotAgentViewModel() }

// ✓ CORRECT
struct ChatView { 
  @Environment(\.appCoordinator) var coordinator
  func openBot(_ id: String) {
    coordinator.selectedSection = .bots
    // Bots feature loads its own state
  }
}
```

## AppCoordinator

`AppCoordinator` (macOS) owns:
- **Sidebar state** — `@Published var selectedSection: SidebarSection` routes the main view tree via a `switch` statement.
- **Feature ViewModels** — `featureViewModel<VM>(for:make:)` caches each feature's root ViewModel so switching sidebar sections doesn't lose state or re-fetch data.
- **Presentation sheets/alerts** — Modal flows (add server, confirm delete, etc.) are triggered through properties like `@Published var addServerSheetIsPresented`.
- **Multi-window state** — Manages the binding between windows and servers.

[[cache-feature-vms-in-appcoordinator]]

## ViewModel Patterns

**Observe state, emit side effects.** Each feature's root ViewModel (e.g., `BotAgentViewModel`, `ChatViewModel`) is marked `@Observable` and:
- Exposes `@Published var isLoading: Bool` — the view uses `.loadingOverlay(isLoading)` to show progress.
- Exposes collections (`messages: [Message]`, `bots: [BotRosterEntry]`) that SwiftUI observes.
- Exposes a `load()` method that the view calls from `.task` on appearance.
- Never uses `@State` or `@StateObject` — the view owns the ViewModel via a property, and SwiftUI's observation framework handles the rest.

[[every-data-loading-pane-must-drive-loadingoverlay]]

**Off-main I/O.** Services are `nonisolated`, so any call that does SSH, SQL, or subprocess I/O runs on a background thread:
```swift
class ChatViewModel {
  @MainActor func load() async {
    let task = Task.detached { [weak self] in
      let sessions = try await backend.fetchSessions()  // off-main I/O
      await MainActor.run { self?.sessions = sessions }
    }
    self.loadTask = task  // Store handle for cancellation
  }
  
  deinit { loadTask?.cancel() }  // Cancel if view disappears
}
```

[[store-cancellable-handles-for-off-main-remote-work]]

## Sidebar Navigation (macOS)

`SidebarView` (`Navigation/SidebarView.swift:13`) renders the sidebar sections:
- Chat, Bots, Projects, Monitor (Dashboard, Insights, Sessions, Activity, Kanban), Configure (Settings, etc.), Manage.
- Each section is a `SidebarSection` enum; tapping it sets `coordinator.selectedSection`.
- The main view uses `@ViewBuilder switch coordinator.selectedSection` to show the right feature.

## View-Load Fetches Behind Navigation

**Prefer `.task` over `.onAppear` when hiding/showing views behind a `switch`.** The switch destroys and recreates views per selection, so `.onAppear` refires on every switch. Use `.task` with the enum case as dependency: [[prefer-task-over-onappear]]

```swift
switch coordinator.selectedSection {
case .chat:
  ChatView()
    .task(id: coordinator.selectedSection) {
      await chatVM.load()  // Fires once per selection
    }
// ...
}
```

## Adding a New Feature

1. Create `Features/MyFeature/` with `Views/` and `ViewModels/` subdirs.
2. Write `MyFeatureView: View` and `MyFeatureViewModel: Observable`.
3. Add a case to `SidebarSection` enum.
4. In `AppCoordinator`, add a `@Published var myFeatureVM: MyFeatureViewModel?` and fill it in the `featureViewModel(for:)` cache.
5. Add a switch case in the main view's sidebar switch.
6. Wire any navigation through the coordinator (never direct imports).

No dependencies on siblings; only on `ScarfCore`, `ScarfDesign`, and system frameworks.