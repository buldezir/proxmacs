import type { ReactNode } from 'react';
import { Badge, KV, Loading, Meter, Panel, StateDot } from '../../components/ui';
import type { Navigate } from '../../components/Shell';
import { fmtBytes, fmtMemMB, fmtPercent } from '../../format';
import { useApp, type StatsSample } from '../../store';
import type { HostMemory } from '../../types';
import { UpdatePanel } from './Update';

export function HostSummary({ navigate }: { navigate: Navigate }) {
  const { host, stats, history, vms, storage } = useApp();
  if (!host) return <Loading what="Loading host information…" />;

  const diskUsed = host.diskTotalBytes ? 1 - host.diskFreeBytes / host.diskTotalBytes : 0;
  const counts: Record<string, number> = {};
  for (const v of vms) counts[v.state] = (counts[v.state] ?? 0) + 1;
  const configuredMB = vms.reduce((sum, v) => sum + (v.memoryMB ?? 0), 0);
  const load = stats?.loadAverage ?? [];

  return (
    <>
      {stats?.memory && <MemoryPanel memory={stats.memory} vmBytes={stats.vmMemoryBytes} runningVMs={stats.runningVMs} history={history} />}
      <div className="grid2">
        <Panel title="Host">
          <KV rows={[
            ['Hostname', host.hostname || '—'],
            ['macOS', host.osVersion || '—'],
            ['Tart', host.tartVersion ?? <Badge kind="err">not found</Badge>],
            ['CPUs', String(host.cpus ?? '—')],
            stats?.cpu != null && ['CPU usage', <div>{fmtPercent(stats.cpu)}<Meter fraction={stats.cpu} /></div>],
            load.length === 3 && ['Load average', <span className="mono">{load.map((l) => l.toFixed(2)).join('  ')}</span>],
            !!host.web?.urls.length && ['Web UI', <ul className="web-urls">
              {host.web.urls.map((u) => (
                <li key={u.url}>
                  <a className="mono" href={u.url}>{u.url}</a>
                  {u.url === window.location.origin && <> <Badge kind="info">this page</Badge></>}
                  <div className="muted small">{[u.name, u.device].filter(Boolean).join(' · ')}</div>
                </li>
              ))}
            </ul>],
            ['API', <span><a className="mono" href="/llms.txt" target="_blank" rel="noreferrer">/llms.txt</a>{' '}
              <span className="muted small">how scripts and AI agents use it</span></span>],
            ...(storage ? (['vms', 'backups'] as const).map((kind) => {
              const loc = storage[kind];
              const v = loc.volume;
              return [kind === 'vms' ? 'VM storage' : 'Backups', !loc.available
                ? <button type="button" className="link" onClick={() => navigate({ type: 'host', tab: 'storage' })}><Badge kind="err">offline</Badge></button>
                : v && <div>
                  <span title={loc.path}>{v.name}</span>: {fmtBytes(v.freeBytes)} free of {fmtBytes(v.totalBytes)}
                  {v.totalBytes > 0 && <Meter fraction={1 - v.freeBytes / v.totalBytes} />}
                </div>] as [string, ReactNode];
            }) : [['Disk', <div>
              {fmtBytes(host.diskFreeBytes)} free of {fmtBytes(host.diskTotalBytes)}
              {host.diskTotalBytes > 0 && <Meter fraction={diskUsed} />}
            </div>] as [string, ReactNode]]),
          ]} />
        </Panel>
        <Panel title="Virtual machines">
          <KV rows={[
            ['Total', String(vms.length)],
            ['Running', <span className="copy-line"><StateDot state="running" />{counts.running ?? 0}</span>],
            ['Stopped', <span className="copy-line"><StateDot state="stopped" />{counts.stopped ?? 0}</span>],
            !!counts.suspended && ['Suspended', <span className="copy-line"><StateDot state="suspended" />{counts.suspended}</span>],
            !!counts.missing && ['Missing', <span className="copy-line"><StateDot state="missing" />{counts.missing}</span>],
            !!counts.offline && ['Offline', <span className="copy-line"><StateDot state="offline" />{counts.offline}</span>],
            ['Memory configured', <span>
              {fmtMemMB(configuredMB)} across all VMs
              {host.memoryBytes > 0 && configuredMB * 2 ** 20 > host.memoryBytes &&
                <> <Badge kind="warn" title="Starting every VM at once would exceed physical memory">overcommitted</Badge></>}
            </span>],
          ]} />
          {vms.length > 0 && (
            <div className="vm-chips">
              {vms.map((v) => (
                <button key={v.name} type="button" className="chip" onClick={() => navigate({ type: 'vm', name: v.name, tab: 'summary' })}>
                  {v.template ? <span className="dot template" /> : <StateDot state={v.state} />}{v.name}
                  <span className="muted">{v.template ? 'template' : fmtMemMB(v.memoryMB)}</span>
                </button>
              ))}
            </div>
          )}
        </Panel>
      </div>
      <UpdatePanel />
    </>
  );
}

const SEGMENTS: { key: keyof HostMemory; label: string; cls: string; hint: string }[] = [
  { key: 'app', label: 'App', cls: 'seg-app', hint: 'Memory used by apps and VMs' },
  { key: 'wired', label: 'Wired', cls: 'seg-wired', hint: 'Kernel memory that cannot be paged out' },
  { key: 'compressed', label: 'Compressed', cls: 'seg-compressed', hint: 'Memory compressed to make room' },
  { key: 'cached', label: 'Cached files', cls: 'seg-cached', hint: 'File cache, reclaimed when needed' },
];

function MemoryPanel({ memory, vmBytes, runningVMs, history }: { memory: HostMemory; vmBytes: number; runningVMs: number; history: StatsSample[] }) {
  const pct = (n: number) => `${((n / memory.total) * 100).toFixed(2)}%`;
  const pressureKind = memory.pressure === 'critical' ? 'err' : memory.pressure === 'warning' ? 'warn' : 'ok';
  return (
    <Panel title="Memory" extra={<Badge kind={pressureKind} title="macOS memory pressure">pressure: {memory.pressure}</Badge>}>
      <div className="mem-head">
        <div>
          <div className="mem-big">{fmtBytes(memory.used)} <span className="muted">of {fmtBytes(memory.total)} used</span></div>
          <div className="muted small">
            {runningVMs ? `${fmtBytes(vmBytes)} assigned to ${runningVMs} running VM${runningVMs === 1 ? '' : 's'}` : 'No VMs running'}
            {' · '}swap {fmtBytes(memory.swapUsed)}{memory.swapTotal ? ` of ${fmtBytes(memory.swapTotal)}` : ''}
          </div>
        </div>
      </div>
      <div className="mem-bar" role="img" aria-label={`${pct(memory.used)} used`}>
        {SEGMENTS.map((s) => (
          <div key={s.key} className={s.cls} style={{ width: pct(memory[s.key] as number) }} title={`${s.label}: ${fmtBytes(memory[s.key] as number)}`} />
        ))}
        {vmBytes > 0 && <div className="vm-mark" style={{ left: `min(${pct(vmBytes)}, 100%)` }} title={`Assigned to running VMs: ${fmtBytes(vmBytes)}`} />}
      </div>
      <div className="legend">
        {SEGMENTS.map((s) => (
          <span key={s.key} title={s.hint}><i className={s.cls} />{s.label} <strong>{fmtBytes(memory[s.key] as number)}</strong></span>
        ))}
        <span><i className="seg-free" />Free <strong>{fmtBytes(memory.free)}</strong></span>
        {vmBytes > 0 && <span><i className="vm-swatch" />VMs assigned <strong>{fmtBytes(vmBytes)}</strong></span>}
      </div>
      <MemoryChart history={history} />
    </Panel>
  );
}

/** Used memory (area) and memory assigned to running VMs (dashed) over the last few minutes. */
function MemoryChart({ history }: { history: StatsSample[] }) {
  if (history.length < 2) return <div className="chart-empty muted small">Collecting samples…</div>;
  const W = 600, H = 80;
  const total = history[history.length - 1].total || 1;
  const t0 = history[0].t, span = Math.max(1, history[history.length - 1].t - t0);
  const x = (s: StatsSample) => ((s.t - t0) / span) * W;
  const y = (v: number) => H - Math.min(1, v / total) * H;
  const used = history.map((s) => `${x(s).toFixed(1)},${y(s.used).toFixed(1)}`);
  const vms = history.map((s) => `${x(s).toFixed(1)},${y(s.vms).toFixed(1)}`).join(' ');
  const minutes = Math.round(span / 60000);
  return (
    <figure className="chart">
      <svg viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none" aria-label="Memory used over time">
        {[0.25, 0.5, 0.75].map((f) => <line key={f} className="grid" x1="0" x2={W} y1={H * f} y2={H * f} />)}
        <polygon className="area" points={`0,${H} ${used.join(' ')} ${W},${H}`} />
        <polyline className="line" points={used.join(' ')} />
        <polyline className="vms" points={vms} />
      </svg>
      <figcaption className="muted small">
        <span>{minutes > 0 ? `last ${minutes} min` : 'last minute'}</span>
        <span>used · <span className="dash">- -</span> assigned to VMs</span>
      </figcaption>
    </figure>
  );
}
