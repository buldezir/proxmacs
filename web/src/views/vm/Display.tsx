import RFBImport from '@novnc/novnc/lib/rfb.js';
import { useCallback, useEffect, useRef, useState, type FormEvent } from 'react';
import { api, enc } from '../../api';
import { Modal } from '../../components/Modal';
import { Badge, Field } from '../../components/ui';
import type { VM } from '../../types';

// @novnc/novnc ships CJS with exports.default; Vite can leave it double-wrapped as
// { default: { default: RFB } }. Unwrap so `new RFB(...)` always gets the class.
interface RFBInstance {
  scaleViewport: boolean;
  resizeSession: boolean;
  viewOnly: boolean;
  disconnect(): void;
  sendCredentials(credentials: { username?: string; password?: string }): void;
  addEventListener(type: string, listener: (event: CustomEvent) => void): void;
  removeEventListener(type: string, listener: (event: CustomEvent) => void): void;
}
type RFBConstructor = new (
  target: HTMLElement,
  urlOrChannel: string | WebSocket,
  options?: { shared?: boolean; credentials?: { username?: string; password?: string } },
) => RFBInstance;
const RFB = ((RFBImport as unknown as { default?: unknown })?.default ?? RFBImport) as unknown as RFBConstructor;

type Status = { text: string; kind: '' | 'ok' | 'warn' | 'err' };
type Credentials = { username: string; password: string };

const SECRET_HINT = 'Stored on this Mac in an owner-only file; never shown again.';

/** Browser display: the guest's Screen Sharing (RFB) session, proxied to noVNC over WebSocket. */
export function DisplayView({ vm }: { vm: VM }) {
  const hostRef = useRef<HTMLDivElement>(null);
  const boxRef = useRef<HTMLDivElement>(null);
  const rfbRef = useRef<RFBInstance | null>(null);
  // Bumped by every connect/teardown so an async continuation from an earlier attempt
  // cannot drive the UI of the current one.
  const genRef = useRef(0);
  // Prefetched pair: undefined = not fetched yet, null = none or rejected, else the pair.
  const savedRef = useRef<Credentials | null | undefined>(undefined);
  // Set once we have answered a sign-in prompt this connect, so a wrong pair cannot be
  // resent automatically and burn the guest's auth attempts in a loop.
  const answeredRef = useRef(false);
  // Pair the user asked us to keep, held until the guest actually accepts it. Persisting
  // earlier would write a typo into secrets.json and then auto-fail every later visit.
  const pendingSaveRef = useRef<Credentials | null>(null);
  // The terminal message. noVNC's `disconnect` event carries only { clean } — it drops
  // both the WebSocket close reason and whatever `securityfailure` said — so the reason
  // is recorded here and rendered once the connection is actually gone.
  const outcomeRef = useRef<string | null>(null);
  const [status, setStatus] = useState<Status>({ text: 'Not connected', kind: '' });
  const [closeReason, setCloseReason] = useState<string | null>(null);
  const [disconnected, setDisconnected] = useState(false);
  const [hasSaved, setHasSaved] = useState(false);
  const [prompt, setPrompt] = useState<{ types: string[]; username: string } | null>(null);
  const name = vm.name;

  const teardown = () => {
    genRef.current += 1;
    savedRef.current = undefined;
    answeredRef.current = false;
    pendingSaveRef.current = null;
    outcomeRef.current = null;
    const rfb = rfbRef.current;
    if (!rfb) return;
    rfbRef.current = null;
    try { rfb.disconnect(); } catch { /* already gone */ }
  };

  const connect = useCallback(() => {
    const host = hostRef.current;
    if (!host) return;
    teardown();
    const gen = genRef.current;
    setDisconnected(false);
    setCloseReason(null);
    outcomeRef.current = null;
    setPrompt(null);
    setStatus({ text: 'Connecting…', kind: 'warn' });
    host.innerHTML = '';
    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    const url = `${proto}//${location.host}/api/vms/${enc(name)}/vnc/ws`;
    // We own the socket rather than letting noVNC open it: a WebSocket close frame is the
    // only place our server's reason survives, and noVNC throws that field away.
    const socket = new WebSocket(url);
    socket.addEventListener('close', (e: CloseEvent) => {
      if (gen !== genRef.current) return;
      if (e.reason) outcomeRef.current = e.reason;
    });
    // Fetched here so `credentialsrequired` can answer without a second round trip.
    const prefetch = api<{ username: string | null; password: string | null }>('GET', `/api/vms/${enc(name)}/vnc/credentials`)
      .then((c) => (c.username && c.password ? { username: c.username, password: c.password } : null))
      .catch(() => null);

    let rfb: RFBInstance;
    try {
      rfb = new RFB(host, socket);
    } catch (e) {
      setCloseReason(e instanceof Error ? e.message : String(e));
      setDisconnected(true);
      setStatus({ text: 'Disconnected', kind: 'err' });
      return;
    }
    // scaleViewport maps the remote framebuffer into the container; resizeSession
    // must stay off or the guest changes resolution and pointer coords drift.
    rfb.scaleViewport = true;
    rfb.resizeSession = false;
    rfb.viewOnly = false;
    rfbRef.current = rfb;

    rfb.addEventListener('connect', () => {
      if (gen !== genRef.current || rfbRef.current !== rfb) return;
      setStatus({ text: 'Connected', kind: 'ok' });
      // The guest accepted the sign-in — only now is this pair worth keeping. Saving
      // earlier would write a typo into secrets.json and auto-fail every later visit.
      const keep = pendingSaveRef.current;
      pendingSaveRef.current = null;
      if (keep) {
        void api('PUT', `/api/vms/${enc(name)}/vnc/credentials`, keep)
          .then(() => {
            if (gen !== genRef.current) return;
            setHasSaved(true);
          })
          .catch(() => {
            // Kept for this session by `savedRef`; just not on disk, so do not offer Forget.
          });
      }
    });
    rfb.addEventListener('disconnect', () => {
      if (gen !== genRef.current || rfbRef.current !== rfb) return;
      rfbRef.current = null;
      // Only fills in a default: `securityfailure` or the socket close reason is more
      // specific and has already been recorded.
      setCloseReason(outcomeRef.current ?? 'The display connection was closed.');
      setDisconnected(true);
      setStatus({ text: 'Disconnected', kind: 'err' });
    });
    rfb.addEventListener('securityfailure', () => {
      if (gen !== genRef.current || rfbRef.current !== rfb) return;
      // A rejected sign-in is not worth retrying silently, and a rejected pair must
      // never reach secrets.json.
      savedRef.current = null;
      pendingSaveRef.current = null;
      setPrompt(null);
      // Wins over the WebSocket reason: noVNC always follows this with a `disconnect`
      // whose detail carries nothing, and the rejection is the actionable part.
      outcomeRef.current = 'Sign-in was rejected by the guest.';
      setCloseReason(outcomeRef.current);
      setDisconnected(true);
      setStatus({ text: 'Sign-in rejected', kind: 'err' });
    });
    rfb.addEventListener('credentialsrequired', (e: CustomEvent) => {
      void (async () => {
        // Apple ARD auth asks for ["username","password"]; RFB type 2 asks for ["password"].
        const types = (e as { detail?: { types?: string[] } })?.detail?.types ?? ['password'];
        if (savedRef.current === undefined) {
          const saved = await prefetch;
          if (gen !== genRef.current || rfbRef.current !== rfb) return;
          savedRef.current = saved;
          setHasSaved(!!saved);
        }
        const saved = savedRef.current;
        if (gen !== genRef.current || rfbRef.current !== rfb) return;
        const wantsUser = types.includes('username');
        const wantsPassword = types.includes('password');
        if (saved && !answeredRef.current && (!wantsUser || saved.username) && (!wantsPassword || saved.password)) {
          answeredRef.current = true;
          // Always both keys: ARD re-asks forever if it only gets a password.
          rfb.sendCredentials({ username: saved.username, password: saved.password });
          return;
        }
        setPrompt({ types, username: saved?.username ?? '' });
      })();
    });
  }, [name]);

  useEffect(() => {
    connect();
    return () => teardown();
  }, [connect]);

  const answer = async (credentials: Credentials, remember: boolean) => {
    const rfb = rfbRef.current;
    setPrompt(null);
    if (!rfb) return;
    // Held until `connect`: only a pair the guest actually accepted gets persisted.
    pendingSaveRef.current = remember ? credentials : null;
    savedRef.current = credentials;
    answeredRef.current = true;
    rfb.sendCredentials({ username: credentials.username, password: credentials.password });
  };

  const forget = async () => {
    try {
      await api('DELETE', `/api/vms/${enc(name)}/vnc/credentials`);
      savedRef.current = null;
      setHasSaved(false);
    } catch (e) {
      setCloseReason(e instanceof Error ? e.message : String(e));
    }
  };

  const overlayText = vm.state !== 'running'
    ? `The VM is ${vm.state}. Start it, then reconnect.`
    : closeReason ?? 'The display connection was closed.';

  return (
    <>
      <div className="console-toolbar">
        <span className="muted">Display. Streams the guest's screen via its Screen Sharing service.</span>
        <div className="spacer" />
        <Badge kind={status.kind}>{status.text}</Badge>
        <button type="button" className="btn small" onClick={connect}>Reconnect</button>
      </div>
      <div ref={boxRef} className="display-box">
        <div ref={hostRef} className="display-host" />
        {disconnected && (
          <div className="term-overlay">
            <strong>Disconnected</strong>
            <div className="small">{overlayText}</div>
            <button type="button" className="btn primary" onClick={connect}>Reconnect</button>
            {hasSaved && (
              <button type="button" className="btn" onClick={forget}>Forget saved credentials</button>
            )}
          </div>
        )}
      </div>
      {prompt && (
        <CredentialsPrompt
          vm={name}
          types={prompt.types}
          username={prompt.username}
          onCancel={() => {
            setPrompt(null);
            setStatus({ text: 'Credentials required', kind: 'warn' });
          }}
          onConnect={answer}
        />
      )}
    </>
  );
}

/** Asks for the guest macOS account Screen Sharing wants, and optionally keeps it here. */
function CredentialsPrompt({ vm, types, username, onCancel, onConnect }: {
  vm: string;
  types: string[];
  username: string;
  onCancel: () => void;
  onConnect: (credentials: Credentials, remember: boolean) => Promise<void>;
}) {
  const [user, setUser] = useState(username);
  const [password, setPassword] = useState('');
  const [remember, setRemember] = useState(true);
  const [busy, setBusy] = useState(false);
  const wantsUser = types.includes('username');
  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true);
    try {
      await onConnect({ username: wantsUser ? user : '', password }, remember);
    } finally {
      setBusy(false);
    }
  };
  return (
    <Modal title={`Sign in to ${vm}`} onClose={onCancel}>
      <form onSubmit={submit}>
        <div className="modal-body">
          <p className="muted">Screen Sharing asks for a macOS account in the guest before it shows the desktop.</p>
          {wantsUser && (
            <Field label="User name">
              <input type="text" required autoComplete="username" spellCheck={false} autoCapitalize="off"
                value={user} onChange={(e) => setUser(e.target.value)} />
            </Field>
          )}
          <Field label="Password">
            <input type="password" required autoComplete="current-password"
              value={password} onChange={(e) => setPassword(e.target.value)} />
          </Field>
          <label className="check">
            <input type="checkbox" checked={remember} onChange={(e) => setRemember(e.target.checked)} />
            Remember on this Mac
          </label>
          {remember && <p className="muted small">{SECRET_HINT}</p>}
        </div>
        <div className="modal-footer">
          <button type="button" className="btn" onClick={onCancel} disabled={busy}>Cancel</button>
          <button type="submit" className="btn primary"
            disabled={busy || !password || (wantsUser && !user)}>Connect</button>
        </div>
      </form>
    </Modal>
  );
}
