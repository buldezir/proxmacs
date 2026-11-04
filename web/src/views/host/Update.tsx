import { api } from '../../api';
import { ActionButton, Badge, KV, Panel, Spinner } from '../../components/ui';
import { useConfirm } from '../../components/Modal';
import { fmtDate, plural } from '../../format';
import { useApp } from '../../store';
import type { UpdateStatus } from '../../types';

const dayFmt = new Intl.DateTimeFormat(undefined, { year: 'numeric', month: 'short', day: 'numeric' });

const PHASES: Record<NonNullable<UpdateStatus['install']>['phase'], string> = {
  checking: 'Checking for the update…',
  downloading: 'Downloading…',
  extracting: 'Unpacking…',
  installing: 'Installing; Proxmacs restarts…',
};

/** Proxmacs's own version, and its updates: checked and installed by the menubar app, through Sparkle. */
export function UpdatePanel() {
  const { update, restarting, tasks, reloadUpdate } = useApp();
  const confirm = useConfirm();
  if (!update) return null;
  const { available, install } = update;

  const running = tasks.filter((t) => t.status === 'running').length;

  const check = async () => {
    await api('POST', '/api/update/check');
    await reloadUpdate();
  };
  const installUpdate = async () => {
    const ok = await confirm({
      title: `Update to Proxmacs ${available?.version ?? ''}`.trim(),
      message: 'Proxmacs downloads the update, quits and opens again, and this page reloads when it is back. VMs keep running.' +
        (running ? ` ${plural(running, 'running task')} (see Tasks) will be cut off.` : ''),
      confirmLabel: 'Install and restart',
    });
    if (!ok) return;
    await api('POST', '/api/update/install');
    await reloadUpdate();
  };

  let status;
  if (restarting) status = <span className="copy-line"><Spinner />Restarting…</span>;
  else if (install) {
    status = <div>
      <span className="copy-line"><Spinner />{PHASES[install.phase]}</span>
      {install.progress != null && <div className="progress"><div style={{ width: `${Math.round(install.progress * 100)}%` }} /></div>}
    </div>;
  } else if (update.checking) status = <span className="copy-line"><Spinner />Checking…</span>;
  else if (available) status = <Badge kind="info">{available.version} available</Badge>;
  else if (update.lastChecked) status = <Badge kind="ok">up to date</Badge>;

  return (
    <Panel title="Proxmacs" extra={update.supported && !install && !restarting && <div className="actions">
      <ActionButton className="small" onClick={check} disabled={update.checking}>Check for updates</ActionButton>
      {available && <ActionButton className="primary small" onClick={installUpdate} disabled={update.checking}>
        Install {available.version}
      </ActionButton>}
    </div>}>
      <KV rows={[
        ['Version', <span className="copy-line"><span className="mono">{update.version || '—'}</span>{status}</span>],
        !update.supported && ['Updates', <span className="muted">{update.reason}</span>],
        update.supported && ['Last checked', update.lastChecked ? fmtDate(update.lastChecked) : 'never'],
        !!update.error && ['Error', <span className="error-text">{update.error}</span>],
        available && ['New version', <div>
          <span className="mono">{available.version}</span>
          {available.date && <span className="muted"> · released {fmtDate(available.date, dayFmt)}</span>}
          {available.url && <> · <a href={available.url} target="_blank" rel="noreferrer">release page</a></>}
          {available.notes && <details className="release-notes">
            <summary>What's new</summary>
            <p className="notes">{available.notes.trim()}</p>
          </details>}
        </div>],
      ]} />
    </Panel>
  );
}
