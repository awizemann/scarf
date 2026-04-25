// Scarf v2 shared components — calmer density, full state matrices.
// Exports to window: Btn, IconBtn, Pill, Dot, Card, StatCard, Section, ContentHeader,
// Field, TextInput, NumberInput, TextArea, Toggle, Checkbox, Radio, RadioGroup,
// Segmented, Select, SettingsGroup, SettingsRow, Tabs, Menu, MenuItem, Divider,
// EmptyState, KbdKey, HelpIcon, Tooltip, Avatar, ProgressBar, Spinner.

const SF = "var(--font-sans)";

// ─────────────── ContentHeader ───────────────
function ContentHeader({ title, subtitle, actions, right, breadcrumb }) {
  return (
    <div style={{
      padding: '24px 32px 22px',
      borderBottom: '0.5px solid var(--border)',
      background: 'var(--bg-card)',
    }}>
      {breadcrumb && (
        <div style={{ fontSize: 12, color: 'var(--fg-muted)', marginBottom: 6 }}>{breadcrumb}</div>
      )}
      <div style={{ display: 'flex', alignItems: 'flex-end', gap: 16 }}>
        <div style={{ flex: 1 }}>
          <div className="scarf-h2" style={{ marginBottom: subtitle ? 6 : 0 }}>{title}</div>
          {subtitle && <div style={{ fontSize: 14, color: 'var(--fg-muted)', maxWidth: 600 }}>{subtitle}</div>}
        </div>
        {right}
        {actions && <div style={{ display: 'flex', gap: 8 }}>{actions}</div>}
      </div>
    </div>
  );
}

// ─────────────── Buttons ───────────────
function Btn({ kind = 'secondary', size = 'md', icon, iconRight, children, onClick, disabled, loading, fullWidth, type = 'button' }) {
  const sizes = {
    sm: { padding: '5px 11px', fontSize: 12, gap: 5, iconSize: 13 },
    md: { padding: '7px 14px', fontSize: 13, gap: 6, iconSize: 14 },
    lg: { padding: '10px 18px', fontSize: 14, gap: 7, iconSize: 16 },
  };
  const kinds = {
    primary:   { background: 'var(--accent)', color: 'var(--on-accent)', border: '1px solid transparent', shadow: '0 1px 0 rgba(0,0,0,0.08), inset 0 1px 0 rgba(255,255,255,0.18)' },
    secondary: { background: 'var(--bg-card)', color: 'var(--fg)', border: '1px solid var(--border-strong)', shadow: 'var(--shadow-sm)' },
    ghost:     { background: 'transparent', color: 'var(--fg)', border: '1px solid transparent' },
    danger:    { background: 'var(--bg-card)', color: 'var(--red-600)', border: '1px solid var(--red-500)' },
    'danger-solid': { background: 'var(--red-500)', color: '#fff', border: '1px solid transparent' },
    accent:    { background: 'var(--accent-tint)', color: 'var(--accent-active)', border: '1px solid transparent' },
  };
  const s = sizes[size];
  const k = kinds[kind];
  const [hover, setHover] = React.useState(false);

  const hoverStyle = !disabled && hover ? {
    primary:   { background: 'var(--accent-hover)' },
    secondary: { background: 'var(--gray-50)', borderColor: 'var(--accent)' },
    ghost:     { background: 'var(--bg-quaternary)' },
    danger:    { background: 'var(--red-100)' },
    'danger-solid': { background: 'var(--red-600)' },
    accent:    { background: 'var(--accent-tint-strong)' },
  }[kind] : {};

  return (
    <button type={type} onClick={onClick} disabled={disabled || loading}
      onMouseEnter={() => setHover(true)} onMouseLeave={() => setHover(false)}
      style={{
        padding: s.padding, fontSize: s.fontSize, gap: s.gap,
        ...k, ...hoverStyle, boxShadow: k.shadow,
        borderRadius: 8, fontFamily: SF, fontWeight: 500,
        display: fullWidth ? 'flex' : 'inline-flex', alignItems: 'center', justifyContent: 'center',
        cursor: (disabled || loading) ? 'default' : 'pointer',
        opacity: disabled ? 0.45 : 1,
        width: fullWidth ? '100%' : 'auto',
        transition: 'all 120ms var(--ease-smooth)',
        whiteSpace: 'nowrap', userSelect: 'none',
      }}>
      {loading
        ? <Spinner size={s.iconSize} color={kind === 'primary' ? 'rgba(255,255,255,0.7)' : 'currentColor'} />
        : icon && <i data-lucide={icon} style={{ width: s.iconSize, height: s.iconSize }}></i>}
      {children}
      {iconRight && <i data-lucide={iconRight} style={{ width: s.iconSize, height: s.iconSize, opacity: 0.7 }}></i>}
    </button>
  );
}

function IconBtn({ icon, onClick, size = 28, tooltip, active, disabled }) {
  const [hover, setHover] = React.useState(false);
  return (
    <button onClick={onClick} disabled={disabled} title={tooltip}
      onMouseEnter={() => setHover(true)} onMouseLeave={() => setHover(false)}
      style={{
        width: size, height: size, padding: 0, borderRadius: 7,
        background: active ? 'var(--accent-tint)' : (hover && !disabled ? 'var(--bg-quaternary)' : 'transparent'),
        color: active ? 'var(--accent-active)' : 'var(--fg-muted)',
        border: 'none', cursor: disabled ? 'default' : 'pointer',
        display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
        opacity: disabled ? 0.45 : 1, transition: 'background 120ms',
      }}>
      <i data-lucide={icon} style={{ width: Math.round(size * 0.55), height: Math.round(size * 0.55) }}></i>
    </button>
  );
}

function Spinner({ size = 14, color = 'currentColor' }) {
  return (
    <span style={{
      display: 'inline-block', width: size, height: size,
      border: `2px solid transparent`, borderTopColor: color, borderRightColor: color,
      borderRadius: '50%', animation: 'scarfSpin 0.8s linear infinite',
    }}></span>
  );
}

// ─────────────── Pills / Dots ───────────────
function Pill({ tone = 'gray', dot, icon, children, size = 'md' }) {
  const tones = {
    gray:    { bg: 'var(--bg-quaternary)', fg: 'var(--fg-muted)', dotc: 'var(--gray-500)' },
    green:   { bg: 'var(--green-100)', fg: 'var(--green-600)', dotc: 'var(--green-500)' },
    red:     { bg: 'var(--red-100)', fg: 'var(--red-600)', dotc: 'var(--red-500)' },
    orange:  { bg: 'var(--orange-100)', fg: '#A8741F', dotc: 'var(--orange-500)' },
    blue:    { bg: 'var(--blue-100)', fg: '#1F70A8', dotc: 'var(--blue-500)' },
    accent:  { bg: 'var(--accent-tint)', fg: 'var(--accent-active)', dotc: 'var(--accent)' },
    amber:   { bg: 'var(--orange-100)', fg: '#A8741F', dotc: 'var(--orange-500)' },
    purple:  { bg: '#EFE0F8', fg: '#5E4080', dotc: '#7E5BA9' },
    idle:    { bg: 'var(--bg-quaternary)', fg: 'var(--fg-faint)', dotc: 'var(--gray-400)' },
  };
  const t = tones[tone];
  const sizes = { sm: { p: '2px 7px', f: 10 }, md: { p: '3px 9px', f: 11 }, lg: { p: '4px 11px', f: 12 } };
  const sz = sizes[size];
  return (
    <span style={{
      display: 'inline-flex', alignItems: 'center', gap: 5,
      fontSize: sz.f, fontWeight: 600, padding: sz.p, borderRadius: 999,
      background: t.bg, color: t.fg, fontFamily: SF, lineHeight: 1.4,
    }}>
      {dot && <span style={{ width: 6, height: 6, borderRadius: '50%', background: t.dotc }}></span>}
      {icon && <i data-lucide={icon} style={{ width: 11, height: 11 }}></i>}
      {children}
    </span>
  );
}

function Dot({ tone = 'gray', size = 8 }) {
  const tones = { gray: 'var(--gray-400)', green: 'var(--green-500)', red: 'var(--red-500)',
    orange: 'var(--orange-500)', blue: 'var(--blue-500)', accent: 'var(--accent)' };
  return <span style={{ width: size, height: size, borderRadius: '50%',
    background: tones[tone], display: 'inline-block', flexShrink: 0 }}></span>;
}

// ─────────────── Cards / Sections ───────────────
function Card({ children, padding = 18, style = {}, onClick, interactive }) {
  return (
    <div onClick={onClick} style={{
      background: 'var(--bg-card)', borderRadius: 10,
      border: '0.5px solid var(--border)',
      boxShadow: 'var(--shadow-sm)',
      padding, cursor: onClick || interactive ? 'pointer' : 'default',
      transition: 'all 160ms var(--ease-smooth)',
      ...style,
    }}>{children}</div>
  );
}

function StatCard({ label, value, sub, accent, icon }) {
  return (
    <Card padding={16} style={{ flex: 1, minWidth: 0 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 11,
        color: 'var(--fg-muted)', fontWeight: 600, marginBottom: 8,
        textTransform: 'uppercase', letterSpacing: '0.05em' }}>
        {icon && <i data-lucide={icon} style={{ width: 12, height: 12 }}></i>}
        {label}
      </div>
      <div style={{ fontFamily: 'var(--font-mono)', fontSize: 24, fontWeight: 600,
        color: accent || 'var(--fg)', letterSpacing: '-0.01em', lineHeight: 1.1 }}>{value}</div>
      {sub && <div style={{ fontSize: 11, color: 'var(--fg-faint)', marginTop: 6 }}>{sub}</div>}
    </Card>
  );
}

function Section({ title, hint, right, children, gap = 12 }) {
  return (
    <div>
      <div style={{ display: 'flex', alignItems: 'baseline', marginBottom: gap, gap: 10 }}>
        <div style={{ fontSize: 11, fontWeight: 600, color: 'var(--fg-muted)',
          textTransform: 'uppercase', letterSpacing: '0.06em' }}>{title}</div>
        {hint && <div style={{ fontSize: 12, color: 'var(--fg-faint)' }}>{hint}</div>}
        <div style={{ marginLeft: 'auto' }}>{right}</div>
      </div>
      {children}
    </div>
  );
}

function Divider({ vertical, label }) {
  if (vertical) return <div style={{ width: 1, alignSelf: 'stretch', background: 'var(--border)' }}></div>;
  if (label) return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 10, color: 'var(--fg-faint)', margin: '8px 0' }}>
      <div style={{ flex: 1, height: 1, background: 'var(--border)' }}></div>
      <span style={{ fontSize: 10, fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.06em' }}>{label}</span>
      <div style={{ flex: 1, height: 1, background: 'var(--border)' }}></div>
    </div>
  );
  return <div style={{ height: 1, background: 'var(--border)', margin: '8px 0' }}></div>;
}

// ─────────────── Form fields ───────────────
function Field({ label, hint, error, help, children, required, inline }) {
  return (
    <label style={{ display: 'flex', flexDirection: inline ? 'row' : 'column',
      gap: inline ? 12 : 6, fontFamily: SF, alignItems: inline ? 'center' : 'stretch' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 5,
        minWidth: inline ? 140 : 0 }}>
        <span style={{ fontSize: 13, color: 'var(--fg)', fontWeight: 500 }}>{label}</span>
        {required && <span style={{ color: 'var(--red-500)', fontSize: 11 }}>*</span>}
        {help && <HelpIcon text={help} />}
      </div>
      <div style={{ flex: inline ? 1 : 'none', display: 'flex', flexDirection: 'column', gap: 4 }}>
        {children}
        {error
          ? <span style={{ fontSize: 11, color: 'var(--red-600)', display: 'flex', alignItems: 'center', gap: 4 }}>
              <i data-lucide="alert-circle" style={{ width: 11, height: 11 }}></i>{error}
            </span>
          : hint && <span style={{ fontSize: 11, color: 'var(--fg-faint)' }}>{hint}</span>
        }
      </div>
    </label>
  );
}

function HelpIcon({ text }) {
  return (
    <span title={text} style={{
      display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
      width: 14, height: 14, borderRadius: '50%', background: 'var(--bg-tertiary)',
      color: 'var(--fg-muted)', cursor: 'help',
    }}>
      <i data-lucide="help-circle" style={{ width: 11, height: 11 }}></i>
    </span>
  );
}

function inputStyle(invalid) {
  return {
    fontFamily: SF, fontSize: 13, padding: '7px 11px',
    border: `1px solid ${invalid ? 'var(--red-500)' : 'var(--border-strong)'}`,
    borderRadius: 7, background: 'var(--bg-card)', color: 'var(--fg)',
    outline: 'none', transition: 'all 120ms', width: '100%', boxSizing: 'border-box',
  };
}

function TextInput({ value, onChange, placeholder, mono, invalid, leftIcon, rightSlot, type = 'text' }) {
  const [v, setV] = React.useState(value ?? '');
  React.useEffect(() => setV(value ?? ''), [value]);
  const ref = React.useRef();
  return (
    <div style={{ position: 'relative', display: 'flex', alignItems: 'center' }}>
      {leftIcon && <i data-lucide={leftIcon} style={{
        position: 'absolute', left: 10, width: 14, height: 14, color: 'var(--fg-faint)', pointerEvents: 'none'
      }}></i>}
      <input ref={ref} type={type} value={v}
        onChange={e => { setV(e.target.value); onChange && onChange(e.target.value); }}
        placeholder={placeholder}
        style={{ ...inputStyle(invalid),
          fontFamily: mono ? 'var(--font-mono)' : SF,
          paddingLeft: leftIcon ? 32 : 11,
          paddingRight: rightSlot ? 36 : 11,
        }}
        onFocus={e => { if (!invalid) { e.target.style.borderColor = 'var(--accent)'; e.target.style.boxShadow = 'var(--shadow-focus)'; }}}
        onBlur={e => { e.target.style.borderColor = invalid ? 'var(--red-500)' : 'var(--border-strong)'; e.target.style.boxShadow = 'none'; }}
      />
      {rightSlot && <div style={{ position: 'absolute', right: 6 }}>{rightSlot}</div>}
    </div>
  );
}

function TextArea({ value, onChange, placeholder, rows = 3, invalid, mono }) {
  const [v, setV] = React.useState(value ?? '');
  React.useEffect(() => setV(value ?? ''), [value]);
  return (
    <textarea value={v} rows={rows} placeholder={placeholder}
      onChange={e => { setV(e.target.value); onChange && onChange(e.target.value); }}
      style={{ ...inputStyle(invalid), resize: 'vertical', lineHeight: 1.45,
        fontFamily: mono ? 'var(--font-mono)' : SF }}
      onFocus={e => { if (!invalid) { e.target.style.borderColor = 'var(--accent)'; e.target.style.boxShadow = 'var(--shadow-focus)'; }}}
      onBlur={e => { e.target.style.borderColor = invalid ? 'var(--red-500)' : 'var(--border-strong)'; e.target.style.boxShadow = 'none'; }}
    />
  );
}

function Select({ value, onChange, options }) {
  const [v, setV] = React.useState(value ?? options?.[0]?.value ?? '');
  React.useEffect(() => setV(value ?? ''), [value]);
  return (
    <div style={{ position: 'relative', display: 'flex' }}>
      <select value={v} onChange={e => { setV(e.target.value); onChange && onChange(e.target.value); }}
        style={{ ...inputStyle(), appearance: 'none', paddingRight: 30, cursor: 'pointer' }}>
        {options.map(o => <option key={o.value} value={o.value}>{o.label}</option>)}
      </select>
      <i data-lucide="chevrons-up-down" style={{
        position: 'absolute', right: 10, top: '50%', transform: 'translateY(-50%)',
        width: 13, height: 13, color: 'var(--fg-muted)', pointerEvents: 'none',
      }}></i>
    </div>
  );
}

// ─────────────── Toggle / Checkbox / Radio ───────────────
function Toggle({ on, onChange, size = 'md', disabled }) {
  const sizes = { sm: { w: 28, h: 16, p: 12 }, md: { w: 36, h: 20, p: 16 }, lg: { w: 44, h: 24, p: 20 } };
  const s = sizes[size];
  return (
    <div onClick={() => !disabled && onChange && onChange(!on)} style={{
      width: s.w, height: s.h, borderRadius: 999, position: 'relative',
      cursor: disabled ? 'default' : 'pointer', flexShrink: 0,
      background: on ? 'var(--accent)' : 'var(--gray-300)',
      transition: 'background 180ms var(--ease-smooth)',
      opacity: disabled ? 0.5 : 1,
    }}>
      <div style={{
        position: 'absolute', top: 2, left: on ? (s.w - s.p - 2) : 2,
        width: s.p, height: s.p, borderRadius: '50%', background: '#fff',
        boxShadow: '0 1px 3px rgba(0,0,0,0.18), 0 1px 1px rgba(0,0,0,0.06)',
        transition: 'left 180ms var(--ease-smooth)',
      }}></div>
    </div>
  );
}

function Checkbox({ checked, onChange, indeterminate, disabled }) {
  return (
    <div onClick={() => !disabled && onChange && onChange(!checked)} style={{
      width: 16, height: 16, borderRadius: 4,
      background: checked || indeterminate ? 'var(--accent)' : 'var(--bg-card)',
      border: `1px solid ${checked || indeterminate ? 'var(--accent)' : 'var(--border-strong)'}`,
      cursor: disabled ? 'default' : 'pointer', flexShrink: 0,
      display: 'flex', alignItems: 'center', justifyContent: 'center',
      transition: 'all 120ms', opacity: disabled ? 0.5 : 1,
    }}>
      {checked && <i data-lucide="check" style={{ width: 12, height: 12, color: '#fff', strokeWidth: 3 }}></i>}
      {indeterminate && !checked && <div style={{ width: 8, height: 2, background: '#fff', borderRadius: 1 }}></div>}
    </div>
  );
}

function Radio({ checked, onChange, disabled }) {
  return (
    <div onClick={() => !disabled && onChange && onChange(true)} style={{
      width: 16, height: 16, borderRadius: '50%',
      background: 'var(--bg-card)',
      border: `1px solid ${checked ? 'var(--accent)' : 'var(--border-strong)'}`,
      cursor: disabled ? 'default' : 'pointer', flexShrink: 0,
      display: 'flex', alignItems: 'center', justifyContent: 'center',
      transition: 'all 120ms', opacity: disabled ? 0.5 : 1,
    }}>
      {checked && <div style={{ width: 7, height: 7, borderRadius: '50%', background: 'var(--accent)' }}></div>}
    </div>
  );
}

// ─────────────── Segmented / Tabs ───────────────
function Segmented({ value, onChange, options, size = 'md' }) {
  const padding = size === 'sm' ? '4px 10px' : '6px 14px';
  const fontSize = size === 'sm' ? 12 : 13;
  return (
    <div style={{
      display: 'inline-flex', padding: 2, borderRadius: 8,
      background: 'var(--bg-quaternary)', border: '0.5px solid var(--border)',
    }}>
      {options.map(o => {
        const active = value === o.value;
        return (
          <button key={o.value} onClick={() => onChange && onChange(o.value)} style={{
            padding, fontSize, fontWeight: active ? 600 : 500, fontFamily: SF,
            background: active ? 'var(--bg-card)' : 'transparent',
            color: active ? 'var(--fg)' : 'var(--fg-muted)',
            border: 'none', borderRadius: 6, cursor: 'pointer',
            boxShadow: active ? 'var(--shadow-sm)' : 'none',
            transition: 'all 120ms var(--ease-smooth)', display: 'inline-flex', alignItems: 'center', gap: 5,
          }}>
            {o.icon && <i data-lucide={o.icon} style={{ width: 12, height: 12 }}></i>}
            {o.label}
            {o.count != null && <span style={{
              fontSize: 10, fontFamily: 'var(--font-mono)',
              padding: '1px 6px', borderRadius: 999,
              background: active ? 'var(--accent-tint)' : 'var(--bg-tertiary)',
              color: active ? 'var(--accent-active)' : 'var(--fg-muted)',
            }}>{o.count}</span>}
          </button>
        );
      })}
    </div>
  );
}

function Tabs({ value, onChange, options }) {
  return (
    <div style={{ display: 'flex', gap: 2, borderBottom: '0.5px solid var(--border)' }}>
      {options.map(o => {
        const active = value === o.value;
        return (
          <button key={o.value} onClick={() => onChange && onChange(o.value)} style={{
            padding: '10px 14px', fontSize: 13, fontWeight: 500, fontFamily: SF,
            background: 'transparent', border: 'none',
            color: active ? 'var(--fg)' : 'var(--fg-muted)',
            borderBottom: `2px solid ${active ? 'var(--accent)' : 'transparent'}`,
            marginBottom: -1, cursor: 'pointer', display: 'inline-flex', alignItems: 'center', gap: 6,
            transition: 'color 120ms',
          }}>
            {o.icon && <i data-lucide={o.icon} style={{ width: 13, height: 13 }}></i>}
            {o.label}
            {o.count != null && <span style={{
              fontSize: 10, fontFamily: 'var(--font-mono)',
              padding: '1px 6px', borderRadius: 999,
              background: 'var(--bg-tertiary)', color: 'var(--fg-muted)',
            }}>{o.count}</span>}
          </button>
        );
      })}
    </div>
  );
}

// ─────────────── Settings groups (card-rows) ───────────────
function SettingsGroup({ title, description, children }) {
  return (
    <div style={{ marginBottom: 28 }}>
      {title && <div style={{ marginBottom: 10 }}>
        <div style={{ fontSize: 13, fontWeight: 600 }}>{title}</div>
        {description && <div style={{ fontSize: 12, color: 'var(--fg-muted)', marginTop: 2 }}>{description}</div>}
      </div>}
      <div style={{
        background: 'var(--bg-card)', border: '0.5px solid var(--border)',
        borderRadius: 10, overflow: 'hidden',
      }}>{children}</div>
    </div>
  );
}

function SettingsRow({ title, description, control, icon, last }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 14, padding: '14px 18px',
      borderBottom: last ? 'none' : '0.5px solid var(--border)',
    }}>
      {icon && <div style={{
        width: 32, height: 32, borderRadius: 7, background: 'var(--accent-tint)',
        display: 'flex', alignItems: 'center', justifyContent: 'center', color: 'var(--accent)', flexShrink: 0,
      }}><i data-lucide={icon} style={{ width: 16, height: 16 }}></i></div>}
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 13, fontWeight: 500 }}>{title}</div>
        {description && <div style={{ fontSize: 12, color: 'var(--fg-muted)', marginTop: 2 }}>{description}</div>}
      </div>
      <div style={{ flexShrink: 0 }}>{control}</div>
    </div>
  );
}

// ─────────────── Menu / dropdown ───────────────
function Menu({ children, anchor = 'bottom-left', style = {} }) {
  const positions = {
    'bottom-left': { top: '100%', left: 0, marginTop: 4 },
    'bottom-right': { top: '100%', right: 0, marginTop: 4 },
    'top-left': { bottom: '100%', left: 0, marginBottom: 4 },
  };
  return (
    <div style={{
      position: 'absolute', zIndex: 200, ...positions[anchor],
      minWidth: 200, padding: 4, background: 'var(--bg-card)',
      border: '0.5px solid var(--border)', borderRadius: 9,
      boxShadow: 'var(--shadow-lg)', fontFamily: SF, ...style,
    }}>
      {children}
    </div>
  );
}

function MenuItem({ icon, label, kbd, onClick, danger, selected, children }) {
  const [hover, setHover] = React.useState(false);
  return (
    <div onClick={onClick} onMouseEnter={() => setHover(true)} onMouseLeave={() => setHover(false)}
      style={{
        display: 'flex', alignItems: 'center', gap: 10, padding: '6px 10px',
        borderRadius: 6, cursor: 'pointer', fontSize: 13,
        background: hover ? 'var(--accent-tint)' : 'transparent',
        color: danger ? 'var(--red-600)' : (hover ? 'var(--accent-active)' : 'var(--fg)'),
      }}>
      {icon && <i data-lucide={icon} style={{ width: 14, height: 14 }}></i>}
      <span style={{ flex: 1 }}>{label || children}</span>
      {selected && <i data-lucide="check" style={{ width: 13, height: 13 }}></i>}
      {kbd && <KbdKey>{kbd}</KbdKey>}
    </div>
  );
}

function KbdKey({ children }) {
  return <span style={{
    fontFamily: 'var(--font-mono)', fontSize: 10,
    padding: '1px 5px', borderRadius: 3,
    background: 'var(--bg-quaternary)', border: '0.5px solid var(--border)',
    color: 'var(--fg-muted)',
  }}>{children}</span>;
}

// ─────────────── Avatar ───────────────
function Avatar({ initials, size = 28, color = 'var(--accent)' }) {
  return (
    <div style={{
      width: size, height: size, borderRadius: '50%', background: color,
      color: '#fff', display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
      fontSize: Math.round(size * 0.4), fontWeight: 600, flexShrink: 0,
    }}>{initials}</div>
  );
}

// ─────────────── ProgressBar ───────────────
function ProgressBar({ value = 0, color = 'var(--accent)', height = 6 }) {
  return (
    <div style={{ height, background: 'var(--bg-quaternary)', borderRadius: height / 2, overflow: 'hidden' }}>
      <div style={{ width: `${Math.min(100, Math.max(0, value))}%`, height: '100%',
        background: color, borderRadius: height / 2, transition: 'width 240ms var(--ease-smooth)' }}></div>
    </div>
  );
}

// ─────────────── Empty ───────────────
function EmptyState({ icon, title, body, action }) {
  return (
    <div style={{ flex: 1, display: 'flex', flexDirection: 'column',
      alignItems: 'center', justifyContent: 'center', padding: 80, textAlign: 'center', gap: 12 }}>
      <div style={{
        width: 64, height: 64, borderRadius: 16, background: 'var(--accent-tint)',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        color: 'var(--accent)', marginBottom: 4,
      }}>
        <i data-lucide={icon || 'inbox'} style={{ width: 28, height: 28 }}></i>
      </div>
      <div style={{ fontSize: 17, fontWeight: 600 }}>{title}</div>
      <div style={{ fontSize: 13, color: 'var(--fg-muted)', maxWidth: 380, lineHeight: 1.5 }}>{body}</div>
      {action && <div style={{ marginTop: 8 }}>{action}</div>}
    </div>
  );
}

Object.assign(window, {
  ContentHeader, Btn, IconBtn, Spinner, Pill, Dot,
  Card, StatCard, Section, Divider,
  Field, HelpIcon, TextInput, TextArea, Select,
  Toggle, Checkbox, Radio,
  Segmented, Tabs,
  SettingsGroup, SettingsRow,
  Menu, MenuItem, KbdKey,
  Avatar, ProgressBar, EmptyState,
});
