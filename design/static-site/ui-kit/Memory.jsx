// Memory — AGENTS.md editor. Stored instructions the agent reads on every turn.

const MEMORY_FILES = [
  { id: 'global', name: 'AGENTS.md', scope: 'Global', path: '~/.scarf/AGENTS.md', updated: '2 days ago', size: '1.2 KB' },
  { id: 'wizemann', name: 'AGENTS.md', scope: 'Org · Wizemann', path: '~/.scarf/orgs/wizemann/AGENTS.md', updated: '1 week ago', size: '3.4 KB' },
  { id: 'project', name: 'AGENTS.md', scope: 'Project · sera', path: 'sera/AGENTS.md', updated: '14m ago', size: '5.8 KB' },
];

const SAMPLE_AGENTS = `# Sera — agent instructions

You are working on **Sera**, a CLI for building Anthropic-style applications.
The codebase is TypeScript + Bun. Tests live next to source as \`*.test.ts\`.

## Style
- Prefer named exports.
- 2-space indent, no semicolons in TS.
- Avoid default exports except for React components.
- Lowercase filenames except for React components (PascalCase).

## Workflow
- Run \`bun test\` after every meaningful change.
- Open a draft PR early; flip to ready when CI is green.
- Update CHANGELOG.md when changing public API.

## Don't
- Touch \`scripts/release.ts\` — owned by ops.
- Pull in dependencies without flagging it first.
- Push directly to main.
`;

function Memory() {
  const [active, setActive] = React.useState('project');
  const [draft, setDraft] = React.useState(SAMPLE_AGENTS);
  const [dirty, setDirty] = React.useState(false);
  React.useEffect(() => { requestAnimationFrame(() => window.lucide && window.lucide.createIcons()); });

  const file = MEMORY_FILES.find(f => f.id === active);

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%' }}>
      <ContentHeader title="Memory" subtitle="AGENTS.md files the agent reads on every turn. Project beats org beats global."
        actions={<>
          <Btn icon="rotate-ccw" disabled={!dirty}>Discard</Btn>
          <Btn kind="primary" icon="check" disabled={!dirty}>Save</Btn>
        </>}
      />

      <div style={{ flex: 1, display: 'flex', minHeight: 0 }}>
        <div style={{ width: 280, borderRight: '0.5px solid var(--border)',
          display: 'flex', flexDirection: 'column', background: 'var(--bg-card)' }}>
          <div style={{ padding: '14px 14px 6px', fontSize: 10, fontWeight: 600,
            color: 'var(--fg-muted)', textTransform: 'uppercase', letterSpacing: '0.06em' }}>
            Memory files
          </div>
          <div style={{ flex: 1, padding: 8 }}>
            {MEMORY_FILES.map(f => {
              const a = f.id === active;
              return (
                <div key={f.id} onClick={() => setActive(f.id)} style={{
                  padding: '10px 12px', borderRadius: 7, cursor: 'pointer', marginBottom: 2,
                  background: a ? 'var(--accent-tint)' : 'transparent',
                }}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 4 }}>
                    <i data-lucide="file-text" style={{ width: 13, height: 13,
                      color: a ? 'var(--accent-active)' : 'var(--fg-muted)' }}></i>
                    <div style={{ fontSize: 13, fontWeight: 500,
                      color: a ? 'var(--accent-active)' : 'var(--fg)' }}>{f.scope}</div>
                  </div>
                  <div style={{ fontSize: 11, color: 'var(--fg-faint)', fontFamily: 'var(--font-mono)',
                    whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{f.path}</div>
                  <div style={{ fontSize: 11, color: 'var(--fg-faint)', marginTop: 2 }}>
                    {f.size} · {f.updated}
                  </div>
                </div>
              );
            })}
            <div style={{ marginTop: 12 }}>
              <Btn fullWidth icon="plus" size="sm">Add memory file</Btn>
            </div>
          </div>
          <div style={{ padding: 14, borderTop: '0.5px solid var(--border)' }}>
            <div style={{ fontSize: 11, color: 'var(--fg-muted)', lineHeight: 1.5 }}>
              <i data-lucide="info" style={{ width: 11, height: 11, verticalAlign: 'text-top', marginRight: 4 }}></i>
              Files are loaded in order — narrower scopes override broader ones.
            </div>
          </div>
        </div>

        <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0 }}>
          <div style={{
            padding: '12px 24px', borderBottom: '0.5px solid var(--border)',
            background: 'var(--bg-card)', display: 'flex', alignItems: 'center', gap: 12,
          }}>
            <i data-lucide="file-text" style={{ width: 16, height: 16, color: 'var(--accent)' }}></i>
            <div style={{ flex: 1 }}>
              <div style={{ fontSize: 13, fontWeight: 500 }}>{file.name}</div>
              <div style={{ fontSize: 11, color: 'var(--fg-faint)', fontFamily: 'var(--font-mono)' }}>{file.path}</div>
            </div>
            {dirty
              ? <Pill tone="amber" dot>unsaved</Pill>
              : <Pill tone="green" dot>saved</Pill>}
            <div style={{ display: 'flex', gap: 4 }}>
              <IconBtn icon="eye" tooltip="Preview" />
              <IconBtn icon="more-horizontal" tooltip="More" />
            </div>
          </div>

          <textarea value={draft}
            onChange={e => { setDraft(e.target.value); setDirty(true); }}
            style={{
              flex: 1, padding: '20px 32px', border: 'none', outline: 'none', resize: 'none',
              fontFamily: 'var(--font-mono)', fontSize: 13, lineHeight: 1.7,
              color: 'var(--fg)', background: 'var(--bg)',
            }}
          />

          <div style={{
            padding: '8px 24px', borderTop: '0.5px solid var(--border)', background: 'var(--bg-card)',
            display: 'flex', alignItems: 'center', gap: 16, fontSize: 11, color: 'var(--fg-faint)', fontFamily: 'var(--font-mono)',
          }}>
            <span>markdown</span>
            <span>·</span>
            <span>{draft.split('\n').length} lines</span>
            <span>·</span>
            <span>{draft.length} chars</span>
            <span style={{ marginLeft: 'auto' }}>last loaded: {file.updated}</span>
          </div>
        </div>
      </div>
    </div>
  );
}

window.Memory = Memory;
