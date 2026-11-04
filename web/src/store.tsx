import { createContext, useCallback, useContext, useMemo, useRef, useState, type ReactNode } from 'react';
import { api, AuthError } from './api';
import { useToast } from './components/Toasts';
import { NARROW, useLocalStorage, usePoller } from './hooks';
import type { BackupJob, Host, HostStats, NetInterface, StorageStatus, Target, Task, UpdateStatus, VM } from './types';

/**
 * The version Proxmacs is updating from, while an update installs: it restarts, which ends every login session,
 * and the page reloads for the new version's web UI, then says what it updated to.
 */
const UPDATING_KEY = 'proxmacs.updatingFrom';

function readUpdating(): string | null {
  try { return sessionStorage.getItem(UPDATING_KEY); } catch { return null; }
}

function writeUpdating(version: string | null) {
  try {
    if (version) sessionStorage.setItem(UPDATING_KEY, version); else sessionStorage.removeItem(UPDATING_KEY);
  } catch { /* storage unavailable */ }
}

/**
 * The version this page's bundle came with: a newer one serves a newer web UI, so the page reloads. Kept outside
 * the provider, which a new login mounts again.
 */
let pageVersion: string | null = null;

/** True while an update this page saw start may have restarted the server. */
export const updateRestarting = () => readUpdating() != null;

/** Samples kept for the host memory chart (3 s apart → 6 minutes). */
const HISTORY = 120;

export interface StatsSample {
  t: number;
  used: number;
  total: number;
  vms: number;
  cpu: number | null;
}

interface AppData {
  loaded: boolean;
  online: boolean;
  host: Host | null;
  stats: HostStats | null;
  history: StatsSample[];
  vms: VM[];
  tasks: Task[];
  targets: Target[];
  jobs: BackupJob[];
  interfaces: NetInterface[];
  storage: StorageStatus | null;
  update: UpdateStatus | null;
  /** The server went away during an update it was installing, and should be back as the new version. */
  restarting: boolean;
  /** VM name → number of its tasks that finished since load; views reload their data when it changes. */
  taskEpoch: Record<string, number>;
  tasksOpen: boolean;
  setTasksOpen(open: boolean): void;
  vm(name: string): VM | null;
  target(id: string): Target | null;
  updateVM(vm: VM): void;
  reloadTargets(): Promise<void>;
  reloadJobs(): Promise<void>;
  reloadStorage(): Promise<void>;
  reloadInterfaces(): Promise<NetInterface[]>;
  reloadUpdate(): Promise<void>;
  /** Starts a backend task (202 {task}); the user is notified when it finishes. */
  startTask(method: string, path: string, body: unknown, label: string): Promise<void>;
  pollNow(): void;
}

const AppDataContext = createContext<AppData | null>(null);

export function useApp(): AppData {
  const value = useContext(AppDataContext);
  if (!value) throw new Error('useApp outside AppDataProvider');
  return value;
}

export function AppDataProvider({ children }: { children: ReactNode }) {
  const { toast } = useToast();
  const [loaded, setLoaded] = useState(false);
  const [online, setOnline] = useState(true);
  const [host, setHost] = useState<Host | null>(null);
  const [stats, setStats] = useState<HostStats | null>(null);
  const [history, setHistory] = useState<StatsSample[]>([]);
  const [vms, setVMs] = useState<VM[]>([]);
  const [tasks, setTasks] = useState<Task[]>([]);
  const [targets, setTargets] = useState<Target[]>([]);
  const [jobs, setJobs] = useState<BackupJob[]>([]);
  const [interfaces, setInterfaces] = useState<NetInterface[]>([]);
  const [storage, setStorage] = useState<StorageStatus | null>(null);
  const [update, setUpdate] = useState<UpdateStatus | null>(null);
  const [taskEpoch, setTaskEpoch] = useState<Record<string, number>>({});
  const [tasksOpen, setTasksOpen] = useLocalStorage('proxmacs.tasksOpen', !matchMedia(NARROW).matches);

  const taskStatus = useRef(new Map<string, Task['status']>());
  const seeded = useRef(false);
  const myTasks = useRef(new Map<string, string>());
  const pollRef = useRef<() => void>(() => {});
  const storageRef = useRef<() => void>(() => {});
  const jobsRef = useRef<() => void>(() => {});

  const handleTasks = useCallback((list: Task[]) => {
    const finished: Task[] = [];
    for (const t of list) {
      const prev = taskStatus.current.get(t.id);
      if (seeded.current && t.status !== 'running' && (prev === 'running' || prev === undefined)) finished.push(t);
      taskStatus.current.set(t.id, t.status);
    }
    seeded.current = true;
    for (const t of finished) {
      const label = myTasks.current.get(t.id);
      if (label === undefined) continue;
      myTasks.current.delete(t.id);
      const detail = t.message ? ` — ${t.message}` : '';
      toast(t.status === 'ok' ? `${t.title || label}: done${detail}` : `${t.title || label}: failed${detail}`, t.status === 'ok' ? 'ok' : 'error');
    }
    if (finished.length) {
      setTaskEpoch((epochs) => {
        const next = { ...epochs };
        for (const t of finished) if (t.vm) next[t.vm] = (next[t.vm] ?? 0) + 1;
        return next;
      });
      if (finished.some((t) => !t.vm)) { storageRef.current(); jobsRef.current(); }
      // The VM's state likely changed with the task: refresh again shortly.
      window.setTimeout(() => pollRef.current(), 300);
    }
    setTasks(list);
  }, [toast]);

  const refreshFast = useCallback(async () => {
    try {
      const [vmList, taskList] = await Promise.all([api<VM[]>('GET', '/api/vms'), api<Task[]>('GET', '/api/tasks')]);
      setOnline(true);
      setVMs([...vmList].sort((a, b) => a.name.localeCompare(b.name)));
      handleTasks(taskList);
      setLoaded(true);
    } catch (e) {
      if (!(e instanceof AuthError)) setOnline(false);
    }
  }, [handleTasks]);

  const refreshStats = useCallback(async () => {
    try {
      const s = await api<HostStats>('GET', '/api/host/stats');
      setStats(s);
      if (s.memory) {
        const sample = { t: Date.parse(s.time) || Date.now(), used: s.memory.used, total: s.memory.total, vms: s.vmMemoryBytes, cpu: s.cpu };
        setHistory((h) => [...h, sample].slice(-HISTORY));
      }
    } catch { /* keep the last sample */ }
  }, []);

  const reloadTargets = useCallback(async () => {
    try {
      setTargets(await api<Target[]>('GET', '/api/targets'));
    } catch (e) {
      if (!(e instanceof AuthError)) console.warn('targets:', e);
    }
  }, []);

  const reloadJobs = useCallback(async () => {
    try {
      setJobs(await api<BackupJob[]>('GET', '/api/jobs'));
    } catch (e) {
      if (!(e instanceof AuthError)) console.warn('jobs:', e);
    }
  }, []);

  const reloadStorage = useCallback(async () => {
    try {
      setStorage(await api<StorageStatus>('GET', '/api/host/storage'));
    } catch (e) {
      if (!(e instanceof AuthError)) console.warn('storage:', e);
    }
  }, []);

  const reloadUpdate = useCallback(async () => {
    try {
      const u = await api<UpdateStatus>('GET', '/api/update');
      const from = readUpdating();
      pageVersion ??= u.version;
      if (u.version !== pageVersion) {
        if (!from) writeUpdating(pageVersion);
        location.reload();
        return;
      }
      if (u.install) {
        if (!from) writeUpdating(u.version);
      } else if (from) {
        writeUpdating(null);
        if (from !== u.version) toast(`Proxmacs updated to ${u.version}`, 'ok');
      }
      setUpdate(u);
    } catch (e) {
      if (!(e instanceof AuthError)) console.warn('update:', e);
    }
  }, [toast]);

  storageRef.current = () => void reloadStorage();
  jobsRef.current = () => void reloadJobs();

  const refreshSlow = useCallback(async () => {
    await Promise.all([
      api<Host>('GET', '/api/host').then(setHost, () => {}),
      reloadTargets(),
      reloadStorage(),
      reloadJobs(),
    ]);
  }, [reloadTargets, reloadStorage, reloadJobs]);

  const reloadInterfaces = useCallback(async () => {
    try {
      const list = await api<NetInterface[]>('GET', '/api/interfaces');
      setInterfaces(list);
      return list;
    } catch {
      return [];
    }
  }, []);

  const pollNow = usePoller(refreshFast, 3000);
  pollRef.current = pollNow;
  usePoller(refreshStats, 3000);
  usePoller(refreshSlow, 15000);
  usePoller(async () => { await reloadInterfaces(); }, 60000);
  const restarting = !online && !!update?.install;
  usePoller(reloadUpdate, update?.checking || update?.install ? 1500 : 60000);

  const startTask = useCallback(async (method: string, path: string, body: unknown, label: string) => {
    const r = await api<{ task?: string; message?: string }>(method, path, body);
    if (r?.task != null) myTasks.current.set(String(r.task), label);
    toast(r?.message ?? `${label}: started`, 'info');
    pollNow();
  }, [pollNow, toast]);

  const updateVM = useCallback((vm: VM) => {
    setVMs((list) => {
      const i = list.findIndex((v) => v.name === vm.name);
      if (i < 0) return [...list, vm].sort((a, b) => a.name.localeCompare(b.name));
      const next = [...list];
      next[i] = vm;
      return next;
    });
  }, []);

  const value = useMemo<AppData>(() => ({
    loaded, online, host, stats, history, vms, tasks, targets, jobs, interfaces, storage, update, restarting, taskEpoch, tasksOpen,
    setTasksOpen,
    vm: (name) => vms.find((v) => v.name === name) ?? null,
    target: (id) => targets.find((t) => String(t.id) === String(id)) ?? null,
    updateVM, reloadTargets, reloadJobs, reloadStorage, reloadInterfaces, reloadUpdate, startTask, pollNow,
  }), [loaded, online, host, stats, history, vms, tasks, targets, jobs, interfaces, storage, update, restarting, taskEpoch, tasksOpen,
    setTasksOpen, updateVM, reloadTargets, reloadJobs, reloadStorage, reloadInterfaces, reloadUpdate, startTask, pollNow]);

  return <AppDataContext.Provider value={value}>{children}</AppDataContext.Provider>;
}
