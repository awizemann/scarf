// MoreViews.jsx — Personalities, Quick Commands, Platforms, Credentials,
// Plugins, Webhooks, Profiles, Gateway. Each is a focused list/detail or grid.

// ─────────────── Personalities ───────────────
const PERSONALITIES = [
  { id: 'forge',  name: 'Forge',  emoji: '⚒',  color: '#C25A2A', desc: 'Engineering pair. Refactors, tests, reviews PRs.', model: 'sonnet-4.5', tools: 14, used: '2m ago' },
  { id: 'hermes', name: 'Hermes', emoji: '✉',  color: '#7E5BA9', desc: 'Operations. Handles ops scripts, summaries, status.', model: 'haiku-4.5',  tools: 8,  used: '32m ago' },
  { id: 'atlas',  name: 'Atlas',  emoji: '◇',  color: '#3F6BA9', desc: 'Long-form writer. Spec drafts, release notes, docs.',  model: 'opus-4.1',   tools: 6,  used: 'yesterday' },
  { id: 'vesta',  name: 'Vesta',  emoji: '✿',  color: '#3F8A6E', desc: 'Design partner. Critiques layouts, suggests patterns.', model: 'sonnet-4.5', tools: 4,  used: '3 days ago' },
  { id: 'gaia',   name: 'Gaia',   emoji: '✱',  color: '#A8741F', desc: 'Researcher. Web search, summarization, citations.',  model: 'sonnet-4.5', tools: 5,  used: '1 week ago' },
];

function Personalities() {
  React.useEffect(() => { requestAnimationFrame(() => window.lucide && window.lucide.createIcons()); });
  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%' }}>
      <ContentHeader title="Personalities"
        subtitle="Pre-configured agents — system prompt, model, allowed tools, defaults"
        actions={<Btn kind="primary" icon="plus">New personality</Btn>} />
      <div style={{ flex: 1, overflowY: 'auto', padding: 32 }}>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(260px, 1fr))', gap: 14 }}>
          {PERSONALITIES.map(p => <PersonalityCard key={p.id} p={p} />)}
          <Card padding={24} interactive style={{ display: 'flex', flexDirection: 'column',
            alignItems: 'center', justifyContent: 'center', minHeight: 180,
            border: '1px dashed var(--border-strong)', background: 'transparent', boxShadow: 'none' }}>
            <div style={{ width: 40, height: 40, borderRadius: 10, background: 'var(--bg-quaternary)',
              display: 'flex', alignItems: 'center', justifyContent: 'center', marginBottom: 8, color: 'var(--fg-muted)' }}>
              <i data-lucide="plus" style={{ width: 20, height: 20 }}></i>
            </div>
            <div style={{ fontSize: 13, fontWeight: 500, color: 'var(--fg-muted)' }}>New personality</div>
          </Card>
        </div>
      </div>
    </div>
  );
}

function PersonalityCard({ p }) {
  return (
    <Card interactive padding={18}>
      <div style={{ display: 'flex', alignItems: 'flex-start', gap: 12, marginBottom: 12 }}>
        <div style={{
          width: 38, height: 38, borderRadius: 9, background: p.color, color: '#fff',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          fontFamily: 'var(--font-display)', fontSize: 18,
        }}>{p.emoji}</div>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontSize: 15, fontWeight: 600 }}>{p.name}</div>
          <div style={{ fontSize: 11, color: 'var(--fg-faint)', fontFamily: 'var(--font-mono)' }}>last used {p.used}</div>
        </div>
        <IconBtn icon="more-horizontal" size={26} />
      </div>
      <div style={{ fontSize: 12.5, color: 'var(--fg-muted)', lineHeight: 1.5, marginBottom: 14, minHeight: 36 }}>{p.desc}</div>
      <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
        <Pill size="sm">{p.model}</Pill>
        <Pill size="sm" icon="wrench">{p.tools} tools</Pill>
      </div>
    </Card>
  );
}

window.Personalities = Personalities;

// ─────────────── Quick Commands ───────────────
const QC = [
  { trigger: '/test',     name: 'Run tests',          desc: 'Run the project test suite, summarize failures.', personality: 'Forge', uses: 142 },
  { trigger: '/review',   name: 'Review PR',          desc: 'Walk the diff in a checked-out PR and post review notes.', personality: 'Forge', uses: 38 },
  { trigger: '/standup',  name: 'Standup summary',    desc: 'Summarize yesterday\'s commits + Linear updates.', personality: 'Hermes', uses: 24 },
  { trigger: '/notes',    name: 'Release notes',      desc: 'Group merged PRs since last tag into release notes.', personality: 'Atlas', uses: 8 },
  { trigger: '/figma',    name: 'Open Figma frame',   desc: 'Resolve a Figma URL and import frame metadata.', personality: 'Vesta', uses: 14 },
  { trigger: '/cite',     name: 'Cite source',        desc: 'Web search + return citations as Markdown footnotes.', personality: 'Gaia', uses: 9 },
];

function QuickCommands() {
  React.useEffect(() => { requestAnimationFrame(() => window.lucide && window.lucide.createIcons()); });
  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%' }}>
      <ContentHeader title="Quick Commands"
        subtitle="Slash-prefixed shortcuts that expand into full prompts"
        actions={<Btn kind="primary" icon="plus">New command</Btn>} />
      <div style={{ flex: 1, overflowY: 'auto', padding: '24px 32px' }}>
        <SettingsGroup>
          {QC.map((q, i) => (
            <div key={q.trigger} style={{
              display: 'flex', alignItems: 'center', gap: 14, padding: '14px 18px',
              borderBottom: i === QC.length - 1 ? 'none' : '0.5px solid var(--border)',
            }}>
              <span style={{
                fontFamily: 'var(--font-mono)', fontSize: 12.5, fontWeight: 600,
                color: 'var(--accent)', background: 'var(--accent-tint)',
                padding: '4px 9px', borderRadius: 6, minWidth: 80, textAlign: 'center',
              }}>{q.trigger}</span>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontSize: 13, fontWeight: 500 }}>{q.name}</div>
                <div style={{ fontSize: 12, color: 'var(--fg-muted)', marginTop: 2 }}>{q.desc}</div>
              </div>
              <Pill size="sm">{q.personality}</Pill>
              <span style={{ fontFamily: 'var(--font-mono)', fontSize: 11, color: 'var(--fg-faint)', width: 70, textAlign: 'right' }}>
                {q.uses} uses
              </span>
              <IconBtn icon="more-horizontal" size={26} />
            </div>
          ))}
        </SettingsGroup>
      </div>
    </div>
  );
}

window.QuickCommands = QuickCommands;

// ─────────────── Platforms ───────────────
const PLATFORMS = [
  { id: 'github',  name: 'GitHub',   desc: 'Repos, issues, PRs', conn: true,  scope: 'org/wizemann · 14 repos' },
  { id: 'linear',  name: 'Linear',   desc: 'Issues & projects', conn: true,  scope: 'wizemann · all teams' },
  { id: 'slack',   name: 'Slack',    desc: 'Messaging',         conn: false, scope: '—' },
  { id: 'notion',  name: 'Notion',   desc: 'Docs',              conn: false, scope: '—' },
  { id: 'figma',   name: 'Figma',    desc: 'Design files',      conn: true,  scope: 'wizemann-design' },
  { id: 'sentry',  name: 'Sentry',   desc: 'Error monitoring',  conn: false, scope: '—' },
  { id: 'pagerduty', name: 'PagerDuty', desc: 'On-call',        conn: false, scope: '—' },
  { id: 'stripe',  name: 'Stripe',   desc: 'Payments',          conn: false, scope: '—' },
];

function Platforms() {
  React.useEffect(() => { requestAnimationFrame(() => window.lucide && window.lucide.createIcons()); });
  const palette = { github: '#1F1B16', linear: '#5E6AD2', slack: '#611F69', notion: '#191919',
    figma: '#F24E1E', sentry: '#362D59', pagerduty: '#06AC38', stripe: '#635BFF' };
  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%' }}>
      <ContentHeader title="Platforms"
        subtitle="Higher-level integrations. Each provides one or more MCP servers and credentials."
        actions={<Btn icon="external-link">Browse marketplace</Btn>} />
      <div style={{ flex: 1, overflowY: 'auto', padding: 32 }}>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(260px, 1fr))', gap: 14 }}>
          {PLATFORMS.map(p => (
            <Card key={p.id} interactive padding={18}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: 14 }}>
                <div style={{
                  width: 38, height: 38, borderRadius: 9, background: palette[p.id] || '#888', color: '#fff',
                  display: 'flex', alignItems: 'center', justifyContent: 'center',
                  fontFamily: 'var(--font-display)', fontSize: 18, fontWeight: 700,
                }}>{p.name[0]}</div>
                <div style={{ flex: 1 }}>
                  <div style={{ fontSize: 14, fontWeight: 600 }}>{p.name}</div>
                  <div style={{ fontSize: 11.5, color: 'var(--fg-muted)' }}>{p.desc}</div>
                </div>
                {p.conn && <Pill tone="green" dot size="sm">on</Pill>}
              </div>
              <div style={{ fontSize: 11, color: 'var(--fg-faint)', fontFamily: 'var(--font-mono)', marginBottom: 12,
                whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{p.scope}</div>
              <Btn fullWidth size="sm" kind={p.conn ? 'secondary' : 'primary'}
                icon={p.conn ? 'settings' : 'plug'}>
                {p.conn ? 'Configure' : 'Connect'}
              </Btn>
            </Card>
          ))}
        </div>
      </div>
    </div>
  );
}

window.Platforms = Platforms;

// ─────────────── Credentials ───────────────
const CREDS = [
  { name: 'ANTHROPIC_API_KEY', kind: 'api-key', source: 'Keychain', last: '2m ago', scope: 'global', value: 'sk-ant-•••••••••a4f2' },
  { name: 'GITHUB_TOKEN',      kind: 'oauth',   source: 'OAuth',    last: '14m ago', scope: 'global', value: 'gho_•••••••••••3kP9' },
  { name: 'LINEAR_TOKEN',      kind: 'oauth',   source: 'OAuth',    last: '2h ago',  scope: 'global', value: 'lin_oauth_•••••8m2x' },
  { name: 'POSTGRES_URL',      kind: 'secret',  source: 'env (.env)', last: '4h ago', scope: 'project · sera', value: 'postgres://ro@•••' },
  { name: 'OPENAI_API_KEY',    kind: 'api-key', source: 'Keychain', last: 'never',   scope: 'global', value: 'sk-•••••••••••L7Pw' },
  { name: 'AWS_ACCESS_KEY_ID', kind: 'secret',  source: '~/.aws/credentials', last: '1d ago', scope: 'global', value: 'AKIA•••••••••QZX' },
];

function Credentials() {
  React.useEffect(() => { requestAnimationFrame(() => window.lucide && window.lucide.createIcons()); });
  const [reveal, setReveal] = React.useState({});
  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%' }}>
      <ContentHeader title="Credentials"
        subtitle="API keys, OAuth tokens, and secrets the agent can read. Stored in OS keychain by default."
        actions={<Btn kind="primary" icon="plus">Add credential</Btn>} />
      <div style={{ flex: 1, overflowY: 'auto', padding: '24px 32px' }}>
        <div style={{
          background: 'var(--accent-tint)', border: '0.5px solid var(--accent)',
          borderRadius: 9, padding: 12, marginBottom: 20, display: 'flex', alignItems: 'flex-start', gap: 10,
        }}>
          <i data-lucide="shield" style={{ width: 16, height: 16, color: 'var(--accent)', marginTop: 1 }}></i>
          <div style={{ fontSize: 12.5, color: 'var(--fg)', lineHeight: 1.5 }}>
            Credentials are never sent to Anthropic. They're injected into tool calls at the local gateway.
          </div>
        </div>
        <SettingsGroup>
          {CREDS.map((c, i) => (
            <div key={c.name} style={{
              display: 'flex', alignItems: 'center', gap: 14, padding: '14px 18px',
              borderBottom: i === CREDS.length - 1 ? 'none' : '0.5px solid var(--border)',
            }}>
              <i data-lucide={c.kind === 'oauth' ? 'key-round' : c.kind === 'api-key' ? 'key' : 'lock'}
                style={{ width: 16, height: 16, color: 'var(--fg-muted)', flexShrink: 0 }}></i>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontFamily: 'var(--font-mono)', fontSize: 13, fontWeight: 500 }}>{c.name}</div>
                <div style={{ fontSize: 11, color: 'var(--fg-faint)', marginTop: 2 }}>
                  {c.source} · {c.scope} · used {c.last}
                </div>
              </div>
              <code style={{
                fontFamily: 'var(--font-mono)', fontSize: 11.5, color: 'var(--fg-muted)',
                background: 'var(--bg-quaternary)', padding: '3px 8px', borderRadius: 5, width: 220, textAlign: 'center',
              }}>
                {reveal[c.name] ? c.value.replace(/•+/g, '************') : c.value}
              </code>
              <IconBtn icon={reveal[c.name] ? 'eye-off' : 'eye'} size={26}
                onClick={() => setReveal({ ...reveal, [c.name]: !reveal[c.name] })} />
              <IconBtn icon="copy" size={26} />
              <IconBtn icon="trash-2" size={26} />
            </div>
          ))}
        </SettingsGroup>
      </div>
    </div>
  );
}

window.Credentials = Credentials;

// ─────────────── Plugins ───────────────
const PLUGINS = [
  { id: 'commit-message', name: 'Smart commits', desc: 'Generate conventional-commit messages from staged changes.', author: 'wizemann', enabled: true,  hooks: ['pre-commit'] },
  { id: 'review-helper',  name: 'Review helper', desc: 'Auto-tag PR reviewers based on touched paths.', author: 'wizemann', enabled: true,  hooks: ['pr-open'] },
  { id: 'todo-extractor', name: 'TODO extractor', desc: 'Surface inline TODOs as a checklist on the dashboard.', author: 'community', enabled: false, hooks: ['session-start'] },
  { id: 'speak',          name: 'Speak responses', desc: 'Read agent responses aloud via system TTS.', author: 'community', enabled: false, hooks: ['turn-end'] },
];

function Plugins() {
  React.useEffect(() => { requestAnimationFrame(() => window.lucide && window.lucide.createIcons()); });
  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%' }}>
      <ContentHeader title="Plugins"
        subtitle="Local extensions that hook into agent and editor lifecycle events"
        actions={<><Btn icon="external-link">Marketplace</Btn><Btn kind="primary" icon="plus">Install</Btn></>} />
      <div style={{ flex: 1, overflowY: 'auto', padding: '24px 32px' }}>
        <SettingsGroup>
          {PLUGINS.map((p, i) => (
            <div key={p.id} style={{
              display: 'flex', alignItems: 'center', gap: 14, padding: '14px 18px',
              borderBottom: i === PLUGINS.length - 1 ? 'none' : '0.5px solid var(--border)',
            }}>
              <div style={{
                width: 32, height: 32, borderRadius: 7, background: 'var(--accent-tint)', color: 'var(--accent)',
                display: 'flex', alignItems: 'center', justifyContent: 'center',
              }}>
                <i data-lucide="puzzle" style={{ width: 15, height: 15 }}></i>
              </div>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                  <span style={{ fontSize: 13, fontWeight: 500 }}>{p.name}</span>
                  <span style={{ fontSize: 11, color: 'var(--fg-faint)', fontFamily: 'var(--font-mono)' }}>by {p.author}</span>
                </div>
                <div style={{ fontSize: 12, color: 'var(--fg-muted)', marginTop: 2 }}>{p.desc}</div>
                <div style={{ display: 'flex', gap: 4, marginTop: 6 }}>
                  {p.hooks.map(h => <Pill key={h} size="sm">{h}</Pill>)}
                </div>
              </div>
              <Toggle on={p.enabled} />
              <IconBtn icon="more-horizontal" size={26} />
            </div>
          ))}
        </SettingsGroup>
      </div>
    </div>
  );
}

window.Plugins = Plugins;

// ─────────────── Webhooks ───────────────
const WEBHOOKS = [
  { name: 'PR opened → review',   url: 'https://hooks.scarf.local/pr-review',   events: ['github.pr.opened'], status: 'active', last: '2h ago' },
  { name: 'Sentry → triage',      url: 'https://hooks.scarf.local/sentry-triage', events: ['sentry.issue.created', 'sentry.issue.regression'], status: 'active', last: '14m ago' },
  { name: 'Linear cycle → recap', url: 'https://hooks.scarf.local/cycle-recap', events: ['linear.cycle.completed'], status: 'paused', last: '8d ago' },
];

function Webhooks() {
  React.useEffect(() => { requestAnimationFrame(() => window.lucide && window.lucide.createIcons()); });
  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%' }}>
      <ContentHeader title="Webhooks"
        subtitle="External events that trigger an agent run. Each maps an event payload to a personality + prompt."
        actions={<Btn kind="primary" icon="plus">New webhook</Btn>} />
      <div style={{ flex: 1, overflowY: 'auto', padding: '24px 32px' }}>
        <SettingsGroup>
          {WEBHOOKS.map((w, i) => (
            <div key={w.name} style={{
              display: 'flex', alignItems: 'center', gap: 14, padding: '14px 18px',
              borderBottom: i === WEBHOOKS.length - 1 ? 'none' : '0.5px solid var(--border)',
            }}>
              <i data-lucide="webhook" style={{ width: 16, height: 16, color: 'var(--fg-muted)' }}></i>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontSize: 13, fontWeight: 500 }}>{w.name}</div>
                <div style={{ fontSize: 11, color: 'var(--fg-faint)', fontFamily: 'var(--font-mono)', marginTop: 2,
                  whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{w.url}</div>
                <div style={{ display: 'flex', gap: 4, marginTop: 6 }}>
                  {w.events.map(e => <Pill key={e} size="sm">{e}</Pill>)}
                </div>
              </div>
              {w.status === 'active'
                ? <Pill tone="green" dot>active</Pill>
                : <Pill tone="gray" dot>paused</Pill>}
              <span style={{ fontFamily: 'var(--font-mono)', fontSize: 11, color: 'var(--fg-faint)', width: 80, textAlign: 'right' }}>{w.last}</span>
              <IconBtn icon="more-horizontal" size={26} />
            </div>
          ))}
        </SettingsGroup>
      </div>
    </div>
  );
}

window.Webhooks = Webhooks;

// ─────────────── Profiles ───────────────
const PROFILES = [
  { id: 'dev',     name: 'Development',  desc: 'Permissive — auto-approve writes & execs in dev branches.', active: true,  policies: 14 },
  { id: 'review',  name: 'Code review',  desc: 'Read-only filesystem, no execute, network only via MCP.', active: false, policies: 8 },
  { id: 'prod',    name: 'Production',   desc: 'All writes & execs require approval. No deletions.', active: false, policies: 22 },
  { id: 'air-gap', name: 'Air-gapped',   desc: 'No network. Local tools only. For sensitive code paths.', active: false, policies: 6 },
];

function Profiles() {
  React.useEffect(() => { requestAnimationFrame(() => window.lucide && window.lucide.createIcons()); });
  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%' }}>
      <ContentHeader title="Profiles"
        subtitle="Bundles of policies you switch between per-project or per-task"
        actions={<Btn kind="primary" icon="plus">New profile</Btn>} />
      <div style={{ flex: 1, overflowY: 'auto', padding: 32 }}>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(280px, 1fr))', gap: 14 }}>
          {PROFILES.map(p => (
            <Card key={p.id} interactive padding={20}
              style={{ borderColor: p.active ? 'var(--accent)' : 'var(--border)',
                       boxShadow: p.active ? '0 0 0 2px var(--accent-tint)' : 'var(--shadow-sm)' }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 8 }}>
                <i data-lucide="user-cog" style={{ width: 18, height: 18,
                  color: p.active ? 'var(--accent)' : 'var(--fg-muted)' }}></i>
                <div style={{ fontSize: 15, fontWeight: 600, flex: 1 }}>{p.name}</div>
                {p.active && <Pill tone="accent" dot>active</Pill>}
              </div>
              <div style={{ fontSize: 12.5, color: 'var(--fg-muted)', lineHeight: 1.5, marginBottom: 14, minHeight: 36 }}>{p.desc}</div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 11, color: 'var(--fg-faint)', fontFamily: 'var(--font-mono)' }}>
                <i data-lucide="shield" style={{ width: 12, height: 12 }}></i>
                {p.policies} policies
                <Btn size="sm" style={{ marginLeft: 'auto' }}>{p.active ? 'Edit' : 'Activate'}</Btn>
              </div>
            </Card>
          ))}
        </div>
      </div>
    </div>
  );
}

window.Profiles = Profiles;

// ─────────────── Gateway ───────────────
function Gateway() {
  React.useEffect(() => { requestAnimationFrame(() => window.lucide && window.lucide.createIcons()); });
  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%' }}>
      <ContentHeader title="Gateway"
        subtitle="Local proxy that routes every model & tool call. Logs, redacts, enforces policies."
        actions={<Btn icon="rotate-cw">Restart</Btn>} />
      <div style={{ flex: 1, overflowY: 'auto', padding: '24px 32px' }}>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 10, marginBottom: 24 }}>
          <StatCard label="Status" value="running" sub="pid 84021 · uptime 4d 2h" accent="var(--green-600)" />
          <StatCard label="Listening" value=":7421" sub="loopback only" />
          <StatCard label="Calls (24h)" value="1,284" sub="13 denied · 4 errored" />
          <StatCard label="Throughput" value="2.4 MB/s" sub="p95: 6.1 MB/s" />
        </div>

        <SettingsGroup title="Network">
          <SettingsRow icon="globe" title="Listen address"
            description="The gateway binds to this address. Default loopback only."
            control={<TextInput value="127.0.0.1:7421" mono />} />
          <SettingsRow icon="lock" title="TLS"
            description="Use a self-signed cert for outbound to 127.0.0.1."
            control={<Toggle on={true} />} />
          <SettingsRow icon="filter" title="Allowed hosts"
            description="3 entries — api.anthropic.com, mcp.github.com, mcp.linear.app"
            control={<Btn size="sm">Edit</Btn>} last />
        </SettingsGroup>

        <SettingsGroup title="Logging & redaction">
          <SettingsRow icon="file-text" title="Request logging"
            description="Persist headers + bodies for 7 days."
            control={<Toggle on={true} />} />
          <SettingsRow icon="eye-off" title="Redact secrets"
            description="Mask values matching credential patterns before logging."
            control={<Toggle on={true} />} />
          <SettingsRow icon="archive" title="Log retention"
            description="Older logs are pruned automatically."
            control={<Select value="7d" options={[
              { value: '1d', label: '1 day' }, { value: '7d', label: '7 days' },
              { value: '30d', label: '30 days' }, { value: 'forever', label: 'Forever' },
            ]} />} last />
        </SettingsGroup>

        <SettingsGroup title="Performance">
          <SettingsRow icon="zap" title="Concurrent requests"
            control={<TextInput value="16" mono />} />
          <SettingsRow icon="hourglass" title="Per-call timeout"
            control={<Select value="60s" options={[
              { value: '30s', label: '30 seconds' }, { value: '60s', label: '60 seconds' },
              { value: '5m', label: '5 minutes' }, { value: '15m', label: '15 minutes' },
            ]} />} last />
        </SettingsGroup>
      </div>
    </div>
  );
}

window.Gateway = Gateway;
