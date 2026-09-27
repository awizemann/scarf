---
title: Remote hermes resolution: appended install-dir PATH, wrapper hints as shell words, probe on stdin
type: note
permalink: scarf/architecture/remote-hermes-resolution-appended-install-dir-path-wrapper
tags: [transport, ssh, hermes-cli, servers]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Transport/SSHTransport.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesConfigReader.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesPathSet.swift, scarf/Packages/ScarfIOS/Sources/ScarfIOS/CitadelServerTransport.swift, scarf/scarf/Features/Servers/ViewModels/TestConnectionProbe.swift, scarf/scarf/Features/Chat/ViewModels/ChatViewModel.swift]
source_paths_inferred: false
source_sha: d6533b8fc52976a84b6ca58711e874e03fce50fc
created: 2026-09-26
updated: 2026-09-27
---

How the Mac finds and invokes a remote `hermes` after R08 (Hermes v0.21.5 audit S15-F1/F3). Hermes' non-root installer links the command into `~/.local/bin` (`scripts/install.sh:487-494` @ v2026.9.24) and adds it to PATH only from rc files a non-login `sh -c` never reads (`install.sh:2269-2313`).

## Observations
- [invariant] Every Mac SSH spawn (`runProcess` sh -c, `makeProcess`/`streamLines` bash -lc) goes through `SSHTransport.remoteShellCommand`, which puts `HermesConfigReader.pathFallback` (`PATH="$PATH"":$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.hermes/bin"; ` since R16c — the quote closes after `$PATH` because csh/tcsh read `$PATH:` as a variable modifier and fish rejects `${PATH}`; verified under sh/dash/bash/zsh/csh/tcsh/fish) in front of `composedRemoteCommand`. APPENDED, never prepended, so a hermes the shell already resolved keeps winning; iOS Citadel and HermesConfigReader scripts still prepend #path
- [convention] A USER-TYPED `hermesBinaryHint` containing whitespace is a shell fragment (`SSHConfig.hermesBinaryHintFragment` / `HermesPathSet.hermesBinaryIsShellFragment`): `composedRemoteCommand` and Citadel `commandLine` emit it verbatim (as executable OR arg), never through `remotePathArg`; `hermesBinaryProbablyResolvable` returns true for it. A hint Test Connection found is saved with `SSHConfig.hermesBinaryHintIsPath = true` (R16c) and is ALWAYS one word (`HermesPathSet.hermesBinaryShellWord` quotes it for shell text) — a `/Users/Jane Doe/...` path used to run `/Users/Jane` → 127. The key is optional: legacy servers.json entries decode nil and keep the whitespace=words reading; a legacy spaced probed path is fixed by re-adding the server (no edit UI); an older Scarf re-saving the file drops the key #hint
- [gotcha] Never pass a multi-line script as an ssh argv word after `/bin/sh -c`: ssh space-joins argv for the login shell, so only the first line runs in the child sh. Test Connection now pipes its probe to `/bin/sh -s` on stdin (like SSHScriptRunner) #ssh
- [gotcha] Never `.`-source rc files inside a `/bin/sh -s` probe: under dash (Ubuntu) one zsh-syntax line in `.zshrc` exits the whole script, and an rc `read` eats the script from stdin. The probe borrows `"$SHELL" -lc 'printf "__SCARF_PATH__%s" "$PATH"' </dev/null` instead. The line is shared as `TestConnectionProbe.loginPathBorrow`; Remote Diagnostics uses it too since R18c (T6-F2 — it used to source rc files and died under dash), and its hermes checks look for the saved `hermesBinaryHint` (probed path = one word, typed wrapper = first word) (T6-F4) #probe
- [convention] The remote Terminal launches (chat Terminal, Webhooks `gateway setup`) are parsed by the user's own login shell UNWRAPPED, so they share `ServerContext.remoteLoginShellHermesWords(args:)`: PATH/HERMES_HOME go through `env` (csh/tcsh have no `VAR=value cmd`), the PATH word uses the csh/fish-safe quoting, the binary is `hermesBinaryShellWord`. Tests run the text under every shell on the Mac (AuditFollowupsR16cTests). iOS Citadel process/script exec strings and the ACP launch are now wrapped as ONE `/bin/sh -c '<cmd>'` word (`CitadelServerTransport.viaPOSIXShell`, R17), like the Mac's SSHTransport; residual on csh/tcsh (both platforms): `!` history expansion and a newline inside the single-quoted word still fail #terminal

## Relations
- relates_to [[Multi-Server Architecture (Scarf 2.0+)]]
