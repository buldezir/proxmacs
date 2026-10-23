import { useState } from 'react';
import { api } from '../../api';
import { useToast } from '../../components/Toasts';
import { Badge, Field, Segmented, Spinner } from '../../components/ui';
import type { CloudInit } from '../../types';

/** Cloud-init settings as edited in a form (strings, one SSH key per line). */
export interface GuestForm {
  user: string;
  password: string;
  confirm: string;
  removePassword: boolean;
  sshKeys: string;
  dhcp: boolean;
  address: string;
  gateway: string;
  dns: string;
}

export function guestForm(config?: CloudInit, hostKeys: string[] = []): GuestForm {
  return {
    user: config?.user ?? 'debian',
    password: '',
    confirm: '',
    removePassword: false,
    sshKeys: (config?.sshKeys ?? hostKeys).join('\n'),
    dhcp: config?.network.dhcp ?? true,
    address: config?.network.address ?? '',
    gateway: config?.network.gateway ?? '',
    dns: (config?.network.dns ?? []).join(', '),
  };
}

export const splitKeys = (text: string) => text.split('\n').map((k) => k.trim()).filter((k) => k && !k.startsWith('#'));

/** Request fields shared by POST /api/vms and PUT /api/vms/:name/cloudinit. */
export function guestPayload(f: GuestForm) {
  return {
    user: f.user.trim(),
    sshKeys: splitKeys(f.sshKeys),
    ipv4: f.dhcp
      ? { dhcp: true }
      : { dhcp: false, address: f.address.trim(), gateway: f.gateway.trim() || null, dns: dnsServers(f) },
  };
}

/** Defaults to the gateway, which most routers serve DNS on. */
function dnsServers(f: GuestForm): string[] {
  const listed = f.dns.split(/[\s,]+/).filter(Boolean);
  return listed.length || !f.gateway.trim() ? listed : [f.gateway.trim()];
}

/** Client-side checks the browser can't express with input attributes. */
export function guestProblem(f: GuestForm): string | null {
  if (f.password !== f.confirm) return 'The passwords don’t match';
  if (!f.dhcp && !/^\d{1,3}(\.\d{1,3}){3}\/\d{1,2}$/.test(f.address.trim())) return 'Enter the static address in CIDR form, e.g. 192.168.1.50/24';
  return null;
}

const PASSWORD_STATE = {
  set: <Badge kind="ok">set</Badge>,
  none: <Badge>none — console login disabled</Badge>,
  unknown: <Badge kind="warn" title="Created before Proxmacs tracked passwords">unchanged since creation</Badge>,
};

export function GuestFields({ value: f, onChange, passwordState, natHint }: {
  value: GuestForm;
  onChange: (form: GuestForm) => void;
  /** Present when editing an existing VM. */
  passwordState?: CloudInit['password'];
  natHint?: boolean;
}) {
  const { toast, report } = useToast();
  const [loadingKeys, setLoadingKeys] = useState(false);
  const set = (patch: Partial<GuestForm>) => onChange({ ...f, ...patch });
  const editing = passwordState !== undefined;

  const addHostKeys = async () => {
    setLoadingKeys(true);
    try {
      const keys = await api<string[]>('GET', '/api/host/sshkeys');
      const current = splitKeys(f.sshKeys);
      const fresh = keys.filter((k) => !current.includes(k));
      // A click that changes nothing must still say why: the endpoint legitimately
      // returns an empty list when this Mac has no keys, and silence reads as a bug.
      if (!fresh.length) {
        toast(keys.length
          ? 'Those keys are already in the list'
          : 'This Mac has no SSH public keys in ~/.ssh. Generate one with `ssh-keygen -t ed25519`, or paste a key below.', keys.length ? 'info' : 'error');
        return;
      }
      set({ sshKeys: [...current, ...fresh].join('\n') });
    } catch (e) {
      report(e);
    } finally {
      setLoadingKeys(false);
    }
  };

  const keyCount = splitKeys(f.sshKeys).length;
  return (
    <div className="form-grid">
      <Field label="User" hint={editing ? 'Changing it adds a new account; the old one is kept.' : 'Gets passwordless sudo.'}>
        <input type="text" required pattern="[a-z_][a-z0-9_\-]{0,31}" title="Lowercase Linux user name"
          autoComplete="off" spellCheck={false} autoCapitalize="off" value={f.user} onChange={(e) => set({ user: e.target.value })} />
      </Field>
      <div className="field">
        <span>Password {editing && PASSWORD_STATE[passwordState]}</span>
        <input type="password" autoComplete="new-password" placeholder={editing ? 'Leave empty to keep' : 'Optional'}
          disabled={f.removePassword} value={f.password} onChange={(e) => set({ password: e.target.value })} />
        <input type="password" autoComplete="new-password" placeholder="Repeat" aria-label="Repeat password"
          disabled={f.removePassword || !f.password} value={f.confirm} onChange={(e) => set({ confirm: e.target.value })} />
        <span className="hint">
          For the serial console; SSH password login stays off.
          {editing && passwordState !== 'none' && (
            <label className="check inline">
              <input type="checkbox" checked={f.removePassword} onChange={(e) => set({ removePassword: e.target.checked, password: '', confirm: '' })} />
              Remove password
            </label>
          )}
        </span>
      </div>

      <div className="field span2">
        <span className="label-row">
          SSH public keys <span className="muted">({keyCount})</span>
          <span className="spacer" />
          <button type="button" className="btn small" onClick={addHostKeys} disabled={loadingKeys}>
            {loadingKeys && <Spinner />}Add this Mac’s keys
          </button>
        </span>
        <textarea rows={4} spellCheck={false} placeholder="ssh-ed25519 AAAA… user@host (one per line)"
          value={f.sshKeys} onChange={(e) => set({ sshKeys: e.target.value })} />
        <span className="hint">Exactly these keys end up in ~/.ssh/authorized_keys.</span>
      </div>

      <div className="field span2">
        <span>IPv4</span>
        <Segmented name="ipv4" value={f.dhcp ? 'dhcp' : 'static'} onChange={(v) => set({ dhcp: v === 'dhcp' })}
          options={[['dhcp', 'DHCP'], ['static', 'Static']]} />
      </div>
      {!f.dhcp && <>
        <Field label="Address" hint={natHint ? 'NAT network: 192.168.64.0/24' : 'CIDR, e.g. 192.168.1.50/24'}>
          <input type="text" required placeholder="192.168.1.50/24" spellCheck={false} autoComplete="off"
            value={f.address} onChange={(e) => set({ address: e.target.value })} />
        </Field>
        <Field label="Gateway" hint={natHint ? 'NAT gateway: 192.168.64.1' : undefined}>
          <input type="text" placeholder="192.168.1.1" spellCheck={false} autoComplete="off"
            value={f.gateway} onChange={(e) => set({ gateway: e.target.value })} />
        </Field>
        <Field label="DNS servers" hint="Comma-separated; defaults to the gateway" className="span2">
          <input type="text" placeholder={f.gateway || '1.1.1.1, 9.9.9.9'} spellCheck={false} autoComplete="off"
            value={f.dns} onChange={(e) => set({ dns: e.target.value })} />
        </Field>
      </>}
    </div>
  );
}
