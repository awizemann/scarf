// Sessions list view — with filters (incl. project filter) and a detail row.

function Sessions() {
  const [filter, setFilter] = React.useState('all');
  const [project, setProject] = React.useState('all'); // project filter
  const [projectMenuOpen, setProjectMenuOpen] = React.useState(false);
  const projectMenuRef = React.useRef();

  React.useEffect(() => {
    function onDoc(e) {
      if (projectMenuRef.current && !projectMenuRef.current.contains(e.target)) {
        setProjectMenuOpen(false);
      }
    }
    if (projectMenuOpen) {
      document.addEventListener('mousedown', onDoc);
      return () => document.removeEventListener('mousedown', onDoc);
    }
  }, [projectMenuOpen]);

  const filters = [
    { id: 'all', label: 'All', count: 847 },
    { id: 'today', label: 'Today', count: 24 },
    { id: 'starred', label: 'Starred', count: 6 },
  ];

  const allRows = [
    { id: 1, project: 'scarf', title: 'Cron diagnostics', model: 'sonnet-4.5', msgs: 14, tokens: '12,847', cost: '$0.04', time: '14m ago', status: 'active' },
    { id: 2, project: 'hermes-blog', title: 'Release notes draft', model: 'haiku-4.5', msgs: 8, tokens: '3,210', cost: '$0.01', time: '42m ago', status: 'idle' },
    { id: 3, project: 'hermes-blog', title: 'PR review summary', model: 'sonnet-4.5', msgs: 22, tokens: '24,108', cost: '$0.08', time: '2h ago', status: 'idle' },
    { id: 4, project: '—', title: 'What model handles function calls best?', model: 'haiku-4.5', msgs: 4, tokens: '284', cost: '$0.00', time: '3h ago', status: 'idle' },
    { id: 5, project: 'scarf', title: 'Memory layout question', model: 'sonnet-4.5', msgs: 11, tokens: '4,892', cost: '$0.02', time: 'yesterday', status: 'idle' },
    { id: 6, project: 'scarf', title: 'Refactor SidebarSection enum', model: 'sonnet-4.5', msgs: 31, tokens: '38,221', cost: '$0.13', time: 'yesterday', status: 'errored' },
    { id: 7, project: 'hermes-blog', title: 'Twitter recap thread', model: 'haiku-4.5', msgs: 6, tokens: '1,247', cost: '$0.00', time: '2 days ago', status: 'idle' },
    { id: 8, project: '—', title: 'Find a good local TTS model', model: 'sonnet-4.5', msgs: 19, tokens: '8,743', cost: '$0.03', time: '3 days ago', status: 'idle' },
  ];

  // Build project facet — counts per project, plus an "Unscoped" bucket.
  const projectCounts = allRows.reduce((acc, r) => {
    acc[r.project] = (acc[r.project] || 0) + 1;
    return acc;
  }, {});
  const projects = [
    { id: 'all', label: 'All projects', icon: 'layers', count: allRows.length },
    ...Object.keys(projectCounts).filter(k => k !== '—').sort().map(k => ({
      id: k, label: k, icon: 'folder', count: projectCounts[k],
    })),
    { id: '—', label: 'Unscoped', icon: 'ghost', count: projectCounts['—'] || 0 },
  ];

  const rows = allRows.filter(r => project === 'all' ? true : r.project === project);
  const activeProject = projects.find(p => p.id === project) || projects[0];

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%' }}>
      <ContentHeader title="Sessions"
        subtitle="Every conversation across projects, agents, and models"
        actions={<><Btn icon="filter">Filter</Btn><Btn icon="download">Export</Btn></>} />

      <div style={{ padding: '14px 28px 0', display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
        {filters.map(f => (
          <div key={f.id} onClick={() => setFilter(f.id)} style={{
            padding: '4px 11px', borderRadius: 999, cursor: 'pointer', fontSize: 12,
            fontWeight: 500,
            background: filter === f.id ? 'var(--accent)' : 'var(--bg-quaternary)',
            color: filter === f.id ? '#fff' : 'var(--fg)',
            display: 'flex', alignItems: 'center', gap: 5,
          }}>{f.label}<span style={{
            opacity: 0.7, fontFamily: 'var(--font-mono)',
          }}>{f.count}</span></div>
        ))}

        {/* Vertical separator */}
        <div style={{ width: 1, height: 18, background: 'var(--border)', margin: '0 4px' }}></div>

        {/* Project filter chip — opens a dropdown */}
        <div ref={projectMenuRef} style={{ position: 'relative' }}>
          <div onClick={() => setProjectMenuOpen(o => !o)} style={{
            padding: '4px 6px 4px 11px', borderRadius: 999, cursor: 'pointer', fontSize: 12,
            fontWeight: 500,
            background: project !== 'all' ? 'var(--accent-tint)' : 'var(--bg-quaternary)',
            color: project !== 'all' ? 'var(--accent-active)' : 'var(--fg)',
            border: project !== 'all' ? '1px solid var(--accent)' : '1px solid transparent',
            display: 'flex', alignItems: 'center', gap: 6,
          }}>
            <i data-lucide={activeProject.icon}
              style={{ width: 12, height: 12 }}></i>
            <span>{activeProject.label}</span>
            <span style={{ opacity: 0.7, fontFamily: 'var(--font-mono)' }}>{activeProject.count}</span>
            {project !== 'all' && (
              <i data-lucide="x" onClick={(e) => { e.stopPropagation(); setProject('all'); }}
                style={{ width: 12, height: 12, marginLeft: 2, padding: 1, borderRadius: 3 }}></i>
            )}
            {project === 'all' && (
              <i data-lucide="chevron-down" style={{ width: 12, height: 12, marginLeft: 2, opacity: 0.7 }}></i>
            )}
          </div>

          {projectMenuOpen && (
            <div style={{
              position: 'absolute', top: '100%', left: 0, marginTop: 6, zIndex: 50,
              minWidth: 220, padding: 4, background: 'var(--bg-card)',
              border: '0.5px solid var(--border)', borderRadius: 9,
              boxShadow: 'var(--shadow-lg)', fontFamily: 'var(--font-sans)',
            }}>
              <div style={{
                padding: '6px 10px 4px', fontSize: 10, fontWeight: 600,
                color: 'var(--fg-muted)', textTransform: 'uppercase', letterSpacing: '0.06em',
              }}>Filter by project</div>
              {projects.map(p => {
                const active = p.id === project;
                return (
                  <div key={p.id} onClick={() => { setProject(p.id); setProjectMenuOpen(false); }}
                    style={{
                      display: 'flex', alignItems: 'center', gap: 9, padding: '6px 10px',
                      borderRadius: 6, cursor: 'pointer', fontSize: 13,
                      background: active ? 'var(--accent-tint)' : 'transparent',
                      color: active ? 'var(--accent-active)' : 'var(--fg)',
                    }}
                    onMouseEnter={e => { if (!active) e.currentTarget.style.background = 'var(--bg-quaternary)'; }}
                    onMouseLeave={e => { if (!active) e.currentTarget.style.background = 'transparent'; }}
                  >
                    <i data-lucide={p.icon} style={{ width: 13, height: 13,
                      color: active ? 'var(--accent-active)' : 'var(--fg-muted)' }}></i>
                    <span style={{ flex: 1,
                      fontStyle: p.id === '—' ? 'italic' : 'normal',
                      color: p.id === '—' && !active ? 'var(--fg-muted)' : 'inherit' }}>{p.label}</span>
                    <span style={{ fontFamily: 'var(--font-mono)', fontSize: 11,
                      color: active ? 'var(--accent-active)' : 'var(--fg-faint)' }}>{p.count}</span>
                    {active && <i data-lucide="check" style={{ width: 13, height: 13 }}></i>}
                  </div>
                );
              })}
            </div>
          )}
        </div>

        <div style={{ marginLeft: 'auto', position: 'relative' }}>
          <i data-lucide="search" style={{
            position: 'absolute', left: 8, top: 6, width: 13, height: 13, color: 'var(--fg-faint)'
          }}></i>
          <input placeholder="Search sessions…" style={{
            width: 200, padding: '4px 10px 4px 28px',
            border: '1px solid var(--border-strong)', borderRadius: 6,
            fontSize: 12, background: 'var(--bg-card)', outline: 'none',
            fontFamily: 'var(--font-sans)',
          }} />
        </div>
      </div>

      {/* Active filter summary */}
      {project !== 'all' && (
        <div style={{ padding: '8px 28px 0', fontSize: 12, color: 'var(--fg-muted)' }}>
          Showing {rows.length} session{rows.length === 1 ? '' : 's'} from
          {' '}<span style={{ color: 'var(--fg)', fontWeight: 500 }}>{activeProject.label}</span>
          {' '}·{' '}
          <span onClick={() => setProject('all')} style={{
            color: 'var(--accent-active)', cursor: 'pointer', textDecoration: 'underline',
            textDecorationStyle: 'dotted', textUnderlineOffset: 3,
          }}>clear filter</span>
        </div>
      )}

      <div style={{ flex: 1, overflowY: 'auto', padding: '14px 28px 28px' }}>
        <Card padding={0}>
          <div style={{
            display: 'grid', gridTemplateColumns: '120px 1fr 110px 60px 90px 70px 80px 24px',
            padding: '8px 14px', borderBottom: '0.5px solid var(--border)',
            fontSize: 11, color: 'var(--fg-muted)', fontWeight: 600,
            textTransform: 'uppercase', letterSpacing: '0.05em',
          }}>
            <div>Project</div><div>Title</div><div>Model</div>
            <div style={{ textAlign: 'right' }}>Msgs</div>
            <div style={{ textAlign: 'right' }}>Tokens</div>
            <div style={{ textAlign: 'right' }}>Cost</div>
            <div style={{ textAlign: 'right' }}>Updated</div>
            <div></div>
          </div>
          {rows.length === 0 && (
            <div style={{ padding: 48, textAlign: 'center', color: 'var(--fg-muted)', fontSize: 13 }}>
              No sessions match this filter.
            </div>
          )}
          {rows.map(r => (
            <div key={r.id} style={{
              display: 'grid', gridTemplateColumns: '120px 1fr 110px 60px 90px 70px 80px 24px',
              padding: '10px 14px', borderBottom: '0.5px solid var(--border)',
              alignItems: 'center', fontSize: 13, cursor: 'pointer', gap: 6,
            }} onMouseEnter={e => e.currentTarget.style.background = 'var(--bg-quaternary)'}
              onMouseLeave={e => e.currentTarget.style.background = 'transparent'}>
              <div>
                {r.project !== '—'
                  ? <span onClick={(e) => { e.stopPropagation(); setProject(r.project); }}
                      title={`Filter by ${r.project}`}
                      style={{ display: 'inline-block' }}>
                      <Pill tone="accent">{r.project}</Pill>
                    </span>
                  : <span style={{ color: 'var(--fg-faint)', fontSize: 11 }}>—</span>}
              </div>
              <div style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
                display: 'flex', gap: 6, alignItems: 'center' }}>
                {r.status === 'active' && <span style={{ width: 7, height: 7, borderRadius: '50%', background: 'var(--green-500)' }}></span>}
                {r.status === 'errored' && <span style={{ width: 7, height: 7, borderRadius: '50%', background: 'var(--red-500)' }}></span>}
                <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{r.title}</span>
              </div>
              <div style={{ fontFamily: 'var(--font-mono)', fontSize: 11, color: 'var(--fg-muted)' }}>{r.model}</div>
              <div style={{ fontFamily: 'var(--font-mono)', fontSize: 12, textAlign: 'right' }}>{r.msgs}</div>
              <div style={{ fontFamily: 'var(--font-mono)', fontSize: 12, textAlign: 'right' }}>{r.tokens}</div>
              <div style={{ fontFamily: 'var(--font-mono)', fontSize: 12, textAlign: 'right', color: 'var(--fg-muted)' }}>{r.cost}</div>
              <div style={{ fontSize: 11, color: 'var(--fg-faint)', textAlign: 'right' }}>{r.time}</div>
              <div style={{ color: 'var(--fg-faint)' }}>
                <i data-lucide="chevron-right" style={{ width: 14, height: 14 }}></i>
              </div>
            </div>
          ))}
        </Card>
      </div>
    </div>
  );
}

window.Sessions = Sessions;
