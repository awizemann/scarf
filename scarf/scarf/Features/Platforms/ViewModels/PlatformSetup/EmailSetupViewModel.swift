import Foundation
import ScarfCore

/// Email setup. IMAP/SMTP with app passwords — no OAuth.
/// Field reference: https://hermes-agent.nousresearch.com/docs/user-guide/messaging/email
@Observable
@MainActor
final class EmailSetupViewModel {
    let context: ServerContext

    init(context: ServerContext = .local) {
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

    func load() {
        let env = HermesEnvService(context: context).load()
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
        // skip_attachments lives in config.yaml.
        let yaml = context.readText(context.paths.configYAML) ?? ""
        let parsed = HermesFileService.parseNestedYAML(yaml)
        skipAttachments = (parsed.values["platforms.email.skip_attachments"] ?? "false") == "true"
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
            "platforms.email.skip_attachments": PlatformSetupHelpers.envBool(skipAttachments)
        ]
        message = PlatformSetupHelpers.saveForm(context: context, envPairs: envPairs, configKV: configKV)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.message = nil
        }
    }
}
