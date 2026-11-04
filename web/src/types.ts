// Shapes returned by the Proxmacs JSON API (Sources/Proxmacs/Web/WebAPI.swift).

/** 'offline': VM storage is on a drive that is not connected. */
export type VMState = 'running' | 'stopped' | 'suspended' | 'missing' | 'offline' | (string & {});

export interface NetworkConfig {
  mode: 'nat' | 'bridged';
  interface: string | null;
}

export interface GuestIPv4 {
  dhcp: boolean;
  address: string | null;
  gateway: string | null;
  dns: string[];
}

export interface CloudInit {
  user: string;
  /** 'unknown' for VMs created before Proxmacs tracked passwords. */
  password: 'set' | 'none' | 'unknown';
  sshKeys: string[];
  legacy: boolean;
  network: GuestIPv4;
}

/** Local backup retention (0 = option off; all 0 keeps everything). */
export interface BackupPolicy {
  keep: number;
  keepDaily: number;
  keepWeekly: number;
  keepMonthly: number;
  keepYearly: number;
}

export interface ExtraDisk {
  /** diskN.img in the VM's Tart directory. */
  file: string;
  sizeGB: number;
  usedBytes: number;
  backup: boolean;
}

export interface SharedFolder {
  name: string;
  path: string;
  readOnly: boolean;
}

/** One sample of a VM's resource use; rates are bytes per second. */
export interface VMSample {
  /** Milliseconds since the epoch. */
  t: number;
  /** Share of the VM's vCPUs in use, 0–1. */
  cpu: number;
  /** Host memory of the VM process. */
  memory: number;
  guestUsed: number | null;
  guestTotal: number | null;
  diskRead: number;
  diskWrite: number;
  netIn: number | null;
  netOut: number | null;
}

export interface VMStats extends Partial<VMSample> {
  /** Seconds since the VM process started. */
  uptime?: number;
}

export type MetricsRange = 'hour' | 'day' | 'week';

export interface Metrics {
  range: MetricsRange;
  step: number;
  samples: VMSample[];
}

export interface GuestInfo {
  os: string | null;
  kernel: string | null;
  hostname: string | null;
  uptime: number | null;
  updated: string;
  interfaces: { name: string; mac: string | null; addresses: string[] }[];
  filesystems: { device: string; type: string; mount: string; sizeBytes: number; usedBytes: number }[];
}

export interface OffsitePolicy {
  targets: string[];
  auto: boolean;
}

export interface VM {
  name: string;
  state: VMState;
  ip: string | null;
  network: NetworkConfig;
  cpus: number | null;
  memoryMB: number | null;
  diskGB: number | null;
  autostart: boolean;
  activity: string | null;
  backup: BackupPolicy;
  offsite: OffsitePolicy;
  /** From Tart's config; null while VM storage is offline. macOS guests have no cloud-init. */
  os: 'linux' | 'darwin' | null;
  /** For `ssh user@ip`: the cloud-init user, or a macOS guest's saved Screen Sharing account (else null). */
  sshUser: string | null;
  cloudInit: CloudInit;
  seedPending: boolean;
  hasSeed: boolean;
  /** Image the VM was created from; null for VMs created by older versions. */
  image: string | null;
  /** Templates can't be started, only cloned. */
  template: boolean;
  tags: string[];
  notes: string;
  /** Start-on-login order (lower first); null = after the ordered VMs. */
  startOrder: number | null;
  /** Seconds to wait after starting this VM at login. */
  startDelay: number;
  nested: boolean;
  disks: ExtraDisk[];
  shares: SharedFolder[];
  /** Latest resource sample while running. */
  stats: VMStats | null;
}

export interface Task {
  id: string;
  vm: string | null;
  title: string;
  status: 'running' | 'ok' | 'error';
  message: string | null;
  progress: number | null;
  started: string;
  finished: string | null;
}

export interface Host {
  hostname: string;
  tartVersion: string | null;
  cpus: number;
  memoryBytes: number;
  osVersion: string;
  diskFreeBytes: number;
  diskTotalBytes: number;
  /** Apple M3 or later on macOS 15+. */
  nestedVirtualization?: boolean;
  web?: { bind: string; port: number; urls: WebURL[] };
}

/** GET /api/update: Proxmacs's own updates, which the menubar app installs with Sparkle. */
export interface UpdateStatus {
  version: string;
  /** False for a local build or `cli serve`; `reason` says why. */
  supported: boolean;
  reason: string | null;
  checking: boolean;
  lastChecked: string | null;
  /** The newest release, when it is newer than this one. */
  available: { version: string; date: string | null; notes: string | null; url: string | null } | null;
  /** An install the web UI started: Proxmacs quits and opens again when it finishes. */
  install: { phase: 'checking' | 'downloading' | 'extracting' | 'installing'; progress: number | null } | null;
  error: string | null;
}

export interface WebURL {
  url: string;
  address: string;
  device: string;
  name: string | null;
}

export interface Volume {
  path: string;
  name: string;
  fileSystem: string;
  internal: boolean;
  ejectable: boolean;
  freeBytes: number;
  totalBytes: number;
}

export interface StorageLocation {
  path: string;
  default: boolean;
  /** False while a custom location's drive is disconnected. */
  available: boolean;
  volume: Volume | null;
}

export type StorageKind = 'vms' | 'backups';

export interface StorageStatus {
  vms: StorageLocation;
  backups: StorageLocation;
  /** Which storage is being moved right now. */
  busy: StorageKind | null;
  /** VM storage is fixed by TART_HOME in the server's environment. */
  vmsFixed: boolean;
  /** Mounted external volumes. */
  volumes: Volume[];
}

export interface HostMemory {
  total: number;
  used: number;
  app: number;
  wired: number;
  compressed: number;
  cached: number;
  free: number;
  swapUsed: number;
  swapTotal: number;
  pressure: 'normal' | 'warning' | 'critical';
}

export interface HostStats {
  time: string;
  /** Share of host CPU in use, 0–1. */
  cpu: number | null;
  loadAverage: number[];
  runningVMs: number;
  vmMemoryBytes: number;
  memory?: HostMemory;
}

export interface Target {
  id: string;
  name: string;
  kind: 'smb' | 'pbs';
  location: string;
  keep: number;
  smb: { url: string } | null;
  pbs: {
    host: string;
    port: number;
    datastore: string;
    namespace: string | null;
    authId: string;
    fingerprint: string | null;
  } | null;
}

export interface NetInterface {
  device: string;
  name: string;
  default: boolean;
}

export interface Image {
  /** Catalog id, or the file name of an imported image. */
  id: string;
  name: string;
  /** null for imported images. */
  distro: string | null;
  /** Suggested cloud-init user. */
  user: string | null;
  /** Where the catalog image is downloaded from. */
  url: string | null;
  imported: boolean;
  cached: boolean;
  /** Virtual disk size: the smallest disk a VM from this image can have. */
  sizeBytes: number | null;
  /** Space the cached (sparse) image takes. */
  diskBytes: number | null;
  downloading: { message: string; progress: number | null } | null;
}

export interface Backup {
  id: string;
  date: string;
  consistent: boolean;
  source: string | null;
}

export interface Snapshot {
  vm: string;
  time: string;
  id: string;
}

export type NotifyWhen = 'never' | 'failure' | 'always';

export interface BackupJob {
  id: string;
  enabled: boolean;
  comment: string;
  title: string;
  /** ISO weekdays, 1 = Monday; empty = every day. */
  days: number[];
  hour: number;
  minute: number;
  selection: 'all' | 'include' | 'exclude';
  vms: string[];
  notify: NotifyWhen;
  /** Offsite target backed up to directly; null = local backups. */
  target: string | null;
  targetName: string | null;
  schedule: string;
  running: boolean;
  nextRun: string | null;
  lastRun: string | null;
  lastOK: boolean | null;
  lastMessage: string | null;
}

/** A webhook notifications are posted to; its URL is a secret and never sent back. */
export interface NotificationTarget {
  id: string;
  name: string;
  enabled: boolean;
  format: 'json' | 'discord' | 'slack' | 'ntfy';
  /** Host of the webhook URL. */
  host: string | null;
  location: string;
}
