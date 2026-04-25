// Projects — list of project folders the agent operates in.

function Projects() {
  const projects = [
    { id: 1, name: 'hermes-blog', dir: '~/code/hermes-blog', template: 'awizemann/hermes-blog', sessions: 142, lastRun: '14m ago', cron: 2, status: 'healthy' },
    { id: 2, name: 'scarf', dir: '~/code/scarf', template: '—', sessions: 89, lastRun: '42m ago', cron: 0, status: 'healthy' },
    { id: 3, name: 'inbox-sweep', dir: '~/code/inbox-sweep', template: 'community/inbox-sweep', sessions: 38, lastRun: '3h ago', cron: 1, status: 'healthy' },
    { id: 4, name: 'twitter-recap', dir: '~/code/twitter-recap', template: 'awizemann/twitter-recap', sessions: 14, lastRun: '2d ago', cron: 1, status: 'paused' },
    { id: 5, name: 'pr-watcher', dir: '~/code/pr-watcher', template: 'community/pr-watcher', sessions: 4, lastRun: '5d ago', cron: 1, status: 'errored' },
  ];

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%' }}>
      <ContentHeader title="Projects"
        subtitle="Each project pins context, AGENTS.md, cron jobs, and session history"
        actions={<><Btn icon="folder-plus">Add Existing</Btn><Btn kind="primary" icon="plus">New from Template</Btn></>} />

      <div style={{ flex: 1, overflowY: 'auto', padding: '20px 28px' }}>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(300px, 1fr))', gap: 14 }}>
          {projects.map(p => (
            <Card key={p.id} padding={16} style={{ display: 'flex', flexDirection: 'column', gap: 10, cursor: 'pointer' }}>
              <div style={{ display: 'flex', alignItems: 'flex-start', gap: 10 }}>
                <div style={{
                  width: 36, height: 36, borderRadius: 8, background: 'var(--accent-tint)',
                  display: 'flex', alignItems: 'center', justifyContent: 'center',
                  color: 'var(--accent)', flexShrink: 0,
                }}>
                  <i data-lucide="folder" style={{ width: 18, height: 18 }}></i>
                </div>
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ fontSize: 14, fontWeight: 600 }}>{p.name}</div>
                  <div style={{ fontSize: 11, color: 'var(--fg-muted)',
                    fontFamily: 'var(--font-mono)', overflow: 'hidden',
                    textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{p.dir}</div>
                </div>
                {p.status === 'healthy' && <Pill tone="green" dot>healthy</Pill>}
                {p.status === 'paused' && <Pill tone="gray" dot>paused</Pill>}
                {p.status === 'errored' && <Pill tone="red" dot>errored</Pill>}
              </div>

              {p.template !== '—' && (
                <div style={{ fontSize: 11, color: 'var(--fg-muted)',
                  display: 'flex', alignItems: 'center', gap: 5 }}>
                  <i data-lucide="package" style={{ width: 11, height: 11 }}></i>
                  <span style={{ fontFamily: 'var(--font-mono)' }}>{p.template}</span>
                </div>
              )}

              <div style={{ display: 'flex', gap: 16, paddingTop: 8,
                borderTop: '0.5px solid var(--border)', fontSize: 11 }}>
                <div>
                  <div style={{ color: 'var(--fg-muted)' }}>Sessions</div>
                  <div style={{ fontFamily: 'var(--font-mono)', fontSize: 13, fontWeight: 600, marginTop: 1 }}>{p.sessions}</div>
                </div>
                <div>
                  <div style={{ color: 'var(--fg-muted)' }}>Cron jobs</div>
                  <div style={{ fontFamily: 'var(--font-mono)', fontSize: 13, fontWeight: 600, marginTop: 1 }}>{p.cron}</div>
                </div>
                <div style={{ marginLeft: 'auto', textAlign: 'right' }}>
                  <div style={{ color: 'var(--fg-muted)' }}>Last run</div>
                  <div style={{ fontSize: 12, marginTop: 1 }}>{p.lastRun}</div>
                </div>
              </div>
            </Card>
          ))}

          <Card padding={16} style={{
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            border: '1px dashed var(--border-strong)', boxShadow: 'none',
            background: 'transparent', minHeight: 140, cursor: 'pointer',
            color: 'var(--fg-muted)', flexDirection: 'column', gap: 8,
          }}>
            <i data-lucide="plus" style={{ width: 24, height: 24 }}></i>
            <div style={{ fontSize: 13, fontWeight: 500 }}>New project</div>
            <div style={{ fontSize: 11, textAlign: 'center', maxWidth: 180 }}>From template, GitHub repo, or empty folder</div>
          </Card>
        </div>
      </div>
    </div>
  );
}

window.Projects = Projects;
