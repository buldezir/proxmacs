import { useCallback, useEffect, useState, type ReactNode } from 'react';
import { api, AuthError, enc, errorMessage } from '../../api';
import { LineChart } from '../../components/Chart';
import { useConfirm } from '../../components/Modal';
import type { Navigate } from '../../components/Shell';
import { useToast } from '../../components/Toasts';
import { ActionButton, Badge, Empty, KV, Loading, MenuButton, Meter, Panel, Segmented, Spinner, StateBadge, Tags } from '../../components/ui';
import { fmtBytes, fmtMemMB, fmtPercent, fmtRate, fmtUptime, networkLabel, retentionLabel } from '../../format';
import { copyText, usePoller } from '../../hooks';
import { useApp } from '../../store';
import type { GuestInfo, Metrics, MetricsRange, VM, VMSample } from '../../types';
import { vmDelete, vmPowerOff, vmReboot, vmReset, vmSetTemplate, vmStart, vmStop } from './actions';
import { BackupButton } from './BackupDialog';
import { CloneDialog } from './CloneDialog';

export function VMSummary({ vm, navigate }: { vm: VM; navigate: Navigate }) {
  const app = useApp();
  const confirm = useConfirm();
  const [cloning, setCloning] = useState(false);
  const running = vm.state === 'running';
  const canStart = !vm.template && (vm.state === 'stopped' || vm.state === 'suspended');
  const unavailable = vm.state === 'missing' || vm.state === 'offline';
  const ci = vm.cloudInit;
  const edit = (tab: string) => (
    <button type="button" className="btn small" onClick={() => navigate({ type: 'vm', name: vm.name, tab })}>Edit</button>
  );
  const offsite = vm.offsite.targets.length
    ? `${vm.offsite.targets.map((id) => app.target(id)?.name ?? id).join(', ')} — ${vm.offsite.auto ? 'pushed automatically after each backup' : 'manual push only'}`
    : 'None';
  const jobs = app.jobs.filter((j) => j.selection === 'all' || (j.selection === 'include') === j.vms.includes(vm.name));
  const setTemplate = async (template: boolean) => {
    const updated = await vmSetTemplate(confirm, vm, template);
    if (updated) app.updateVM(updated);
  };

  return (
    <>
      <div className="toolbar">
        {vm.template ? (
          <ActionButton className="primary" disabled={unavailable} onClick={() => setCloning(true)}>Clone</ActionButton>
        ) : <>
          <ActionButton className="primary" disabled={!canStart} title={canStart ? null : running ? 'Already running' : `Cannot start a ${vm.state} VM`}
            onClick={() => vmStart(app.startTask, vm)}>Start</ActionButton>
          <ActionButton disabled={!running} title={running ? null : 'The VM is not running'} onClick={() => vmStop(app.startTask, vm)}>Shutdown</ActionButton>
          <ActionButton disabled={!running} title={running ? null : 'The VM is not running'} onClick={() => vmReboot(app.startTask, vm)}>Reboot</ActionButton>
          <ActionButton disabled={unavailable} onClick={() => setCloning(true)}>Clone</ActionButton>
        </>}
        <BackupButton vm={vm} />
        <MenuButton label="More" items={[
          !vm.template && { label: 'Stop (turn off now)', disabled: !running, onClick: () => vmPowerOff(app.startTask, confirm, vm) },
          !vm.template && { label: 'Reset', disabled: !running, onClick: () => vmReset(app.startTask, confirm, vm) },
          vm.template
            ? { label: 'Convert to VM', onClick: () => setTemplate(false) }
            : { label: 'Convert to template', disabled: vm.state !== 'stopped', title: vm.state === 'stopped' ? undefined : 'Shut the VM down first',
              onClick: () => setTemplate(true) },
        ]} />
        <div className="spacer" />
        <ActionButton className="danger" disabled={vm.state === 'offline'} title={vm.state === 'offline' ? 'VM storage is not connected' : null}
          onClick={() => vmDelete(app.startTask, confirm, vm)}>Delete</ActionButton>
      </div>
      {vm.template && (
        <div className="note">This is a template: it can’t be started. Clone it to create VMs that start from its disks and settings.</div>
      )}
      {vm.seedPending && (
        <div className="note warn">Cloud-init settings changed while the VM was running. Shut it down and start it again to apply them.</div>
      )}
      {vm.state === 'offline' && (
        <div className="note warn">
          VM storage ({app.storage?.vms.path ?? 'external drive'}) is not connected. Connect the drive, or{' '}
          <button type="button" className="link" onClick={() => navigate({ type: 'host', tab: 'storage' })}>change the storage location</button>.
        </div>
      )}
      {vm.state === 'missing' && (
        <div className="note">This VM is registered with Proxmacs but its Tart VM was not found. Restore it from the Backups tab, or pull a snapshot from the Offsite tab.</div>
      )}
      <div className="grid2">
        <Panel title="Status">
          <KV rows={[
            ['State', <span className="copy-line">
              {vm.template ? <Badge>template</Badge> : <StateBadge state={vm.state} />}
              {vm.activity && <Badge kind="info"><Spinner />{vm.activity}</Badge>}
            </span>],
            running && ['Uptime', fmtUptime(vm.stats?.uptime)],
            running && ['CPU usage', <Usage fraction={vm.stats?.cpu} label={`${fmtPercent(vm.stats?.cpu, 1)} of ${vm.cpus ?? '?'} CPU${vm.cpus === 1 ? '' : 's'}`} />],
            running && ['Memory', <MemoryUsage vm={vm} />],
            !vm.template && ['IP address', <IPCell vm={vm} />],
            ['Network', networkLabel(vm.network, app.interfaces)],
            !vm.template && ['Start on login', <AutostartSwitch vm={vm} />],
            vm.tags.length > 0 && ['Tags', <Tags tags={vm.tags} />],
          ]} />
        </Panel>
        <Panel title="Hardware" extra={edit('hardware')}>
          <KV rows={[
            ['CPUs', vm.cpus != null ? String(vm.cpus) : '—'],
            ['Memory', fmtMemMB(vm.memoryMB)],
            ['Disk', vm.diskGB != null ? `${vm.diskGB} GB` : '—'],
            vm.disks.length > 0 && ['Extra disks', vm.disks.map((d) => `${d.file} (${d.sizeGB} GB)`).join(', ')],
            vm.shares.length > 0 && ['Shared folders', vm.shares.map((s) => s.name).join(', ')],
            vm.nested && ['Nested virtualization', 'on'],
            !!vm.image && ['Image', vm.image],
          ]} />
        </Panel>
        {running && <GuestPanel vm={vm} />}
        {vm.os !== 'darwin' && (
          <Panel title="Cloud-Init" extra={edit('cloudinit')}>
            <KV rows={[
              ['User', <span className="mono">{ci.user}</span>],
              ['Password', { set: 'set', none: 'none', unknown: 'unchanged since creation' }[ci.password]],
              ['SSH keys', ci.sshKeys.length ? `${ci.sshKeys.length} key${ci.sshKeys.length === 1 ? '' : 's'}` : 'none'],
              ['IPv4', ci.network.dhcp ? 'DHCP' : <span className="mono">{ci.network.address}{ci.network.gateway && ` via ${ci.network.gateway}`}</span>],
            ]} />
          </Panel>
        )}
        <Panel title="Protection" extra={edit('backups')}>
          <KV rows={[
            ['Backup jobs', jobs.length
              ? jobs.map((j) => `${j.title} → ${j.targetName ?? 'local'}${j.enabled ? '' : ' (disabled)'}`).join(', ')
              : <span className="muted">none — <button type="button" className="link" onClick={() => navigate({ type: 'host', tab: 'jobs' })}>add one</button></span>],
            ['Retention', retentionLabel(vm.backup)],
            ['Offsite', offsite],
          ]} />
        </Panel>
        <NotesPanel vm={vm} />
      </div>
      {!vm.template && <PerformancePanel vm={vm} />}
      {cloning && <CloneDialog vm={vm} onClose={() => setCloning(false)} />}
    </>
  );
}

function Usage({ fraction, label }: { fraction: number | null | undefined; label: string }) {
  if (fraction == null) return <span className="muted">measuring…</span>;
  return <div>{label}<Meter fraction={fraction} title={label} /></div>;
}

function MemoryUsage({ vm }: { vm: VM }) {
  const s = vm.stats;
  if (!s?.memory) return <span className="muted">measuring…</span>;
  const total = (vm.memoryMB ?? 0) * 2 ** 20;
  return (
    <div>
      {s.guestUsed != null && s.guestTotal
        ? <>{fmtBytes(s.guestUsed)} used in the guest of {fmtBytes(s.guestTotal)}<Meter fraction={s.guestUsed / s.guestTotal} /></>
        : `${fmtMemMB(vm.memoryMB)} assigned`}
      <div className="small muted">{fmtBytes(s.memory)} of host memory{total ? ` (${fmtPercent(s.memory / total)} of assigned)` : ''}</div>
    </div>
  );
}

function IPCell({ vm }: { vm: VM }) {
  const [copied, setCopied] = useState<string | null>(null);
  if (!vm.ip) return <span className="muted">{vm.state === 'running' ? 'waiting for an address…' : '—'}</span>;
  // A macOS guest's user is known only once its Screen Sharing account is saved.
  if (!vm.sshUser) return <div className="mono">{vm.ip}</div>;
  const ssh = `ssh ${vm.sshUser}@${vm.ip}`;
  const copy = async () => {
    setCopied((await copyText(ssh)) ? 'Copied' : 'Copy failed');
    window.setTimeout(() => setCopied(null), 1500);
  };
  return (
    <div>
      <div className="mono">{vm.ip}</div>
      <div className="copy-line spaced">
        <code>{ssh}</code>
        <button type="button" className="btn small" onClick={copy}>{copied ?? 'Copy'}</button>
      </div>
    </div>
  );
}

function AutostartSwitch({ vm }: { vm: VM }) {
  const app = useApp();
  const { report } = useToast();
  const [busy, setBusy] = useState(false);
  const toggle = async (autostart: boolean) => {
    setBusy(true);
    try {
      app.updateVM(await api<VM>('PATCH', `/api/vms/${enc(vm.name)}`, { autostart }));
    } catch (e) {
      report(e);
    } finally {
      setBusy(false);
    }
  };
  return (
    <label className="check">
      <input type="checkbox" className="switch" aria-label="Start on login" checked={vm.autostart} disabled={busy}
        onChange={(e) => toggle(e.target.checked)} />
      {vm.autostart ? `On${vm.startOrder != null ? `, order ${vm.startOrder}` : ''}${vm.startDelay ? `, then wait ${vm.startDelay} s` : ''}` : 'Off'}
    </label>
  );
}

/** What the guest agent reports: OS, addresses, filesystems. */
function GuestPanel({ vm }: { vm: VM }) {
  const [info, setInfo] = useState<GuestInfo | null>(null);
  const [error, setError] = useState<string | null>(null);
  const name = vm.name;
  const load = useCallback(async (refresh = false) => {
    try {
      setInfo(await api<GuestInfo>('GET', `/api/vms/${enc(name)}/guest${refresh ? '?refresh=1' : ''}`));
      setError(null);
    } catch (e) {
      if (!(e instanceof AuthError)) setError(errorMessage(e));
    }
  }, [name]);
  usePoller(() => load(), 60000);

  return (
    <Panel title="Guest agent" extra={<ActionButton className="small" onClick={() => load(true)}>Refresh</ActionButton>}>
      {error && !info ? <Empty>{error.includes('did not answer') || error.includes('agent') ? 'The guest agent is not answering yet.' : error}</Empty>
        : !info ? <Loading what="Asking the guest…" /> : (
          <KV rows={[
            ['OS', info.os ?? '—'],
            ['Kernel', <span className="mono">{info.kernel ?? '—'}</span>],
            ['Hostname', info.hostname ?? '—'],
            ['Guest uptime', fmtUptime(info.uptime)],
            ...info.interfaces.map((i) => [i.name, <div>
              {i.addresses.map((a) => <div key={a} className="mono">{a}</div>)}
              {i.mac && <div className="small muted mono">{i.mac}</div>}
            </div>] as [string, ReactNode]),
            info.filesystems.length > 0 && ['Filesystems', <div className="stack">
              {info.filesystems.map((fs) => (
                <div key={fs.mount} className="fs-row">
                  <span className="mono">{fs.mount}</span>
                  <span className="small muted">{fmtBytes(fs.usedBytes)} of {fmtBytes(fs.sizeBytes)} · {fs.type}</span>
                  <Meter fraction={fs.usedBytes / fs.sizeBytes} />
                </div>
              ))}
            </div>],
          ]} />
        )}
    </Panel>
  );
}

function NotesPanel({ vm }: { vm: VM }) {
  const app = useApp();
  const { report } = useToast();
  const [draft, setDraft] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const save = async () => {
    setBusy(true);
    try {
      app.updateVM(await api<VM>('PATCH', `/api/vms/${enc(vm.name)}`, { notes: draft ?? '' }));
      setDraft(null);
    } catch (e) {
      report(e);
    } finally {
      setBusy(false);
    }
  };
  return (
    <Panel title="Notes" extra={draft == null && <button type="button" className="btn small" onClick={() => setDraft(vm.notes)}>Edit</button>}>
      {draft != null ? (
        <>
          <textarea rows={6} autoFocus value={draft} maxLength={16000} onChange={(e) => setDraft(e.target.value)} aria-label="Notes" />
          <div className="form-actions">
            <button type="button" className="btn" onClick={() => setDraft(null)}>Cancel</button>
            <button type="button" className="btn primary" disabled={busy} onClick={save}>{busy && <Spinner />}Save</button>
          </div>
        </>
      ) : vm.notes ? <p className="notes">{vm.notes}</p> : <span className="muted">No notes.</span>}
    </Panel>
  );
}

const RANGE_MS: Record<MetricsRange, number> = { hour: 3600e3, day: 86400e3, week: 7 * 86400e3 };

function PerformancePanel({ vm }: { vm: VM }) {
  const [range, setRange] = useState<MetricsRange>('hour');
  const [metrics, setMetrics] = useState<Metrics | null>(null);
  const name = vm.name;
  const load = useCallback(async () => {
    try {
      setMetrics(await api<Metrics>('GET', `/api/vms/${enc(name)}/metrics?range=${range}`));
    } catch { /* keep the last data */ }
  }, [name, range]);
  useEffect(() => { setMetrics(null); }, [range]);
  usePoller(load, range === 'hour' ? 10000 : 60000);

  const samples = metrics?.range === range ? metrics.samples : [];
  const end = Date.now(), start = end - RANGE_MS[range];
  const step = (metrics?.step ?? 10) * 1000;
  const memoryMax = Math.max((vm.memoryMB ?? 0) * 2 ** 20, ...samples.map((s) => s.memory));
  const common = { samples, start, end, step };
  return (
    <Panel title="Performance" extra={
      <Segmented name={`range-${name}`} value={range} onChange={setRange} options={[['hour', 'Hour'], ['day', 'Day'], ['week', 'Week']]} />
    }>
      {metrics && !samples.length && <p className="muted">
        {vm.state === 'running' ? 'Collecting samples (every 10 seconds)…' : 'No data for this period. Usage is recorded while the VM runs.'}
      </p>}
      <div className="charts">
        <LineChart<VMSample> title="CPU" {...common} max={1} format={(v) => fmtPercent(v, 1)}
          series={[{ label: 'usage', cls: 'series-a', value: (s) => s.cpu }]} />
        <LineChart<VMSample> title="Memory" {...common} max={memoryMax || undefined} format={fmtBytes}
          series={[
            { label: 'host', cls: 'series-a', value: (s) => s.memory },
            { label: 'guest used', cls: 'series-b', value: (s) => s.guestUsed },
          ]} />
        <LineChart<VMSample> title="Network" {...common} format={fmtRate}
          series={[{ label: 'in', cls: 'series-a', value: (s) => s.netIn }, { label: 'out', cls: 'series-b', value: (s) => s.netOut }]} />
        <LineChart<VMSample> title="Disk I/O" {...common} format={fmtRate}
          series={[{ label: 'read', cls: 'series-a', value: (s) => s.diskRead }, { label: 'write', cls: 'series-b', value: (s) => s.diskWrite }]} />
      </div>
    </Panel>
  );
}
