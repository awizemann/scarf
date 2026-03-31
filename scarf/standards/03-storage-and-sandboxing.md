# 03 — Storage & Sandboxing

Standards for iCloud storage, file operations, sandboxing, and path security across all macOS apps.

---

## 1. iCloud-First Strategy

All user data lives in the Ubiquity Container (`Documents/`). This provides zero-config cross-device sync via CloudKit.

- Use `FileManager.default.url(forUbiquityContainerIdentifier:)` to discover the container
- Store user-created content in `Documents/` within the container
- Monitor `NSMetadataQuery` for `ubiquitousItemHasUnresolvedConflictsKey` to detect sync conflicts
- For apps without iCloud (e.g., hardware-specific apps), store in Application Support

---

## 2. NSFileCoordinator Mandate

**ALL file operations within the iCloud library root must use NSFileCoordinator.** Direct `FileManager.default` calls are prohibited.

| Operation | Required API |
|-----------|-------------|
| Read file | `FileCoordinatorService.shared.coordinatedRead()` |
| Write file | `FileCoordinatorService.shared.coordinatedWrite()` |
| Move file | `FileCoordinatorService.shared.coordinatedMove()` (locks both source + destination) |
| Delete file | `SafeFileOperations.shared.coordinatedDelete()` |
| Async file ops | `AsyncFileManager.shared.*` (routes through FileCoordinatorService) |
| Create directory | `AsyncFileManager.shared.createDirectory()` |
| List directory | `AsyncFileManager.shared.contentsOfDirectory()` |

### Allowed FileManager.default Exceptions

Direct `FileManager.default` is acceptable ONLY for:

- **`.url(forUbiquityContainerIdentifier:)`** — iCloud container discovery
- **`.temporaryDirectory`** — Temp path access (no coordination needed)
- **App bundle resources** — Read-only checks outside iCloud
- **Pre-container-init checks** — Migration coordinators before container is available

### Async Wrappers

Always prefer async wrappers over synchronous coordination:

```swift
// Use these:
FileCoordinatorService.coordinatedReadAsync()
FileCoordinatorService.coordinatedWriteAsync()
FileCoordinatorService.coordinatedDelete()
FileCoordinatorService.coordinatedCreateDirectory()
```

---

## 3. TOCTOU Prevention

Never use `fileExists` before an operation that would fail gracefully without it.

| Anti-Pattern | Correct Pattern |
|---|---|
| `if fileExists { removeItem }` | `try? removeItem` (ignore ENOENT) |
| `if fileExists { moveItem }` | `try moveItem` (handle error in catch) |
| `if !fileExists { createDirectory }` | `createDirectory(withIntermediateDirectories: true)` |
| `if fileExists { read }` | `try read` (handle ENOENT in catch) |

### Valid Uses of `fileExists`

Where the check IS the operation (no subsequent file op):

- **User-facing warnings** — "File missing" display-only messages
- **Migration gates** — "Does old database exist?" (read-only decision)
- **Cache hit checks** — Thumbnail cache optimization where race is harmless

---

## 4. Safe Deletion Paths

Coordinated delete operations should only allow deletion within controlled directories:

- `/tmp/`
- `/Caches/`
- `/_Duplicate`
- `/_Deleted`
- `/_InBox`
- `/.bento/` (or app-specific internal directory)

Deletion outside these paths requires explicit user confirmation.

---

## 5. Conflict Resolution

- Monitor `NSMetadataQuery` for `ubiquitousItemHasUnresolvedConflictsKey`
- No silent last-writer-wins — merge deterministically or queue for user resolution
- Implement conflict resolution UI for user-facing data conflicts
- See `08-data-integrity.md` for CloudKit sync safety guards

---

## 6. Sandboxing

### Security-Scoped Bookmarks

- All apps are sandboxed for App Store distribution
- Use security-scoped bookmarks for persistent access to user-selected folders outside the container
- Always call `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()` in balanced pairs

### Inbox Pattern

- New documents enter through a centralized `_InBox/` directory for review and classification
- System folder names use singular with underscore prefix: `_InBox`, `_Duplicate`, `_Deleted`
- Never use plural forms (`_Deleted` not `_Deleteds`)

---

## 7. Path Security

### Filename Sanitization

- Sanitize ALL filenames from external sources via `PathUtilities.sanitizeFilename()` / `sanitizePath()` / `resolveURL(relativePath:rootURL:)`
- Never trust filenames from: file imports, drag-and-drop, network responses, user input
- Prevent path traversal (`../`) attacks

### LLM Prompt Injection Defense

- All document text must pass through `sanitizeForPrompt()` before embedding in LLM prompts (RAG chunks, summaries, chat context)
- When adding new LLM provider support, add that provider's format markers to `sanitizeForPrompt()` (special tokens like `<s>`, `<bos>`, bracket delimiters like `[SYSTEM]`)
- Test sanitization against the provider's known injection vectors

---

## 8. Performance Notes

- **`autoreleasepool`** is required in any loop processing images, thumbnails, or PDF pages (synchronous only — no `await` inside the autoreleasepool block)
- **Single `resourceValues(forKeys:)`** — Never call `fileExists` + `attributesOfItem` separately; use one `resourceValues(forKeys:)` call
- **Cap PDF rendering** at 4096px maximum dimension
- **Close both Pipe file handles** after subprocess communication
- **Check `Task.isCancelled`** at the top of every iteration in long file-processing loops

---

## 9. URL Storage

When storing URLs via `@AppStorage`, remember:
- `URL.absoluteString` includes the `file://` scheme
- Reconstruct with `URL(string:)`, **never** `URL(fileURLWithPath:)` (which would double the scheme)
- Document this pattern wherever URL storage is used
