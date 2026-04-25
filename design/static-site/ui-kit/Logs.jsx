// Logs — streaming monospace surface. Filter pills + a fake live tail.

const LOG_LINES = [
  { ts: '09:42:18.124', level: 'info',  source: 'gateway',  msg: 'POST /v1/messages → 200 (1.2s, 482 tokens out)' },
  { ts: '09:42:18.066', level: 'debug', source: 'tool',     msg: 'tool_call read_file path=src/App.jsx (8.2KB)' },
  { ts: '09:42:17.880', level: 'info',  source: 'agent',    msg: 'turn 14 started — personality=Forge model=claude-sonnet-4.5' },
  { ts: '09:42:15.341', level: 'warn',  source: 'mcp',      msg: 'github: rate-limit warning 4500/5000 used this hour' },
  { ts: '09:42:11.012', level: 'info',  source: 'tool',     msg: 'tool_call execute cmd="npm test -- --watch=false" status=ok 14.2s' },
  { ts: '09:42:01.508', level: 'error', source: 'tool',     msg: 'tool_call execute denied: command "rm -rf node_modules" matches deny rule "rm -rf"' },
  { ts: '09:41:58.211', level: 'info',  source: 'agent',    msg: 'user message received (1.4KB)' },
  { ts: '09:41:42.004', level: 'debug', source: 'memory',   msg: 'AGENTS.md hash unchanged (4f02…ab19), skipping reload' },
  { ts: '09:41:30.882', level: 'info',  source: 'cron',     msg: 'incident-triage finished ok (4.2s)' },
  { ts: '09:41:26.108', level: 'info',  source: 'cron',     msg: 'incident-triage started' },
  { ts: '09:41:18.443', level: 'info',  source: 'mcp',      msg: 'linear: tools/list 9 tools (142ms)' },
  { ts: '09:40:54.221', level: 'warn',  source: 'gateway',  msg: 'approval pending: tool_call execute cmd="git push origin main" (12s)' },
  { ts: '09:40:42.001', level: 'info',  source: 'agent',    msg: 'turn 13 ended — 2.1s, 7 tool calls, $0.0042' },
  { ts: '09:40:21.778', level: 'debug', source: 'tool',     msg: 'tool_call list_files path=ui_kits/scarf-mac (24 entries)' },
  { ts: '09:40:18.422', level: 'error', source: 'mcp',      msg: 'notion: TLS handshake failed (timeout 5s) — backing off 30s' },
  { ts: '09:40:02.114', level: 'info',  source: 'agent',    msg: 'session resumed (idle 14m)' },
];

const LEVEL_TONES = {
  debug: '#7C7263', info: 'var(--blue-500)', warn: 'var(--amber-500)', error: 'var(--red-500)',
};

function Logs() {
  const [level, setLevel] = React.useState(['info', 'warn', 'error']);
  const [source, setSource] = React.useState('all');
  const [search, setSearch] = React.useState('');
  const [follow, setFollow] = React.useState(true);
  React.useEffect(() => { requestAnimationFrame(() => window.lucide && window.lucide.createIcons()); });

  const sources = ['all', 'agent', 'tool', 'gateway', 'mcp', 'cron', 'memory'];
  const filtered = LOG_LINES.filter(l => {
    if (!level.includes(l.level)) return false;
    if (source !== 'all' && l.source !== source) return false;
    if (search && !l.msg.toLowerCase().includes(search.toLowerCase())) return false;
    return true;
  });

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%' }}>
      <ContentHeader title="Logs"
        subtitle="Live tail across the gateway, agent, tools, MCP servers, and cron"
        actions={<>
          <Btn icon="download">Export</Btn>
          <Btn icon={follow ? 'pause' : 'play'} onClick={() => setFollow(!follow)}>
            {follow ? 'Pause' : 'Follow'}
          </Btn>
        </>} />

      {/* Toolbar */}
      <div style={{
        padding: '12px 24px', borderBottom: '0.5px solid var(--border)',
        background: 'var(--bg-card)', display: 'flex', gap: 12, alignItems: 'center', flexWrap: 'wrap',
      }}>
        <TextInput value={search} onChange={setSearch} leftIcon="search" placeholder="Filter messages…" mono width={280} />

        <div style={{ display: 'flex', gap: 4 }}>
          {['debug', 'info', 'warn', 'error'].map(lv => {
            const on = level.includes(lv);
            return (
              <button key={lv} onClick={() => setLevel(on ? level.filter(x => x !== lv) : [...level, lv])} style={{
                padding: '4px 10px', borderRadius: 6, border: '0.5px solid var(--border)',
                background: on ? 'var(--bg-tertiary)' : 'var(--bg-card)',
                fontFamily: 'var(--font-mono)', fontSize: 11, fontWeight: 600,
                color: on ? LEVEL_TONES[lv] : 'var(--fg-faint)',
                textTransform: 'uppercase', cursor: 'pointer', letterSpacing: '0.04em',
              }}>{lv}</button>
            );
          })}
        </div>

        <div style={{ display: 'flex', gap: 4, marginLeft: 'auto' }}>
          {sources.map(s => (
            <button key={s} onClick={() => setSource(s)} style={{
              padding: '4px 10px', borderRadius: 6, border: 'none',
              background: source === s ? 'var(--accent-tint)' : 'transparent',
              color: source === s ? 'var(--accent-active)' : 'var(--fg-muted)',
              fontFamily: 'var(--font-mono)', fontSize: 11, cursor: 'pointer',
            }}>{s}</button>
          ))}
        </div>
      </div>

      {/* Tail */}
      <div style={{
        flex: 1, overflowY: 'auto', background: '#1F1B16', color: '#E8E1D2',
        fontFamily: 'var(--font-mono)', fontSize: 12, lineHeight: 1.7,
        padding: '12px 0',
      }}>
        {filtered.map((l, i) => <LogRow key={i} l={l} />)}
        {follow && (
          <div style={{ padding: '6px 24px', display: 'flex', alignItems: 'center', gap: 8,
            color: '#A89B82', fontSize: 11 }}>
            <span style={{ width: 6, height: 6, borderRadius: 3, background: 'var(--green-500)',
              animation: 'pulse 1.4s ease-in-out infinite' }}></span>
            following — 4 lines/sec
          </div>
        )}
      </div>
      <style>{`
        @keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.3; } }
      `}</style>
    </div>
  );
}

function LogRow({ l }) {
  return (
    <div style={{
      display: 'flex', gap: 14, padding: '1px 24px', alignItems: 'baseline',
    }}>
      <span style={{ color: '#7C7263', fontSize: 11, width: 100, flexShrink: 0 }}>{l.ts}</span>
      <span style={{ color: LEVEL_TONES[l.level], width: 50, flexShrink: 0,
        textTransform: 'uppercase', fontSize: 10, fontWeight: 700, letterSpacing: '0.04em' }}>{l.level}</span>
      <span style={{ color: '#A89B82', width: 70, flexShrink: 0 }}>{l.source}</span>
      <span style={{ color: '#E8E1D2', flex: 1 }}>{l.msg}</span>
    </div>
  );
}

window.Logs = Logs;
