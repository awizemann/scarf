# 06 — Editor Patterns

Modern Liquid Glass tabbed editor architecture for all add/edit sheets.

---

## Overview

All add/edit sheets follow a consistent tabbed architecture with:
- Wide canvas (800-900px x 600-700px)
- Tabbed navigation for progressive disclosure
- Smart natural language input prioritized as Tab 0
- Consistent spacing and visual hierarchy
- Instant tab switching with smooth transitions

---

## Architecture

### Sheet Presentation

```swift
.sheet(isPresented: $showEditor) {
    NavigationStack {
        EditorView(mode: editorMode, onDismiss: { showEditor = false })
    }
    .frame(minWidth: 800, idealWidth: 900, minHeight: 600, idealHeight: 700)
}
```

- Always wrap in `NavigationStack` for toolbar support
- Use `minWidth/idealWidth` and `minHeight/idealHeight`

### Tab Structure

```swift
private let tabs: [DSEditorTab] = [
    DSEditorTab(title: "Quick Entry", icon: "sparkles"),     // Tab 0: Always NL input
    DSEditorTab(title: "Details", icon: "info.circle"),       // Tab 1: Core fields
    DSEditorTab(title: "Financial", icon: "dollarsign.circle"), // Tab 2+: Domain-specific
    DSEditorTab(title: "Terms", icon: "doc.text")
]

@State private var selectedTab: Int = 0
```

### Body Structure

```swift
var body: some View {
    VStack(spacing: 0) {
        DSEditorTabBar(tabs: tabs, selectedTab: $selectedTab)
        Divider()
        ZStack {
            if selectedTab == 0 { quickEntryTab }
            if selectedTab == 1 { detailsTab }
            if selectedTab == 2 { financialTab }
            if selectedTab == 3 { termsTab }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .navigationTitle(mode.isCreate ? "New Entity" : "Edit Entity")
    .toolbar { /* cancel + save */ }
    .onAppear { loadExisting() }
}
```

**Rules**:
- `VStack` with `spacing: 0` for tab bar + content
- `ZStack` with conditional `if` rendering (NOT `switch` statement)
- Each tab gets `.transition(.opacity.animation(.easeInOut(duration: 0.15)))`

### Tab Content Template

```swift
private var tabName: some View {
    ScrollView {
        VStack(spacing: DS.Spacing.lg) {
            DSFormSection("Section Title", icon: "icon.name") {
                VStack(spacing: DS.Spacing.md) {
                    // Fields
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(DS.Spacing.xl)
        .padding(.top, DS.Spacing.md)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}
```

---

## Tab Types

### Tab 0: Quick Entry (All Editors)

Natural language input with live parsing preview.

```swift
DSSmartInputField(
    placeholder: "Entity description example...",
    text: $smartInput
)
```

Examples by entity type:
- **Estimate**: "Estimate for BKSI for $5000 due March 15 with Net 30 terms"
- **Person**: "John Doe at Apple, john@apple.com, (555) 123-4567"
- **Project**: "$50k website redesign for Acme Corp, starting March 1"
- **Expense**: "$250 client dinner at Restaurant with Jane from Acme"

### Tab 1: Details

Core entity fields. Use `DSTwoColumnRow` for related pairs (number/status, date/expiry). Keep single-column for complex fields (text editors, long pickers).

### Tab 2+: Domain-Specific

Financial (discount, tax, budget), Terms (payment, T&C), Contacts (related people/orgs), Time (tracking, estimates), Attachments, etc.

---

## Design System Components

| Component | Purpose | Key Features |
|-----------|---------|-------------|
| `DSEditorTabBar` | Custom tab bar | 56pt height, full-area clickable, accent highlight, 0.15s animation |
| `DSFormSection` | Grouped form fields | DSPlate styling, 16pt corners, 16pt padding, icon + title header |
| `DSTextField` | Single-line input | Label above, 8pt padding, quinary background, 10pt corners |
| `DSTextEditor` | Multi-line input | Configurable height (default 100pt), scrollable |
| `DSPickerRow` | Menu-style picker | Menu style, hidden redundant label, full width |
| `DSDatePickerRow` | Compact date picker | Supports .date, .hourAndMinute, or both |
| `DSToggleRow` | Toggle switch | System switch style |
| `DSTwoColumnRow` | Side-by-side layout | Equal-width columns, 24pt gap, top alignment |
| `DSSmartInputField` | NL input | 120pt height, accent border, ready for parsing |
| `DSAmountField` | Currency input | Label + prefix ($) + input + optional suffix |
| `DSNumericField` | Numeric input | Label + input + suffix (%) |

---

## Spacing Standards

| Context | Token | Value |
|---------|-------|-------|
| Outer padding (horizontal) | `DS.Spacing.xl` | 32pt |
| Top padding (additional) | `DS.Spacing.md` | 16pt |
| Between sections | `DS.Spacing.lg` | 24pt |
| Between fields | `DS.Spacing.md` | 16pt |
| Label-to-input | `DS.Spacing.xs` | 4pt |
| Internal section padding | `DS.Spacing.md` | 16pt |
| Tab bar height | Fixed | 56pt |
| Two-column gap | `DS.Spacing.lg` | 24pt |

---

## Common Patterns

### Create vs Edit Mode

```swift
let mode: EditorMode<Entity>

.navigationTitle(mode.isCreate ? "New Entity" : "Edit Entity")
.toolbar {
    ToolbarItem(placement: .confirmationAction) {
        Button(mode.isCreate ? "Create" : "Save") { save() }
            .buttonStyle(.borderedProminent)
    }
}
```

### Loading Existing Data

```swift
private func loadExisting() {
    if case .edit(let entity) = mode {
        field1 = entity.field1
        field2 = entity.field2 ?? ""
    } else {
        number = Entity.generateNumber()
    }
}
```

### Width Consistency

Apply `.frame(maxWidth: .infinity)` at every level:
1. `DSFormSection` content VStack
2. `DSPickerRow` Picker
3. Tab content VStack (before padding)
4. Tab content ScrollView (at end)

---

## Checklist for New Editor

- [ ] 3+ tabs with `DSEditorTab` definitions
- [ ] `ZStack` with conditional `if` rendering (not `switch`)
- [ ] Tab 0: Quick Entry with `DSSmartInputField`
- [ ] Tab 1: Details with entity-specific fields
- [ ] All tabs: consistent padding (`xl` + top `md`)
- [ ] All tabs: `maxWidth/maxHeight` frames
- [ ] `DSFormSection` for all content groups
- [ ] `DSTwoColumnRow` for related field pairs
- [ ] `.borderedProminent` on save/create button
- [ ] Sheet frame: 800-900px x 600-700px
- [ ] Smooth 0.15s tab transitions
- [ ] Width consistency cascade
- [ ] Full tab area clickable
- [ ] Icons on all tabs and sections

---

## Migration from Old Form Style

**Before** (Form-based):
```swift
Form {
    Section("Title") {
        TextField("Field", text: $value)
    }
}
.formStyle(.grouped)
```

**After** (Tabbed editor):
```swift
VStack(spacing: 0) {
    DSEditorTabBar(tabs: tabs, selectedTab: $selectedTab)
    Divider()
    ZStack {
        if selectedTab == 0 { /* Quick Entry */ }
        if selectedTab == 1 {
            ScrollView {
                VStack(spacing: DS.Spacing.lg) {
                    DSFormSection("Title", icon: "icon") {
                        DSTextField("Field", text: $value)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(DS.Spacing.xl)
                .padding(.top, DS.Spacing.md)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
```

---

## Note

Each project implements these DS components in its own design system namespace (e.g., `InControlDS`, `ShabuBoxTheme`). The pattern and API surface should be consistent across projects even if the concrete implementation differs.
