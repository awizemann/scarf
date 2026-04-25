// Chat — three-pane: session list / transcript / inspector.
// Inspector defaults to ToolCall details for the focused tool call; falls
// back to session-level metadata. Transcript supports reasoning, multi-step
// tool calls, file diffs, and a slash-command palette in the composer.

const TOOL_TONES = {
  read:    { color: 'var(--green-500)',       tint: 'var(--green-100)',  icon: 'book-open',  label: 'Read'    },
  edit:    { color: 'var(--blue-500)',        tint: 'var(--blue-100)',   icon: 'file-edit',  label: 'Edit'    },
  execute: { color: 'var(--orange-500)',      tint: 'var(--orange-100)', icon: 'terminal',   label: 'Execute' },
  fetch:   { color: 'var(--purple-tool-500)', tint: '#EFE0F8',           icon: 'globe',      label: 'Fetch'   },
  browser: { color: 'var(--indigo-500)',      tint: '#E0E5F8',           icon: 'compass',    label: 'Browser' },
  search:  { color: 'var(--accent)',          tint: 'var(--accent-tint)',icon: 'search',     label: 'Search'  },
};

// ─────────────── Top-level Chat ───────────────
function Chat() {
  const [active, setActive] = React.useState('s1');
  const [focused, setFocused] = React.useState({ kind: 'tool', id: 'tc-2' }); // inspector subject
  const [composerOpen, setComposerOpen] = React.useState(false); // slash menu

  React.useEffect(() => {
    requestAnimationFrame(() => window.lucide && window.lucide.createIcons());
  });

  const sessions = [
    { id: 's1', title: 'Cron diagnostics', project: 'scarf', preview: 'The daily-summary job ran 14 minutes ago…', time: '14m', model: 'sonnet-4.5', unread: 0, pinned: true, status: 'live' },
    { id: 's2', title: 'Release notes draft', project: 'hermes-blog', preview: 'Pulled the merged PRs from this week…', time: '42m', model: 'haiku-4.5', unread: 2, status: 'idle' },
    { id: 's3', title: 'PR review summary',  project: 'hermes-blog', preview: 'Three PRs are ready for review.', time: '2h', model: 'sonnet-4.5', status: 'idle' },
    { id: 's4', title: 'Function calling models', project: '—', preview: 'Sonnet handles structured tool use…', time: '3h', model: 'haiku-4.5', status: 'idle' },
    { id: 's5', title: 'Memory layout question', project: 'scarf', preview: 'The shared memory keys live at…', time: 'yesterday', model: 'sonnet-4.5', status: 'idle' },
    { id: 's6', title: 'Catalog publish flow', project: 'hermes-blog', preview: 'Walked through the .scarftemplate bundle…', time: 'yesterday', model: 'sonnet-4.5', status: 'idle' },
    { id: 's7', title: 'SSH tunnel debug', project: 'scarf-remote', preview: 'Connection drops after ~90s of idle…', time: 'Mon', model: 'sonnet-4.5', status: 'error' },
  ];

  return (
    <div style={{ display: 'flex', height: '100%', overflow: 'hidden' }}>
      <ChatList sessions={sessions} active={active} setActive={setActive} />
      <Transcript focused={focused} setFocused={setFocused} composerOpen={composerOpen} setComposerOpen={setComposerOpen} />
      <Inspector focused={focused} setFocused={setFocused} />
    </div>
  );
}

// ─────────────── Pane 1 — session list ───────────────
function ChatList({ sessions, active, setActive }) {
  const [filter, setFilter] = React.useState('all');
  return (
    <div style={{
      width: 264, borderRight: '0.5px solid var(--border)',
      background: 'var(--gray-50)', display: 'flex', flexDirection: 'column'
    }}>
      <div style={{ padding: '14px 14px 8px', display: 'flex', alignItems: 'center', gap: 8 }}>
        <div style={{ flex: 1, fontFamily: 'var(--font-display)', fontSize: 17, fontWeight: 600 }}>Chats</div>
        <IconBtn icon="search" tooltip="Search ⌘F" />
        <Btn size="sm" kind="primary" icon="plus">New</Btn>
      </div>

      <div style={{ padding: '0 12px 8px' }}>
        <Segmented value={filter} onChange={setFilter} size="sm" options={[
          { value: 'all', label: 'All', count: sessions.length },
          { value: 'live', label: 'Live', count: 1 },
          { value: 'pinned', label: 'Pinned', count: 1 },
        ]} />
      </div>

      <div style={{ flex: 1, overflowY: 'auto', padding: '0 6px 8px' }}>
        <SessionGroupHeader>Today</SessionGroupHeader>
        {sessions.slice(0, 4).map(s => <SessionRow key={s.id} s={s} active={active === s.id} onClick={() => setActive(s.id)} />)}
        <SessionGroupHeader>Earlier</SessionGroupHeader>
        {sessions.slice(4).map(s => <SessionRow key={s.id} s={s} active={active === s.id} onClick={() => setActive(s.id)} />)}
      </div>

      <div style={{ padding: '8px 14px', borderTop: '0.5px solid var(--border)',
        display: 'flex', alignItems: 'center', gap: 8, fontSize: 11, color: 'var(--fg-muted)' }}>
        <i data-lucide="message-square" style={{ width: 12, height: 12 }}></i>
        <span>{sessions.length} chats</span>
        <span style={{ marginLeft: 'auto', fontFamily: 'var(--font-mono)', fontSize: 10 }}>1.2 MB · state.db</span>
      </div>
    </div>
  );
}

function SessionGroupHeader({ children }) {
  return (
    <div style={{
      padding: '10px 10px 4px', fontSize: 10, fontWeight: 600,
      color: 'var(--fg-muted)', textTransform: 'uppercase', letterSpacing: '0.06em',
    }}>{children}</div>
  );
}

function SessionRow({ s, active, onClick }) {
  const [hover, setHover] = React.useState(false);
  const statusColor = s.status === 'live' ? 'var(--green-500)' : s.status === 'error' ? 'var(--red-500)' : 'var(--gray-400)';
  return (
    <div onClick={onClick} onMouseEnter={() => setHover(true)} onMouseLeave={() => setHover(false)}
      style={{
        padding: '8px 10px', borderRadius: 7, cursor: 'pointer', marginBottom: 1,
        background: active ? 'var(--accent-tint)' : (hover ? 'var(--bg-quaternary)' : 'transparent'),
        position: 'relative',
      }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 7 }}>
        {s.status === 'live'
          ? <span style={{ width: 7, height: 7, borderRadius: '50%', background: statusColor,
              boxShadow: '0 0 0 2px rgba(42,168,118,0.20)' }}></span>
          : <span style={{ width: 6, height: 6, borderRadius: '50%', background: statusColor }}></span>}
        {s.pinned && <i data-lucide="pin" style={{ width: 11, height: 11, color: 'var(--accent)' }}></i>}
        <div style={{ flex: 1, fontSize: 13, fontWeight: 500,
          color: active ? 'var(--accent-active)' : 'var(--fg)',
          whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{s.title}</div>
        <div style={{ fontSize: 10, color: 'var(--fg-faint)', fontFamily: 'var(--font-mono)' }}>{s.time}</div>
      </div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginTop: 4, paddingLeft: 14 }}>
        {s.project !== '—' && <span style={{
          fontSize: 10, fontWeight: 500, color: 'var(--fg-muted)', fontFamily: 'var(--font-mono)',
          background: 'var(--bg-card)', border: '0.5px solid var(--border)',
          padding: '0 5px', borderRadius: 4,
        }}>{s.project}</span>}
        <div style={{ flex: 1, fontSize: 11, color: 'var(--fg-muted)',
          whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{s.preview}</div>
        {s.unread > 0 && <span style={{
          fontSize: 9, fontWeight: 700, fontFamily: 'var(--font-mono)',
          padding: '1px 5px', borderRadius: 999, background: 'var(--accent)', color: '#fff', minWidth: 14, textAlign: 'center',
        }}>{s.unread}</span>}
      </div>
    </div>
  );
}

// ─────────────── Pane 2 — transcript ───────────────
function Transcript({ focused, setFocused, composerOpen, setComposerOpen }) {
  return (
    <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0,
      background: 'var(--bg)' }}>
      <TranscriptHeader />
      <div style={{ flex: 1, overflowY: 'auto', padding: '20px 28px 8px',
        display: 'flex', flexDirection: 'column', gap: 16, scrollBehavior: 'smooth' }}>

        <DateMarker>Today · 9:42 AM</DateMarker>

        <UserMsg time="9:42 AM">What's the status of the daily-summary cron job? I need to know if it's healthy before I push the new schedule changes.</UserMsg>

        <AssistantMsg time="9:42 AM" tokens={284} model="sonnet-4.5" durationMs={2140}>
          <Reasoning tokens={127} preview="Check the registry first, then the most recent execution." />
          <ToolCall id="tc-1" kind="read" name="read_file" arg="~/.scarf/cron/jobs.json" duration="86 ms" focus={focused} setFocus={setFocused} />
          <ToolCall id="tc-2" kind="execute" name="execute" arg='hermes cron status daily-summary' duration="1.4 s" focus={focused} setFocus={setFocused} expanded />
          <p style={msgPara}>
            The <code style={inlineCode}>daily-summary</code> job ran <strong>14 minutes ago</strong> and completed
            successfully in 14.2 s, using 1,847 tokens. Next run is scheduled for tomorrow at 09:00 — safe to ship the schedule changes.
          </p>
          <MsgFooter />
        </AssistantMsg>

        <UserMsg time="9:43 AM">Show me what it produced.</UserMsg>

        <AssistantMsg time="9:43 AM" tokens={612} model="sonnet-4.5" inProgress durationMs={4280}>
          <ToolCall id="tc-3" kind="read" name="read_file" arg="~/.scarf/cron/output/daily-summary.md" duration="42 ms" focus={focused} setFocus={setFocused} />
          <p style={msgPara}>The latest summary covers <strong>April 24, 2026</strong>. Highlights:</p>
          <ul style={{ ...msgPara, paddingLeft: 18, margin: '4px 0' }}>
            <li>3 PRs merged across <code style={inlineCode}>hermes</code> and <code style={inlineCode}>scarf</code></li>
            <li>2 cron failures auto-recovered (gateway timeouts)</li>
            <li>Token spend down 8% week-over-week</li>
          </ul>
          <ToolCall id="tc-4" kind="edit" name="apply_patch" arg="~/.scarf/cron/jobs.json" duration="120 ms" diff focus={focused} setFocus={setFocused} />
        </AssistantMsg>

        <SuggestedReplies items={['Schedule a dry run', 'Show last 5 runs', 'Disable daily-summary']} />
      </div>

      <Composer open={composerOpen} setOpen={setComposerOpen} />
    </div>
  );
}

function TranscriptHeader() {
  return (
    <div style={{
      padding: '14px 24px', borderBottom: '0.5px solid var(--border)',
      display: 'flex', alignItems: 'center', gap: 12, background: 'var(--bg-card)',
    }}>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <i data-lucide="pin" style={{ width: 13, height: 13, color: 'var(--accent)' }}></i>
          <div style={{ fontSize: 14, fontWeight: 600 }}>Cron diagnostics</div>
          <Pill tone="green" dot size="sm">live</Pill>
        </div>
        <div style={{ fontSize: 11, color: 'var(--fg-muted)', display: 'flex', gap: 10, marginTop: 3, alignItems: 'center', flexWrap: 'wrap' }}>
          <span style={{ display: 'inline-flex', alignItems: 'center', gap: 4 }}>
            <i data-lucide="folder" style={{ width: 11, height: 11, color: 'var(--accent)' }}></i>
            <span style={{ color: 'var(--accent)', fontWeight: 600 }}>scarf</span>
          </span>
          <span style={{ color: 'var(--fg-faint)' }}>·</span>
          <span style={{ fontFamily: 'var(--font-mono)' }}>claude-sonnet-4.5</span>
          <span style={{ color: 'var(--fg-faint)' }}>·</span>
          <span>14 messages</span>
          <span style={{ color: 'var(--fg-faint)' }}>·</span>
          <span style={{ fontFamily: 'var(--font-mono)' }}>12,847 tok</span>
          <span style={{ color: 'var(--fg-faint)' }}>·</span>
          <span style={{ fontFamily: 'var(--font-mono)' }}>$0.0421</span>
        </div>
      </div>
      <Btn size="sm" kind="ghost" icon="git-branch">Branch</Btn>
      <Btn size="sm" kind="secondary" icon="share">Share</Btn>
      <IconBtn icon="more-horizontal" tooltip="More" />
    </div>
  );
}

function DateMarker({ children }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 10, color: 'var(--fg-faint)' }}>
      <div style={{ flex: 1, height: 1, background: 'var(--border)' }}></div>
      <span style={{ fontSize: 10, fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.06em' }}>{children}</span>
      <div style={{ flex: 1, height: 1, background: 'var(--border)' }}></div>
    </div>
  );
}

const msgPara = { fontSize: 14, lineHeight: 1.55, color: 'var(--fg)', margin: '6px 0' };
const inlineCode = { fontFamily: 'var(--font-mono)', fontSize: 12.5,
  background: 'var(--bg-quaternary)', padding: '1px 5px', borderRadius: 4 };

function UserMsg({ time, children }) {
  return (
    <div style={{ display: 'flex', justifyContent: 'flex-end', flexDirection: 'column', alignItems: 'flex-end' }}>
      <div style={{
        maxWidth: '76%', padding: '10px 14px', borderRadius: 14, borderBottomRightRadius: 4,
        background: 'var(--accent)', color: 'var(--on-accent)', fontSize: 14, lineHeight: 1.5,
        boxShadow: '0 1px 0 rgba(0,0,0,0.06)',
      }}>{children}</div>
      <div style={{ fontSize: 10, color: 'var(--fg-faint)', marginTop: 4, marginRight: 4,
        display: 'flex', gap: 6, alignItems: 'center' }}>
        <i data-lucide="check-check" style={{ width: 11, height: 11, color: 'var(--green-500)' }}></i>
        <span>{time}</span>
      </div>
    </div>
  );
}

function AssistantMsg({ time, tokens, model, inProgress, durationMs, children }) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'flex-start', maxWidth: '88%', position: 'relative' }}>
      <div style={{ display: 'flex', alignItems: 'flex-start', gap: 10, width: '100%' }}>
        <div style={{
          width: 26, height: 26, borderRadius: 7, marginTop: 2, flexShrink: 0,
          background: 'var(--gradient-brand)',
          display: 'flex', alignItems: 'center', justifyContent: 'center', color: '#fff',
          boxShadow: '0 1px 2px rgba(122, 46, 20, 0.25)',
        }}>
          <i data-lucide="sparkles" style={{ width: 14, height: 14 }}></i>
        </div>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{
            background: 'var(--bg-card)', borderRadius: 12,
            border: '0.5px solid var(--border)',
            padding: '12px 14px', boxShadow: 'var(--shadow-sm)',
          }}>{children}</div>
          <div style={{ fontSize: 10, color: 'var(--fg-faint)', marginTop: 4, marginLeft: 4,
            display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
            {inProgress && <span style={{ display: 'inline-flex', alignItems: 'center', gap: 4 }}>
              <span style={{
                width: 7, height: 7, borderRadius: '50%', background: 'var(--accent)',
                animation: 'pulseScarf 1.4s ease-in-out infinite',
              }}></span>
              <span style={{ color: 'var(--accent)', fontWeight: 600 }}>thinking…</span>
            </span>}
            <span style={{ fontFamily: 'var(--font-mono)' }}>{model}</span>
            <span>·</span>
            <span style={{ fontFamily: 'var(--font-mono)' }}>{tokens} tok</span>
            <span>·</span>
            <span>{(durationMs / 1000).toFixed(1)}s</span>
            <span>·</span>
            <span>{time}</span>
          </div>
        </div>
      </div>
    </div>
  );
}

function MsgFooter() {
  const Btnn = ({ icon, label }) => {
    const [hover, setHover] = React.useState(false);
    return (
      <button onMouseEnter={() => setHover(true)} onMouseLeave={() => setHover(false)} style={{
        padding: '3px 7px', fontSize: 11, color: hover ? 'var(--fg)' : 'var(--fg-muted)',
        background: hover ? 'var(--bg-quaternary)' : 'transparent',
        border: 'none', borderRadius: 5, cursor: 'pointer',
        display: 'inline-flex', alignItems: 'center', gap: 4, fontFamily: 'var(--font-sans)',
      }}>
        <i data-lucide={icon} style={{ width: 11, height: 11 }}></i>{label}
      </button>
    );
  };
  return (
    <div style={{ display: 'flex', gap: 2, marginTop: 6, paddingTop: 6, borderTop: '0.5px solid var(--border)' }}>
      <Btnn icon="copy" label="Copy" />
      <Btnn icon="thumbs-up" label="" />
      <Btnn icon="thumbs-down" label="" />
      <Btnn icon="rotate-cw" label="Retry" />
      <div style={{ flex: 1 }}></div>
      <Btnn icon="pin" label="Pin" />
    </div>
  );
}

// ─────────────── Reasoning disclosure ───────────────
function Reasoning({ tokens, preview, children }) {
  const [open, setOpen] = React.useState(false);
  return (
    <div style={{ marginBottom: 8, background: 'var(--orange-100)', borderRadius: 7,
      padding: '6px 10px', border: '0.5px solid rgba(240, 173, 78, 0.3)' }}>
      <div onClick={() => setOpen(!open)} style={{
        cursor: 'pointer', fontSize: 11, fontWeight: 600,
        display: 'flex', alignItems: 'center', gap: 5, color: '#A8741F',
      }}>
        <i data-lucide="brain" style={{ width: 12, height: 12 }}></i>
        <span style={{ textTransform: 'uppercase', letterSpacing: '0.04em' }}>Reasoning</span>
        <span style={{ color: 'var(--fg-faint)', fontWeight: 500, fontFamily: 'var(--font-mono)' }}>· {tokens} tok</span>
        <span style={{ flex: 1 }}></span>
        <i data-lucide={open ? 'chevron-down' : 'chevron-right'} style={{ width: 12, height: 12 }}></i>
      </div>
      {!open && preview && (
        <div style={{ fontSize: 12, color: 'var(--fg-muted)', marginTop: 3,
          fontStyle: 'italic', lineHeight: 1.5,
          whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{preview}</div>
      )}
      {open && (
        <div style={{ fontSize: 12.5, color: 'var(--fg-muted)', lineHeight: 1.55,
          padding: '6px 0 2px', fontStyle: 'italic' }}>
          The user wants the status of a specific cron job named "daily-summary".
          I should check the cron registry first, then look at the most recent execution
          via <code style={inlineCode}>hermes cron status</code>. If exit_code is 0,
          the job is healthy and the schedule push is safe.
        </div>
      )}
    </div>
  );
}

// ─────────────── ToolCall card ───────────────
function ToolCall({ id, kind, name, arg, duration, expanded: initial, diff, focus, setFocus }) {
  const [open, setOpen] = React.useState(initial || false);
  const t = TOOL_TONES[kind] || TOOL_TONES.read;
  const isFocused = focus.kind === 'tool' && focus.id === id;

  return (
    <div style={{ marginBottom: 5 }}>
      <div onClick={() => { setOpen(!open); setFocus({ kind: 'tool', id }); }} style={{
        background: isFocused ? t.tint : 'var(--bg-quaternary)',
        border: `0.5px solid ${isFocused ? t.color : 'var(--border)'}`,
        outline: isFocused ? `1px solid ${t.color}` : 'none', outlineOffset: '-1px',
        borderRadius: 7, padding: '6px 10px',
        display: 'flex', alignItems: 'center', gap: 9,
        fontSize: 12, cursor: 'pointer', transition: 'all 120ms',
      }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 5 }}>
          <i data-lucide={t.icon} style={{ width: 12, height: 12, color: t.color }}></i>
          <span style={{ fontSize: 10, fontWeight: 700, color: t.color,
            textTransform: 'uppercase', letterSpacing: '0.04em' }}>{t.label}</span>
        </div>
        <span style={{ fontFamily: 'var(--font-mono)', fontWeight: 600, color: 'var(--fg)' }}>{name}</span>
        <span style={{ fontFamily: 'var(--font-mono)', color: 'var(--fg-muted)', flex: 1, minWidth: 0,
          whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{arg}</span>
        <span style={{ fontFamily: 'var(--font-mono)', fontSize: 10, color: 'var(--fg-faint)' }}>{duration}</span>
        <i data-lucide="check-circle-2" style={{ width: 13, height: 13, color: 'var(--green-500)' }}></i>
        <i data-lucide={open ? 'chevron-down' : 'chevron-right'} style={{ width: 12, height: 12, color: 'var(--fg-faint)' }}></i>
      </div>
      {open && (
        diff
          ? <DiffPreview />
          : <ToolOutput kind={kind} />
      )}
    </div>
  );
}

function ToolOutput({ kind }) {
  if (kind === 'execute') {
    return (
      <div style={{
        background: 'var(--gray-900)', color: '#E8E1D2', borderRadius: 7,
        padding: '10px 12px', fontFamily: 'var(--font-mono)', fontSize: 11.5,
        marginTop: 6, lineHeight: 1.55, overflow: 'auto',
        border: '1px solid var(--gray-800)',
      }}>
        <div><span style={{ color: '#7A7367' }}>$</span> <span style={{ color: '#EFC59E' }}>hermes</span> cron status daily-summary</div>
        <div style={{ marginTop: 4 }}>
          <span style={{ color: '#2AA876' }}>✓</span> <span style={{ color: '#A39C92' }}>last_run</span>:    <span>2026-04-25T09:28:14Z</span><br/>
          <span style={{ color: '#2AA876' }}>✓</span> <span style={{ color: '#A39C92' }}>duration</span>:    <span>14.2s</span><br/>
          <span style={{ color: '#2AA876' }}>✓</span> <span style={{ color: '#A39C92' }}>exit_code</span>:   <span>0</span><br/>
          <span style={{ color: '#2AA876' }}>✓</span> <span style={{ color: '#A39C92' }}>tokens_used</span>: <span>1,847</span><br/>
          <span style={{ color: '#A39C92' }}>next_run</span>:    <span>2026-04-26T09:00:00Z</span>
        </div>
      </div>
    );
  }
  // read
  return (
    <div style={{
      background: 'var(--bg-card)', borderRadius: 7,
      padding: '8px 12px', fontFamily: 'var(--font-mono)', fontSize: 11.5,
      marginTop: 6, lineHeight: 1.6, color: 'var(--fg-muted)',
      border: '0.5px solid var(--border)', maxHeight: 120, overflow: 'auto',
    }}>
      <div><span style={{ color: 'var(--fg-faint)' }}>1</span>  &#123;</div>
      <div><span style={{ color: 'var(--fg-faint)' }}>2</span>    "name": "daily-summary",</div>
      <div><span style={{ color: 'var(--fg-faint)' }}>3</span>    "schedule": "0 9 * * *",</div>
      <div><span style={{ color: 'var(--fg-faint)' }}>4</span>    "enabled": true</div>
      <div><span style={{ color: 'var(--fg-faint)' }}>5</span>  &#125;</div>
    </div>
  );
}

function DiffPreview() {
  return (
    <div style={{
      background: 'var(--bg-card)', borderRadius: 7,
      padding: '8px 12px', fontFamily: 'var(--font-mono)', fontSize: 11.5,
      marginTop: 6, lineHeight: 1.6, color: 'var(--fg)',
      border: '0.5px solid var(--border)',
    }}>
      <div><span style={{ color: 'var(--fg-faint)', display: 'inline-block', width: 22 }}>3</span><span>  "schedule": "0 9 * * *",</span></div>
      <div style={{ background: 'rgba(217, 83, 79, 0.10)' }}>
        <span style={{ color: 'var(--red-600)', display: 'inline-block', width: 22 }}>-</span>
        <span>  "timezone": "UTC",</span>
      </div>
      <div style={{ background: 'rgba(42, 168, 118, 0.10)' }}>
        <span style={{ color: 'var(--green-600)', display: 'inline-block', width: 22 }}>+</span>
        <span>  "timezone": "America/New_York",</span>
      </div>
      <div><span style={{ color: 'var(--fg-faint)', display: 'inline-block', width: 22 }}>5</span><span>  "enabled": true</span></div>
    </div>
  );
}

// ─────────────── Suggested replies ───────────────
function SuggestedReplies({ items }) {
  return (
    <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', marginTop: 4, paddingLeft: 36 }}>
      {items.map(s => (
        <button key={s} style={{
          fontSize: 12, padding: '5px 10px', borderRadius: 999,
          background: 'var(--bg-card)', border: '0.5px solid var(--border-strong)',
          color: 'var(--fg)', fontFamily: 'var(--font-sans)', cursor: 'pointer',
          display: 'inline-flex', alignItems: 'center', gap: 4,
        }}>
          <i data-lucide="sparkles" style={{ width: 11, height: 11, color: 'var(--accent)' }}></i>
          {s}
        </button>
      ))}
    </div>
  );
}

// ─────────────── Composer ───────────────
const SLASH_COMMANDS = [
  { cmd: 'compress', desc: 'Compress conversation context', icon: 'minimize-2' },
  { cmd: 'clear',    desc: 'Clear and start fresh',         icon: 'trash-2' },
  { cmd: 'model',    desc: 'Switch model',                  icon: 'cpu' },
  { cmd: 'project',  desc: 'Change project',                icon: 'folder' },
  { cmd: 'memory',   desc: 'Edit AGENTS.md',                icon: 'database' },
  { cmd: 'cost',     desc: 'Show token / cost report',      icon: 'circle-dollar-sign' },
];

function Composer({ open, setOpen }) {
  const [text, setText] = React.useState('');
  const onChange = e => {
    const v = e.currentTarget.innerText;
    setText(v);
    setOpen(v.trim().startsWith('/'));
  };
  return (
    <div style={{
      borderTop: '0.5px solid var(--border)', padding: '12px 24px 14px',
      background: 'var(--bg-card)', position: 'relative',
    }}>
      {open && (
        <div style={{
          position: 'absolute', bottom: 'calc(100% - 4px)', left: 24, right: 24,
          background: 'var(--bg-card)', border: '0.5px solid var(--border)',
          borderRadius: 9, boxShadow: 'var(--shadow-lg)', padding: 4, maxWidth: 360,
        }}>
          <div style={{ padding: '4px 8px 6px', fontSize: 10, fontWeight: 600,
            color: 'var(--fg-muted)', textTransform: 'uppercase', letterSpacing: '0.06em' }}>
            Slash commands
          </div>
          {SLASH_COMMANDS.map((c, i) => (
            <div key={c.cmd} style={{
              display: 'flex', alignItems: 'center', gap: 9, padding: '6px 8px',
              borderRadius: 6, fontSize: 13, cursor: 'pointer',
              background: i === 0 ? 'var(--accent-tint)' : 'transparent',
              color: i === 0 ? 'var(--accent-active)' : 'var(--fg)',
            }}>
              <i data-lucide={c.icon} style={{ width: 14, height: 14 }}></i>
              <span style={{ fontFamily: 'var(--font-mono)', fontWeight: 600 }}>/{c.cmd}</span>
              <span style={{ flex: 1, color: 'var(--fg-muted)', fontSize: 12 }}>{c.desc}</span>
              {i === 0 && <KbdKey>↵</KbdKey>}
            </div>
          ))}
        </div>
      )}

      <div style={{
        display: 'flex', flexDirection: 'column', gap: 8,
        border: `1px solid ${open ? 'var(--accent)' : 'var(--border-strong)'}`,
        borderRadius: 12, padding: '10px 12px',
        background: 'var(--bg-card)',
        boxShadow: open ? 'var(--shadow-focus)' : 'none',
        transition: 'box-shadow 120ms, border-color 120ms',
      }}>
        {/* Attached context chips */}
        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
          <ContextChip icon="folder" label="scarf" tone="accent" />
          <ContextChip icon="file-text" label="cron/jobs.json" />
          <ContextChip icon="plus" label="Add context" muted />
        </div>

        {/* Input */}
        <div contentEditable suppressContentEditableWarning onInput={onChange}
          style={{
            fontSize: 14, fontFamily: 'var(--font-sans)', outline: 'none',
            color: 'var(--fg)', padding: '2px 0', minHeight: 22, maxHeight: 160, overflowY: 'auto',
            lineHeight: 1.5,
          }}
          data-placeholder="Message Hermes…  /  for commands  ·  @  for files"></div>

        {/* Footer row */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
          <ComposerChip icon="paperclip" label="" />
          <ComposerChip icon="at-sign" label="@" />
          <ComposerChip icon="image" label="" />
          <Divider vertical />
          <ComposerChip icon="cpu" label="sonnet-4.5" />
          <ComposerChip icon="folder" label="scarf" />

          <div style={{ flex: 1 }}></div>

          <span style={{ fontSize: 11, color: 'var(--fg-faint)', fontFamily: 'var(--font-mono)' }}>
            ↵ send · ⇧↵ newline
          </span>
          <button style={{
            width: 30, height: 30, borderRadius: 8, background: 'var(--accent)',
            color: '#fff', border: 'none', cursor: 'pointer',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            boxShadow: '0 1px 2px rgba(122, 46, 20, 0.3)',
          }}>
            <i data-lucide="arrow-up" style={{ width: 15, height: 15 }}></i>
          </button>
        </div>
      </div>
    </div>
  );
}

function ContextChip({ icon, label, tone, muted }) {
  return (
    <div style={{
      display: 'inline-flex', alignItems: 'center', gap: 5,
      padding: '2px 8px', borderRadius: 999, fontSize: 11, fontWeight: 500,
      background: tone === 'accent' ? 'var(--accent-tint)' : 'var(--bg-quaternary)',
      color: tone === 'accent' ? 'var(--accent-active)' : (muted ? 'var(--fg-muted)' : 'var(--fg)'),
      fontFamily: tone === 'accent' ? 'var(--font-sans)' : 'var(--font-mono)',
      border: muted ? '0.5px dashed var(--border-strong)' : 'none',
      cursor: muted ? 'pointer' : 'default',
    }}>
      <i data-lucide={icon} style={{ width: 11, height: 11 }}></i>{label}
    </div>
  );
}

function ComposerChip({ icon, label }) {
  const [hover, setHover] = React.useState(false);
  return (
    <button onMouseEnter={() => setHover(true)} onMouseLeave={() => setHover(false)} style={{
      display: 'inline-flex', alignItems: 'center', gap: 4,
      padding: label ? '3px 7px' : '4px', borderRadius: 6, fontSize: 12,
      background: hover ? 'var(--bg-quaternary)' : 'transparent',
      color: 'var(--fg-muted)', border: 'none', cursor: 'pointer',
      fontFamily: 'var(--font-mono)',
    }}>
      <i data-lucide={icon} style={{ width: 13, height: 13 }}></i>{label}
    </button>
  );
}

// ─────────────── Pane 3 — Inspector ───────────────
function Inspector({ focused }) {
  const [tab, setTab] = React.useState('details');
  // Find the focused tool call. For demo, hard-code tc-2 details.
  const FOCUS_DATA = {
    'tc-1': { kind: 'read', name: 'read_file', arg: '~/.scarf/cron/jobs.json',
      duration: '86 ms', startedAt: '09:42:18.214', tokens: 412 },
    'tc-2': { kind: 'execute', name: 'execute', arg: 'hermes cron status daily-summary',
      duration: '1.4 s', startedAt: '09:42:18.302', tokens: 86,
      cwd: '~/.scarf', exitCode: 0 },
    'tc-3': { kind: 'read', name: 'read_file', arg: '~/.scarf/cron/output/daily-summary.md',
      duration: '42 ms', startedAt: '09:43:01.190', tokens: 1284 },
    'tc-4': { kind: 'edit', name: 'apply_patch', arg: '~/.scarf/cron/jobs.json',
      duration: '120 ms', startedAt: '09:43:03.910', tokens: 88, linesAdded: 1, linesRemoved: 1 },
  };
  const data = FOCUS_DATA[focused.id] || FOCUS_DATA['tc-2'];
  const t = TOOL_TONES[data.kind];

  return (
    <aside style={{
      width: 320, borderLeft: '0.5px solid var(--border)',
      background: 'var(--bg-card)', display: 'flex', flexDirection: 'column',
    }}>
      {/* Header */}
      <div style={{ padding: '14px 16px 10px', borderBottom: '0.5px solid var(--border)' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 10 }}>
          <div style={{
            width: 24, height: 24, borderRadius: 6,
            background: t.tint, color: t.color,
            display: 'flex', alignItems: 'center', justifyContent: 'center',
          }}>
            <i data-lucide={t.icon} style={{ width: 13, height: 13 }}></i>
          </div>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ fontSize: 10, fontWeight: 700, color: t.color,
              textTransform: 'uppercase', letterSpacing: '0.05em' }}>{t.label} call</div>
            <div style={{ fontSize: 13, fontWeight: 600, fontFamily: 'var(--font-mono)',
              whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{data.name}</div>
          </div>
          <IconBtn icon="x" tooltip="Close inspector" />
        </div>
        <Tabs value={tab} onChange={setTab} options={[
          { value: 'details', label: 'Details', icon: 'info' },
          { value: 'output',  label: 'Output',  icon: 'terminal' },
          { value: 'raw',     label: 'Raw',     icon: 'braces' },
        ]} />
      </div>

      <div style={{ flex: 1, overflowY: 'auto', padding: 16 }}>
        {tab === 'details' && <InspectorDetails data={data} t={t} />}
        {tab === 'output'  && <InspectorOutput  data={data} t={t} />}
        {tab === 'raw'     && <InspectorRaw     data={data} />}
      </div>

      {/* Footer */}
      <div style={{ padding: '10px 16px', borderTop: '0.5px solid var(--border)',
        display: 'flex', gap: 6 }}>
        <Btn size="sm" kind="secondary" icon="rotate-cw" fullWidth>Re-run</Btn>
        <Btn size="sm" kind="ghost" icon="copy">Copy</Btn>
      </div>
    </aside>
  );
}

function InspectorDetails({ data, t }) {
  return (
    <div>
      <Section title="Status">
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '8px 10px',
          background: 'var(--green-100)', borderRadius: 7,
          border: '0.5px solid rgba(42, 168, 118, 0.25)' }}>
          <i data-lucide="check-circle-2" style={{ width: 16, height: 16, color: 'var(--green-600)' }}></i>
          <div style={{ flex: 1 }}>
            <div style={{ fontSize: 12, fontWeight: 600, color: 'var(--green-600)' }}>Completed</div>
            <div style={{ fontSize: 11, color: 'var(--fg-muted)' }}>Exit 0 · No errors</div>
          </div>
        </div>
      </Section>

      <div style={{ marginTop: 18 }}>
        <Section title="Arguments">
          <div style={{
            background: 'var(--bg-quaternary)', borderRadius: 7, padding: '8px 10px',
            fontFamily: 'var(--font-mono)', fontSize: 11.5, lineHeight: 1.5,
            color: 'var(--fg)', wordBreak: 'break-all',
          }}>{data.arg}</div>
        </Section>
      </div>

      <div style={{ marginTop: 18 }}>
        <Section title="Telemetry">
          <KV k="Started"   v={data.startedAt} mono />
          <KV k="Duration"  v={data.duration} mono />
          <KV k="Tokens"    v={data.tokens.toLocaleString()} mono />
          {data.exitCode != null && <KV k="Exit code" v={data.exitCode} mono color="var(--green-600)" />}
          {data.cwd && <KV k="CWD" v={data.cwd} mono />}
          {data.linesAdded != null && (
            <KV k="Diff" v={
              <span style={{ fontFamily: 'var(--font-mono)' }}>
                <span style={{ color: 'var(--green-600)' }}>+{data.linesAdded}</span>
                <span style={{ color: 'var(--fg-faint)' }}> / </span>
                <span style={{ color: 'var(--red-600)' }}>−{data.linesRemoved}</span>
              </span>
            } />
          )}
        </Section>
      </div>

      <div style={{ marginTop: 18 }}>
        <Section title="Permissions" hint="Tool gateway policy applied at run time">
          <div style={{
            background: 'var(--bg-quaternary)', borderRadius: 7, padding: '10px',
            fontSize: 12, color: 'var(--fg-muted)', display: 'flex', flexDirection: 'column', gap: 6,
          }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
              <i data-lucide="shield-check" style={{ width: 13, height: 13, color: 'var(--green-500)' }}></i>
              <span>Allowed by <code style={inlineCode}>scarf-default</code> profile</span>
            </div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
              <i data-lucide="check" style={{ width: 13, height: 13, color: 'var(--green-500)' }}></i>
              <span>No human approval required</span>
            </div>
          </div>
        </Section>
      </div>
    </div>
  );
}

function InspectorOutput({ data, t }) {
  return (
    <div>
      <Section title="stdout" right={<KbdKey>⌘C</KbdKey>}>
        <div style={{
          background: 'var(--gray-900)', color: '#E8E1D2', borderRadius: 7,
          padding: '10px 12px', fontFamily: 'var(--font-mono)', fontSize: 11,
          lineHeight: 1.6, overflow: 'auto',
        }}>
          <div><span style={{ color: '#7A7367' }}>$</span> <span style={{ color: '#EFC59E' }}>hermes</span> cron status daily-summary</div>
          <div style={{ marginTop: 6 }}>
            <span style={{ color: '#2AA876' }}>✓</span> last_run:    2026-04-25T09:28:14Z<br/>
            <span style={{ color: '#2AA876' }}>✓</span> duration:    14.2s<br/>
            <span style={{ color: '#2AA876' }}>✓</span> exit_code:   0<br/>
            <span style={{ color: '#2AA876' }}>✓</span> tokens_used: 1,847<br/>
            next_run:    2026-04-26T09:00:00Z<br/>
            schedule:    0 9 * * *<br/>
            timezone:    America/New_York
          </div>
        </div>
      </Section>
      <div style={{ marginTop: 16 }}>
        <Section title="stderr">
          <div style={{ background: 'var(--bg-quaternary)', borderRadius: 7, padding: '10px',
            fontFamily: 'var(--font-mono)', fontSize: 11.5, color: 'var(--fg-faint)' }}>
            (empty)
          </div>
        </Section>
      </div>
    </div>
  );
}

function InspectorRaw({ data }) {
  return (
    <div style={{
      background: 'var(--gray-900)', color: '#E8E1D2', borderRadius: 7,
      padding: '12px', fontFamily: 'var(--font-mono)', fontSize: 11,
      lineHeight: 1.55,
    }}>
{`{
  "id": "${data.kind === 'execute' ? 'tc-2' : 'tc-x'}",
  "type": "tool_use",
  "name": "${data.name}",
  "input": {
    "command": "hermes cron status daily-summary",
    "cwd": "~/.scarf"
  },
  "result": {
    "exit_code": 0,
    "duration_ms": 1402,
    "stdout_bytes": 287
  }
}`}
    </div>
  );
}

function KV({ k, v, mono, color }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', padding: '5px 0',
      borderBottom: '0.5px solid var(--border)' }}>
      <span style={{ fontSize: 12, color: 'var(--fg-muted)', flex: '0 0 90px' }}>{k}</span>
      <span style={{
        fontSize: 12, color: color || 'var(--fg)',
        fontFamily: mono ? 'var(--font-mono)' : 'var(--font-sans)', flex: 1, textAlign: 'right',
      }}>{v}</span>
    </div>
  );
}

window.Chat = Chat;
