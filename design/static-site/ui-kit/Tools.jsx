// Tools — registry of every callable tool, with status, kind, and a
// permission policy. Two-pane: list of tools (left), detail (right).

const TOOL_KIND_TONES = {
  read:    { color: 'var(--green-500)',       tint: 'var(--green-100)',  icon: 'book-open' },
  edit:    { color: 'var(--blue-500)',        tint: 'var(--blue-100)',   icon: 'file-edit' },
  execute: { color: 'var(--orange-500)',      tint: 'var(--orange-100)', icon: 'terminal' },
  fetch:   { color: 'var(--purple-tool-500)', tint: '#EFE0F8',           icon: 'globe' },
  browser: { color: 'var(--indigo-500)',      tint: '#E0E5F8',           icon: 'compass' },
  mcp:     { color: 'var(--accent)',          tint: 'var(--accent-tint)',icon: 'server' },
};

const TOOLS_DATA = [
  // Built-in
  { id: 'read_file', kind: 'read', source: 'built-in', server: '—', enabled: true, calls7d: 1284, lastUsed: '2m ago', policy: 'auto', desc: 'Read a file from disk by path. Honors hidden-file setting.' },
  { id: 'write_file', kind: 'edit', source: 'built-in', server: '—', enabled: true, calls7d: 412, lastUsed: '14m ago', policy: 'approve-write', desc: 'Write content to a file, creating parent directories as needed.' },
  { id: 'apply_patch', kind: 'edit', source: 'built-in', server: '—', enabled: true, calls7d: 348, lastUsed: '14m ago', policy: 'approve-write', desc: 'Apply a unified-diff patch to existing files.' },
  { id: 'list_files', kind: 'read', source: 'built-in', server: '—', enabled: true, calls7d: 928, lastUsed: '32m ago', policy: 'auto', desc: 'List entries in a directory, optionally recursive.' },
  { id: 'execute', kind: 'execute', source: 'built-in', server: '—', enabled: true, calls7d: 661, lastUsed: '14m ago', policy: 'approve-exec', desc: 'Run a shell command. Subject to gateway approval policy.' },
  { id: 'web_fetch', kind: 'fetch', source: 'built-in', server: '—', enabled: true, calls7d: 184, lastUsed: '1h ago', policy: 'auto', desc: 'Fetch a URL and return the extracted text.' },
  { id: 'web_search', kind: 'fetch', source: 'built-in', server: '—', enabled: true, calls7d: 92, lastUsed: '3h ago', policy: 'auto', desc: 'Search the public web. Returns top 10 results.' },
  { id: 'browser_navigate', kind: 'browser', source: 'built-in', server: '—', enabled: false, calls7d: 0, lastUsed: 'never', policy: 'approve-all', desc: 'Drive a Chromium instance for live page interaction.' },
  // MCP
  { id: 'github__list_issues', kind: 'mcp', source: 'mcp', server: 'github', enabled: true, calls7d: 84, lastUsed: '42m ago', policy: 'auto', desc: 'List issues for a GitHub repository the user has access to.' },
  { id: 'github__create_pr',   kind: 'mcp', source: 'mcp', server: 'github', enabled: true, calls7d: 12, lastUsed: 'yesterday', policy: 'approve-write', desc: 'Open a pull request from a branch.' },
  { id: 'linear__list_issues', kind: 'mcp', source: 'mcp', server: 'linear', enabled: true, calls7d: 38, lastUsed: '2h ago', policy: 'auto', desc: 'Query Linear issues with filters.' },
  { id: 'slack__send_message', kind: 'mcp', source: 'mcp', server: 'slack', enabled: false, calls7d: 0, lastUsed: 'never', policy: 'approve-all', desc: 'Post a message to a Slack channel as the connected user.' },
  { id: 'postgres__query',     kind: 'mcp', source: 'mcp', server: 'postgres-prod', enabled: true, calls7d: 14, lastUsed: '4h ago', policy: 'approve-write', desc: 'Run read-only SQL against the configured database.' },
];

function Tools() {
  const [active, setActive] = React.useState('execute');
  const [filter, setFilter] = React.useState('all');
  const [search, setSearch] = React.useState('');
  React.useEffect(() => { requestAnimationFrame(() => window.lucide && window.lucide.createIcons()); });

  const filtered = TOOLS_DATA.filter(t => {
    if (filter === 'enabled' && !t.enabled) return false;
    if (filter === 'mcp' && t.source !== 'mcp') return false;
    if (filter === 'builtin' && t.source !== 'built-in') return false;
    if (search && !t.id.toLowerCase().includes(search.toLowerCase())) return false;
    return true;
  });
  const tool = TOOLS_DATA.find(t => t.id === active) || TOOLS_DATA[0];

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%' }}>
      <ContentHeader title="Tools"
        subtitle="Every callable tool the agent can use, plus their gateway policy"
        actions={<><Btn icon="rotate-cw">Sync</Btn><Btn kind="primary" icon="plus">Register tool</Btn></>} />

      <div style={{ flex: 1, display: 'flex', minHeight: 0 }}>
        {/* List */}
        <div style={{ width: 380, borderRight: '0.5px solid var(--border)',
          display: 'flex', flexDirection: 'column', background: 'var(--bg-card)' }}>
          <div style={{ padding: '14px 14px 8px', display: 'flex', flexDirection: 'column', gap: 10 }}>
        <TextInput value={search} onChange={setSearch} leftIcon="search" placeholder="Search tools…" mono />
            <Segmented value={filter} onChange={setFilter} size="sm" options={[
              { value: 'all', label: 'All', count: TOOLS_DATA.length },
              { value: 'enabled', label: 'Enabled', count: TOOLS_DATA.filter(t => t.enabled).length },
              { value: 'mcp', label: 'MCP', count: TOOLS_DATA.filter(t => t.source === 'mcp').length },
              { value: 'builtin', label: 'Built-in', count: TOOLS_DATA.filter(t => t.source === 'built-in').length },
            ]} />
          </div>
          <div style={{ flex: 1, overflowY: 'auto', padding: '0 6px 8px' }}>
            <ToolGroupHeader>Built-in</ToolGroupHeader>
            {filtered.filter(t => t.source === 'built-in').map(t =>
              <ToolRow key={t.id} t={t} active={t.id === active} onClick={() => setActive(t.id)} />
            )}
            <ToolGroupHeader>MCP servers</ToolGroupHeader>
            {filtered.filter(t => t.source === 'mcp').map(t =>
              <ToolRow key={t.id} t={t} active={t.id === active} onClick={() => setActive(t.id)} />
            )}
          </div>
        </div>

        {/* Detail */}
        <div style={{ flex: 1, overflowY: 'auto', background: 'var(--bg)', padding: '24px 32px' }}>
          <ToolDetail tool={tool} />
        </div>
      </div>
    </div>
  );
}

function ToolGroupHeader({ children }) {
  return (
    <div style={{
      padding: '12px 10px 4px', fontSize: 10, fontWeight: 600,
      color: 'var(--fg-muted)', textTransform: 'uppercase', letterSpacing: '0.06em',
    }}>{children}</div>
  );
}

function ToolRow({ t, active, onClick }) {
  const tone = TOOL_KIND_TONES[t.kind] || TOOL_KIND_TONES.read;
  const [hover, setHover] = React.useState(false);
  return (
    <div onClick={onClick} onMouseEnter={() => setHover(true)} onMouseLeave={() => setHover(false)} style={{
      padding: '8px 10px', borderRadius: 7, cursor: 'pointer', marginBottom: 1,
      background: active ? 'var(--accent-tint)' : (hover ? 'var(--bg-quaternary)' : 'transparent'),
      display: 'flex', alignItems: 'center', gap: 9,
    }}>
      <div style={{
        width: 24, height: 24, borderRadius: 6, background: tone.tint, color: tone.color,
        display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0,
      }}>
        <i data-lucide={tone.icon} style={{ width: 13, height: 13 }}></i>
      </div>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 13, fontWeight: 500, fontFamily: 'var(--font-mono)',
          color: active ? 'var(--accent-active)' : 'var(--fg)',
          whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{t.id}</div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 11, color: 'var(--fg-faint)', marginTop: 1 }}>
          {t.server !== '—' && <span style={{ fontFamily: 'var(--font-mono)' }}>{t.server}</span>}
          <span>· {t.calls7d.toLocaleString()} calls</span>
        </div>
      </div>
      {t.enabled
        ? <Dot tone="green" />
        : <Dot tone="gray" />}
    </div>
  );
}

function ToolDetail({ tool }) {
  const tone = TOOL_KIND_TONES[tool.kind] || TOOL_KIND_TONES.read;
  return (
    <>
      <div style={{ display: 'flex', alignItems: 'flex-start', gap: 14, marginBottom: 22 }}>
        <div style={{
          width: 44, height: 44, borderRadius: 9, background: tone.tint, color: tone.color,
          display: 'flex', alignItems: 'center', justifyContent: 'center',
        }}>
          <i data-lucide={tone.icon} style={{ width: 22, height: 22 }}></i>
        </div>
        <div style={{ flex: 1 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 4 }}>
            <div className="scarf-h2" style={{ fontFamily: 'var(--font-mono)', fontSize: 22 }}>{tool.id}</div>
            {tool.enabled ? <Pill tone="green" dot>enabled</Pill> : <Pill tone="gray" dot>disabled</Pill>}
          </div>
          <div style={{ fontSize: 13, color: 'var(--fg-muted)', maxWidth: 560 }}>{tool.desc}</div>
        </div>
        <Toggle on={tool.enabled} size="lg" />
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 10, marginBottom: 24 }}>
        <StatCard label="Calls (7d)" value={tool.calls7d.toLocaleString()} />
        <StatCard label="Last used" value={tool.lastUsed} />
        <StatCard label="Avg duration" value="142 ms" sub="p95: 920 ms" />
        <StatCard label="Error rate" value="0.4%" sub="3 of 661 calls" />
      </div>

      <SettingsGroup title="Permissions" description="Applied at the gateway. Per-project profiles can override.">
        <SettingsRow icon="shield-check" title="Default policy"
          description={POLICY_DESC[tool.policy]}
          control={<Select value={tool.policy} options={[
            { value: 'auto', label: 'Auto-approve' },
            { value: 'approve-write', label: 'Approve writes' },
            { value: 'approve-exec', label: 'Approve every call' },
            { value: 'approve-all', label: 'Approve every call (strict)' },
            { value: 'deny', label: 'Deny' },
          ]} />} />
        <SettingsRow icon="users" title="Per-project overrides"
          description="2 projects override the default policy for this tool."
          control={<Btn size="sm" icon="external-link">Manage</Btn>} last />
      </SettingsGroup>

      <SettingsGroup title="Schema" description="JSON Schema declared by the tool. Read-only.">
        <div style={{ background: 'var(--gray-900)', color: '#E8E1D2', padding: 14,
          fontFamily: 'var(--font-mono)', fontSize: 11.5, lineHeight: 1.55,
          borderRadius: '0 0 10px 10px' }}>
{`{
  "name": "${tool.id}",
  "input_schema": {
    "type": "object",
    "properties": {
      "command": { "type": "string", "description": "Shell command" },
      "cwd":     { "type": "string", "default": "$PWD" },
      "timeout": { "type": "integer", "default": 60 }
    },
    "required": ["command"]
  }
}`}
        </div>
      </SettingsGroup>

      <SettingsGroup title="Recent calls">
        <RecentCallRow when="2m ago" args="hermes cron status daily-summary" status="ok" duration="1.4s" />
        <RecentCallRow when="14m ago" args="git log --oneline -n 20" status="ok" duration="86ms" />
        <RecentCallRow when="1h ago" args="npm test -- --watch=false" status="ok" duration="14.2s" />
        <RecentCallRow when="2h ago" args="rm -rf node_modules" status="denied" duration="—" last />
      </SettingsGroup>
    </>
  );
}

const POLICY_DESC = {
  'auto':            'Always invoke without asking.',
  'approve-write':   'Pause for approval when the tool changes state.',
  'approve-exec':    'Pause for approval before every call.',
  'approve-all':     'Pause for approval before every call. Strictest mode.',
  'deny':            'Reject the call. Tool appears in lists but cannot be invoked.',
};

function RecentCallRow({ when, args, status, duration, last }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 12, padding: '10px 18px',
      borderBottom: last ? 'none' : '0.5px solid var(--border)',
    }}>
      <span style={{ fontSize: 11, color: 'var(--fg-faint)', fontFamily: 'var(--font-mono)', width: 90 }}>{when}</span>
      <span style={{ flex: 1, fontFamily: 'var(--font-mono)', fontSize: 12,
        whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis', color: 'var(--fg-muted)' }}>{args}</span>
      {status === 'ok' && <Pill tone="green" size="sm" icon="check">ok</Pill>}
      {status === 'denied' && <Pill tone="red" size="sm" icon="ban">denied</Pill>}
      <span style={{ fontFamily: 'var(--font-mono)', fontSize: 11, color: 'var(--fg-faint)', width: 60, textAlign: 'right' }}>{duration}</span>
    </div>
  );
}

window.Tools = Tools;
