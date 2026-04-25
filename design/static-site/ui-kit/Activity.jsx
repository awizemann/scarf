// Activity — chronological feed of everything that happened recently across
// all projects, sessions, cron, and tools. Day-grouped, filterable.

const ACTIVITY_GROUPS = [
  { day: 'Today', items: [
    { time: '09:42', icon: 'message-square', tone: 'accent', title: 'Sera — chat session resumed', sub: 'Forge · 14 turns · refactored CronRunner', proj: 'sera' },
    { time: '09:30', icon: 'clock', tone: 'green', title: 'incident-triage ran', sub: 'cron · ok in 4.2s · 0 issues created', proj: '—' },
    { time: '09:00', icon: 'clock', tone: 'green', title: 'daily-summary ran', sub: 'cron · ok in 36s · posted to #standup', proj: '—' },
    { time: '08:42', icon: 'git-pull-request', tone: 'blue', title: 'PR #284 opened', sub: 'sera · "Switch to AbortController for cron timeouts"', proj: 'sera' },
    { time: '08:14', icon: 'shield', tone: 'amber', title: 'Approval: execute git push origin main', sub: 'sera · approved by Aurora · 3.2s wait', proj: 'sera' },
  ]},
  { day: 'Yesterday', items: [
    { time: '17:22', icon: 'check-circle', tone: 'green', title: 'release-notes generated', sub: 'cron · ok in 1m 03s · draft saved', proj: '—' },
    { time: '15:08', icon: 'plug', tone: 'accent', title: 'MCP server connected — Figma', sub: '6 tools, 2 prompts available', proj: '—' },
    { time: '14:31', icon: 'message-square', tone: 'accent', title: 'Hermes — onboarding draft', sub: '8 turns · drafted welcome email', proj: 'hermes' },
    { time: '11:02', icon: 'alert-triangle', tone: 'red', title: 'Tool denied — rm -rf node_modules', sub: 'sera · matched deny rule "rm -rf"', proj: 'sera' },
    { time: '09:00', icon: 'clock', tone: 'green', title: 'daily-summary ran', sub: 'cron · ok in 41s', proj: '—' },
  ]},
  { day: 'Mon, Apr 21', items: [
    { time: '16:48', icon: 'user-plus', tone: 'accent', title: 'New personality — Atlas', sub: 'Created by Aurora · long-form writing model', proj: '—' },
    { time: '14:00', icon: 'database', tone: 'blue', title: 'Postgres (prod, ro) reconfigured', sub: 'switched to read replica', proj: '—' },
    { time: '09:00', icon: 'clock', tone: 'red', title: 'daily-summary failed', sub: 'cron · github 502 bad gateway · retried ok at 09:14', proj: '—' },
  ]},
];

const ACT_TONES = {
  accent: { bg: 'var(--accent-tint)', fg: 'var(--accent)' },
  green:  { bg: 'var(--green-100)', fg: 'var(--green-600)' },
  blue:   { bg: 'var(--blue-100)', fg: 'var(--blue-500)' },
  amber:  { bg: 'var(--orange-100)', fg: 'var(--orange-500)' },
  red:    { bg: 'var(--red-100)', fg: 'var(--red-500)' },
};

function Activity() {
  const [filter, setFilter] = React.useState('all');
  React.useEffect(() => { requestAnimationFrame(() => window.lucide && window.lucide.createIcons()); });

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%' }}>
      <ContentHeader title="Activity"
        subtitle="Everything Scarf has done recently — sessions, cron, tools, MCP, approvals"
        actions={<Btn icon="filter">Filter</Btn>}
        right={
          <Segmented value={filter} onChange={setFilter} size="sm" options={[
            { value: 'all', label: 'All' },
            { value: 'sessions', label: 'Sessions' },
            { value: 'cron', label: 'Cron' },
            { value: 'tools', label: 'Tools' },
          ]} />
        } />
      <div style={{ flex: 1, overflowY: 'auto', padding: '24px 32px' }}>
        {ACTIVITY_GROUPS.map(g => (
          <div key={g.day} style={{ marginBottom: 28 }}>
            <div style={{
              fontSize: 11, fontWeight: 600, color: 'var(--fg-muted)',
              textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 8,
              padding: '0 4px',
            }}>{g.day}</div>
            <div style={{
              background: 'var(--bg-card)', border: '0.5px solid var(--border)',
              borderRadius: 10, overflow: 'hidden',
            }}>
              {g.items.map((it, i) => <ActivityRow key={i} it={it} last={i === g.items.length - 1} />)}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

function ActivityRow({ it, last }) {
  const tone = ACT_TONES[it.tone];
  const [hover, setHover] = React.useState(false);
  return (
    <div onMouseEnter={() => setHover(true)} onMouseLeave={() => setHover(false)} style={{
      display: 'flex', alignItems: 'center', gap: 12, padding: '12px 16px',
      borderBottom: last ? 'none' : '0.5px solid var(--border)',
      background: hover ? 'var(--bg-quaternary)' : 'transparent', cursor: 'pointer',
    }}>
      <span style={{ fontSize: 11, fontFamily: 'var(--font-mono)', color: 'var(--fg-faint)', width: 44 }}>{it.time}</span>
      <div style={{
        width: 26, height: 26, borderRadius: 6, background: tone.bg, color: tone.fg,
        display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0,
      }}>
        <i data-lucide={it.icon} style={{ width: 14, height: 14 }}></i>
      </div>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 13, fontWeight: 500 }}>{it.title}</div>
        <div style={{ fontSize: 11.5, color: 'var(--fg-muted)', marginTop: 1 }}>{it.sub}</div>
      </div>
      {it.proj !== '—' && <Pill size="sm">{it.proj}</Pill>}
      <i data-lucide="chevron-right" style={{ width: 14, height: 14, color: 'var(--fg-faint)' }}></i>
    </div>
  );
}

window.Activity = Activity;
