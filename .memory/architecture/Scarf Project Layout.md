---
title: Scarf Project Layout
type: note
permalink: scarf/architecture/scarf-project-layout
tags: [layout, paths]
source_paths: [scarf/scarf.xcodeproj/project.pbxproj, scarf/Packages/ScarfCore/Package.swift, scarf/Packages/ScarfIOS/Package.swift]
source_paths_inferred: false
source_sha: 18806e7c4dbac0ffd6ff7e91c12d27440d0a8cc5
created: 2026-05-29
updated: 2026-05-29
reviewed: 2026-09-19
reviewed_by: audit:claude-code (background)
---

## Observations
- [path] Xcode project: scarf/scarf.xcodeproj — open with Xcode 16.0+ #build
- [path] Main app source: scarf/scarf/ with subdirs Core/Services, Core/Models, Features/<Name>, Navigation/ #source
- [path] Core/Services (Mac-specific): ACPClient+Mac, HermesFileService, HermesFileWatcher, HermesProxyService, ProjectTemplateService, ProjectAgentContextService, NousSubscriptionService, SkillBootstrapService, and others #services
- [path] ScarfCore services (cross-platform): HermesDataService, HermesLogService, HermesCapabilities, KanbanService, ModelCatalogService, ModelPresetService, SessionAttributionService, CuratorService, and others #services
- [path] Feature modules under Features/: Activity, Bots, Chat, Common, CredentialPools, Cron, Curator, Dashboard, Gateway, Health, Insights, Kanban, Logs, MCPServers, Memory, Models, Peers, Personalities, Platforms, Plugins, Profiles, Projects, Proxy, QuickCommands, Servers, Sessions, Settings, Skills, Templates, Tools, Webhooks #features
- [path] ScarfDesign Swift package: scarf/Packages/ScarfDesign/ — shared design tokens for both macOS and iOS targets #design
- [path] ScarfCore Swift package: scarf/Packages/ScarfCore/ — shared services including HermesCapabilities #core
- [path] ScarfIOS Swift package: scarf/Packages/ScarfIOS/ — iOS-specific services including CitadelServerTransport and IOSDashboardViewModel #ios
- [path] Internal dev docs (PRD, Architecture, Discovery, I18N): scarf/docs/ — not public #docs
- [path] Standards reference (read-only): scarf/standards/ #docs
- [path] Repo root: BUILDING.md, CLAUDE.md, CONTRIBUTING.md, README.md, releases/, scripts/, site/, templates/, tools/, wiki/, design/ #root

## Relations
- implements [[Scarf Architecture Rules]]
