---
id: t-aud04
title: **[t-aud04]** Raw `print()` → `os.Logger` — FIXED. Both `WebviewWidgetView` Coordinators (macOS `Features/Projects/Views/Widgets/` + iOS `Scarf iOS/Projects/Widgets/`) gained `import os` + `Logger(subsystem: "com.scarf", category: "WebviewWidgetView")` and now `logger.warning(…, privacy: .public)` for WKNavigationDelegate nav/load failures. `HermesFileService` 599/659/2006 → `Self.logger.warning(…, privacy: .public)` (logger already existed). Verified: macOS + iOS (`scarf mobile`) BUILD SUCCEEDED, zero new warnings.
status: archived
---

## Description



## Plan



## Artifacts



