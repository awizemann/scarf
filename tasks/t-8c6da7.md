---
id: t-8c6da7
title: macOS: manual "Hermes binary" override in Add Remote Server (Advanced disclosure) — user-supplied `hermesBinaryHint` wins over the auto-probe; TestConnectionProbe sources login rc files and resolves the hint's first token via `command -v` before falling back to surfacing the hint verbatim. Edit-server affordance still open
status: done
added: 2026-06-02
source: gh#105
---

## Description

> Imported from gh#105 — https://github.com/awizemann/scarf/issues/105

## Is your feature request related to a problem?

In a sense. When testing a connection to a remote server [running Hermes via Docker](https://hermes-agent.nousresearch.com/docs/user-guide/docker), I don't have Hermes on the `$PATH` whatsoever, yet get connection error `hermes binary not found in remote $PATH`.

My setup is to have a shell function that exposes `hermes` as a command for Scarf to find:

```sh
hermes ()
{
    ( cd ~/hermes && docker compose exec hermes hermes "$@" )
}
```

This shows the error when *testing* the connection, ~~but if I save the server configuration anyway and connect, the connection succeeds without issue, showing that an explicit `$PATH` check isn't required, rather whether the command is available at all (as an executable, function, alias, etc.) is all that is necessary.~~

**Update:** Scarf isn't essentially at all for me here; even though it connected fine. It's very odd since it is clearly able to run `hermes status`, as it was able to pull the default model, provider, and gateway status with the correct information:

<img width="1212" height="812" alt="Image" src="https://github.com/user-attachments/assets/d4e2db63-34e8-451c-bac4-699a748f885d" />

Even with this, the UI flashes every ~10 seconds or so trying to refresh:

<img width="1212" height="812" alt="Image" src="https://github.com/user-attachments/assets/a58664dd-21cf-431a-b869-1b06b931e7a4" />

which makes it unusable for me here.

The weird part is, the diagnostics UI says `hermes couldn't be located even after sourcing login rc files. Install path is non-standard — set the hermes binary path manually in Manage Servers`:

<img width="1212" height="824" alt="Image" src="https://github.com/user-attachments/assets/fce6ad3d-0b60-45b5-950b-792932f9a708" />

, yet there is nowhere to set the hermes binary path when creating a server:

<img width="1212" height="849" alt="Image" src="https://github.com/user-attachments/assets/33cd7fdb-1b44-4488-8214-80edd1a2f95b" />

Aside: Quite frustrating that there's no way to edit a server connection once created:

<img width="1212" height="812" alt="Image" src="https://github.com/user-attachments/assets/9e1471a6-c162-4ea6-8e5c-dd1be22ea6ac" />

I think there should be some way to edit existing server connections.

## Describe the solution you'd like

1. I would like to see Scarf able to run without `hermes` being available on `$PATH`, enabling flexibility for both Dockerised and non-Dockerised setups.
2. I would like to see a way of editing existing server connections.

Until (1) is added, I don't believe there's any reliable way for me to use Scarf with my Hermes setup unfortunately.

## Plan



## Artifacts



