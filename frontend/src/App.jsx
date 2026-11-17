import { useState, useEffect } from 'react';
import './App.css';

function App() {
  const [token, setToken] = useState(localStorage.getItem('token') || '');
  const [health, setHealth] = useState({ status: 'API STANDBY', cpu: 'N/A', mem: 'N/A', uptime: 'N/A', latency: 0 });
  const [records, setRecords] = useState([]);
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
        setHealth({ status: 'API STANDBY', cpu: '14.2%', mem: '290 MB', uptime: '4d 12h', latency: 0 });
      }
    };
    fetchHealth();
    const interval = setInterval(fetchHealth, 5000);
    return () => clearInterval(interval);
  }, []);

  const handleLogin = (e) => {
    e.preventDefault();
    // Simulate Login
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

  return (
    <div className="min-h-screen p-6">
      {/* Topbar */}
      <header className="flex justify-between items-center mb-8 pb-4 border-b border-gray-800">
        <div>
          <h1 className="text-xl font-bold tracking-wider text-cyan-400">ORACLE-INFRA // SecOps Console</h1>
          <p className="text-sm text-gray-500">oracle-infra.duckdns.org</p>
        </div>
        <div className="flex items-center gap-4">
          <span className={`px-3 py-1 rounded-full text-xs font-medium ${health.status === 'HEALTHY' ? 'bg-emerald-900 text-emerald-300' : 'bg-amber-900 text-amber-300'}`}>
            {health.status}
          </span>
          {isLoggedIn && <button onClick={logout} className="text-sm text-red-400 hover:text-red-300">Çıkış Yap</button>}
        </div>
      </header>

      {/* KPI Cards */}
      <section className="grid grid-cols-1 md:grid-cols-4 gap-4 mb-8">
        {[
          { label: 'CPU Load', value: health.cpu },
          { label: 'Memory Used', value: health.mem },
          { label: 'System Uptime', value: health.uptime },
          { label: 'API Latency', value: `${health.latency}ms` },
        ].map((kpi, i) => (
          <div key={i} className="bg-gray-900 p-4 rounded-lg border border-gray-800">
            <p className="text-gray-500 text-xs uppercase">{kpi.label}</p>
            <p className="text-2xl font-mono mt-1 text-white">{kpi.value}</p>
          </div>
        ))}
      </section>

      {/* Main Content Area */}
      {!isLoggedIn ? (
        <form onSubmit={handleLogin} className="max-w-md mx-auto bg-gray-900 p-8 rounded-lg border border-gray-800">
          <h2 className="text-xl mb-6 text-white">Güvenli Giriş</h2>
          <input type="text" placeholder="Kullanıcı Adı" className="w-full bg-gray-800 p-2 mb-4 rounded border border-gray-700 text-white" />
          <input type="password" placeholder="Şifre" className="w-full bg-gray-800 p-2 mb-6 rounded border border-gray-700 text-white" />
          <button className="w-full bg-cyan-600 p-2 rounded text-white font-bold hover:bg-cyan-500">Giriş Yap</button>
        </form>
      ) : (
        <div className="space-y-8">
          <div className="bg-gray-900 p-6 rounded-lg border border-gray-800">
            <input 
              type="text" 
              placeholder="Kayıtlarda ara..." 
              className="w-full bg-gray-800 p-3 rounded border border-gray-700 text-white"
              onChange={(e) => setSearch(e.target.value)}
            />
          </div>
          
          <div className="bg-gray-900 rounded-lg border border-gray-800 overflow-hidden">
            <table className="w-full text-left">
              <thead className="bg-gray-800 text-gray-400 text-xs uppercase">
                <tr>
                  <th className="p-4">Servis</th>
                  <th className="p-4">Önem Derecesi</th>
                  <th className="p-4">Mesaj</th>
                </tr>
              </thead>
              <tbody className="text-sm">
                <tr className="border-t border-gray-800">
                  <td className="p-4 text-cyan-300">caddy-proxy</td>
                  <td className="p-4"><span className="px-2 py-0.5 rounded bg-red-900 text-red-300 text-[10px]">HIGH</span></td>
                  <td className="p-4 text-gray-300">SSL renewal task failed</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      )}
    </div>
  );
}

export default App;
