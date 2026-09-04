---
title: Path containment for untrusted dirs must resolve symlinks, not just normalize lexically
type: note
permalink: scarf/conventions/path-containment-for-untrusted-dirs-must-resolve-symlinks-not-just-normalize-lexically
tags: [security, miniapps, webkit, convention, gotcha]
created: 2026-06-16
updated: 2026-09-04
---

When serving files out of a directory that untrusted or agent-writable content can populate (the mini-app `scarf-miniapp://` host is the live case), a lexical path-containment check is NOT enough — it's a real escape vector.

## Observations

- [convention] DELETION needs a different containment than reading (S1, 2026-09-04, `ProjectTemplateUninstaller.PathGuard`): resolving the CANDIDATE (as `containedFilePath` does) would also refuse a symlink pointing outside — but a planted link must still be removable AS A LINK. So the delete-side guard resolves only the candidate's PARENT chain (any symlinked component between root and target refuses), admits the link itself, and `removeRecursively` unlinks it instead of descending. Two related-but-distinct helpers; consolidate only if the read/delete asymmetry is preserved. #security

- [gotcha] `NSString.standardizingPath` (and any purely-lexical normalize) resolves `..`/`.`/`~` but does NOT resolve symlinks. A symlink planted inside the served dir (`app/leak -> ~/.hermes/auth.json`) passes a `hasPrefix(base + "/")` check, then `FileManager.contents(atPath:)` reads THROUGH it — leaking secrets into the page DOM. Found in the M2 fresh-eyes review (HIGH); the mini-app dir is agent-writable + template-delivered, so it's plantable. #security
- [fix] Containment for an untrusted dir must (1) lexically reject `..` etc., THEN (2) run BOTH the base and the candidate through `URL(fileURLWithPath:).resolvingSymlinksInPath()` and re-check `hasPrefix`. Resolve BOTH sides, not just the file — otherwise legit serves break when the base itself is under a symlinked prefix (macOS `/tmp` → `/private/tmp`, and test temp dirs under `/var` → `/private/var`). Implemented as `MiniAppAssetResolver.containedFilePath` (ScarfCore); the WebKit scheme handler reads only through it. #fix
- [pattern] Keep the lexical check pure/unit-testable (`resolvedPath`) and add the FS-touching symlink+existence layer as a separate function (`containedFilePath`) so the escape case is unit-testable with a real planted symlink — don't bury it in the WebKit handler where it can't be tested. #testing
- [related] Same review fixed two more: narrowing a mini-app's granted permissions didn't affect a running `WKWebView` (dispatcher captured at mount) — fix is `.id(grantedSet)` on the host so a tighter grant rebuilds it; and `minBridgeVersion` is now enforced at mount (`MiniAppBridge.satisfiesMinBridgeVersion`) instead of being a doc claim with no code. #miniapps

## Relations
- relates_to [[Phase-1 Milestone 1: First-Class Project Object — implementation decisions]]


## T1 (t-09019d73): resolving the path is not enough — the READ must be the thing that was checked

Two extensions of this convention landed for the P8 audit.

**A path check does not survive to the read (SEC-M1).** Every caller here
checked containment on a PATH and opened that path again later — in the
scheme handler's case after an async hop. The mini-app directory is
agent-writable, so the attacker owns both ends of that window: serve a real
file for the check, swap it for a symlink to `~/.hermes/auth.json` before
the read. No amount of path-resolving fixes that; the thing checked has to
BE the thing read.

`MiniAppAssetResolver.readContainedFile` / `readValidated` now do it in one
descriptor: `open(2)` with `O_NOFOLLOW` (final component may not be a
symlink) `| O_NONBLOCK` (a planted fifo would otherwise block the open
forever) `| O_CLOEXEC`, then `fstat` (regular file only; the size cap is
applied to the object actually held), then `F_GETPATH` on the fd — which is
what catches a swapped INTERMEDIATE directory, something `O_NOFOLLOW` says
nothing about — and a final `isSymlinkContained` on that answer. Then read
the fd to EOF. The path is never re-opened.

Deliberate narrowing: this also refuses a symlink pointing somewhere
legitimate INSIDE the base, which `containedFilePath` allowed. There is no
way to tell it from the attack at open time, an asset dir is unpacked from a
zip rather than authored in place, and the cost is a 404 on one file.

Locality is now a precondition rather than an assumption: `open(2)` is on
THIS Mac, so a remote project's path would silently name a different file of
the same name. `readContainedFile(isLocal:)` refuses `.notLocal`, and
`ScarfMiniAppBridge.file.read` checks `serverContext.kind` before calling it
(it previously read local bytes for a remote project — a latent bug).

**Containment is only as good as its ROOT, and the root needs resolving too
(SEC-H1/M3).** `ProjectRootPolicy` was lexical, so a `~/r → /` symlink or the
`/System/Volumes/Data` firmlink spelling of home walked past it. It now
judges the candidate in every spelling that denotes it — literal first (so
ordinary refusals keep their ordinary message), then the physical path, then
the `/private` and `/System/Volumes/Data` variants of both. Three separate
transforms because no single Foundation call produces them:
`resolvingSymlinksInPath` STRIPS `/private` rather than adding it and leaves
the firmlink prefix entirely alone. A refusal found in a resolved spelling is
wrapped as `.resolvesTo(spelling:refusal:)` so the message can say what the
folder really is. Remote roots get the universal rules only — there is no
realpath primitive on `ServerTransport`, and resolving locally answers a
question about the wrong machine.

`ProjectRootPolicy.physicalPath` uses the same deepest-existing-ancestor
trick as `ProjectTemplateUninstaller.PathGuard.physicalPath`, for the same
reason: `resolvingSymlinksInPath` gives up entirely when the leaf is missing,
which would make the verdict depend on whether the folder happened to exist.


## F1: resolving the base is not enough — the base must be ANCHORED once

Resolving both sides closes the "file is a link out" escape. It does not
close "the BASE is a link out", and that is a different bug with the same
shape: `<root>/.scarf/miniapps/<id>` is agent-writable, so an agent can
replace the base DIRECTORY with a symlink to `/Users/me`. Every check that
re-resolves the base at check time — lexical containment, `O_NOFOLLOW`, and
notably the `F_GETPATH` re-check on the open descriptor — then measures
against the relocated base and unanimously agrees the file is contained.
The fd was never the weak part; the thing it was compared to was.

**The rule.** A containment base that lives in an agent-writable tree is
resolved ONCE, proven, and frozen; every later check compares against the
frozen spelling. "Proven" is three conditions:

1. absolute;
2. the owning project root passes `ProjectRootPolicy` at time of use
   (a base is only as meaningful as its root — P8 SEC-H1);
3. `physical(base) == physical(root) + base's lexical tail below root` —
   i.e. NO symlinked component between root and base, the base itself
   included.

Condition 3 is `PathGuard.admits`'s parent-chain rule extended one
component further: `PathGuard` may tolerate a symlinked leaf because it
UNLINKS it, whereas an anchor's leaf is the thing everything else is
measured from. A root under a symlinked prefix (`/tmp` → `/private/tmp`)
still anchors — both sides of the comparison resolve.

**Where it is.** `MiniAppAssetResolver.anchor(baseDirectory:context:)` →
`BaseAnchor` (only that function can mint one, so holding one IS the
proof); `isContained(path:inRealBase:)` is the frozen-base comparison, and
`readContainedFile`/`readValidated` take an anchor. `MiniAppSchemeHandler`
anchors at MOUNT (an anchor re-derived per request is not an anchor);
`ScarfMiniAppBridge.fileRead` anchors per call, where the base is the
project root itself and condition 3 is vacuous.

The four path primitives both guards need (`standardized` / `resolved` /
`physical` / lstat-flavored `exists`) now live in `ScarfCore.PhysicalPath`;
`PathGuard` forwards to them. Two containment guards with two notions of
"where does this path really point" is one too many.
