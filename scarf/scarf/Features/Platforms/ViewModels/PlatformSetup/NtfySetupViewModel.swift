import Foundation
import ScarfCore
import os

/// ntfy setup (Hermes v0.15, 23rd platform). Pub/sub push via an
/// ntfy.sh-compatible server.
///
/// `topic` + `server` are settable via env (`NTFY_TOPIC` /
/// `NTFY_SERVER_URL`), which win over config.yaml. `publish_topic`,
/// and `markdown` live under `platforms.ntfy.extra` in config.yaml. `token`
/// is a bearer token, or `user:pass` for HTTP Basic auth, and Scarf keeps it
/// in `.env` as `NTFY_TOKEN` so it never crosses a command line — see
/// `save()`.
///
/// Field reference: https://hermes-agent.nousresearch.com/docs/user-guide/messaging/ntfy
@Observable
@MainActor
final class NtfySetupViewModel {
    let context: ServerContext
    init(context: ServerContext = .local) { self.context = context }

    // Required
    var topic: String = ""
    // Optional
    var server: String = "https://ntfy.sh"
    var publishTopic: String = ""
    var token: String = ""
    var markdown: Bool = false

    var message: String?

    func load() {
        let env = HermesEnvService(context: context).load()
        let cfg = HermesFileService(context: context).loadConfig().ntfy

        // env wins over config.yaml for topic + server.
        topic = env["NTFY_TOPIC"] ?? cfg.topic
        server = env["NTFY_SERVER_URL"] ?? (cfg.server.isEmpty ? "https://ntfy.sh" : cfg.server)
        publishTopic = cfg.publishTopic
        // config.yaml wins in Hermes (`extra.get("token") or NTFY_TOKEN`),
        // so read it first — a token left there by an older Scarf or by hand
        // is what the adapter will actually use. Save migrates it to .env.
        token = cfg.token.isEmpty ? (env["NTFY_TOKEN"] ?? "") : cfg.token
        markdown = cfg.markdown
    }

    func save() {
        let envPairs: [String: String] = [
            "NTFY_TOPIC": topic,
            // Don't persist the default server as an env override.
            "NTFY_SERVER_URL": server == "https://ntfy.sh" ? "" : server,
            // The token goes through .env, NOT `hermes config set`.
            // `config set` puts the value in argv, and on a remote host every
            // local user can read another process's argv out of /proc — so
            // the secret leaks for the lifetime of the call. The .env path
            // writes through the transport (0600, no argv) instead. Hermes
            // reads `_get_scoped_secret("NTFY_TOKEN")` as the fallback when
            // `extra.token` is empty, which is why the config key below is
            // explicitly CLEARED rather than merely left alone: it wins over
            // the env var, so a stale value there would shadow this one.
            "NTFY_TOKEN": token
        ]
        let configKV: [String: String] = [
            "platforms.ntfy.extra.topic": topic,
            "platforms.ntfy.extra.server": server,
            "platforms.ntfy.extra.publish_topic": publishTopic,
            "platforms.ntfy.extra.token": "",
            "platforms.ntfy.extra.markdown": PlatformSetupHelpers.envBool(markdown)
        ]
        message = PlatformSetupHelpers.saveForm(context: context, envPairs: envPairs, configKV: configKV)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.message = nil
        }
    }
}
