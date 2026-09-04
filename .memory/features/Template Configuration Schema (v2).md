---
title: Template Configuration Schema (v2)
type: note
permalink: scarf/features/template-configuration-schema-v2
tags: [templates, config, keychain]
source_paths: [scarf/scarf/Core/Models/TemplateConfig.swift, scarf/scarf/Core/Services/ProjectConfigKeychain.swift, scarf/scarf/Core/Services/ProjectConfigService.swift, scarf/scarf/Features/Templates/Views/TemplateConfigSheet.swift, tools/build-catalog.py]
source_sha: 64bb87b88f785636aea2386ba3837723f7b81eec
created: 2026-05-29
updated: 2026-09-04
reviewed: 2026-06-28
reviewed_by: audit:claude-code (audit)
---

## Observations
- [schema-version] template.json schemaVersion 2 adds typed `config` block with `schema` (array of fields) + optional `modelRecommendation` (preferred + rationale). schemaVersion 1 templates have no config #schema
- [field-types] Supported: string, text, number, bool, enum (with options:[{value,label}]), list (itemType 'string' only in v1), secret. Type-specific constraints: pattern, min/max, minLength/maxLength, minItems/maxItems. Secret fields MUST NOT declare a default — validator refuses #types
- [ui-flow] Installer renders a Configure step between parent-dir pick and preview sheet. Values land at <project>/.scarf/config.json (non-secret) and login Keychain (secret). Post-install Configuration button on dashboard header (shown when <project>/.scarf/manifest.json exists) opens same form pre-filled #ui
- [services] TemplateConfig.swift (schema + value models + Keychain ref helpers), ProjectConfigKeychain.swift (thin SecItemAdd/Copy/Delete wrapper; ONLY Keychain user in Scarf today), ProjectConfigService.swift (load/save, resolve secrets, cache manifest, validate). UI in TemplateConfigViewModel + TemplateConfigSheet #services
- [secret-storage] Keychain service name: `com.scarf.template.<slug>`; account: `<fieldKey>:<project-path-hash-short>`. Path-hash suffix means two installs of same template in different dirs don't collide. config.json holds `keychain://service/account` URIs — NEVER plaintext — and since S1 (2026-09-04) a URI is only honored when it parses into the com.scarf.template.* namespace with a `<fieldKey>:<8-hex>` account AND its path hash matches the READING project, so one project's config.json can't name another's secret. Bytes hit Keychain only on form commit, so cancelling never leaves orphans #security
- [uninstall] TemplateLock v2 adds config_keychain_items and config_fields arrays. The uninstaller deletes an item ONLY when its URI parses into the com.scarf.template.* namespace AND belongs(toProjectPath:) the project being uninstalled (S1, 2026-09-04) — a lock naming another project's or another app's item is refused and listed in the plan's refusedEntries. Absent items (user hand-cleaned) are no-ops #uninstall
- [exporter-rule] Exporter carries the SCHEMA from manifest.json into exported bundles, NEVER values. Exporting cannot leak anyone's secrets. schemaVersion bumps to 2 only when schema is forwarded; schema-less exports stay at 1 #security
- [catalog] tools/build-catalog.py mirrors the Swift schema validator. v2 templates' template.json is copied into .gh-pages-worktree/templates/<slug>/manifest.json; site widgets.js calls ScarfWidgets.renderConfigSchema for display-only rendering (form lives in-app) #catalog
- [drift-rule] Schema is Swift-primary. New TemplateConfigField.FieldType case → update in order: TemplateConfig.swift (model + validation) → tools/build-catalog.py (SUPPORTED_CONFIG_FIELD_TYPES + type-specific rules) → widgets.js (summariseConstraint) → TemplateConfigSheet.swift (new control subview) → tests on both sides #maintenance

## Relations
- extends [[Project Templates (.scarftemplate)]]
- relates_to [[Template Catalog Pipeline]]
