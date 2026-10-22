import RFBImport from '@novnc/novnc/lib/rfb.js';

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
import { useCallback, useEffect, useRef, useState } from 'react';
import { api, enc } from '../../api';
import { Badge } from '../../components/ui';
import type { VM } from '../../types';

type Status = { text: string; kind: '' | 'ok' | 'warn' | 'err' };

/** Browser display via noVNC over tart's --vnc-experimental (Virtualization.framework VNC). */
export function DisplayView({ vm }: { vm: VM }) {
  const hostRef = useRef<HTMLDivElement>(null);
  const boxRef = useRef<HTMLDivElement>(null);
  const rfbRef = useRef<RFBInstance | null>(null);
  const [status, setStatus] = useState<Status>({ text: 'Not connected', kind: '' });
  const [closeReason, setCloseReason] = useState<string | null>(null);
  const [disconnected, setDisconnected] = useState(false);
  const name = vm.name;

  const teardown = () => {
    const rfb = rfbRef.current;
    if (!rfb) return;
    rfbRef.current = null;
    try { rfb.disconnect(); } catch { /* already gone */ }
  };

  const connect = useCallback(() => {
    const host = hostRef.current;
    if (!host) return;
    teardown();
    setDisconnected(false);
    setCloseReason(null);
    setStatus({ text: 'Connecting…', kind: 'warn' });
    host.innerHTML = '';
    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    const url = `${proto}//${location.host}/api/vms/${enc(name)}/vnc/ws`;
    void (async () => {
      let password = '';
      try {
        const info = await api<{ host: string; port: number; password: string }>('GET', `/api/vms/${enc(name)}/vnc`);
        password = info.password ?? '';
      } catch {
        /* WS will fail if unavailable */
      }
      let rfb: RFBInstance;
      try {
        rfb = new RFB(host, url, password ? { credentials: { password } } : undefined);
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
        setStatus({ text: 'Connected', kind: 'ok' });
      });
      rfb.addEventListener('disconnect', (e: CustomEvent) => {
        if (rfbRef.current !== rfb) return;
        rfbRef.current = null;
        const reason = (e as { detail?: { reason?: string } })?.detail?.reason;
        setCloseReason(reason || 'The display connection was closed.');
        setDisconnected(true);
        setStatus({ text: 'Disconnected', kind: 'err' });
      });
      rfb.addEventListener('credentialsrequired', () => {
        if (password) rfb.sendCredentials({ password });
        else {
          const pw = window.prompt('VNC password for this VM:');
          if (pw != null) rfb.sendCredentials({ password: pw });
          else setStatus({ text: 'Credentials required', kind: 'warn' });
        }
      });
      rfb.addEventListener('securityfailure', () => {
        setCloseReason('VNC security handshake failed.');
        setDisconnected(true);
        setStatus({ text: 'Security failure', kind: 'err' });
      });
    })();
  }, [name]);

  useEffect(() => {
    connect();
    return () => teardown();
  }, [connect]);

  const overlayText = vm.state !== 'running'
    ? `The VM is ${vm.state}. Start it, then reconnect.`
    : closeReason ?? 'The display connection was closed.';

  return (
    <>
      <div className="console-toolbar">
        <span className="muted">Display (VNC). Works for macOS and Linux guests started under Proxmacs.</span>
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
          </div>
        )}
      </div>
    </>
  );
}
