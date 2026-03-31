# 01 — Architecture Standard

Applies to: **InControl, ShabuBox, Threader, Modeler**
Swift 6 / SwiftUI / SwiftData / macOS-native

---

## 1. MVVM-F (MVVM-Feature) Pattern

Every feature is a self-contained module that owns its **Models**, **ViewModels**, and **Views**.

```
Features/
  Email/
    Models/
    ViewModels/
    Views/
  Projects/
    Models/
    ViewModels/
    Views/
```

Rules:
- Feature modules never import or reference another feature's ViewModel directly.
- Cross-feature communication goes through **shared services** injected into each feature.
- A feature may depend on `Core/` and `Services/` but never on a sibling feature.

---

## 2. AppCoordinator

`AppCoordinator` is the **single source of truth** for all navigation state.

```swift
@Observable
final class AppCoordinator {
    var selectedSection: SidebarSection = .inbox
    var selectedFileID: PersistentIdentifier?
    var isFilePreviewOpen: Bool = false
    // ... all navigation-related state lives here
}
```

Rules:
- `AppCoordinator` is `@Observable` and injected via `.environment()` at the app root.
- All navigation mutations flow through `AppCoordinator` methods.
- Leaf views **read** coordinator state but never own independent navigation state.
- Never deep-nest `NavigationStack` inside leaf views. One `NavigationStack` (or `NavigationSplitView`) at the top level, driven by the coordinator.

---

## 3. AppState vs AppCoordinator

These are **separate concerns**. Do not merge them.

| Concern | Owner | Examples |
|---|---|---|
| Navigation | `AppCoordinator` | `selectedSection`, `selectedFileID`, `isFilePreviewOpen`, modal presentation flags |
| Cross-section shared state | `AppState` | Global search query, loading states, feature flags, user preferences |

Rules:
- Never duplicate a navigation property in both `AppCoordinator` and `AppState`.
- `AppState` does not drive navigation. `AppCoordinator` does not hold domain data.
- Both are `@Observable` and injected via `.environment()`.

---

## 4. Directory Layout (Single-Platform)

Standard layout for macOS-only projects (InControl, Threader, Modeler).

```
ProjectName/
  App/              — App entry point, AppCoordinator, AppLoadingState
  Core/             — Models, Services, Utilities, Schema
  Features/         — Per-feature modules (Email/, Projects/, Dashboard/, Settings/)
  Services/         — Shared services (Storage, AI, Sync, Network)
  Shared/           — Reusable components, Extensions
  Resources/        — Assets, Localizations
```

Each feature directory mirrors the MVVM-F structure internally:

```
Features/
  Email/
    Models/         — Feature-specific data types
    ViewModels/     — Feature logic, @Observable classes
    Views/          — SwiftUI views
```

---

## 5. Directory Layout (Multiplatform)

Used by ShabuBox (macOS + iOS companion). This layout splits platform-specific code into separate targets while sharing models and design tokens through a shared library.

```
ProjectName/
  ProjectName/                — macOS app target
    App/
    Core/
    Features/
    Services/
    Views/
  ProjectNameMobile/          — iOS companion target
    App/
    Features/
    Views/
  Shared/                     — Shared library (both targets link this)
    Models/                   — All SwiftData @Model types
    DesignSystem/             — Shared theme tokens
    SchemaVersioning.swift
    CloudKitSyncHelper.swift
    LoggingKit.swift
    PathUtilities.swift
    ModelContext+SafeSave.swift
```

Rules:
- **Models are ALWAYS shared.** Never duplicate a `@Model` type per platform.
- Schema versioning lives in `Shared/` so both targets use the same migration plan.
- Platform-specific services live in their respective target directories.
- The `Shared/` library contains no UI code — only models, utilities, and design tokens.

---

## 6. Service Orchestration

Use the **Coordinator Pattern** to decouple UI state from background processing.

```swift
// Services are injected, never accessed as singletons
@Observable
final class FilePipelineService {
    private let ocrService: OCRServiceProtocol
    private let indexingService: IndexingServiceProtocol

    init(ocrService: OCRServiceProtocol, indexingService: IndexingServiceProtocol) {
        self.ocrService = ocrService
        self.indexingService = indexingService
    }
}
```

Rules:
- Services are **injected** via initializer or environment — never accessed as global singletons.
- Background processing (indexing, OCR, sync, ingestion) is orchestrated by dedicated service classes, not by ViewModels.
- ViewModels call service methods; they do not manage background task lifecycles directly.
- Long-running operations report progress through `AppLoadingState` in the footer.

---

## 7. Protocol-Driven Design

All engines and services expose **protocol interfaces**, not concrete types.

```swift
protocol TextGenerating: Sendable {
    func generate(prompt: String) async throws -> String
}

protocol GenerationEngine: Sendable {
    func run(config: GenerationConfig) async throws -> GenerationResult
}
```

Rules:
- Define a protocol for every service boundary (storage, AI, network, sync).
- ViewModels and orchestrators depend on protocols, not concrete implementations.
- Test suites swap real services for **protocol-conforming mocks**.
- This enables backend swappability (e.g., local LLM vs hosted LLM behind the same `TextGenerating` protocol).

---

## 8. @Observable Architecture

Use the `@Observable` macro exclusively. Do **not** use `ObservableObject` / `@Published` / Combine.

```swift
@Observable
final class AppState {
    var searchQuery: String = ""
    var isLoading: Bool = false
}

// Injection at app root
@main struct MyApp: App {
    @State private var appState = AppState()
    @State private var coordinator = AppCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(coordinator)
        }
    }
}
```

Rules:
- Root state objects (`AppState`, `AppCoordinator`) are injected via `.environment()`.
- Domain services are `@Observable` classes or actors.
- Views read state directly from environment objects — no bindings to published properties.
- All mutations go through service or coordinator methods, not direct property writes from views.
- No Combine. Use `@Observable` + `async/await` for reactive patterns.

---

## 9. Navigation Rules

All navigation is driven by `AppCoordinator`.

```swift
// Three-column layout (standard for these apps)
NavigationSplitView {
    Sidebar(coordinator: coordinator)
} content: {
    ContentList(coordinator: coordinator)
} detail: {
    DetailView(coordinator: coordinator)
}
```

Rules:
- Use `NavigationSplitView` for three-column layouts (sidebar / content / detail).
- **One** `NavigationStack` or `NavigationSplitView` at the top level. Never nest additional stacks inside feature views.
- Modal flows (sheets, alerts, inspectors) are presented via boolean flags on `AppCoordinator`.
- Deep linking and programmatic navigation go through coordinator methods.
- Use `.navigationDestination(for:)` driven by coordinator state for push-based navigation within a column.
