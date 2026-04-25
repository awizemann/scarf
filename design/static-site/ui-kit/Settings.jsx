// Settings — global preferences. One scrollable page with grouped settings.

function Settings() {
  React.useEffect(() => { requestAnimationFrame(() => window.lucide && window.lucide.createIcons()); });
  const [tab, setTab] = React.useState('general');

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%' }}>
      <ContentHeader title="Settings" subtitle="Global preferences for Scarf. Per-project overrides live in each project." />
      <div style={{ padding: '12px 32px 0', borderBottom: '0.5px solid var(--border)', background: 'var(--bg-card)' }}>
        <Tabs value={tab} onChange={setTab} options={[
          { value: 'general', label: 'General', icon: 'sliders-horizontal' },
          { value: 'appearance', label: 'Appearance', icon: 'palette' },
          { value: 'agent', label: 'Agent', icon: 'cpu' },
          { value: 'permissions', label: 'Permissions', icon: 'shield' },
          { value: 'account', label: 'Account', icon: 'user-circle' },
          { value: 'advanced', label: 'Advanced', icon: 'wrench' },
        ]} />
      </div>
      <div style={{ flex: 1, overflowY: 'auto', padding: '24px 32px', maxWidth: 880 }}>
        {tab === 'general' && <GeneralTab />}
        {tab === 'appearance' && <AppearanceTab />}
        {tab === 'agent' && <AgentTab />}
        {tab === 'permissions' && <PermissionsTab />}
        {tab === 'account' && <AccountTab />}
        {tab === 'advanced' && <AdvancedTab />}
      </div>
    </div>
  );
}

function GeneralTab() {
  return <>
    <SettingsGroup title="Workspace">
      <SettingsRow icon="folder" title="Default project location"
        description="New projects are created here unless overridden."
        control={<Btn size="sm" icon="folder-open">~/Projects</Btn>} />
      <SettingsRow icon="terminal" title="Default shell"
        description="Used when the agent runs commands."
        control={<Select value="zsh" options={[{value:'zsh',label:'/bin/zsh'},{value:'bash',label:'/bin/bash'},{value:'fish',label:'/usr/local/bin/fish'}]} />} />
      <SettingsRow icon="globe" title="Locale" description="Affects date and number formatting."
        control={<Select value="en-US" options={[{value:'en-US',label:'English (US)'},{value:'en-GB',label:'English (UK)'},{value:'de-DE',label:'Deutsch'}]} />} last />
    </SettingsGroup>
    <SettingsGroup title="Notifications">
      <SettingsRow icon="bell" title="Approval requests" description="Notify when the agent needs permission to run a tool."
        control={<Toggle on={true} />} />
      <SettingsRow icon="check-circle" title="Run completion" description="Ping when long-running tasks finish."
        control={<Toggle on={true} />} />
      <SettingsRow icon="alert-triangle" title="Errors only" description="Suppress non-error notifications."
        control={<Toggle on={false} />} last />
    </SettingsGroup>
    <SettingsGroup title="Updates">
      <SettingsRow icon="download" title="Auto-update Scarf"
        description="Currently on 0.14.2 — 0.15.0 available."
        control={<Btn size="sm" kind="primary">Install 0.15.0</Btn>} last />
    </SettingsGroup>
  </>;
}

function AppearanceTab() {
  return <>
    <SettingsGroup title="Theme">
      <SettingsRow icon="sun" title="Color mode" description="Light is the only mode shipped in this kit."
        control={<Segmented value="light" options={[
          { value: 'light', label: 'Light', icon: 'sun' },
          { value: 'dark', label: 'Dark', icon: 'moon' },
          { value: 'auto', label: 'Auto', icon: 'monitor' },
        ]} />} />
      <SettingsRow icon="droplet" title="Accent" description="Scarf uses a warm rust accent across the app."
        control={
          <div style={{ display: 'flex', gap: 6 }}>
            {['#C25A2A','#A8741F','#7E5BA9','#3F8A6E','#3F6BA9','#1F1B16'].map((c,i) =>
              <div key={i} style={{ width: 22, height: 22, borderRadius: 11, background: c,
                border: i === 0 ? '2px solid var(--fg)' : '0.5px solid var(--border)', cursor: 'pointer' }} />)}
          </div>} last />
    </SettingsGroup>
    <SettingsGroup title="Density & type">
      <SettingsRow icon="rows-3" title="UI density"
        control={<Segmented value="comfy" options={[
          { value: 'compact', label: 'Compact' }, { value: 'comfy', label: 'Comfortable' }, { value: 'roomy', label: 'Roomy' },
        ]} />} />
      <SettingsRow icon="type" title="Mono font" description="Used in code blocks, logs, and identifiers."
        control={<Select value="berkeley" options={[
          { value: 'berkeley', label: 'Berkeley Mono' },
          { value: 'jetbrains', label: 'JetBrains Mono' },
          { value: 'sf-mono', label: 'SF Mono' },
        ]} />} last />
    </SettingsGroup>
  </>;
}

function AgentTab() {
  return <>
    <SettingsGroup title="Default model" description="Used when no personality overrides it.">
      <SettingsRow icon="sparkles" title="Model"
        control={<Select value="sonnet" options={[
          { value: 'sonnet', label: 'claude-sonnet-4.5' }, { value: 'opus', label: 'claude-opus-4.1' }, { value: 'haiku', label: 'claude-haiku-4.5' },
        ]} />} />
      <SettingsRow icon="thermometer" title="Temperature"
        description="Lower is more deterministic. Default 0.4."
        control={<TextInput value="0.4" mono />} />
      <SettingsRow icon="cpu" title="Max tokens out"
        control={<TextInput value="4096" mono />} last />
    </SettingsGroup>
    <SettingsGroup title="Behavior">
      <SettingsRow icon="message-square" title="Stream responses"
        control={<Toggle on={true} />} />
      <SettingsRow icon="fast-forward" title="Aggressive tool batching"
        description="Allow multiple parallel tool calls per turn." control={<Toggle on={true} />} />
      <SettingsRow icon="rotate-cw" title="Retry on transient errors"
        control={<Toggle on={true} />} last />
    </SettingsGroup>
  </>;
}

function PermissionsTab() {
  return <>
    <SettingsGroup title="Defaults" description="Override per-tool in Tools, per-project in each project.">
      <SettingsRow icon="book-open" title="Read filesystem"
        control={<Pill tone="green" dot>auto</Pill>} />
      <SettingsRow icon="file-edit" title="Write filesystem"
        control={<Pill tone="amber" dot>approve</Pill>} />
      <SettingsRow icon="terminal" title="Execute commands"
        control={<Pill tone="amber" dot>approve</Pill>} />
      <SettingsRow icon="globe" title="Network access"
        control={<Pill tone="green" dot>auto</Pill>} last />
    </SettingsGroup>
    <SettingsGroup title="Deny rules" description="Patterns the agent can never run.">
      <SettingsRow icon="ban" title="rm -rf /"
        control={<Btn size="sm">Edit</Btn>} />
      <SettingsRow icon="ban" title="git push --force* (origin/main, origin/prod)"
        control={<Btn size="sm">Edit</Btn>} />
      <SettingsRow icon="plus" title="Add rule" control={<Btn size="sm" kind="primary">New</Btn>} last />
    </SettingsGroup>
  </>;
}

function AccountTab() {
  return <>
    <SettingsGroup title="Account">
      <SettingsRow icon="user-circle" title="Aurora Wong"
        description="aurora@wizemann.com — connected via Anthropic Console"
        control={<Btn size="sm">Sign out</Btn>} last />
    </SettingsGroup>
    <SettingsGroup title="Plan & billing">
      <SettingsRow icon="zap" title="Team — 5 seats"
        description="Renews May 12. $99/mo."
        control={<Btn size="sm" icon="external-link">Manage</Btn>} />
      <SettingsRow icon="bar-chart-2" title="Usage this month"
        description="$42.18 of $200 cap"
        control={<div style={{ width: 140 }}><ProgressBar value={21} /></div>} last />
    </SettingsGroup>
    <SettingsGroup title="Danger zone">
      <SettingsRow icon="trash-2" title="Reset all settings"
        description="Returns Scarf to defaults. Projects and history are preserved."
        control={<Btn size="sm" kind="danger">Reset</Btn>} />
      <SettingsRow icon="x-circle" title="Delete account"
        description="Permanently delete this account. This cannot be undone."
        control={<Btn size="sm" kind="danger-solid">Delete</Btn>} last />
    </SettingsGroup>
  </>;
}

function AdvancedTab() {
  return <>
    <SettingsGroup title="Telemetry">
      <SettingsRow icon="bar-chart" title="Anonymous usage data"
        description="Helps improve Scarf. No prompts or file contents are sent."
        control={<Toggle on={true} />} />
      <SettingsRow icon="bug" title="Crash reports"
        control={<Toggle on={true} />} last />
    </SettingsGroup>
    <SettingsGroup title="Experimental">
      <SettingsRow icon="flask-conical" title="Multi-agent fan-out"
        description="Let one agent spawn focused subagents." control={<Toggle on={false} />} />
      <SettingsRow icon="flask-conical" title="Background reasoning"
        description="Pre-compute likely next steps while you type." control={<Toggle on={false} />} last />
    </SettingsGroup>
    <SettingsGroup title="Storage" description="Local-only data on this device.">
      <SettingsRow icon="database" title="Project history" description="14.2 GB across 11 projects"
        control={<Btn size="sm">Manage</Btn>} />
      <SettingsRow icon="hard-drive" title="Cache"
        description="412 MB"
        control={<Btn size="sm">Clear</Btn>} last />
    </SettingsGroup>
  </>;
}

window.Settings = Settings;
