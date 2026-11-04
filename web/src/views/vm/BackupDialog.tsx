import { useState, type FormEvent } from 'react';
import { enc } from '../../api';
import { Modal } from '../../components/Modal';
import { useToast } from '../../components/Toasts';
import { Field, Spinner } from '../../components/ui';
import { useApp } from '../../store';
import type { VM } from '../../types';

/** Back up now: to local backups or straight to an offsite target (Proxmox: Backup now → Storage). */
export function BackupDialog({ vm, onClose }: { vm: VM; onClose: () => void }) {
  const app = useApp();
  const { report } = useToast();
  const [target, setTarget] = useState('local');
  const [busy, setBusy] = useState(false);
  const chosen = app.target(target);
  const autoPush = vm.offsite.auto && vm.offsite.targets.length > 0;

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true);
    try {
      await app.startTask('POST', `/api/vms/${enc(vm.name)}/backup`, { target: chosen ? chosen.id : null },
        chosen ? `Back up ${vm.name} to ${chosen.name}` : `Back up ${vm.name}`);
      onClose();
    } catch (err) {
      report(err);
      setBusy(false);
    }
  };

  return (
    <Modal title={`Back up ${vm.name}`} onClose={onClose}>
      <form onSubmit={submit}>
        <div className="modal-body stack">
          <Field label="Destination" hint={chosen
            ? `Straight to ${chosen.name}, without a local backup; keeps the newest ${chosen.keep} there.`
            : `An instant APFS clone in local backups${autoPush ? ', then pushed to the VM’s offsite targets' : ''}.`}>
            <select value={target} autoFocus onChange={(e) => setTarget(e.target.value)}>
              <option value="local">Local backups</option>
              {app.targets.map((t) => <option key={t.id} value={t.id}>{t.name} ({t.kind.toUpperCase()})</option>)}
            </select>
          </Field>
          {vm.state === 'running' && (
            <p className="muted small">{vm.os === 'darwin'
              ? 'macOS can’t freeze its filesystem, so a backup of the running VM is crash-consistent: shut it down first for a clean one.'
              : 'The guest’s root filesystem is frozen for the moment of the clone.'}</p>
          )}
        </div>
        <div className="modal-footer">
          <button type="button" className="btn" onClick={onClose}>Cancel</button>
          <button type="submit" className="btn primary" disabled={busy}>{busy && <Spinner />}Back up</button>
        </div>
      </form>
    </Modal>
  );
}

/** The Back up now button: asks for the destination once offsite targets exist. */
export function BackupButton({ vm, className = '' }: { vm: VM; className?: string }) {
  const app = useApp();
  const { report } = useToast();
  const [open, setOpen] = useState(false);
  const unavailable = vm.state === 'missing' || vm.state === 'offline';
  const click = async () => {
    if (app.targets.length) { setOpen(true); return; }
    try {
      await app.startTask('POST', `/api/vms/${enc(vm.name)}/backup`, {}, `Back up ${vm.name}`);
    } catch (err) {
      report(err);
    }
  };
  return (
    <>
      <button type="button" className={`btn ${className}`} disabled={unavailable} title={unavailable ? `The VM is ${vm.state}` : undefined}
        onClick={() => void click()}>Back up now{app.targets.length ? '…' : ''}</button>
      {open && <BackupDialog vm={vm} onClose={() => setOpen(false)} />}
    </>
  );
}
