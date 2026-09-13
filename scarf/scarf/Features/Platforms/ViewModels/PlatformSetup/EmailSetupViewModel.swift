import Foundation
import ScarfCore

/// Email setup. IMAP/SMTP with app passwords — no OAuth.
/// Field reference: https://hermes-agent.nousresearch.com/docs/user-guide/messaging/email
@Observable
@MainActor
final class EmailSetupViewModel: PlatformSetupForm {
    let context: ServerContext

    /// C10 test seam — nil in production. See ``PlatformSetupForm``.
    let cliRunner: HermesCLIRunner?
    /// Load/save in-flight flags owned by ``PlatformSetupForm``.
    var isLoading = false
    var isSaving = false
    /// Latched load refusal owned by ``PlatformSetupForm`` — set when a
    /// `.env` / config.yaml read could not be proved, and what makes
    /// `commitSave` refuse rather than publish blanks (P33).
    var loadRefusal: String?
    init(context: ServerContext = .local, cliRunner: HermesCLIRunner? = nil) {
        self.cliRunner = cliRunner
        self.context = context
    }

    var address: String = ""
    var password: String = ""
    var imapHost: String = ""
    var smtpHost: String = ""
    var imapPort: String = "993"
    var smtpPort: String = "587"
    var pollInterval: String = "15"
    var allowedUsers: String = ""
    var homeAddress: String = ""
    var allowAllUsers: Bool = false
    var skipAttachments: Bool = false

    var message: String?
    /// Outcome of `message` (GW-F4) — the save bar's colour, glyph and
    /// VoiceOver announcement come from this, never from the prose.
    var messageIsFailure = false
    /// P54b: the third seal state — an exit-0 run that proved nothing.
    var messageIsUnconfirmed = false

    /// Common provider presets so users don't have to look up IMAP/SMTP servers.
    struct Preset {
        let name: String
        let imap: String
        let smtp: String
    }
    let presets: [Preset] = [
        Preset(name: "Gmail", imap: "imap.gmail.com", smtp: "smtp.gmail.com"),
        Preset(name: "Outlook", imap: "outlook.office365.com", smtp: "smtp.office365.com"),
        Preset(name: "iCloud", imap: "imap.mail.me.com", smtp: "smtp.mail.me.com"),
        Preset(name: "Fastmail", imap: "imap.fastmail.com", smtp: "smtp.fastmail.com"),
        Preset(name: "Yahoo", imap: "imap.mail.yahoo.com", smtp: "smtp.mail.yahoo.com")
    ]

    /// Off the main actor (C10) — see ``PlatformSetupForm``. GW-F6 / audit
    /// DI L10: an unreadable `.env` used to arrive as an EMPTY one, so this
    /// form rendered blank fields over live values and a Save then commented
    /// those keys out. Absent is still an empty form; unreadable says so.
    func load() {
        loadSnapshot(includeConfig: false, includeRawConfigText: true) { [weak self] snapshot in
            guard let self else { return }
            let env = snapshot.env
            address = env["EMAIL_ADDRESS"] ?? ""
            password = env["EMAIL_PASSWORD"] ?? ""
            imapHost = env["EMAIL_IMAP_HOST"] ?? ""
            smtpHost = env["EMAIL_SMTP_HOST"] ?? ""
            imapPort = env["EMAIL_IMAP_PORT"] ?? "993"
            smtpPort = env["EMAIL_SMTP_PORT"] ?? "587"
            pollInterval = env["EMAIL_POLL_INTERVAL"] ?? "15"
            allowedUsers = env["EMAIL_ALLOWED_USERS"] ?? ""
            homeAddress = env["EMAIL_HOME_ADDRESS"] ?? ""
            allowAllUsers = PlatformSetupHelpers.parseEnvBool(env["EMAIL_ALLOW_ALL_USERS"])
            // skip_attachments lives in config.yaml, under the platform's
            // `extra:` sub-map. Verified against Hermes **v2026.9.7**:
            // `plugins/platforms/email/adapter.py:354` does
            // `self._skip_attachments = extra.get("skip_attachments", False)`
            // (and carries `# platforms.email.skip_attachments` as its own
            // comment), and `extra` is populated ONLY from the `extra:`
            // sub-key (`gateway/config.py:415::PlatformConfig.from_dict`)
            // plus the shared-key bridge `_SHARED_KEYS`
            // (`gateway/config_loader.py:197-213`) — which does NOT include
            // skip_attachments. The old TOP-LEVEL
            // `platforms.email.skip_attachments` Scarf used to write was
            // therefore never read by Hermes; Scarf's own reader read the
            // same dead key back, so the toggle looked like it worked.
            //
            // Back-compat: the legacy top-level key is still read as a
            // FALLBACK so a user who saved the toggle before this fix keeps
            // their intent on screen; the next save rewrites it to the
            // `extra.` path. The stale top-level key is left in place —
            // Hermes ignores unknown platform keys, and a second
            // `config unset` round-trip on every save isn't worth it.
            // `nil` means the config.yaml read was REFUSED (P33), not that
            // the file is empty — leave the toggle showing whatever it had
            // rather than flipping it to the default over a live `true`.
            // `loadSnapshot` has already put the refusal on the bar and
            // latched the save.
            guard let rawConfigText = snapshot.rawConfigText else { return }
            let parsed = HermesFileService.parseNestedYAML(rawConfigText)
            let raw = parsed.values["platforms.email.extra.skip_attachments"]
                ?? parsed.values["platforms.email.skip_attachments"]
                ?? "false"
            // Hermes reads this as plain Python truthiness over the
            // PyYAML-TYPED value (`extra.get("skip_attachments", False)`,
            // `plugins/platforms/email/adapter.py:354` @ v2026.9.7), so a
            // YAML bool written `yes` / `on` / `1` is ON on the host. The
            // literal `== "true"` read it as OFF — the exact class P18 closed
            // by giving Scarf ONE boolish helper.
            skipAttachments = HermesYAML.boolishValue(raw) ?? false
        }
    }

    func applyPreset(_ preset: Preset) {
        imapHost = preset.imap
        smtpHost = preset.smtp
    }

    func save() {
        let envPairs: [String: String] = [
            "EMAIL_ADDRESS": address,
            "EMAIL_PASSWORD": password,
            "EMAIL_IMAP_HOST": imapHost,
            "EMAIL_SMTP_HOST": smtpHost,
            "EMAIL_IMAP_PORT": imapPort,
            "EMAIL_SMTP_PORT": smtpPort,
            "EMAIL_POLL_INTERVAL": pollInterval,
            "EMAIL_ALLOWED_USERS": allowAllUsers ? "" : allowedUsers,
            "EMAIL_HOME_ADDRESS": homeAddress,
            "EMAIL_ALLOW_ALL_USERS": allowAllUsers ? "true" : ""
        ]
        let configKV: [String: String] = [
            // `extra.` — the only shape the email adapter reads. See load().
            "platforms.email.extra.skip_attachments": PlatformSetupHelpers.envBool(skipAttachments)
        ]
        commitSave(envPairs: envPairs, configKV: configKV)
    }
}
