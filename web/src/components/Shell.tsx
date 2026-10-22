import { lazy, Suspense, useEffect, useState, type ReactNode } from 'react';
import { fmtDate, fmtDuration, plural, timeFmt } from '../format';
import { routeHash, useHashRoute, useLocalStorage, type Route } from '../hooks';
import { useApp } from '../store';
import type { Task } from '../types';
import { CreateVMDialog } from '../views/CreateVM';
import { HostSummary } from '../views/host/HostSummary';
import { ImagesView } from '../views/host/Images';
import { JobsView } from '../views/host/Jobs';
import { NotificationsView } from '../views/host/Notifications';
import { StorageView } from '../views/host/Storage';
import { TargetsView } from '../views/host/Targets';
import { BackupsView } from '../views/vm/Backups';
import { CloudInitView } from '../views/vm/CloudInit';
import { HardwareView } from '../views/vm/Hardware';
import { OffsiteView } from '../views/vm/Offsite';
import { OptionsView } from '../views/vm/Options';
import { VMSummary } from '../views/vm/Summary';
import { Badge, Loading, Spinner, StateBadge, StateDot, Tags } from './ui';

// xterm is large; load it with the console tab.
const ConsoleView = lazy(() => import('../views/vm/Console').then((m) => ({ default: m.ConsoleView })));
const DisplayView = lazy(() => import('../views/vm/Display').then((m) => ({ default: m.DisplayView })));

const HOST_TABS = [
  ['summary', 'Summary'], ['storage', 'Storage'], ['jobs', 'Backup Jobs'], ['targets', 'Backup Targets'],
  ['notifications', 'Notifications'], ['images', 'Images'],
] as const;
const VM_TABS = [
  ['summary', 'Summary'], ['hardware', 'Hardware'], ['cloudinit', 'Cloud-Init'], ['options', 'Options'],
  ['display', 'Display'], ['console', 'Console'], ['backups', 'Backups'], ['offsite', 'Offsite'],
] as const;

export type Navigate = (route: Route) => void;

export function Shell({ onLogout }: { onLogout: () => void }) {
  const app = useApp();
  const [rawRoute, setRoute] = useHashRoute();
  const [creating, setCreating] = useState(false);
  // The resource tree is a slide-out menu on narrow screens.
  const [navOpen, setNavOpen] = useState(false);
  const navigate: Navigate = (next) => { setNavOpen(false); setRoute(next); };

  // Fall back to the host when the VM is gone; unknown tabs show the summary.
  let route = rawRoute;
  if (route.type === 'vm' && app.loaded && !app.vm(route.name)) route = { type: 'host', tab: 'summary' };
  const tabs = route.type === 'vm' ? VM_TABS : HOST_TABS;
  if (!tabs.some(([id]) => id === route.tab)) route = { ...route, tab: 'summary' };
  // Rewrite the URL only when the route was corrected; otherwise a render that lands between a URL
  // change and its hashchange event would put the old route back.
  useEffect(() => {
    const hash = routeHash(route);
    if (app.loaded && routeHash(rawRoute) !== hash && location.hash !== hash) history.replaceState(null, '', hash);
  });
  useEffect(() => {
    if (!navOpen) return;
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') setNavOpen(false); };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [navOpen]);

  return (
    <div id="app">
      <Topbar onCreate={() => setCreating(true)} onLogout={onLogout} navigate={navigate} navOpen={navOpen} onToggleNav={() => setNavOpen(!navOpen)} />
      <div className="main">
        <Tree route={route} navigate={navigate} open={navOpen} onLogout={onLogout} />
        {navOpen && <div className="nav-backdrop" onClick={() => setNavOpen(false)} />}
        <section className="content">
          {app.loaded ? <Content route={route} navigate={navigate} /> : <Loading />}
        </section>
      </div>
      <TasksPanel />
      {creating && <CreateVMDialog onClose={() => setCreating(false)} />}
    </div>
  );
}

function Topbar({ onCreate, onLogout, navigate, navOpen, onToggleNav }: {
  onCreate: () => void; onLogout: () => void; navigate: Navigate; navOpen: boolean; onToggleNav: () => void;
}) {
  const { host, stats, tasks, online, storage, setTasksOpen } = useApp();
  const offline = storage ? (['vms', 'backups'] as const).filter((k) => !storage[k].available) : [];
  const running = tasks.filter((t) => t.status === 'running').length;
  const memory = stats?.memory;
  const usedPct = memory ? Math.round((memory.used / memory.total) * 100) : null;
  return (
    <header className="topbar">
      <button type="button" className="nav-toggle" aria-label="Resources" aria-expanded={navOpen} onClick={onToggleNav}>
        <span aria-hidden="true" />
      </button>
      <div className="brand"><span className="brand-mark" aria-hidden="true" /><span className="brand-name">Proxmacs</span></div>
      <div className="host-info">
        {host && <>
          <strong>{host.hostname || 'host'}</strong>
          <span>·</span>
          {host.tartVersion ? <span>Tart {host.tartVersion}</span>
            : <Badge kind="err" title="The tart binary was not found on this Mac">Tart not found</Badge>}
        </>}
      </div>
      <div className="spacer" />
      {memory && usedPct != null && (
        <button type="button" className={`mem-indicator ${memory.pressure}`} title={`Memory pressure: ${memory.pressure}`}
          onClick={() => navigate({ type: 'host', tab: 'summary' })}>
          <span className="wide-only">Memory</span>
          <span className="mini-meter"><span style={{ width: `${usedPct}%` }} /></span>
          <span className="mono">{usedPct}%</span>
        </button>
      )}
      {offline.length > 0 && (
        <button type="button" className="btn storage-indicator" title="A storage drive is disconnected"
          onClick={() => navigate({ type: 'host', tab: 'storage' })}>
          <Badge kind="err"><span className="wide-only">{offline.map((k) => (k === 'vms' ? 'VM storage' : 'Backup storage')).join(' & ')} </span>offline</Badge>
        </button>
      )}
      {!online && <Badge kind="err">Offline<span className="wide-only">: connection lost</span></Badge>}
      <button type="button" className={`task-indicator${running ? ' active' : ''}`} title="Show task log" onClick={() => setTasksOpen(true)}>
        {running
          ? <><Spinner /><span className="wide-only">{plural(running, 'task')} running</span><span className="narrow-only">{running}</span></>
          : <><span className="wide-only">No running tasks</span><span className="narrow-only">Tasks</span></>}
      </button>
      <button type="button" className="btn primary" onClick={onCreate}><span className="wide-only">Create VM</span><span className="narrow-only">New VM</span></button>
      <button type="button" className="btn wide-only" onClick={onLogout}>Log out</button>
    </header>
  );
}

function Tree({ route, navigate, open, onLogout }: { route: Route; navigate: Navigate; open: boolean; onLogout: () => void }) {
  const { host, vms: all } = useApp();
  const [filter, setFilter] = useLocalStorage('proxmacs.treeFilter', '');
  const terms = filter.toLowerCase().split(/[\s,]+/).filter(Boolean);
  const vms = terms.length ? all.filter((vm) => terms.every((t) => vm.name.includes(t) || vm.tags.some((tag) => tag.includes(t)))) : all;
  return (
    <nav className={`tree-panel${open ? ' open' : ''}`} aria-label="Resources">
      {(all.length > 5 || filter) && (
        <div className="tree-filter">
          <input type="search" placeholder="Filter by name or tag" aria-label="Filter VMs" value={filter}
            onChange={(e) => setFilter(e.target.value)} />
        </div>
      )}
      <ul className="tree" role="tree">
        <li role="treeitem" aria-expanded="true">
          <button type="button" className={`tree-item${route.type === 'host' ? ' selected' : ''}`}
            onClick={() => navigate({ type: 'host', tab: route.type === 'host' ? route.tab : 'summary' })}>
            <span className="host-icon" aria-hidden="true" />
            <span className="label">{host?.hostname || 'Host'}</span>
          </button>
          <ul role="group">
            {vms.length === 0 && <li className="tree-empty">{all.length ? 'No matching VMs' : 'No VMs'}</li>}
            {vms.map((vm) => {
              const selected = route.type === 'vm' && route.name === vm.name;
              return (
                <li key={vm.name} role="treeitem">
                  <button type="button" className={`tree-item${selected ? ' selected' : ''}`}
                    title={`${vm.name} — ${vm.template ? 'template' : vm.state}${vm.activity ? ` (${vm.activity})` : ''}${vm.tags.length ? ` · ${vm.tags.join(', ')}` : ''}`}
                    onClick={() => navigate({ type: 'vm', name: vm.name, tab: route.type === 'vm' ? route.tab : 'summary' })}>
                    {vm.template ? <span className="dot template" /> : <StateDot state={vm.state} />}
                    <span className="label">{vm.name}</span>
                    {!!vm.tags.length && <span className="tree-tags wide-only"><Tags tags={vm.tags.slice(0, 2)} /></span>}
                    {vm.activity && <Spinner title={vm.activity} />}
                  </button>
                </li>
              );
            })}
          </ul>
        </li>
      </ul>
      <div className="tree-footer narrow-only">
        <button type="button" className="btn block" onClick={onLogout}>Log out</button>
      </div>
    </nav>
  );
}

function Content({ route, navigate }: { route: Route; navigate: Navigate }) {
  const app = useApp();
  const tabs = route.type === 'vm' ? VM_TABS : HOST_TABS;
  const vm = route.type === 'vm' ? app.vm(route.name) : null;
  const full = route.type === 'vm' && (route.tab === 'console' || route.tab === 'display');

  let body: ReactNode = null;
  if (route.type === 'host') {
    body = {
      storage: <StorageView />,
      jobs: <JobsView navigate={navigate} />,
      targets: <TargetsView />,
      notifications: <NotificationsView />,
      images: <ImagesView />,
    }[route.tab] ?? <HostSummary navigate={navigate} />;
  } else if (vm) {
    const props = { vm, navigate };
    body = {
      summary: <VMSummary {...props} />,
      hardware: <HardwareView {...props} />,
      cloudinit: <CloudInitView {...props} />,
      options: <OptionsView vm={vm} />,
      display: <Suspense fallback={<Loading />}><DisplayView vm={vm} /></Suspense>,
      console: <Suspense fallback={<Loading />}><ConsoleView vm={vm} /></Suspense>,
      backups: <BackupsView {...props} />,
      offsite: <OffsiteView {...props} />,
    }[route.tab] ?? <VMSummary {...props} />;
  }

  return (
    <>
      <div className="content-header">
        {route.type === 'host'
          ? <h2><span className="kind">Host</span>{app.host?.hostname ?? ''}</h2>
          : <>
            <h2><span className="kind">VM</span>{route.name}</h2>
            {vm && (vm.template ? <Badge>template</Badge> : <StateBadge state={vm.state} />)}
            {vm && <Tags tags={vm.tags} />}
            {vm?.activity && <Badge kind="info"><Spinner />{vm.activity}</Badge>}
            {vm?.seedPending && <Badge kind="warn" title="Cloud-init settings changed while running">restart to apply cloud-init</Badge>}
          </>}
      </div>
      <div className="tabbar" role="tablist">
        {tabs.map(([id, label]) => (
          <button key={id} type="button" role="tab" className={`tab${id === route.tab ? ' active' : ''}`} aria-selected={id === route.tab}
            onClick={() => navigate({ ...route, tab: id })}>
            {label}
          </button>
        ))}
      </div>
      {/* Keyed so each VM/tab gets fresh view state. */}
      <div key={routeHash(route)} className={`content-body${full ? ' full' : ''}`} role="tabpanel">
        <div className="view">{body}</div>
      </div>
    </>
  );
}

function TasksPanel() {
  const { tasks, tasksOpen, setTasksOpen } = useApp();
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const sorted = [...tasks].sort((a, b) => String(b.started).localeCompare(String(a.started)));
  const running = sorted.filter((t) => t.status === 'running').length;
  const errors = sorted.filter((t) => t.status === 'error').length;
  const toggle = (id: string) => setExpanded((s) => {
    const next = new Set(s);
    if (!next.delete(id)) next.add(id);
    return next;
  });

  return (
    <section className={`tasks-panel${tasksOpen ? '' : ' collapsed'}`}>
      <div className="tasks-header">
        <button type="button" className="tasks-toggle" aria-expanded={tasksOpen} onClick={() => setTasksOpen(!tasksOpen)}>
          <span className="chevron" aria-hidden="true" />Tasks
        </button>
        <span className="muted">
          {sorted.length ? `${sorted.length} total · ${running} running${errors ? ` · ${errors} failed` : ''}` : ''}
        </span>
      </div>
      <div className="tasks-body">
        {!sorted.length ? <div className="empty">No tasks yet.</div> : (
          <table className="table">
            <thead><tr><th>Started</th><th>VM</th><th>Task</th><th>Status</th><th>Message</th></tr></thead>
            <tbody>
              {sorted.map((t) => {
                const open = expanded.has(t.id);
                return [
                  <tr key={t.id} className={`task-row${open ? ' expanded' : ''}`} tabIndex={0} aria-expanded={open}
                    onClick={() => toggle(t.id)}
                    onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggle(t.id); } }}>
                    <td className="nowrap">{fmtDate(t.started, timeFmt)}</td>
                    <td className="nowrap">{t.vm || '—'}</td>
                    <td>
                      {t.title}
                      {t.status === 'running' && typeof t.progress === 'number' && (
                        <div className="progress"><div style={{ width: `${Math.round(Math.min(1, Math.max(0, t.progress)) * 100)}%` }} /></div>
                      )}
                    </td>
                    <td className="nowrap"><TaskStatus task={t} /></td>
                    <td className="task-msg" title={t.message ?? ''}>{t.message}</td>
                  </tr>,
                  open && (
                    <tr key={`${t.id}-detail`} className="task-detail">
                      <td colSpan={5}>
                        <div className="muted small">
                          Task {t.id} · started {fmtDate(t.started, timeFmt)}
                          {t.finished && ` · finished ${fmtDate(t.finished, timeFmt)} · took ${fmtDuration(t.started, t.finished)}`}
                        </div>
                        {t.message ? <pre>{t.message}</pre> : <div className="muted">No message.</div>}
                      </td>
                    </tr>
                  ),
                ];
              })}
            </tbody>
          </table>
        )}
      </div>
    </section>
  );
}

function TaskStatus({ task }: { task: Task }) {
  if (task.status === 'running') {
    const pct = typeof task.progress === 'number' ? ` ${Math.round(task.progress * 100)}%` : '';
    return <span className="task-status"><Spinner />running{pct}</span>;
  }
  if (task.status === 'ok') return <span className="task-status ok">OK</span>;
  if (task.status === 'error') return <span className="task-status error">Error</span>;
  return <span className="task-status">{task.status}</span>;
}
