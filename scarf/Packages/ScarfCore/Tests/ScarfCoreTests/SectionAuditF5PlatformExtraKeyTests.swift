import Testing
import Foundation
@testable import ScarfCore

/// F5 / CONFIGURE-1 — platform config keys that live in the adapter's
/// `extra:` sub-map.
///
/// Hermes builds `PlatformConfig.extra` from exactly two sources
/// (`gateway/config.py`, tag `v2026.8.31`):
///
/// 1. the platform section's literal `extra:` sub-key
///    (`PlatformConfig.from_dict`), and
/// 2. a HARDCODED list of "shared" keys bridged up from the section's top
///    level (`load_gateway_config`, ~lines 1700-1766, applied by
///    `extra.update(bridged)` at :1809).
///
/// A key in neither place is a silent no-op no matter how sensible the
/// top-level spelling looks. `require_mention` IS in the bridge list
/// (config.py:1719-1720); `skip_attachments` is NOT — which is why the
/// email toggle needed moving under `extra.` and the slack one did not.
struct SectionAuditF5PlatformExtraKeyTests {

    // MARK: - email: skip_attachments (fixed — was a dead top-level key)

    /// The shape Scarf now WRITES (`platforms.email.extra.skip_attachments`)
    /// must survive back through the flattening reader the Email setup VM
    /// uses. Adapter read site: `plugins/platforms/email/adapter.py:565`
    /// — `extra.get("skip_attachments", False)`.
    @Test func emailSkipAttachmentsRoundTripsUnderExtra() {
        let yaml = """
        platforms:
          email:
            extra:
              skip_attachments: true
        """
        let parsed = HermesYAML.parseNestedYAML(yaml)
        #expect(parsed.values["platforms.email.extra.skip_attachments"] == "true")
    }

    @Test func emailSkipAttachmentsFalseRoundTripsUnderExtra() {
        let yaml = """
        platforms:
          email:
            extra:
              skip_attachments: false
        """
        let parsed = HermesYAML.parseNestedYAML(yaml)
        #expect(parsed.values["platforms.email.extra.skip_attachments"] == "false")
    }

    /// Back-compat: a config.yaml saved by a PRE-fix Scarf carries the key
    /// at the platform's top level. The VM falls back to it so the toggle
    /// keeps showing the user's intent (and the next save rewrites it to
    /// the live `extra.` path). This pins that the legacy key is still
    /// distinguishable — i.e. the fallback has something to read.
    @Test func emailSkipAttachmentsLegacyTopLevelKeyIsStillParsed() {
        let yaml = """
        platforms:
          email:
            skip_attachments: true
        """
        let parsed = HermesYAML.parseNestedYAML(yaml)
        #expect(parsed.values["platforms.email.extra.skip_attachments"] == nil)
        #expect(parsed.values["platforms.email.skip_attachments"] == "true")
    }

    /// The two shapes must not collide: when both are present the reader
    /// has to be able to tell them apart, since Hermes honors only `extra`.
    @Test func emailSkipAttachmentsBothShapesAreDistinct() {
        let yaml = """
        platforms:
          email:
            skip_attachments: true
            extra:
              skip_attachments: false
        """
        let parsed = HermesYAML.parseNestedYAML(yaml)
        #expect(parsed.values["platforms.email.skip_attachments"] == "true")
        #expect(parsed.values["platforms.email.extra.skip_attachments"] == "false")
    }

    // MARK: - slack: require_mention (REFUTED — top level is bridged)

    /// Scarf writes `platforms.slack.require_mention` (top level in the
    /// slack section). That is NOT dead: config.py:1719-1720 bridges it
    /// into `extra`, and the slack plugin's `_apply_yaml_config` hook also
    /// exports SLACK_REQUIRE_MENTION. The adapter's read site is
    /// `plugins/platforms/slack/adapter.py:9058`
    /// (`self.config.extra.get("require_mention")`), which the bridge fills.
    /// This pins the shape Scarf writes staying readable.
    @Test func slackRequireMentionRoundTripsAtTopLevel() {
        let cfg = HermesConfig(yaml: """
        platforms:
          slack:
            require_mention: false
        """)
        #expect(cfg.slack.requireMention == false)
    }

    /// A config.yaml hand-written in the adapter's own shape must ALSO be
    /// read, or Scarf renders the default and then overwrites the user's
    /// value on the next save.
    @Test func slackRequireMentionRoundTripsUnderExtra() {
        let cfg = HermesConfig(yaml: """
        platforms:
          slack:
            extra:
              require_mention: false
        """)
        #expect(cfg.slack.requireMention == false)
    }

    /// Precedence must mirror Hermes: `extra.update(bridged)` lets the
    /// TOP-LEVEL value overwrite the `extra:` one, so top level wins.
    @Test func slackRequireMentionTopLevelWinsOverExtra() {
        let cfg = HermesConfig(yaml: """
        platforms:
          slack:
            require_mention: true
            extra:
              require_mention: false
        """)
        #expect(cfg.slack.requireMention == true)
    }

    /// Default with nothing configured stays `true` (Hermes' own default).
    @Test func slackRequireMentionDefaultsTrue() {
        #expect(HermesConfig(yaml: "").slack.requireMention == true)
    }
}
