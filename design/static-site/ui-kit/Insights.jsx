// Insights — usage charts and breakdowns.

function Insights() {
  return (
    <div style={{ overflow: 'auto', height: '100%' }}>
      <ContentHeader title="Insights"
        subtitle="Patterns across sessions, models, and tools"
        right={<select style={{
          fontSize: 12, padding: '5px 10px', border: '1px solid var(--border-strong)',
          borderRadius: 6, background: 'var(--bg-card)', fontFamily: 'var(--font-sans)',
        }}><option>Last 7 days</option><option>Last 30 days</option><option>This year</option></select>}
        actions={<Btn icon="download">Export CSV</Btn>} />

      <div style={{ padding: '20px 28px', display: 'flex', flexDirection: 'column', gap: 20 }}>
        <div style={{ display: 'flex', gap: 12 }}>
          <StatCard label="Sessions" value="847" sub="↗ +12% vs prev" />
          <StatCard label="Tokens" value="2.4M" sub="1.8M in · 0.6M out" />
          <StatCard label="Tool calls" value="3,221" sub="3.8 avg/session" />
          <StatCard label="Avg latency" value="1.2s" accent="var(--accent)" sub="p95 4.1s" />
          <StatCard label="Cost" value="$42.18" sub="$0.05 avg/session" />
        </div>

        <Card>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 14 }}>
            <div style={{ flex: 1, fontSize: 13, fontWeight: 600 }}>Token usage</div>
            <div style={{ display: 'flex', gap: 12, fontSize: 11, color: 'var(--fg-muted)' }}>
              <span style={{ display: 'flex', alignItems: 'center', gap: 5 }}>
                <span style={{ width: 9, height: 9, borderRadius: 2, background: 'var(--accent)' }}></span>
                Input
              </span>
              <span style={{ display: 'flex', alignItems: 'center', gap: 5 }}>
                <span style={{ width: 9, height: 9, borderRadius: 2, background: 'var(--brand-200)' }}></span>
                Output
              </span>
            </div>
          </div>
          <BarChart />
        </Card>

        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
          <Card>
            <div style={{ fontSize: 13, fontWeight: 600, marginBottom: 14 }}>By model</div>
            <BreakdownRow label="claude-sonnet-4.5" value="62%" bar="var(--accent)" sub="$28.41 · 524 sessions" />
            <BreakdownRow label="claude-haiku-4.5"  value="31%" bar="var(--brand-300)" sub="$10.18 · 263 sessions" />
            <BreakdownRow label="claude-opus-4.5"   value="5%"  bar="var(--brand-700)" sub="$3.40 · 42 sessions" />
            <BreakdownRow label="local/llama-3.3"   value="2%"  bar="var(--gray-400)" sub="$0.00 · 18 sessions" last />
          </Card>
          <Card>
            <div style={{ fontSize: 13, fontWeight: 600, marginBottom: 14 }}>By tool kind</div>
            <BreakdownRow label="read"    value="42%" bar="var(--green-500)"  sub="1,353 calls" />
            <BreakdownRow label="execute" value="24%" bar="var(--orange-500)" sub="773 calls" />
            <BreakdownRow label="edit"    value="18%" bar="var(--blue-500)"   sub="580 calls" />
            <BreakdownRow label="fetch"   value="11%" bar="var(--purple-tool-500)" sub="354 calls" />
            <BreakdownRow label="browser" value="5%"  bar="var(--indigo-500)" sub="161 calls" last />
          </Card>
        </div>
      </div>
    </div>
  );
}

function BarChart() {
  // 14 days of data, hand-tuned
  const data = [
    [120, 40], [80, 32], [180, 60], [240, 90], [200, 75], [60, 22], [40, 15],
    [110, 38], [170, 56], [220, 82], [280, 98], [310, 110], [240, 78], [190, 64],
  ];
  const max = 420;
  const chartH = 160; // px area for bars
  return (
    <div style={{ display: 'flex', alignItems: 'flex-end', gap: 6, height: 184, padding: '0 4px' }}>
      {data.map(([inp, outp], i) => {
        const inpH  = Math.round(inp / max * chartH);
        const outpH = Math.round(outp / max * chartH);
        return (
          <div key={i} style={{
            flex: 1, display: 'flex', flexDirection: 'column',
            justifyContent: 'flex-end', alignItems: 'stretch', minWidth: 0,
          }}>
            <div style={{ background: 'var(--brand-200)', height: outpH,
              borderRadius: '3px 3px 0 0' }}></div>
            <div style={{ background: 'var(--accent)', height: inpH }}></div>
            <div style={{ fontSize: 9, color: 'var(--fg-faint)', textAlign: 'center', marginTop: 4,
              fontFamily: 'var(--font-mono)', height: 14 }}>{i % 2 === 0 ? `04/${12 + i}` : ''}</div>
          </div>
        );
      })}
    </div>
  );
}

function BreakdownRow({ label, value, bar, sub, last }) {
  return (
    <div style={{ marginBottom: last ? 0 : 14 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 4 }}>
        <div style={{ flex: 1, fontFamily: 'var(--font-mono)', fontSize: 12 }}>{label}</div>
        <div style={{ fontFamily: 'var(--font-mono)', fontSize: 12, fontWeight: 600 }}>{value}</div>
      </div>
      <div style={{ height: 6, background: 'var(--bg-quaternary)', borderRadius: 3, overflow: 'hidden' }}>
        <div style={{ width: value, height: '100%', background: bar, borderRadius: 3 }}></div>
      </div>
      <div style={{ fontSize: 10.5, color: 'var(--fg-faint)', marginTop: 3 }}>{sub}</div>
    </div>
  );
}

window.Insights = Insights;
