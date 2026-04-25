// Dashboard — first screen. Mirrors the structure: status header,
// quick stats, recent sessions, recent activity.

function Dashboard() {
  return (
    <div style={{ padding: '0 0 28px', overflow: 'auto' }}>
      <ContentHeader title="Dashboard"
        subtitle="At-a-glance status of your Hermes agent"
        actions={<><Btn icon="rotate-cw">Refresh</Btn><Btn kind="primary" icon="plus">New Session</Btn></>} />

      <div style={{ padding: '20px 28px', display: 'flex', flexDirection: 'column', gap: 20 }}>
        {/* Status row */}
        <div style={{ display: 'flex', gap: 12 }}>
          <StatusCard icon="activity" label="Hermes" value="Running" tone="green" sub="3h 14m uptime" />
          <StatusCard icon="cpu" label="Model" value="claude-sonnet-4.5" sub="Anthropic" />
          <StatusCard icon="cloud" label="Provider" value="Anthropic" sub="us-east-1 · 18ms" />
          <StatusCard icon="network" label="Gateway" value="Connected" tone="green" sub="3 platforms" />
        </div>

        {/* Stats row */}
        <Section title="Last 7 days" right={<Btn size="sm" kind="ghost" icon="bar-chart-3">View Insights</Btn>}>
          <div style={{ display: 'flex', gap: 12 }}>
            <StatCard label="Sessions" value="847" sub="+12% vs prev" />
            <StatCard label="Messages" value="12,394" />
            <StatCard label="Tool Calls" value="3,221" />
            <StatCard label="Tokens" value="2.4M" sub="1.8M in · 0.6M out" />
            <StatCard label="Cost" value="$42.18" accent="var(--accent)" />
          </div>
        </Section>

        {/* Two col */}
        <div style={{ display: 'grid', gridTemplateColumns: '1.3fr 1fr', gap: 16 }}>
          <Section title="Recent sessions" right={<a style={linkStyle}>View all →</a>}>
            <Card padding={0}>
              <RecentSessionRow project="hermes-blog" message="Draft this week's release notes…" model="haiku-4.5" tokens="1,247" time="14m ago" />
              <RecentSessionRow project="scarf" message="Implement the cron diagnostics view" model="sonnet-4.5" tokens="8,392" time="42m ago" />
              <RecentSessionRow project="hermes-blog" message="Review the open PRs and summarize" model="sonnet-4.5" tokens="4,108" time="2h ago" />
              <RecentSessionRow project="—" message="What model handles function calls best?" model="haiku-4.5" tokens="284" time="3h ago" last />
            </Card>
          </Section>

          <Section title="Recent activity" right={<a style={linkStyle}>View all →</a>}>
            <Card padding={0}>
              <DashActivityRow icon="file-edit" tone="blue" text="Edited cron/jobs.json" sub="hermes-blog · session #3a2f" time="14m" />
              <DashActivityRow icon="terminal" tone="orange" text="Ran hermes status" sub="3 platforms healthy" time="42m" />
              <DashActivityRow icon="git-branch" tone="green" text="Cron daily-summary completed" sub="14.2s · 1,847 tokens" time="2h" />
              <DashActivityRow icon="package" tone="purple" text="Installed template hermes-blog" sub="from awizemann/hermes-blog" time="yesterday" last />
            </Card>
          </Section>
        </div>
      </div>
    </div>
  );
}

const linkStyle = { fontSize: 12, color: 'var(--accent)', cursor: 'pointer', textDecoration: 'none' };

function StatusCard({ icon, label, value, sub, tone }) {
  const dotColor = tone === 'green' ? 'var(--green-500)' : 'var(--gray-400)';
  return (
    <Card padding={14} style={{ flex: 1, minWidth: 0 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 11,
        color: 'var(--fg-muted)', fontWeight: 600, marginBottom: 6 }}>
        {tone === 'green'
          ? <span style={{ width: 7, height: 7, borderRadius: '50%', background: dotColor }}></span>
          : <i data-lucide={icon} style={{ width: 12, height: 12 }}></i>
        }
        <span style={{ textTransform: 'uppercase', letterSpacing: '0.05em' }}>{label}</span>
      </div>
      <div style={{ fontFamily: 'var(--font-mono)', fontSize: 14, fontWeight: 500,
        whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{value}</div>
      {sub && <div style={{ fontSize: 11, color: 'var(--fg-faint)', marginTop: 3 }}>{sub}</div>}
    </Card>
  );
}

function RecentSessionRow({ project, message, model, tokens, time, last }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 10, padding: '10px 14px',
      borderBottom: last ? 'none' : '0.5px solid var(--border)',
      cursor: 'pointer', transition: 'background 120ms',
    }} onMouseEnter={e => e.currentTarget.style.background = 'var(--bg-quaternary)'}
      onMouseLeave={e => e.currentTarget.style.background = 'transparent'}>
      <Pill tone="accent">{project}</Pill>
      <div style={{ flex: 1, fontSize: 13, color: 'var(--fg)',
        whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{message}</div>
      <div style={{ fontFamily: 'var(--font-mono)', fontSize: 11, color: 'var(--fg-faint)' }}>{model}</div>
      <div style={{ fontFamily: 'var(--font-mono)', fontSize: 11, color: 'var(--fg-faint)', width: 70, textAlign: 'right' }}>{tokens}</div>
      <div style={{ fontSize: 11, color: 'var(--fg-faint)', width: 60, textAlign: 'right' }}>{time}</div>
    </div>
  );
}

function DashActivityRow({ icon, tone, text, sub, time, last }) {
  const tones = { green: 'var(--green-500)', blue: 'var(--blue-500)', orange: 'var(--orange-500)', purple: 'var(--accent)' };
  return (
    <div style={{
      display: 'flex', alignItems: 'flex-start', gap: 10, padding: '10px 14px',
      borderBottom: last ? 'none' : '0.5px solid var(--border)',
    }}>
      <div style={{
        width: 22, height: 22, borderRadius: 5, background: 'var(--bg-quaternary)',
        display: 'flex', alignItems: 'center', justifyContent: 'center', color: tones[tone], flexShrink: 0,
      }}>
        <i data-lucide={icon} style={{ width: 12, height: 12 }}></i>
      </div>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 13, color: 'var(--fg)' }}>{text}</div>
        <div style={{ fontSize: 11, color: 'var(--fg-faint)', marginTop: 1 }}>{sub}</div>
      </div>
      <div style={{ fontSize: 11, color: 'var(--fg-faint)' }}>{time}</div>
    </div>
  );
}

window.Dashboard = Dashboard;
