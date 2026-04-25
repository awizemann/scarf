// Cron — scheduled agent runs, with run history and a calendar heat strip.

const CRON_JOBS = [
  { id: 'daily-summary', name: 'Daily standup summary', schedule: '0 9 * * 1-5', cronText: 'Weekdays at 9:00am', enabled: true,
    lastRun: '2h ago', lastStatus: 'ok', avgDuration: '38s', nextRun: 'tomorrow 9:00am',
    personality: 'Hermes', desc: 'Read yesterday\'s commits + Linear updates and post a summary to #standup.', runs7d: 5 },
  { id: 'incident-triage', name: 'Incident triage', schedule: '*/15 * * * *', cronText: 'Every 15 minutes', enabled: true,
    lastRun: '3m ago', lastStatus: 'ok', avgDuration: '4.2s', nextRun: 'in 12m',
    personality: 'Forge', desc: 'Poll Sentry for unresolved high-severity issues and create Linear tickets.', runs7d: 672 },
  { id: 'design-review', name: 'Friday design review prep', schedule: '0 16 * * 4', cronText: 'Thursdays at 4:00pm', enabled: true,
    lastRun: 'yesterday', lastStatus: 'ok', avgDuration: '2m 14s', nextRun: 'Thursday 4:00pm',
    personality: 'Atlas', desc: 'Collect new Figma frames + recent PRs, draft an agenda for the design review.', runs7d: 1 },
  { id: 'docs-stale', name: 'Find stale docs', schedule: '0 0 * * 0', cronText: 'Sundays at midnight', enabled: false,
    lastRun: '8d ago', lastStatus: 'skipped', avgDuration: '47s', nextRun: 'paused',
    personality: 'Hermes', desc: 'Scan the docs site for pages not updated in >90 days; open a checklist.', runs7d: 0 },
  { id: 'release-notes', name: 'Draft release notes', schedule: '0 14 * * 5', cronText: 'Fridays at 2:00pm', enabled: true,
    lastRun: '6d ago', lastStatus: 'failed', avgDuration: '1m 03s', nextRun: 'Friday 2:00pm',
    personality: 'Atlas', desc: 'Walk merged PRs since last tag; group by area; write user-facing release notes.', runs7d: 1 },
];

const RUN_HISTORY = [
  { when: '2h ago',     status: 'ok',     duration: '36s',     ts: '2026-04-25 09:00:14' },
  { when: 'yesterday',  status: 'ok',     duration: '41s',     ts: '2026-04-24 09:00:08' },
  { when: '2d ago',     status: 'ok',     duration: '38s',     ts: '2026-04-23 09:00:11' },
  { when: '3d ago',     status: 'ok',     duration: '34s',     ts: '2026-04-22 09:00:06' },
  { when: '4d ago',     status: 'failed', duration: '12s',     ts: '2026-04-21 09:00:09', error: 'github: 502 bad gateway' },
  { when: '5d ago',     status: 'ok',     duration: '40s',     ts: '2026-04-18 09:00:12' },
  { when: '6d ago',     status: 'ok',     duration: '37s',     ts: '2026-04-17 09:00:09' },
];

function Cron() {
  const [active, setActive] = React.useState('daily-summary');
  const job = CRON_JOBS.find(j => j.id === active);
  React.useEffect(() => { requestAnimationFrame(() => window.lucide && window.lucide.createIcons()); });

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%' }}>
      <ContentHeader title="Cron"
        subtitle="Scheduled agent runs. Each job invokes a personality with a fixed prompt."
        actions={<><Btn icon="calendar">Timezone: PT</Btn><Btn kind="primary" icon="plus">New cron job</Btn></>} />

      <div style={{ flex: 1, display: 'flex', minHeight: 0 }}>
        <div style={{ width: 360, borderRight: '0.5px solid var(--border)',
          display: 'flex', flexDirection: 'column', background: 'var(--bg-card)' }}>
          <div style={{ flex: 1, overflowY: 'auto', padding: 8 }}>
            {CRON_JOBS.map(j => <CronRow key={j.id} j={j} active={j.id === active} onClick={() => setActive(j.id)} />)}
          </div>
        </div>
        <div style={{ flex: 1, overflowY: 'auto', background: 'var(--bg)', padding: '24px 32px' }}>
          <CronDetail job={job} />
        </div>
      </div>
    </div>
  );
}

function CronRow({ j, active, onClick }) {
  const [hover, setHover] = React.useState(false);
  const tone = j.lastStatus === 'failed' ? 'red' : j.lastStatus === 'skipped' ? 'gray' : 'green';
  return (
    <div onClick={onClick} onMouseEnter={() => setHover(true)} onMouseLeave={() => setHover(false)} style={{
      padding: '11px 12px', borderRadius: 7, cursor: 'pointer', marginBottom: 2,
      background: active ? 'var(--accent-tint)' : (hover ? 'var(--bg-quaternary)' : 'transparent'),
    }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 3 }}>
        <i data-lucide="clock" style={{ width: 13, height: 13, color: 'var(--fg-muted)', flexShrink: 0 }}></i>
        <div style={{ flex: 1, fontSize: 13, fontWeight: 500,
          color: active ? 'var(--accent-active)' : 'var(--fg)' }}>{j.name}</div>
        {!j.enabled && <Pill tone="gray" size="sm">paused</Pill>}
        <Dot tone={tone} />
      </div>
      <div style={{ display: 'flex', gap: 10, fontSize: 11, color: 'var(--fg-faint)', fontFamily: 'var(--font-mono)' }}>
        <span>{j.schedule}</span>
        <span style={{ color: 'var(--fg-muted)' }}>· next {j.nextRun}</span>
      </div>
    </div>
  );
}

function CronDetail({ job }) {
  return (
    <>
      <div style={{ display: 'flex', alignItems: 'flex-start', gap: 14, marginBottom: 20 }}>
        <div style={{
          width: 44, height: 44, borderRadius: 9, background: 'var(--accent-tint)', color: 'var(--accent)',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
        }}>
          <i data-lucide="clock" style={{ width: 22, height: 22 }}></i>
        </div>
        <div style={{ flex: 1 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 4 }}>
            <div className="scarf-h2" style={{ fontSize: 22 }}>{job.name}</div>
            {job.enabled ? <Pill tone="green" dot>active</Pill> : <Pill tone="gray" dot>paused</Pill>}
          </div>
          <div style={{ fontSize: 13, color: 'var(--fg-muted)', maxWidth: 520 }}>{job.desc}</div>
        </div>
        <div style={{ display: 'flex', gap: 6 }}>
          <Btn icon="play">Run now</Btn>
          <Toggle on={job.enabled} size="lg" />
        </div>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 10, marginBottom: 24 }}>
        <StatCard label="Schedule" value={job.cronText} sub={job.schedule} />
        <StatCard label="Last run" value={job.lastRun} sub={job.lastStatus} />
        <StatCard label="Avg duration" value={job.avgDuration} />
        <StatCard label="Next run" value={job.nextRun} />
      </div>

      <SettingsGroup title="Schedule">
        <SettingsRow icon="calendar" title="Cron expression"
          description={`Parsed as: ${job.cronText} (America/Los_Angeles)`}
          control={<TextInput value={job.schedule} mono />} />
        <SettingsRow icon="globe" title="Timezone"
          description="Job triggers fire in this timezone."
          control={<Select value="pt" options={[{ value: 'pt', label: 'America/Los_Angeles' }, { value: 'utc', label: 'UTC' }]} />} />
        <SettingsRow icon="hourglass" title="Timeout"
          description="Kill the run after this duration."
          control={<Select value="5m" options={[
            { value: '1m', label: '1 minute' }, { value: '5m', label: '5 minutes' },
            { value: '15m', label: '15 minutes' }, { value: '1h', label: '1 hour' },
          ]} />} last />
      </SettingsGroup>

      <SettingsGroup title="Behavior">
        <SettingsRow icon="user-circle" title="Personality"
          description={`This job runs as "${job.personality}" with its system prompt + tools.`}
          control={<Btn size="sm" icon="external-link">{job.personality}</Btn>} />
        <SettingsRow icon="message-square" title="Prompt"
          description="The instruction sent to the agent at each scheduled run."
          control={<Btn size="sm" icon="edit-3">Edit</Btn>} />
        <SettingsRow icon="bell" title="Notify on failure"
          description="Send a message to #ops if any run errors out."
          control={<Toggle on={true} />} last />
      </SettingsGroup>

      <SettingsGroup title="Run history" description="Last 7 runs.">
        {RUN_HISTORY.map((r, i) => <RunRow key={i} r={r} last={i === RUN_HISTORY.length - 1} />)}
      </SettingsGroup>
    </>
  );
}

function RunRow({ r, last }) {
  const tone = r.status === 'failed' ? 'red' : r.status === 'skipped' ? 'gray' : 'green';
  const icon = r.status === 'failed' ? 'x' : r.status === 'skipped' ? 'minus' : 'check';
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 12, padding: '10px 18px',
      borderBottom: last ? 'none' : '0.5px solid var(--border)',
    }}>
      <Pill tone={tone} size="sm" icon={icon}>{r.status}</Pill>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 12.5, color: 'var(--fg)' }}>{r.when}
          <span style={{ color: 'var(--fg-faint)', fontFamily: 'var(--font-mono)', marginLeft: 8, fontSize: 11 }}>{r.ts}</span>
        </div>
        {r.error && <div style={{ fontSize: 11, color: 'var(--red-500)', fontFamily: 'var(--font-mono)', marginTop: 2 }}>{r.error}</div>}
      </div>
      <span style={{ fontFamily: 'var(--font-mono)', fontSize: 11, color: 'var(--fg-muted)', width: 60, textAlign: 'right' }}>{r.duration}</span>
      <Btn size="sm">View log</Btn>
    </div>
  );
}

window.Cron = Cron;
