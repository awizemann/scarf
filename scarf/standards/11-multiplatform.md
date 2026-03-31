# 11 — Multiplatform (iOS Companion Apps)

Standards for building iOS companion apps alongside macOS apps, sharing code and syncing via CloudKit.

**Reference implementation**: ShabuBox (working macOS + iOS with CloudKit sync)

---

## 1. Shared Library Structure

Any code that both platforms need goes in `Shared/`. Models are ALWAYS shared — never duplicate a `@Model` type per platform.

```
ProjectName/
  ProjectName/              -- macOS app target
    App/
    Core/
    Features/
    Services/
    Views/
  ProjectNameMobile/        -- iOS companion target
    App/                    -- iOS app entry point
    Features/               -- iOS-specific views/flows
    Views/                  -- iOS-specific UI
    Info.plist              -- UIBackgroundModes, etc.
  Shared/                   -- Shared library (both targets link this)
    Models/                 -- ALL SwiftData @Model types
    DesignSystem/           -- Shared theme tokens (platform-adapted)
    SchemaVersioning.swift  -- VersionedSchema + MigrationPlan
    CloudKitSyncHelper.swift
    LoggingKit.swift
    PathUtilities.swift
    ModelContext+SafeSave.swift
```

### What Goes in Shared/

| Category | Examples | Why Shared |
|----------|----------|-----------|
| SwiftData models | All `@Model` types | Schema must be identical for CloudKit sync |
| Schema versioning | `VersionedSchema`, `SchemaMigrationPlan` | Version mismatch breaks sync |
| Sync helpers | `CloudKitSyncHelper`, manual sync utilities | Both platforms need sync control |
| Design tokens | Theme colors, spacing, typography values | Visual consistency across platforms |
| Logging | Logger configuration, safe-save extensions | Consistent error handling |
| Path utilities | Filename sanitization, path security | Same rules apply everywhere |

### What Stays Platform-Specific

| Category | macOS Target | iOS Target |
|----------|-------------|-----------|
| App entry point | `ProjectNameApp.swift` | `ProjectName_MobileApp.swift` |
| Navigation | `NavigationSplitView` (3-column) | `NavigationStack` or compact `NavigationSplitView` |
| Views | Desktop-optimized layouts | Touch-optimized layouts |
| Services | Desktop-specific services (file monitoring, etc.) | iOS-specific services |
| Platform APIs | AppKit (`NSImage`, `NSWorkspace`) | UIKit (`UIImage`, UIBackgroundModes) |

---

## 2. CloudKit Container Setup

### Both Platforms Must Match

```swift
// CRITICAL: Both macOS and iOS must use identical configuration
let config = ModelConfiguration(
    cloudKitDatabase: .private("iCloud.com.yourapp.identifier")
)
```

**Never** use `.automatic` — it can infer different containers per platform, causing sync to silently fail.

### Entitlements (macOS)

```xml
<key>com.apple.developer.icloud-container-identifiers</key>
<array>
    <string>iCloud.com.yourapp.identifier</string>
</array>
<key>com.apple.developer.icloud-services</key>
<array>
    <string>CloudKit</string>
    <string>CloudDocuments</string>
</array>
```

### Entitlements (iOS)

```xml
<key>com.apple.developer.icloud-container-identifiers</key>
<array>
    <string>iCloud.com.yourapp.identifier</string>
</array>
<key>com.apple.developer.icloud-services</key>
<array>
    <string>CloudKit</string>
    <string>CloudDocuments</string>
</array>
<key>com.apple.developer.aps-environment</key>  <!-- NOT "aps-environment" -->
<string>development</string>
```

**Common mistake**: Using `aps-environment` instead of `com.apple.developer.aps-environment` for the APS key. The wrong key silently disables push notifications for CloudKit changes.

---

## 3. iOS Background Sync

### Info.plist Configuration

```xml
<key>UIBackgroundModes</key>
<array>
    <string>remote-notification</string>
    <string>fetch</string>
</array>
```

### Sync Behavior

- **Typical delay**: 5-30 seconds between devices
- **Simulator**: 30-60 seconds (slower than physical devices)
- **Background**: System may defer sync to save battery
- **Sync triggers**: App launch, app background, periodic intervals, network restored, significant changes

### Manual Sync Trigger

Provide a way for users to force sync (pull-to-refresh, sync button):

```swift
// Trigger foreground sync
try modelContext.save()
// CloudKit will push changes on next sync cycle
```

---

## 4. Platform-Adaptive UI

### Navigation Patterns

```swift
#if os(macOS)
NavigationSplitView {
    Sidebar()
} content: {
    ContentList()
} detail: {
    DetailView()
}
#else
NavigationStack {
    ContentList()
}
#endif
```

### Size Classes

```swift
@Environment(\.horizontalSizeClass) private var sizeClass

var body: some View {
    if sizeClass == .compact {
        // iPhone layout (single column)
    } else {
        // iPad layout (split view)
    }
}
```

### Platform-Specific Modifiers

```swift
extension View {
    @ViewBuilder
    func platformToolbar() -> some View {
        #if os(macOS)
        self.toolbar { /* macOS toolbar items */ }
        #else
        self.toolbar { /* iOS toolbar items */ }
        #endif
    }
}
```

---

## 5. Shared Design System with Platform Adaptation

Define tokens once in `Shared/DesignSystem/`, apply platform-specific modifiers:

```swift
// Shared/DesignSystem/AppTheme.swift
enum AppTheme {
    enum Spacing {
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
    }

    enum Typography {
        static let title: Font = .title
        static let body: Font = .body
    }
}
```

Platform-specific extensions live in each target:

```swift
// macOS target
extension View {
    func appCard() -> some View {
        self.background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// iOS target
extension View {
    func appCard() -> some View {
        self.background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
```

---

## 6. Schema Versioning Across Platforms

**Both platforms MUST use identical `VersionedSchema` definitions.** This is why schema versioning lives in `Shared/`.

- Add new schema versions in `Shared/SchemaVersioning.swift`
- Both targets pick up the change automatically
- Test migration on both platforms before shipping
- A schema version mismatch between platforms causes sync failures or crashes

---

## 7. Testing Across Platforms

| Test Type | Location | Runs On |
|-----------|----------|---------|
| Model tests | `SharedTests/` | Both platforms |
| Service tests | `SharedTests/` | Both platforms |
| macOS UI tests | `ProjectNameTests/` | macOS only |
| iOS UI tests | `ProjectNameMobileTests/` | iOS only |
| Sync roundtrip tests | `SharedTests/` | Both platforms |

---

## 8. CloudKit Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Simple models sync, complex models don't | Container ID mismatch (`.automatic` vs explicit) | Use explicit `.private("iCloud.com....")` on both |
| iOS doesn't receive remote changes | Wrong APS entitlement key | Use `com.apple.developer.aps-environment` |
| Sync works on device, not simulator | Simulator CloudKit delays | Wait longer (30-60s), test on device for real behavior |
| "Duplicate checksums" crash | V1 and V2 models sharing live types | Plan version transitions — see `08-data-integrity.md` |
| Cascade deletes cause sync issues | Complex relationship graphs | Simplify relationships, use explicit join tables |

---

## 9. When NOT to Go Multiplatform

Not every app needs an iOS companion. Skip it when:

- **Hardware-specific requirements**: Apps targeting Apple Silicon GPU (e.g., ML model training), large displays, or specific peripherals
- **Desktop-only workflows**: Complex multi-window setups, file system manipulation, development tools
- **Python/subprocess backends**: Apps that rely on bundled Python environments or native subprocess management
- **No user data to sync**: If the app doesn't have user-created content that benefits from cross-device access

Example: Modeler (AI photo generation) requires Apple Silicon Max with 32GB+ RAM and a bundled Python environment — an iOS companion would not be practical.
