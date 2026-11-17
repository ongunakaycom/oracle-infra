import { useState, useEffect, useCallback } from 'react';
import './index.css';

function App() {
  const [token, setToken] = useState(() => localStorage.getItem('token') || '');
  const [edgeOnline, setEdgeOnline] = useState(false);
  const [metrics, setMetrics] = useState({ cpu_percent: '—', memory_used: '—', uptime: '—', latency: 0 });
  const [records, setRecords] = useState([]);
  const [search, setSearch] = useState('');
  const [showLoginModal, setShowLoginModal] = useState(false);
  const [loginError, setLoginError] = useState('');
  const [authenticating, setAuthenticating] = useState(false);
  const [loadingRecords, setLoadingRecords] = useState(false);
  const [recordError, setRecordError] = useState('');

  // New Audit Record Form State
  const [newService, setNewService] = useState('caddy-proxy');
  const [newSeverity, setNewSeverity] = useState('INFO');
  const [newMsg, setNewMsg] = useState('');

  const isLoggedIn = !!token;

  const logout = useCallback(() => {
    localStorage.removeItem('token');
    setToken('');
    setRecords([]);
    setMetrics({ cpu_percent: '—', memory_used: '—', uptime: '—', latency: 0 });
  }, []);

  // Public availability probe: reports only whether the edge is reachable.
  useEffect(() => {
    let active = true;
    const check = async () => {
      try {
        const res = await fetch('/api/health', { cache: 'no-store' });
        if (active) setEdgeOnline(res.ok);
      } catch (err) {
        if (active) setEdgeOnline(false);
      }
    };
    check();
    const interval = setInterval(check, 15000);
    return () => {
      active = false;
      clearInterval(interval);
    };
  }, []);

  const fetchRecords = useCallback(async () => {
    if (!token) return;
    setLoadingRecords(true);
    try {
      const res = await fetch('/api/records', {
        headers: { 'Authorization': `Bearer ${token}` },
        cache: 'no-store',
      });
      if (res.status === 401 || res.status === 403) {
        logout();
        return;
      }
      if (res.ok) {
        const data = await res.json();
        setRecords(Array.isArray(data) ? data : []);
      }
    } catch (err) {
      console.error('Failed to fetch audit records', err);
    } finally {
      setLoadingRecords(false);
    }
  }, [token, logout]);

  // Authenticated telemetry polling. Metrics are never fetched before sign-in.
  useEffect(() => {
    if (!token) return;
    let active = true;

    const fetchMetrics = async () => {
      const start = performance.now();
      try {
        const res = await fetch('/api/metrics', {
          headers: { 'Authorization': `Bearer ${token}` },
          cache: 'no-store',
        });
        if (res.status === 401 || res.status === 403) {
          logout();
          return;
        }
        if (!res.ok) return;
        const data = await res.json();
        if (active) {
          setMetrics({ ...data, latency: Math.round(performance.now() - start) });
        }
      } catch (err) {
        // Keep the previous reading; the next poll will retry.
      }
    };

    fetchMetrics();
    const interval = setInterval(fetchMetrics, 5000);
    return () => {
      active = false;
      clearInterval(interval);
    };
  }, [token, logout]);

  useEffect(() => {
    if (token) fetchRecords();
  }, [token, fetchRecords]);

  const handleLogin = async (e) => {
    e.preventDefault();
    setLoginError('');
    setAuthenticating(true);
    const username = e.target.username.value;
    const password = e.target.password.value;

    try {
      const res = await fetch('/api/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username, password })
      });
      if (res.ok) {
        const data = await res.json();
        localStorage.setItem('token', data.token);
        setToken(data.token);
        setShowLoginModal(false);
        e.target.reset();
      } else if (res.status === 401) {
        setLoginError('Invalid username or password.');
      } else {
        setLoginError('Authentication is temporarily unavailable.');
      }
    } catch (err) {
      setLoginError('Authentication service unreachable.');
    } finally {
      setAuthenticating(false);
    }
  };

  const handleAddRecord = async (e) => {
    e.preventDefault();
    setRecordError('');
    if (!newMsg.trim()) return;

    try {
      const res = await fetch('/api/records', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${token}`
        },
        body: JSON.stringify({ service: newService, severity: newSeverity, message: newMsg })
      });
      if (res.status === 401 || res.status === 403) {
        logout();
        return;
      }
      if (res.ok) {
        setNewMsg('');
        fetchRecords();
      } else {
        setRecordError('The audit entry could not be stored.');
      }
    } catch (err) {
      setRecordError('The audit entry could not be stored.');
    }
  };

  const filteredRecords = records.filter(r =>
    r.service.toLowerCase().includes(search.toLowerCase()) ||
    r.message.toLowerCase().includes(search.toLowerCase())
  );

  return (
    <div className="secops-container">
      {/* Topbar */}
      <header className="secops-header">
        <div className="secops-title">
          <h1>ORACLE-INFRA // DevSecOps Platform</h1>
          <p>oracle-infra.duckdns.org</p>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: '16px' }}>
          <span className={`secops-badge ${edgeOnline ? 'healthy' : 'standby'}`}>
            {edgeOnline ? 'EDGE ONLINE' : 'EDGE OFFLINE'}
          </span>
          {!isLoggedIn ? (
            <button onClick={() => { setLoginError(''); setShowLoginModal(true); }} className="secops-btn-small">
              Operator Sign In
            </button>
          ) : (
            <button onClick={logout} style={{ background: 'transparent', border: 'none', color: '#ef4444', cursor: 'pointer', fontSize: '0.85rem', fontWeight: 600 }}>
              Sign Out
            </button>
          )}
        </div>
      </header>

      {/* Public View vs Authenticated Console */}
      {!isLoggedIn ? (
        <div className="space-y-8">
          {/* Hero Section */}
          <div className="secops-card" style={{ padding: '32px' }}>
            <h2 style={{ fontSize: '1.5rem', color: '#06b6d4', marginTop: 0 }}>Enterprise Infrastructure & Automated CI/CD Pipeline</h2>
            <p style={{ color: '#94a3b8', lineHeight: '1.6', fontSize: '1rem' }}>
              Production-oriented Infrastructure-as-Code (IaC) and automated CI/CD pipeline hosted on Oracle Cloud Infrastructure (OCI). 
              Provisioned via Terraform, validated with Checkov security scanner, and secured behind an automated TLS reverse proxy with zero information disclosure.
            </p>
          </div>

          {/* Architecture Flow */}
          <div className="secops-card">
            <h3 style={{ fontSize: '1.1rem', color: '#f1f5f9', marginTop: 0, marginBottom: '16px' }}>CI/CD & Deployment Flow</h3>
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(200px, 1fr))', gap: '12px', textAlign: 'center' }}>
              <div style={{ background: '#0f1522', padding: '16px', borderRadius: '8px', border: '1px solid #232f46' }}>
                <span style={{ color: '#06b6d4', fontWeight: 'bold' }}>1. Push</span>
                <p style={{ fontSize: '0.85rem', color: '#94a3b8', margin: '8px 0 0 0' }}>Developer git push to main branch</p>
              </div>
              <div style={{ background: '#0f1522', padding: '16px', borderRadius: '8px', border: '1px solid #232f46' }}>
                <span style={{ color: '#3b82f6', fontWeight: 'bold' }}>2. Validate & Scan</span>
                <p style={{ fontSize: '0.85rem', color: '#94a3b8', margin: '8px 0 0 0' }}>Terraform validate & Checkov security scan</p>
              </div>
              <div style={{ background: '#0f1522', padding: '16px', borderRadius: '8px', border: '1px solid #232f46' }}>
                <span style={{ color: '#8b5cf6', fontWeight: 'bold' }}>3. Build</span>
                <p style={{ fontSize: '0.85rem', color: '#94a3b8', margin: '8px 0 0 0' }}>Vite React bundle & Go static binary compile</p>
              </div>
              <div style={{ background: '#0f1522', padding: '16px', borderRadius: '8px', border: '1px solid #232f46' }}>
                <span style={{ color: '#10b981', fontWeight: 'bold' }}>4. Deploy</span>
                <p style={{ fontSize: '0.85rem', color: '#94a3b8', margin: '8px 0 0 0' }}>Secure SSH/rsync to OCI VM & systemd restart</p>
              </div>
            </div>
          </div>

          {/* Infrastructure Matrix Table */}
          <div className="secops-table-container">
            <table>
              <thead>
                <tr>
                  <th>Layer</th>
                  <th>Technology & Implementation</th>
                  <th>Security Control</th>
                </tr>
              </thead>
              <tbody>
                <tr>
                  <td style={{ color: '#06b6d4', fontWeight: 500 }}>Infrastructure as Code</td>
                  <td style={{ color: '#cbd5e1' }}>Terraform &gt;= 1.10.0, OCI Provider</td>
                  <td style={{ color: '#94a3b8' }}>S3 remote backend (`use_lockfile = true`), `prevent_destroy` guards</td>
                </tr>
                <tr>
                  <td style={{ color: '#06b6d4', fontWeight: 500 }}>Compute & Network</td>
                  <td style={{ color: '#cbd5e1' }}>OCI Always Free (`VM.Standard.E2.1.Micro`), VCN NSG</td>
                  <td style={{ color: '#94a3b8' }}>Public SSH disabled (Port 22 via OCI Bastion)</td>
                </tr>
                <tr>
                  <td style={{ color: '#06b6d4', fontWeight: 500 }}>Edge & Transport</td>
                  <td style={{ color: '#cbd5e1' }}>Caddy Reverse Proxy + DuckDNS</td>
                  <td style={{ color: '#94a3b8' }}>Automatic HTTPS/TLS, HSTS, `nosniff`, `X-Frame-Options: DENY`</td>
                </tr>
                <tr>
                  <td style={{ color: '#06b6d4', fontWeight: 500 }}>Application Stack</td>
                  <td style={{ color: '#cbd5e1' }}>React 19 + Vite & Go + SQLite</td>
                  <td style={{ color: '#94a3b8' }}>Stateless JWT auth, parameterized SQLite queries, `128MB` RAM cap</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      ) : (
        <div className="space-y-8">
          {/* Telemetry KPI Cards */}
          <section className="secops-grid">
            {[
              { label: 'CPU Load', value: metrics.cpu_percent },
              { label: 'Memory Footprint', value: metrics.memory_used },
              { label: 'System Uptime', value: metrics.uptime },
              { label: 'Edge Latency', value: `${metrics.latency}ms` },
            ].map((kpi, i) => (
              <div key={i} className="secops-card">
                <label>{kpi.label}</label>
                <p className="value">{kpi.value}</p>
              </div>
            ))}
          </section>

          {/* Add Audit Record Form */}
          <div className="secops-card" style={{ marginBottom: '24px' }}>
            <h3 style={{ fontSize: '1.1rem', color: '#f1f5f9', marginTop: 0, marginBottom: '16px' }}>Add Audit Event</h3>
            <form onSubmit={handleAddRecord} style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 2fr auto', gap: '12px', alignItems: 'center' }}>
              <select value={newService} onChange={(e) => setNewService(e.target.value)} className="secops-input" style={{ margin: 0 }}>
                <option value="caddy-proxy">caddy-proxy</option>
                <option value="auth-gateway">auth-gateway</option>
                <option value="oci-firewall">oci-firewall</option>
                <option value="database">database</option>
              </select>
              <select value={newSeverity} onChange={(e) => setNewSeverity(e.target.value)} className="secops-input" style={{ margin: 0 }}>
                <option value="INFO">INFO</option>
                <option value="LOW">LOW</option>
                <option value="MEDIUM">MEDIUM</option>
                <option value="HIGH">HIGH</option>
              </select>
              <input 
                type="text" 
                placeholder="Audit message description..." 
                value={newMsg} 
                onChange={(e) => setNewMsg(e.target.value)} 
                className="secops-input" 
                style={{ margin: 0 }} 
                required 
              />
              <button type="submit" className="secops-btn" style={{ padding: '12px 24px', width: 'auto' }}>Submit</button>
            </form>
            {recordError && <p style={{ color: '#ef4444', fontSize: '0.85rem', margin: '12px 0 0 0' }}>{recordError}</p>}
          </div>

          {/* Audit Logs Table */}
          <div>
            <input 
              type="text" 
              placeholder="Search audit logs by service or message..." 
              className="secops-search"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
            />
            
            <div className="secops-table-container">
              <table>
                <thead>
                  <tr>
                    <th>Service</th>
                    <th>Severity</th>
                    <th>Event Message</th>
                    <th>Timestamp</th>
                  </tr>
                </thead>
                <tbody>
                  {filteredRecords.length === 0 ? (
                    <tr>
                      <td colSpan="4" style={{ textAlign: 'center', color: '#64748b', padding: '32px' }}>
                        {loadingRecords ? 'Loading audit events...' : 'No audit events recorded yet.'}
                      </td>
                    </tr>
                  ) : (
                    filteredRecords.map((item) => (
                      <tr key={item.id}>
                        <td style={{ color: '#06b6d4', fontWeight: 500 }}>{item.service}</td>
                        <td>
                          <span className={`badge-${item.severity.toLowerCase()}`}>
                            {item.severity}
                          </span>
                        </td>
                        <td style={{ color: '#cbd5e1' }}>{item.message}</td>
                        <td style={{ color: '#64748b', fontSize: '0.8rem', fontFamily: 'monospace' }}>{item.created_at}</td>
                      </tr>
                    ))
                  )}
                </tbody>
              </table>
            </div>
          </div>
        </div>
      )}

      {/* Login Modal */}
      {showLoginModal && (
        <div style={{ position: 'fixed', top: 0, left: 0, width: '100%', height: '100%', background: 'rgba(10, 14, 23, 0.8)', display: 'flex', justifyContent: 'center', alignItems: 'center', zIndex: 1000 }}>
          <form onSubmit={handleLogin} className="secops-auth" style={{ margin: 0, width: '100%', maxWidth: '400px', position: 'relative' }}>
            <button type="button" onClick={() => setShowLoginModal(false)} style={{ position: 'absolute', top: '16px', right: '16px', background: 'transparent', border: 'none', color: '#94a3b8', fontSize: '1.2rem', cursor: 'pointer' }}>×</button>
            <h2>Operator Sign In</h2>
            {loginError && <p style={{ color: '#ef4444', fontSize: '0.85rem', marginBottom: '16px' }}>{loginError}</p>}
            <input type="text" name="username" placeholder="Username" autoComplete="username" className="secops-input" required autoFocus />
            <input type="password" name="password" placeholder="Password" autoComplete="current-password" className="secops-input" required />
            <button type="submit" className="secops-btn" disabled={authenticating}>
              {authenticating ? 'Authenticating...' : 'Authenticate'}
            </button>
          </form>
        </div>
      )}
    </div>
  );
}

export default App;
