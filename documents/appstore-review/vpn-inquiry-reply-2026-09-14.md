# App Review reply — "app contains VPN functionality" (automated), 2026-09-14

## What we verified in the repo before answering

- `Scarf_iOS.entitlements` is empty: no Network Extension, no Personal VPN, no packet-tunnel entitlement.
- No `NetworkExtension` / `NEVPN*` / `NETunnelProvider` symbols anywhere in the iOS target, ScarfIOS, or ScarfCore.
- The word "VPN" appears nowhere in code, strings, or the review packet. "Tailscale" appears only in three code comments describing a customer network condition.
- Likely trigger: the pure-Swift SSH stack (Citadel 0.12 + swift-nio-ssh). NIOSSH ships symbols for the SSH protocol's `direct-tcpip` / `forwarded-tcpip` channel types (port forwarding) because they are part of RFC 4254. ScarfGo never opens those channel types; it uses only `session` channels (exec) and the SFTP subsystem.

## Reply to paste into App Store Connect (and into App Review Information → Notes)

ScarfGo does not contain VPN functionality, and we are confirming that here as requested.

ScarfGo is a remote-control client for a self-hosted AI agent ("Hermes"). It connects to a server the user owns over a standard SSH connection (like a terminal or SFTP client) to run commands and read files on that server. It does not:

- use the Network Extension framework or any Personal VPN, Packet Tunnel, App Proxy, or Content Filter entitlement (the app's entitlements file is empty);
- route, intercept, filter, or proxy any traffic from the device or from other apps;
- change the device's network configuration or install any VPN profile;
- perform SSH port forwarding or tunneling of any kind.

We believe the automated analysis flagged the SSH client library we bundle (Citadel, built on Apple's open-source swift-nio-ssh). That library implements the full SSH protocol, which includes port-forwarding message types, and those symbols are present in the binary even though ScarfGo never uses them. All the app's network activity is a direct SSH session to a single user-specified host.

For completeness, since no VPN exists there is no data collected "using VPN": ScarfGo collects no user information at all. It has no accounts, no analytics service, and no third-party SDKs that transmit data. The only data leaving the device is the SSH traffic to the user's own server, and the only data stored on the device is the user's server address and SSH key, kept in the iOS Keychain. Nothing is shared with any third party.

## Also do in App Store Connect

1. App Review Information → Notes: prepend the reply above to the existing reviewer instructions.
2. App Privacy: confirm it says "Data Not Collected" (consistent with the reply).
3. Check the App Store description and keywords contain no "VPN", "tunnel", or "Tailscale" wording; those words alone can trip the same scanner.
