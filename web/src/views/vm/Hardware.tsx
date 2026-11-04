import { useState, type FormEvent } from 'react';
import { api, enc } from '../../api';
import { useConfirm } from '../../components/Modal';
import type { Navigate } from '../../components/Shell';
import { useToast } from '../../components/Toasts';
import { ActionButton, Empty, Field, Panel, Segmented, Spinner } from '../../components/ui';
import { fmtBytes, fmtMemMB } from '../../format';
import { useApp } from '../../store';
import type { VM } from '../../types';

/** Memory in MB, in 256 MB steps from 512 MB up to the host's RAM. */
export function MemoryField({ value, onChange, hostBytes }: { value: string; onChange: (value: string) => void; hostBytes?: number }) {
  const hostMB = hostBytes ? Math.floor(hostBytes / 2 ** 20) : undefined;
  const mb = parseInt(value, 10);
  return (
    <Field label="Memory (MB)" hint={`${Number.isFinite(mb) ? `${fmtMemMB(mb)} · ` : ''}multiples of 256 MB${hostMB ? `, host has ${fmtMemMB(hostMB)}` : ''}`}>
      <input type="number" required min={512} max={hostMB} step={256} value={value} onChange={(e) => onChange(e.target.value)} />
    </Field>
  );
}

export function HardwareView({ vm, navigate }: { vm: VM; navigate: Navigate }) {
  const app = useApp();
  const { toast, report } = useToast();
  const server = {
    cpus: String(vm.cpus ?? 2),
    memoryMB: String(vm.memoryMB ?? 2048),
    diskGB: String(vm.diskGB ?? 20),
    mode: vm.network.mode,
    iface: vm.network.interface ?? app.interfaces.find((i) => i.default)?.device ?? app.interfaces[0]?.device ?? '',
    nested: vm.nested,
  };
  // The form shows the server's values overlaid with the user's edits.
  const [edits, setEdits] = useState<Partial<typeof server>>({});
  const [busy, setBusy] = useState(false);
  const f = { ...server, ...edits };
  const set = (patch: Partial<typeof server>) => setEdits({ ...edits, ...patch });

  const stopped = vm.state === 'stopped';
  const hostCPUs = Math.max(1, app.host?.cpus ?? 4);
  const changed = f.cpus !== server.cpus || f.memoryMB !== server.memoryMB || f.diskGB !== server.diskGB
    || f.mode !== server.mode || (f.mode === 'bridged' && f.iface !== vm.network.interface) || f.nested !== server.nested;

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true);
    try {
      const updated = await api<VM>('PUT', `/api/vms/${enc(vm.name)}/hardware`, {
        cpus: parseInt(f.cpus, 10), memoryMB: parseInt(f.memoryMB, 10), diskGB: parseInt(f.diskGB, 10),
        network: { mode: f.mode, interface: f.mode === 'bridged' ? f.iface : null }, nested: f.nested,
      });
      app.updateVM(updated);
      setEdits({});
      toast(`Hardware of ${vm.name} updated`, 'ok');
    } catch (err) {
      report(err);
    } finally {
      setBusy(false);
    }
  };

  return (
    <>
      {!stopped && (
        <div className="note">
          {vm.state === 'running' ? 'Shut down the VM to change its hardware.' : `The VM is ${vm.state}; hardware can only be changed while it is stopped.`}
        </div>
      )}
      <Panel title="Hardware" narrow>
        <form onSubmit={submit}>
          <fieldset disabled={!stopped || busy}>
            <div className="form-grid">
              <Field label="CPUs" hint={`Host has ${hostCPUs}`}>
                <select value={f.cpus} onChange={(e) => set({ cpus: e.target.value })}>
                  {Array.from({ length: hostCPUs }, (_, i) => <option key={i} value={String(i + 1)}>{i + 1}</option>)}
                </select>
              </Field>
              <MemoryField value={f.memoryMB} onChange={(memoryMB) => set({ memoryMB })} hostBytes={app.host?.memoryBytes} />
              <Field label="Disk (GB)" hint="Disks can only grow. The root filesystem expands on the next boot.">
                <input type="number" required min={vm.diskGB ?? 1} max={16384} step={1} value={f.diskGB} onChange={(e) => set({ diskGB: e.target.value })} />
              </Field>
              <div className="field">
                <span>Network</span>
                <Segmented name="mode" value={f.mode} onChange={(mode) => set({ mode })}
                  options={[['bridged', 'Bridged', !app.interfaces.length], ['nat', 'NAT']]} />
                <span className="hint">The MAC address stays the same.</span>
              </div>
              {f.mode === 'bridged' && (
                <Field label="Interface">
                  <select value={f.iface} onChange={(e) => set({ iface: e.target.value })}>
                    {app.interfaces.map((i) => <option key={i.device} value={i.device}>{i.name} ({i.device}){i.default ? ' — default' : ''}</option>)}
                    {f.iface && !app.interfaces.some((i) => i.device === f.iface) && <option value={f.iface}>{f.iface}</option>}
                  </select>
                </Field>
              )}
              <div className="field span2">
                <label className="check">
                  <input type="checkbox" checked={f.nested} disabled={!f.nested && app.host?.nestedVirtualization === false}
                    onChange={(e) => set({ nested: e.target.checked })} />
                  Nested virtualization
                </label>
                <span className="hint">
                  {app.host?.nestedVirtualization === false
                    ? 'Needs Apple M3 or later and macOS 15.'
                    : 'Lets the guest run its own VMs (KVM, /dev/kvm).'}
                </span>
              </div>
            </div>
            {f.mode !== vm.network.mode && vm.os !== 'darwin' && !vm.cloudInit.network.dhcp && (
              <p className="note warn">This VM has a static address. Update it on the{' '}
                <button type="button" className="link" onClick={() => navigate({ type: 'vm', name: vm.name, tab: 'cloudinit' })}>Cloud-Init</button>{' '}
                tab to match the new network.</p>
            )}
            <div className="form-actions">
              <button type="button" className="btn" disabled={!changed} onClick={() => setEdits({})}>Reset</button>
              <button type="submit" className="btn primary" disabled={!changed}>{busy && <Spinner />}Save</button>
            </div>
          </fieldset>
        </form>
      </Panel>
      <DisksPanel vm={vm} />
      <SharesPanel vm={vm} />
    </>
  );
}

function DisksPanel({ vm }: { vm: VM }) {
  const app = useApp();
  const confirm = useConfirm();
  const { toast } = useToast();
  const [size, setSize] = useState('10');
  const stopped = vm.state === 'stopped';
  const why = stopped ? null : 'Shut the VM down first';
  const path = (file: string) => `/api/vms/${enc(vm.name)}/disks/${enc(file)}`;

  const add = async () => {
    const updated = await api<VM>('POST', `/api/vms/${enc(vm.name)}/disks`, { sizeGB: parseInt(size, 10) });
    app.updateVM(updated);
    toast(`Added a ${size} GB disk to ${vm.name}`, 'ok');
  };
  const resize = async (file: string, current: number) => {
    const answer = window.prompt(`New size of ${file} in GB (now ${current} GB; disks can only grow):`, String(current * 2));
    if (!answer) return;
    app.updateVM(await api<VM>('PUT', path(file), { sizeGB: parseInt(answer, 10) }));
  };
  const remove = async (file: string) => {
    const ok = await confirm({
      title: `Remove ${file}`, danger: true, confirmLabel: 'Remove disk', requireText: file,
      message: `Permanently delete ${file} of “${vm.name}” and everything on it? Backups that contain it are kept.`,
    });
    if (ok) app.updateVM(await api<VM>('DELETE', path(file), {}));
  };

  return (
    <Panel title="Extra disks" flush narrow extra={
      <div className="actions">
        <input type="number" className="narrow" min={1} max={16384} value={size} aria-label="Size in GB" disabled={!stopped}
          onChange={(e) => setSize(e.target.value)} />
        <span className="muted small">GB</span>
        <ActionButton className="small" disabled={!stopped || !(parseInt(size, 10) > 0)} title={why} onClick={add}>Add disk</ActionButton>
      </div>
    }>
      {!vm.disks.length ? <Empty>No extra disks. Added disks appear in the guest as /dev/vdb, /dev/vdc, … and take space only as they fill.</Empty> : (
        <table className="table">
          <thead><tr><th>Disk</th><th>Size</th><th className="wide-only">Used on host</th><th>Backup</th><th /></tr></thead>
          <tbody>
            {vm.disks.map((d, i) => (
              <tr key={d.file}>
                <td><span className="mono">{d.file}</span><div className="small muted">/dev/vd{String.fromCharCode(98 + i)}</div></td>
                <td className="nowrap">{d.sizeGB} GB</td>
                <td className="nowrap wide-only">{fmtBytes(d.usedBytes)}</td>
                <td>
                  <input type="checkbox" className="switch" checked={d.backup} aria-label={`Back up ${d.file}`}
                    onChange={async (e) => app.updateVM(await api<VM>('PUT', path(d.file), { backup: e.target.checked }))} />
                </td>
                <td className="actions-cell">
                  <div className="actions">
                    <ActionButton className="small" disabled={!stopped} title={why} onClick={() => resize(d.file, d.sizeGB)}>Resize</ActionButton>
                    <ActionButton className="small danger" disabled={!stopped} title={why} onClick={() => remove(d.file)}>Remove</ActionButton>
                  </div>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      {vm.disks.length > 0 && (
        <p className="muted small prose" style={{ padding: '0 14px 10px' }}>
          {vm.os === 'darwin' ? (
            <>Format a new disk in the guest with Disk Utility. macOS can’t freeze its filesystems, so backups of the running VM
              are crash-consistent.</>
          ) : (
            <>Format a new disk in the guest (e.g. <span className="mono">sudo mkfs.ext4 /dev/vdb</span>) and mount it by UUID in
              /etc/fstab. Only the root filesystem is frozen during backups.</>
          )}
        </p>
      )}
    </Panel>
  );
}

function SharesPanel({ vm }: { vm: VM }) {
  const app = useApp();
  const { toast, report } = useToast();
  const [name, setName] = useState('');
  const [path, setPath] = useState('');
  const [readOnly, setReadOnly] = useState(false);
  const [busy, setBusy] = useState(false);
  const stopped = vm.state === 'stopped';

  const add = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true);
    try {
      app.updateVM(await api<VM>('POST', `/api/vms/${enc(vm.name)}/shares`, { name: name.trim(), path: path.trim(), readOnly }));
      toast(`Shared ${path.trim()} with ${vm.name}`, 'ok');
      setName('');
      setPath('');
      setReadOnly(false);
    } catch (err) {
      report(err);
    } finally {
      setBusy(false);
    }
  };
  const remove = async (share: string) => {
    app.updateVM(await api<VM>('DELETE', `/api/vms/${enc(vm.name)}/shares/${enc(share)}`, {}));
  };
  // macOS mounts Tart's shares itself; Linux guests mount them with a unit from the cloud-init seed.
  const macOS = vm.os === 'darwin';
  const mountRoot = macOS ? '/Volumes/My Shared Files' : '/mnt/shared';

  return (
    <Panel title="Shared folders" narrow>
      {vm.shares.length > 0 && (
        <table className="table">
          <thead><tr><th>In the guest</th><th>Folder on this Mac</th><th /></tr></thead>
          <tbody>
            {vm.shares.map((s) => (
              <tr key={s.name}>
                <td className="mono wrap">{mountRoot}/{s.name}{s.readOnly && <span className="muted"> (read-only)</span>}</td>
                <td className="mono wrap">{s.path}</td>
                <td className="actions-cell">
                  <ActionButton className="small danger" disabled={!stopped} title={stopped ? null : 'Shut the VM down first'}
                    onClick={() => remove(s.name)}>Remove</ActionButton>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      <form onSubmit={add} className={vm.shares.length ? 'spaced' : undefined}>
        <fieldset disabled={!stopped || busy}>
          <div className="form-row">
            <Field label="Name"><input type="text" required pattern="[A-Za-z0-9][A-Za-z0-9_.\-]{0,62}" placeholder="projects"
              autoComplete="off" spellCheck={false} value={name} onChange={(e) => setName(e.target.value)} /></Field>
            <Field label="Folder on this Mac" className="grow"><input type="text" required placeholder="~/Projects" autoComplete="off"
              spellCheck={false} value={path} onChange={(e) => setPath(e.target.value)} /></Field>
            <label className="check tall">
              <input type="checkbox" checked={readOnly} onChange={(e) => setReadOnly(e.target.checked)} />
              Read-only
            </label>
            <button type="submit" className="btn">{busy && <Spinner />}Share</button>
          </div>
        </fieldset>
      </form>
      <p className="muted small spaced">
        {stopped ? 'Shares' : 'Shut the VM down to change shares. They'} are mounted in the guest at {mountRoot}/&lt;name&gt; on every
        boot (virtiofs). Files the guest creates belong to your macOS user.
        {!macOS && !vm.hasSeed && ' This VM has no cloud-init seed: mount them yourself with sudo mount -t virtiofs com.apple.virtio-fs.automount /mnt/shared.'}
      </p>
    </Panel>
  );
}
