import { useState, type FormEvent } from 'react';
import { enc } from '../../api';
import { Modal } from '../../components/Modal';
import { useToast } from '../../components/Toasts';
import { Field, Segmented, Spinner } from '../../components/ui';
import { useApp } from '../../store';
import type { VM } from '../../types';

/** Copies a VM or template under a new name; a static address has to change, or the two VMs would clash. */
export function CloneDialog({ vm, onClose }: { vm: VM; onClose: () => void }) {
  const app = useApp();
  const { report } = useToast();
  const taken = new Set(app.vms.map((v) => v.name));
  const base = vm.template ? vm.name.replace(/-?template$/, '') || vm.name : `${vm.name}-clone`;
  let suggestion = base;
  for (let i = 2; taken.has(suggestion); i++) suggestion = `${base}-${i}`;

  // A macOS guest's address isn't Proxmacs's to set (no cloud-init).
  const isStatic = vm.os !== 'darwin' && !vm.cloudInit.network.dhcp;
  const [name, setName] = useState(suggestion);
  const [start, setStart] = useState(!vm.template && vm.state === 'running');
  const [mode, setMode] = useState<'dhcp' | 'static'>(isStatic ? 'static' : 'dhcp');
  const [address, setAddress] = useState(vm.cloudInit.network.address ?? '');
  const [busy, setBusy] = useState(false);
  const sameAddress = isStatic && mode === 'static' && address.trim() === vm.cloudInit.network.address;

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    if (sameAddress) return;
    setBusy(true);
    try {
      const ipv4 = !isStatic ? undefined : mode === 'dhcp' ? { dhcp: true } : {
        dhcp: false, address: address.trim(), gateway: vm.cloudInit.network.gateway, dns: vm.cloudInit.network.dns,
      };
      await app.startTask('POST', `/api/vms/${enc(vm.name)}/clone`, { name: name.trim(), start, ipv4 }, `Clone ${vm.name} to ${name.trim()}`);
      onClose();
    } catch (err) {
      report(err);
      setBusy(false);
    }
  };

  return (
    <Modal title={`Clone ${vm.name}`} onClose={onClose}>
      <form onSubmit={submit}>
        <div className="modal-body stack">
          <p className="muted">
            Disks are copied as instant APFS clones and take space only as they diverge. The clone gets a new MAC address
            {vm.os === 'darwin'
              ? ' and serial number, and on its first boot its own host name and new SSH host keys.'
              : ', and on its first boot new SSH host keys and machine-id.'}
            {vm.state === 'running' && ' The running VM’s filesystem is frozen for the moment of the copy.'}
          </p>
          <Field label="Name" hint="Lowercase letters, digits and dashes">
            <input type="text" required autoFocus pattern="[a-z0-9][a-z0-9\-]{0,62}" autoComplete="off" spellCheck={false}
              value={name} onChange={(e) => setName(e.target.value)} />
          </Field>
          {isStatic && (
            <div className="field">
              <span>IPv4</span>
              <Segmented name="clone-ip" value={mode} onChange={setMode} options={[['static', 'Static'], ['dhcp', 'DHCP']]} />
              {mode === 'static' && (
                <input type="text" required placeholder="192.168.1.51/24" value={address} onChange={(e) => setAddress(e.target.value)}
                  aria-label="Static address" />
              )}
              <span className={`hint${sameAddress ? ' error-text' : ''}`}>
                {sameAddress ? `${vm.name} already uses this address: pick another one.` : `${vm.name} uses ${vm.cloudInit.network.address}.`}
              </span>
            </div>
          )}
          <label className="check">
            <input type="checkbox" checked={start} onChange={(e) => setStart(e.target.checked)} />
            Start the clone
          </label>
        </div>
        <div className="modal-footer">
          <button type="button" className="btn" onClick={onClose}>Cancel</button>
          <button type="submit" className="btn primary" disabled={busy || sameAddress}>{busy && <Spinner />}Clone</button>
        </div>
      </form>
    </Modal>
  );
}
