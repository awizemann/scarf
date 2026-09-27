import Testing
import Foundation
import ScarfCore
@testable import scarf

/// R17: `HermesFileService.configDerivedMultiplexServes`, the wiring R16c
/// added for a root `gateway_state.json` written before the multiplexer
/// stamped `served_profiles`. Hermes then decides from the DEFAULT profile's
/// config — an explicit `multiplex_profiles` opt-in — plus a live default
/// gateway (gateway/status.py:1283-1287, gateway_multiplex_mode.py:53-76 @
/// v2026.9.24). The pure rule is covered in ScarfCore; this drives the real
/// service: its capability read, its root-config read and its pid probe.
@Suite("R17 — config-derived multiplex serving, through HermesFileService")
struct GatewayMultiplexConfigR17Tests {

    typealias Transport = GatewayProcessScopeR07Tests.Transport

    static let root = GatewayProcessScopeR07Tests.root
    static let workHome = GatewayProcessScopeR07Tests.workHome

    /// The root record before `served_profiles` is stamped.
    static let unstampedRoot = #"""
    {"pid": 4242, "gateway_state": "running", "updated_at": "2026-09-27T01:50:28+00:00",
     "platforms": {"telegram": {"state": "connected"},
                   "work:telegram": {"state": "connected"},
                   "work:discord": {"state": "fatal", "error_code": "auth_failed"}}}
    """#

    private static func context() -> ServerContext {
        ServerContext(
            id: UUID(), displayName: "Box",
            kind: .ssh(SSHConfig(host: "r17-multiplex-\(UUID().uuidString).local", remoteHome: workHome,
                                 hermesBinaryHint: "/usr/local/bin/hermes"))
        )
    }

    private static func result(_ stdout: String, _ exit: Int32) -> ProcessResult {
        ProcessResult(exitCode: exit, stdout: Data(stdout.utf8), stderr: Data())
    }

    /// A service over `files`, whose default-profile `pgrep` finds a live
    /// gateway when `defaultLive`, on a host reporting `version`.
    private static func service(
        version: String, rootConfig: String?, defaultLive: Bool
    ) -> (HermesFileService, Transport) {
        var files = [root + "/gateway_state.json": unstampedRoot]
        if let rootConfig { files[root + "/config.yaml"] = rootConfig }
        let transport = Transport(files: files) { exe, args in
            if exe.contains("pgrep"), args.last == HermesGatewayProcessMatch.pgrepPattern(profile: nil) {
                return defaultLive ? result("4242\n", 0) : result("", 1)
            }
            return result("", 1)
        }
        let ctx = context()
        HermesVersionCache.shared.primeForTesting(HermesCapabilities.parse(version), for: ctx)
        return (HermesFileService(context: ctx, transport: transport), transport)
    }

    private static func platforms(_ data: Data?) -> [String: Any]? {
        guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["platforms"] as? [String: Any]
    }

    @Test func anOptedInLiveMultiplexerServesTheProfile() {
        let (svc, _) = Self.service(
            version: "Hermes Agent v0.21.5 (2026.9.24)",
            rootConfig: "multiplex_profiles: true\n", defaultLive: true)
        let plats = Self.platforms(svc.gatewayStateData(own: nil))
        #expect((plats?["telegram"] as? [String: Any])?["state"] as? String == "connected")
        #expect((plats?["discord"] as? [String: Any])?["state"] as? String == "fatal")
    }

    /// The nested spelling Hermes also reads.
    @Test func theGatewayScopedFlagCountsToo() {
        let (svc, _) = Self.service(
            version: "Hermes Agent v0.21.5 (2026.9.24)",
            rootConfig: "gateway:\n  multiplex_profiles: yes\n", defaultLive: true)
        #expect(Self.platforms(svc.gatewayStateData(own: nil)) != nil)
    }

    @Test func noOptInOrAnExplicitNoIsNotServed() {
        for config in [nil, "model:\n  default: x\n", "multiplex_profiles: false\n"] {
            let (svc, _) = Self.service(
                version: "Hermes Agent v0.21.5 (2026.9.24)", rootConfig: config, defaultLive: true)
            #expect(svc.gatewayStateData(own: nil) == nil, Comment(rawValue: "config: \(config ?? "none")"))
        }
    }

    @Test func aDeadDefaultGatewayServesNothing() {
        let (svc, transport) = Self.service(
            version: "Hermes Agent v0.21.5 (2026.9.24)",
            rootConfig: "multiplex_profiles: true\n", defaultLive: false)
        #expect(svc.gatewayStateData(own: nil) == nil)
        #expect(transport.calls.contains { $0.exe.contains("pgrep") }, "the liveness probe never ran")
    }

    /// Below v0.21.4 (no `explicit_multiplex_flag`) nothing extra is read or
    /// probed, and the answer is the one older Scarf gave (C1).
    @Test func anOlderHostProbesNothing() {
        let (svc, transport) = Self.service(
            version: "Hermes Agent v0.21.3 (2026.9.14)",
            rootConfig: "multiplex_profiles: true\n", defaultLive: true)
        #expect(svc.gatewayStateData(own: nil) == nil)
        #expect(transport.calls.isEmpty)
    }
}
