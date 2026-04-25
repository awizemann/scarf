// MCP Servers — connection list + detail with health, capabilities, and logs.

const MCP_SERVERS = [
  { id: 'github', name: 'GitHub', transport: 'http', url: 'https://mcp.github.com/v1', status: 'connected', tools: 18, prompts: 4, resources: 12, latency: 84, version: '1.4.2', auth: 'oauth', scope: 'org/wizemann' },
  { id: 'linear', name: 'Linear', transport: 'http', url: 'https://mcp.linear.app/sse', status: 'connected', tools: 9, prompts: 0, resources: 6, latency: 142, version: '0.9.1', auth: 'oauth', scope: 'wizemann' },
  { id: 'slack', name: 'Slack', transport: 'http', url: 'https://mcp.slack.com/v1', status: 'auth-required', tools: 0, prompts: 0, resources: 0, latency: null, version: '—', auth: 'oauth', scope: '—' },
  { id: 'postgres-prod', name: 'Postgres (prod, ro)', transport: 'stdio', url: 'mcp-postgres --readonly', status: 'connected', tools: 4, prompts: 0, resources: 28, latency: 12, version: '2.1.0', auth: 'env', scope: 'prod-replica' },
  { id: 'figma', name: 'Figma', transport: 'http', url: 'https://mcp.figma.com/v1', status: 'connected', tools: 6, prompts: 2, resources: 0, latency: 210, version: '0.4.0', auth: 'oauth', scope: 'wizemann-design' },
  { id: 'notion', name: 'Notion', transport: 'http', url: 'https://mcp.notion.so/v1', status: 'error', tools: 0, prompts: 0, resources: 0, latency: null, version: '—', auth: 'oauth', scope: '—', error: 'TLS handshake failed (timeout 5s)' },
  { id: 'sentry', name: 'Sentry', transport: 'http', url: 'https://mcp.sentry.io/v1', status: 'disabled', tools: 0, prompts: 0, resources: 0, latency: null, version: '—', auth: 'token', scope: 'wizemann' },
];

const STATUS_TONES = {
  'connected':     { tone: 'green',  label: 'connected' },
  'auth-required': { tone: 'amber',  label: 'auth required' },
  'error':         { tone: 'red',    label: 'error' },
  'disabled':      { tone: 'gray',   label: 'disabled' },
};

function MCPServers() {
  const [active, setActive] = React.useState('github');
  const server = MCP_SERVERS.find(s => s.id === active);
  React.useEffect(() => { requestAnimationFrame(() => window.lucide && window.lucide.createIcons()); });

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%' }}>
      <ContentHeader title="MCP Servers"
        subtitle="Model Context Protocol endpoints — each adds a bundle of tools, prompts, and resources"
        actions={<><Btn icon="rotate-cw">Reconnect all</Btn><Btn kind="primary" icon="plus">Add server</Btn></>} />

      <div style={{ flex: 1, display: 'flex', minHeight: 0 }}>
        <div style={{ width: 320, borderRight: '0.5px solid var(--border)',
          display: 'flex', flexDirection: 'column', background: 'var(--bg-card)' }}>
          <div style={{ flex: 1, overflowY: 'auto', padding: 8 }}>
            {MCP_SERVERS.map(s => <MCPRow key={s.id} s={s} active={s.id === active} onClick={() => setActive(s.id)} />)}
          </div>
          <div style={{ padding: 12, borderTop: '0.5px solid var(--border)' }}>
            <Btn fullWidth icon="hard-drive">Browse marketplace</Btn>
          </div>
        </div>

        <div style={{ flex: 1, overflowY: 'auto', background: 'var(--bg)', padding: '24px 32px' }}>
          <MCPDetail server={server} />
        </div>
      </div>
    </div>
  );
}

function MCPRow({ s, active, onClick }) {
  const status = STATUS_TONES[s.status];
  const [hover, setHover] = React.useState(false);
  return (
    <div onClick={onClick} onMouseEnter={() => setHover(true)} onMouseLeave={() => setHover(false)} style={{
      padding: '11px 12px', borderRadius: 7, cursor: 'pointer', marginBottom: 2,
      background: active ? 'var(--accent-tint)' : (hover ? 'var(--bg-quaternary)' : 'transparent'),
    }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 4 }}>
        <ServerGlyph id={s.id} size={22} />
        <div style={{ flex: 1, fontSize: 13, fontWeight: 500,
          color: active ? 'var(--accent-active)' : 'var(--fg)' }}>{s.name}</div>
        <Dot tone={status.tone} />
      </div>
      <div style={{ fontSize: 11, color: 'var(--fg-faint)', fontFamily: 'var(--font-mono)',
        whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
        {s.transport} · {s.tools} tools · {s.prompts} prompts
      </div>
    </div>
  );
}

function ServerGlyph({ id, size = 22 }) {
  const palette = {
    github: '#1F1B16', linear: '#5E6AD2', slack: '#611F69',
    'postgres-prod': '#336791', figma: '#F24E1E', notion: '#191919', sentry: '#362D59',
  };
  const letter = id[0].toUpperCase();
  return (
    <div style={{
      width: size, height: size, borderRadius: 5, background: palette[id] || '#888',
      color: 'white', display: 'flex', alignItems: 'center', justifyContent: 'center',
      fontFamily: 'var(--font-display)', fontSize: size * 0.5, fontWeight: 700, flexShrink: 0,
    }}>{letter}</div>
  );
}

function MCPDetail({ server }) {
  const status = STATUS_TONES[server.status];
  return (
    <>
      <div style={{ display: 'flex', alignItems: 'flex-start', gap: 14, marginBottom: 20 }}>
        <ServerGlyph id={server.id} size={48} />
        <div style={{ flex: 1 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 4 }}>
            <div className="scarf-h2" style={{ fontSize: 22 }}>{server.name}</div>
            <Pill tone={status.tone} dot>{status.label}</Pill>
            <span style={{ fontSize: 11, color: 'var(--fg-faint)', fontFamily: 'var(--font-mono)' }}>v{server.version}</span>
          </div>
          <div style={{ fontSize: 12, color: 'var(--fg-muted)', fontFamily: 'var(--font-mono)' }}>{server.url}</div>
        </div>
        <div style={{ display: 'flex', gap: 6 }}>
          <Btn icon="rotate-cw">Reconnect</Btn>
          <Toggle on={server.status !== 'disabled'} size="lg" />
        </div>
      </div>

      {server.error && (
        <div style={{
          background: 'var(--red-100)', border: '0.5px solid var(--red-500)',
          borderRadius: 9, padding: 12, marginBottom: 20, display: 'flex', gap: 10, alignItems: 'flex-start',
        }}>
          <i data-lucide="alert-triangle" style={{ width: 16, height: 16, color: 'var(--red-500)', flexShrink: 0, marginTop: 1 }}></i>
          <div>
            <div style={{ fontSize: 13, fontWeight: 500, color: 'var(--red-500)', marginBottom: 2 }}>Connection failed</div>
            <div style={{ fontSize: 12, color: 'var(--fg-muted)', fontFamily: 'var(--font-mono)' }}>{server.error}</div>
          </div>
        </div>
      )}

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 10, marginBottom: 24 }}>
        <StatCard label="Tools" value={server.tools} />
        <StatCard label="Prompts" value={server.prompts} />
        <StatCard label="Resources" value={server.resources} />
        <StatCard label="Latency" value={server.latency != null ? `${server.latency} ms` : '—'} sub={server.latency != null ? 'p95: ' + Math.round(server.latency * 2.4) + ' ms' : '—'} />
      </div>

      <SettingsGroup title="Connection">
        <SettingsRow icon="link" title="Transport"
          description={server.transport === 'http' ? 'HTTP / SSE' : 'Local stdio process'}
          control={<Pill>{server.transport}</Pill>} />
        <SettingsRow icon="key" title="Auth"
          description={server.auth === 'oauth' ? 'OAuth — refreshed automatically' : server.auth === 'env' ? 'Environment variable' : 'Static token'}
          control={<Btn size="sm" icon="external-link">Manage</Btn>} />
        <SettingsRow icon="shield" title="Scope"
          description={`Calls scoped to "${server.scope}".`}
          control={<Btn size="sm">Edit</Btn>} last />
      </SettingsGroup>

      <SettingsGroup title="Capabilities" description="Tools, prompts, and resources advertised by this server.">
        <CapRow icon="wrench" name="list_issues" kind="tool" desc="List repository issues with filters" />
        <CapRow icon="wrench" name="create_pr" kind="tool" desc="Open a pull request from a branch" />
        <CapRow icon="wrench" name="search_code" kind="tool" desc="Full-text search across accessible repos" />
        <CapRow icon="message-square" name="review_pr" kind="prompt" desc="Structured PR review prompt" />
        <CapRow icon="folder" name="repo://*" kind="resource" desc="Read-only access to repo file trees" last />
      </SettingsGroup>

      <SettingsGroup title="Activity log" description="Last 5 events from this server.">
        <LogLine when="2m ago" level="info" msg="tools/list returned 18 tools (84ms)" />
        <LogLine when="14m ago" level="info" msg="github__list_issues invoked (owner=wizemann, state=open)" />
        <LogLine when="42m ago" level="warn" msg="rate-limit warning: 4500/5000 used this hour" />
        <LogLine when="1h ago"  level="info" msg="oauth token refreshed" />
        <LogLine when="3h ago"  level="info" msg="connection established (TLS 1.3)" last />
      </SettingsGroup>

      <SettingsGroup title="Danger zone" tone="danger">
        <SettingsRow icon="x-circle" title="Disconnect server"
          description="Remove this server. Tools it provided will become unavailable."
          control={<Btn size="sm" kind="danger">Disconnect</Btn>} last />
      </SettingsGroup>
    </>
  );
}

function CapRow({ icon, name, kind, desc, last }) {
  const tones = { tool: 'blue', prompt: 'purple', resource: 'green' };
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 12, padding: '11px 18px',
      borderBottom: last ? 'none' : '0.5px solid var(--border)',
    }}>
      <i data-lucide={icon} style={{ width: 14, height: 14, color: 'var(--fg-muted)', flexShrink: 0 }}></i>
      <div style={{ fontFamily: 'var(--font-mono)', fontSize: 12.5, color: 'var(--fg)', minWidth: 140 }}>{name}</div>
      <div style={{ flex: 1, fontSize: 12, color: 'var(--fg-muted)' }}>{desc}</div>
      <Pill tone={tones[kind]} size="sm">{kind}</Pill>
    </div>
  );
}

function LogLine({ when, level, msg, last }) {
  const tones = { info: 'var(--fg-faint)', warn: 'var(--amber-500)', error: 'var(--red-500)' };
  return (
    <div style={{
      display: 'flex', gap: 12, padding: '8px 18px', fontFamily: 'var(--font-mono)', fontSize: 11.5,
      borderBottom: last ? 'none' : '0.5px solid var(--border)',
    }}>
      <span style={{ color: 'var(--fg-faint)', width: 80 }}>{when}</span>
      <span style={{ color: tones[level], textTransform: 'uppercase', width: 44, fontSize: 10, fontWeight: 600, paddingTop: 1 }}>{level}</span>
      <span style={{ color: 'var(--fg-muted)', flex: 1 }}>{msg}</span>
    </div>
  );
}

window.MCPServers = MCPServers;
