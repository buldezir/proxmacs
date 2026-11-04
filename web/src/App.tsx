import { useEffect, useRef, useState, type FormEvent } from 'react';
import { api, errorMessage, onUnauthorized } from './api';
import { Shell } from './components/Shell';
import { AppDataProvider, updateRestarting } from './store';

type Auth = 'checking' | 'out' | 'in';

export function App() {
  const [auth, setAuth] = useState<Auth>('checking');
  const [message, setMessage] = useState('');

  useEffect(() => {
    // An update's restart ends the session: reload first, for the new version's web UI.
    onUnauthorized(() => { if (updateRestarting()) location.reload(); else setAuth('out'); });
    api<{ authenticated: boolean }>('GET', '/api/session').then(
      (s) => setAuth(s.authenticated ? 'in' : 'out'),
      (e) => { setMessage(errorMessage(e)); setAuth('out'); },
    );
  }, []);

  if (auth === 'checking') return <div className="boot"><div className="spinner" /></div>;
  if (auth === 'out') return <Login message={message} onLoggedIn={() => { setMessage(''); setAuth('in'); }} />;

  const logout = async () => {
    try { await api('POST', '/api/logout', {}); } catch { /* the session is gone either way */ }
    setAuth('out');
  };
  return (
    <AppDataProvider>
      <Shell onLogout={logout} />
    </AppDataProvider>
  );
}

function Login({ message, onLoggedIn }: { message: string; onLoggedIn: () => void }) {
  const [password, setPassword] = useState('');
  const [error, setError] = useState(message);
  const [busy, setBusy] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setError('');
    try {
      await api('POST', '/api/login', { password });
      setPassword('');
      onLoggedIn();
    } catch (err) {
      setError(errorMessage(err));
      inputRef.current?.select();
    } finally {
      setBusy(false);
    }
  };

  return (
    <main className="login">
      <form className="login-card" autoComplete="on" onSubmit={submit}>
        <h1 className="brand-title"><span className="brand-mark" aria-hidden="true" />Proxmacs</h1>
        <label className="field">
          <span>Password</span>
          <input ref={inputRef} type="password" name="password" autoComplete="current-password" required autoFocus
            value={password} onChange={(e) => setPassword(e.target.value)} />
        </label>
        <div className="login-error" role="alert">{error}</div>
        <button type="submit" className="btn primary block" disabled={busy}>Log in</button>
      </form>
    </main>
  );
}
