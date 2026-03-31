# 07 — AI Integration

Standards for AI/ML capabilities across all macOS apps.

---

## 1. Native-First Principle

Always prefer Apple's on-device frameworks before reaching for LLMs:

| Task | Framework | Level |
|------|-----------|-------|
| Text recognition (OCR) | Apple Vision | Level 1 (primary) |
| Entity extraction (names, dates, places) | NaturalLanguage | Level 1 (primary) |
| Text classification | NaturalLanguage | Level 1 (primary) |
| Language detection | NaturalLanguage | Level 1 (primary) |
| Image classification | Vision | Level 1 (primary) |
| Barcode/QR detection | Vision | Level 1 (primary) |
| Summarization | LLM via protocol | Level 3 (enrichment) |
| Complex reasoning | LLM via protocol | Level 3 (enrichment) |

**Why**: On-device frameworks are fast, private, free, and work offline. LLMs are slow, may require network, and cost compute.

---

## 2. LLM Protocol Layer

Access LLMs through protocols for backend swappability:

```swift
protocol TextGenerating: Sendable {
    func generate(prompt: String, maxTokens: Int) async throws -> String
    func generate(prompt: String, maxTokens: Int) -> AsyncThrowingStream<String, Error>
}
```

This allows swapping between:
- Local models (MLX Swift, Core ML)
- Cloud APIs (Anthropic, OpenAI)
- Mock implementations (testing)

Without changing any calling code.

### Implementation Rules

- Service layer holds the active `TextGenerating` implementation
- Views never call LLM APIs directly
- Configuration determines which backend is active
- All backends conform to the same protocol

---

## 3. Hardware Acceleration

- Use **Accelerate framework** (vDSP) for vector math and similarity search
- Use **Core ML** for model inference when models are available in `.mlmodel` format
- Use **Metal Performance Shaders** only when Accelerate is insufficient
- For apps with Python backends (e.g., Modeler), communicate via JSON-lines over stdin/stdout

### Python Backend Protocol (when applicable)

```json
// Request (one JSON object per line on stdin)
{"id": "req-1", "method": "generate", "params": {"prompt": "...", "steps": 50}}

// Response (one JSON object per line on stdout)
{"id": "req-1", "type": "progress", "step": 25, "total": 50}
{"id": "req-1", "type": "image_result", "path": "/path/to/output.png"}
{"id": "req-1", "type": "complete"}
```

- Backend is a managed subprocess — start on demand, health-check, auto-restart
- Close both Pipe file handles after communication

---

## 4. Memory Hygiene

```swift
// autoreleasepool in ALL loops processing images, thumbnails, or PDFs
for page in pages {
    autoreleasepool {
        // Process page (synchronous only — no await inside)
        let image = renderPage(page)
        processImage(image)
    }
}

// Check cancellation in long loops
for item in items {
    guard !Task.isCancelled else { break }
    // process...
}
```

- **autoreleasepool**: Required for image/thumbnail/PDF processing loops. Synchronous only — no `await` inside the autoreleasepool block
- **PDF rendering cap**: Max 4096px in any dimension
- **Task.isCancelled**: Check at top of every iteration in long loops
- **Pipe handles**: Always close both ends after subprocess communication

---

## 5. Pipeline Architecture

For apps with file ingestion or multi-stage processing, use a stage-based pipeline:

### Two-Phase Architecture

**Phase 1: "Ready-to-Review"** (target: <5s per file)
- First-page thumbnail only
- First-page OCR (1-3s)
- Fast classification
- Skeleton Record created immediately for UI feedback

**Phase 2: "Full Processing"** (deferred, on-demand)
- Complete OCR (all pages)
- AI analysis and summarization
- Embedding generation
- Visual fingerprinting

### Job Priority System

Each processing job conforms to a pipeline protocol and runs at a defined priority:

```swift
protocol ProcessingJob {
    var priority: Int { get }  // Lower = runs first
    func process(_ item: Item) async throws
}
```

Jobs register in the pipeline service and execute in priority order. Each job must:
- Have its own `os.Logger`
- Log entry/exit at `.info` level
- Check `Task.isCancelled` in loops
- Handle errors without blocking subsequent jobs

---

## 6. Prompt Injection Defense

All document text must be sanitized before embedding in LLM prompts:

```swift
let safeText = LLMService.sanitizeForPrompt(rawDocumentText)
let prompt = "Summarize the following document:\n\n\(safeText)"
```

### Sanitization Rules

- Strip provider-specific special tokens (`<s>`, `<bos>`, `</s>`, `[INST]`, `[/INST]`)
- Strip bracket delimiters (`[SYSTEM]`, `[USER]`, `[ASSISTANT]`)
- Strip XML-style role tags (`<|system|>`, `<|user|>`, `<|assistant|>`)
- When adding new LLM provider support, add that provider's format markers
- Test sanitization against the provider's known injection vectors

---

## 7. When NOT to Use AI

- Don't use LLMs for tasks that deterministic code handles well (date parsing, number formatting, sorting)
- Don't call LLMs on the critical path of user interactions (search, navigation, filtering)
- Don't store LLM outputs as authoritative data — they are suggestions for user review
- Don't send sensitive data (credentials, financial details) to cloud LLM APIs without user consent
