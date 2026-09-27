---
id: t-3ce7e7ca
title: R16c Audit follow-ups: remote shells, binary hint, credentials, providers
status: done
added: 2026-09-27
priority: high
---

## Description

From R14 audit: F1 (P2, reproduced) remote Terminal paths fail on csh/tcsh: `env PATH="$PATH:..."` → use "${PATH}:..." everywhere pathFallback is spliced into text a login shell parses (ChatViewModel.swift:3252-3253, GatewaySetupTerminalCommand.swift:31, HermesConfigReader.pathFallback :37) — test with tcsh, dash, bash, zsh if available; F2 probed hermes path with a space saved unquoted → treated as a shell fragment → 127 (AddServerViewModel.swift:125-126, HermesPathSet.swift:158-163, ServerContext.hermesBinaryProbablyResolvable :479) — distinguish probed paths from user-typed wrappers; F3 credential hint ignores provider aliases (HermesProviderCredentials.swift:73-77 vs auth.py:1315-1330: hf, hugging-face, github, github-copilot, github-models); doc drift: MCPLoginController cites SSHTransport.swift:693-716 (now ~744-770); HermesCapabilities.swift:709-710 comment says agent.approval_mode = yolo → approvals.mode: off; R03 residual: nvidia natively uses vendor/model ids — verify at tag and add the preflight skip if Hermes passes them through; two write-plan callers pass .empty capabilities (ChatViewModel ~834, CredentialPoolsView ~1213) — pass real capabilities; S03-F5 tests for the remote /scarf-* bootstrap positive paths (install, once per host, retry after failure, missing-home skip); R02 carry-over: local default-bot context drift when host sticky active_profile changes after pinning — investigate and fix if real; S07-F2 residual: config-derived fallback for pre-served_profiles gateway records (Hermes status.py:1285).

## Plan

R16c plan (worktree Scarf-wt/r16c, branch fix/hermes-v0215-audit-r16c).
- F1 csh/tcsh: HermesConfigReader.pathFallback + pathPrelude use "${PATH}" (csh reads `$PATH:` as a modifier; reproduced under /bin/tcsh "Bad : modifier"). Covers SSHTransport (inside sh -c, harmless) and the two Terminal argv builders (ChatViewModel.launchTerminal, GatewaySetupTerminalCommand) that the login shell parses directly. Test: run the generated remote command text under tcsh, csh, dash, bash, zsh (root + named profile) with a fake hermes.
- F2 probed binary path with spaces: SSHConfig gains `hermesBinaryHintIsPath: Bool?` (true = found by Test Connection → always one word; nil/false = user-typed → words when it has whitespace, as today). HermesPathSet carries it; one predicate (hermesBinaryIsShellFragment) + one shell-word helper feed SSHTransport, CitadelServerTransport, ServerContext.hermesBinaryProbablyResolvable, the two Terminal builders and the /bin/sh script callers. Migration: legacy entries decode as nil → today's reading (every working wrapper keeps working); a legacy spaced probed path was already failing and is fixed by re-adding with Test Connection (no edit UI exists). Tests: codable round-trip + legacy decode, command text under real shells with a spaced path, wrapper still words.
- F3: HermesProviderCredentials normalizes model.provider through Hermes' _PROVIDER_ALIASES entries that land on copilot/huggingface/keyless ids (auth.py:1300-1335 @ v2026.9.24, strip().lower() then alias).
- Doc drift: MCPLoginController SSHTransport citation → symbol names; HermesCapabilities hasYOLOWarning comment → approvals.mode: off (tools/approval_context.py:200-236).
- R03 residual nvidia: verified model_normalize never strips for nvidia at any tag (catalogue repair only for bare ids); add unconditional nvidia skip in ModelPreflight.detectMismatch (separate set, not aggregatorProviders so lane 2 unchanged).
- .empty caps: ChatViewModel.stripPrefixFromModelDefault + CredentialPoolsView AddCredentialSheet swap pass real capabilities.
- S03-F5 tests: seam in SlashCommandBootstrapService.bootstrapRemoteIfNeeded (transport + bundle dir injectable) → tests for install, once per host, retry after failure, missing-home skip.
- R02 carry-over: pinnedToProfile on .local returns self (dynamic active_profile home) when the pin equals the currently resolved home → drifts when sticky active_profile changes; fix by always freezing localHomeOverride. Test.
- S07-F2 residual: config-derived fallback (status.py:1283-1287, gateway.py:3680-3687 @ v2026.9.24): root record lacks served_profiles key + explicit multiplex flag true in root config + live root gateway → served. Gate on hasMultiplexByDefault (v0.21.4 floor where explicit_multiplex_flag landed).
Blast radius: every remote spawn text (Mac SSH, iOS Citadel), Terminal launches, servers.json schema (additive optional key), chat preflight banner, credential hint, bot contexts on local, Gateway tab for named profiles.
Memory/wiki to review: remote PATH / binary-hint notes, provider credential hint notes, gateway multiplex note, bot-mode decisions, model preflight notes.

## Artifacts

Merged as 7828d9d8 (7 commits). PATH word verified under sh/bash/zsh/dash/csh/tcsh/fish. iOS csh/tcsh gap → R17. P52 citation drift at gate → R17.

