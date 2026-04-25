// Scarf Sidebar — sectioned nav matching SidebarView.swift
// Sections: Monitor / Projects / Interact / Configure / Manage

const SIDEBAR_SECTIONS = [
  { title: 'Monitor', items: [
    { id: 'dashboard', label: 'Dashboard', icon: 'layout-dashboard' },
    { id: 'insights', label: 'Insights', icon: 'bar-chart-3' },
    { id: 'sessions', label: 'Sessions', icon: 'messages-square' },
    { id: 'activity', label: 'Activity', icon: 'activity' },
  ]},
  { title: 'Projects', items: [
    { id: 'projects', label: 'Projects', icon: 'folder' },
  ]},
  { title: 'Interact', items: [
    { id: 'chat', label: 'Chat', icon: 'sparkles' },
    { id: 'memory', label: 'Memory', icon: 'database' },
    { id: 'skills', label: 'Skills', icon: 'wand-2' },
  ]},
  { title: 'Configure', items: [
    { id: 'platforms', label: 'Platforms', icon: 'cloud' },
    { id: 'personalities', label: 'Personalities', icon: 'user-circle' },
    { id: 'quickCommands', label: 'Quick Commands', icon: 'zap' },
    { id: 'credentialPools', label: 'Credentials', icon: 'key' },
    { id: 'plugins', label: 'Plugins', icon: 'puzzle' },
    { id: 'webhooks', label: 'Webhooks', icon: 'webhook' },
    { id: 'profiles', label: 'Profiles', icon: 'users' },
  ]},
  { title: 'Manage', items: [
    { id: 'tools', label: 'Tools', icon: 'wrench' },
    { id: 'mcpServers', label: 'MCP Servers', icon: 'server' },
    { id: 'gateway', label: 'Gateway', icon: 'network' },
    { id: 'cron', label: 'Cron', icon: 'clock' },
    { id: 'health', label: 'Health', icon: 'stethoscope' },
    { id: 'logs', label: 'Logs', icon: 'file-text' },
    { id: 'settings', label: 'Settings', icon: 'settings' },
  ]},
];

function ScarfSidebar({ active, onSelect }) {
  return (
    <aside style={{
      width: 224, height: '100%', display: 'flex', flexDirection: 'column',
      background: 'rgba(243, 242, 245, 0.7)',
      backdropFilter: 'blur(40px) saturate(180%)',
      WebkitBackdropFilter: 'blur(40px) saturate(180%)',
      borderRight: '0.5px solid var(--border)',
      paddingTop: 38, // space for traffic lights
      fontFamily: 'var(--font-sans)',
    }}>
      <div style={{ padding: '0 16px 12px', display: 'flex', alignItems: 'center', gap: 8 }}>
        <img src="../../assets/scarf-app-icon-128.png" width="22" height="22" style={{ borderRadius: 5 }} alt="" />
        <div style={{ fontSize: 14, fontWeight: 600, letterSpacing: '-0.01em' }}>Scarf</div>
        <div style={{ marginLeft: 'auto', fontSize: 10, color: 'var(--fg-faint)', fontFamily: 'var(--font-mono)' }}>local</div>
      </div>
      <div style={{ flex: 1, overflowY: 'auto', padding: '4px 8px 16px' }}>
        {SIDEBAR_SECTIONS.map(sec => (
          <div key={sec.title} style={{ marginBottom: 14 }}>
            <div style={{
              padding: '6px 10px 4px', fontSize: 10.5, fontWeight: 600,
              color: 'var(--fg-muted)', textTransform: 'uppercase', letterSpacing: '0.06em'
            }}>{sec.title}</div>
            {sec.items.map(it => {
              const isActive = active === it.id;
              return (
                <div key={it.id} onClick={() => onSelect && onSelect(it.id)}
                  style={{
                    display: 'flex', alignItems: 'center', gap: 9,
                    padding: '5px 10px', borderRadius: 6, cursor: 'pointer',
                    fontSize: 13, fontWeight: isActive ? 500 : 400,
                    color: isActive ? 'var(--accent-active)' : 'var(--fg)',
                    background: isActive ? 'var(--accent-tint)' : 'transparent',
                    transition: 'background 120ms',
                  }}>
                  <i data-lucide={it.icon} style={{ width: 15, height: 15 }}></i>
                  <span>{it.label}</span>
                </div>
              );
            })}
          </div>
        ))}
      </div>
      <div style={{
        padding: '10px 14px', borderTop: '0.5px solid var(--border)',
        display: 'flex', alignItems: 'center', gap: 8, fontSize: 12
      }}>
        <div style={{ width: 7, height: 7, borderRadius: '50%', background: 'var(--green-500)' }}></div>
        <span style={{ color: 'var(--fg-muted)' }}>Hermes running</span>
        <span style={{ marginLeft: 'auto', fontFamily: 'var(--font-mono)', color: 'var(--fg-faint)', fontSize: 11 }}>v0.42</span>
      </div>
    </aside>
  );
}

window.ScarfSidebar = ScarfSidebar;
window.SIDEBAR_SECTIONS = SIDEBAR_SECTIONS;
