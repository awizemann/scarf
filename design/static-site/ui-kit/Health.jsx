// Health — diagnostics report. One-shot health check across services.

const HEALTH_CHECKS = [
  { name: 'Anthropic API', status: 'ok', latency: '124 ms', detail: 'authenticated as Aurora · sonnet-4.5 reachable' },
  { name: 'Local gateway',     status: 'ok', latency: '2 ms',   detail: 'pid 84021 · uptime 4d 2h · listening :7421' },
  { name: 'Filesystem',        status: 'ok', latency: '—',      detail: '14.2 GB free of 512 GB' },
  { name: 'GitHub MCP',        status: 'ok', latency: '84 ms',  detail: 'oauth ok · 18 tools · rate-limit 4500/5000 (warn at 4750)' },
  { name: 'Linear MCP',        status: 'ok', latency: '142 ms', detail: 'oauth ok · 9 tools' },
  { name: 'Postgres MCP',      status: 'ok', latency: '12 ms',  detail: 'stdio · prod read replica' },
  { name: 'Figma MCP',         status: 'ok', latency: '210 ms', detail: 'oauth ok · 6 tools' },
  { name: 'Notion MCP',        status: 'error', latency: '—',  detail: 'TLS handshake failed · 4 retries · backing off 30s' },
  { name: 'Slack MCP',         status: 'warn', latency: '—',  detail: 'oauth token expired · re-authenticate' },
  { name: 'Sentry MCP',        status: 'idle', latency: '—',   detail: 'disabled' },
  { name: 'Cron scheduler',    status: 'ok', latency: '—',     detail: '5 jobs registered · next: incident-triage in 12m' },
  { name: 'Local model cache', status: 'ok', latency: '—',    detail: '412 MB · last pruned 2d ago' },
];

function Health() {
  const [scanning, setScanning] = React.useState(false);
  React.useEffect(() => { requestAnimationFrame(() => window.lucide && window.lucide.createIcons()); });

  const ok = HEALTH_CHECKS.filter(c => c.status === 'ok').length;
  const warn = HEALTH_CHECKS.filter(c => c.status === 'warn').length;
  const err = HEALTH_CHECKS.filter(c => c.status === 'error').length;

  function rerun() {
    setScanning(true);
    setTimeout(() => setScanning(false), 1400);
  }

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%' }}>
      <ContentHeader title="Health"
        subtitle="A diagnostics report across Scarf, the agent, and connected services"
        actions={<>
          <Btn icon="download">Save report</Btn>
          <Btn kind="primary" icon="rotate-cw" loading={scanning} onClick={rerun}>{scanning ? 'Scanning…' : 'Re-run'}</Btn>
        </>} />

      <div style={{ flex: 1, overflowY: 'auto', padding: '24px 32px' }}>
        {/* Summary banner */}
        <div style={{
          background: err > 0 ? 'var(--red-100)' : warn > 0 ? 'var(--orange-100)' : 'var(--green-100)',
          border: `0.5px solid ${err > 0 ? 'var(--red-500)' : warn > 0 ? 'var(--orange-500)' : 'var(--green-500)'}`,
          borderRadius: 10, padding: 16, marginBottom: 24,
          display: 'flex', alignItems: 'center', gap: 14,
        }}>
          <div style={{
            width: 38, height: 38, borderRadius: 9,
            background: err > 0 ? 'var(--red-500)' : warn > 0 ? 'var(--orange-500)' : 'var(--green-500)',
            color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center',
          }}>
            <i data-lucide={err > 0 ? 'alert-octagon' : warn > 0 ? 'alert-triangle' : 'shield-check'} style={{ width: 20, height: 20 }}></i>
          </div>
          <div style={{ flex: 1 }}>
            <div style={{ fontSize: 15, fontWeight: 600, marginBottom: 2 }}>
              {err > 0 ? `${err} service${err === 1 ? '' : 's'} unhealthy`
                : warn > 0 ? `${warn} warning${warn === 1 ? '' : 's'} to review`
                : 'All systems healthy'}
            </div>
            <div style={{ fontSize: 13, color: 'var(--fg-muted)' }}>
              {ok} ok · {warn} warning · {err} error · scanned 2 minutes ago
            </div>
          </div>
        </div>

        {/* Checks */}
        <SettingsGroup title="Diagnostic checks">
          {HEALTH_CHECKS.map((c, i) => <HealthRow key={c.name} c={c} last={i === HEALTH_CHECKS.length - 1} />)}
        </SettingsGroup>

        <SettingsGroup title="Environment">
          <SettingsRow icon="info" title="Scarf version"
            description="0.14.2 · 0.15.0 available"
            control={<Btn size="sm">Update</Btn>} />
          <SettingsRow icon="cpu" title="Platform"
            description="macOS 14.4.1 · Apple M3 Pro · 36 GB"
            control={<Pill tone="green" dot>supported</Pill>} />
          <SettingsRow icon="terminal" title="Shell"
            description="/bin/zsh 5.9 · path 47 entries"
            control={<Btn size="sm">Inspect</Btn>} last />
        </SettingsGroup>
      </div>
    </div>
  );
}

function HealthRow({ c, last }) {
  const tones = {
    ok:    { tone: 'green',  icon: 'check-circle' },
    warn:  { tone: 'amber',  icon: 'alert-triangle' },
    error: { tone: 'red',    icon: 'x-circle' },
    idle:  { tone: 'gray',   icon: 'minus-circle' },
  };
  const t = tones[c.status];
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 12, padding: '12px 18px',
      borderBottom: last ? 'none' : '0.5px solid var(--border)',
    }}>
      <Pill tone={t.tone} icon={t.icon} size="sm">{c.status}</Pill>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 13, fontWeight: 500 }}>{c.name}</div>
        <div style={{ fontSize: 11.5, color: 'var(--fg-muted)', marginTop: 2, fontFamily: 'var(--font-mono)' }}>{c.detail}</div>
      </div>
      <span style={{ fontFamily: 'var(--font-mono)', fontSize: 11, color: 'var(--fg-faint)', width: 70, textAlign: 'right' }}>{c.latency}</span>
    </div>
  );
}

window.Health = Health;
