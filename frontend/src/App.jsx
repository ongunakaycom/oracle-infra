import { useState, useEffect } from 'react';
import './index.css';

function App() {
  const [token, setToken] = useState(localStorage.getItem('token') || '');
  const [health, setHealth] = useState({ status: 'API STANDBY', cpu: 'N/A', mem: 'N/A', uptime: 'N/A', latency: 0 });
  const [records, setRecords] = useState([
    { id: 1, service: 'caddy-proxy', severity: 'HIGH', message: 'SSL renewal task failed or proxy timeout detected', created_at: '2026-03-30 12:00:00' },
    { id: 2, service: 'auth-gateway', severity: 'MEDIUM', message: 'Rate limit threshold approaching on endpoint /api/login', created_at: '2026-03-30 12:05:12' },
    { id: 3, service: 'oci-firewall', severity: 'LOW', message: 'NSG rule synchronized successfully across VCN subnets', created_at: '2026-03-30 12:10:45' }
  ]);
  const [search, setSearch] = useState('');
  const [isLoggedIn, setIsLoggedIn] = useState(!!token);

  // Health Check Simulation
  useEffect(() => {
    const fetchHealth = async () => {
      const start = performance.now();
      try {
        const res = await fetch('/api/health');
        const data = await res.json();
        const latency = Math.round(performance.now() - start);
        setHealth({ ...data, status: 'HEALTHY', latency });
      } catch (err) {
        setHealth({ status: 'API STANDBY', cpu: '14.2%', mem: '290 MB / 1024 MB', uptime: '4d 12h', latency: 0 });
      }
    };
    fetchHealth();
    const interval = setInterval(fetchHealth, 5000);
    return () => clearInterval(interval);
  }, []);

  const handleLogin = (e) => {
    e.preventDefault();
    const mockToken = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.demo-token";
    localStorage.setItem('token', mockToken);
    setToken(mockToken);
    setIsLoggedIn(true);
  };

  const logout = () => {
    localStorage.removeItem('token');
    setToken('');
    setIsLoggedIn(false);
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
          <h1>ORACLE-INFRA // SecOps Console</h1>
          <p>oracle-infra.duckdns.org</p>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: '16px' }}>
          <span className={`secops-badge ${health.status === 'HEALTHY' ? 'healthy' : 'standby'}`}>
            {health.status}
          </span>
          {isLoggedIn && (
            <button onClick={logout} style={{ background: 'transparent', border: 'none', color: '#ef4444', cursor: 'pointer', fontSize: '0.85rem', fontWeight: 600 }}>
              Çıkış Yap
            </button>
          )}
        </div>
      </header>

      {/* KPI Cards */}
      <section className="secops-grid">
        {[
          { label: 'CPU Load', value: health.cpu },
          { label: 'Memory Used', value: health.mem },
          { label: 'System Uptime', value: health.uptime },
          { label: 'API Latency', value: `${health.latency}ms` },
        ].map((kpi, i) => (
          <div key={i} className="secops-card">
            <label>{kpi.label}</label>
            <p className="value">{kpi.value}</p>
          </div>
        ))}
      </section>

      {/* Main Content Area */}
      {!isLoggedIn ? (
        <form onSubmit={handleLogin} className="secops-auth">
          <h2>Güvenli Giriş</h2>
          <input type="text" placeholder="Kullanıcı Adı" defaultValue="admin" className="secops-input" required />
          <input type="password" placeholder="Şifre" defaultValue="••••••••" className="secops-input" required />
          <button type="submit" className="secops-btn">Giriş Yap</button>
        </form>
      ) : (
        <div>
          <input 
            type="text" 
            placeholder="Audit log kayıtlarında ara (servis veya mesaj)..." 
            className="secops-search"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
          />
          
          <div className="secops-table-container">
            <table>
              <thead>
                <tr>
                  <th>Servis</th>
                  <th>Önem Derecesi</th>
                  <th>Mesaj</th>
                  <th>Zaman</th>
                </tr>
              </thead>
              <tbody>
                {filteredRecords.map((item) => (
                  <tr key={item.id}>
                    <td style={{ color: '#06b6d4', fontWeight: 500 }}>{item.service}</td>
                    <td><span className="badge-high">{item.severity}</span></td>
                    <td style={{ color: '#cbd5e1' }}>{item.message}</td>
                    <td style={{ color: '#64748b', fontSize: '0.8rem', fontFamily: 'monospace' }}>{item.created_at}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}
    </div>
  );
}

export default App;
