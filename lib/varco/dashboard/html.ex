defmodule Varco.Dashboard.HTML do
  @moduledoc """
  Generates the zero-dependency, embedded real-time dashboard HTML.
  """

  def render do
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Varco - Reverse Proxy Dashboard</title>
      <style>
        :root {
          --bg: #090d16;
          --card: #131b2e;
          --border: #1e293b;
          --text: #f8fafc;
          --muted: #94a3b8;
          --accent: #38bdf8;
          --success: #10b981;
          --warning: #f59e0b;
          --danger: #f43f5e;
          --purple: #a855f7;
        }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: var(--bg); color: var(--text); padding: 2rem; min-height: 100vh; }
        .container { max-width: 1200px; margin: 0 auto; }
        header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 2rem; border-bottom: 1px solid var(--border); padding-bottom: 1.5rem; }
        .logo-group { display: flex; align-items: center; gap: 0.75rem; }
        .logo-badge { background: linear-gradient(135deg, #0284c7, #6366f1); padding: 0.4rem 0.8rem; border-radius: 0.5rem; font-weight: 900; font-size: 1.25rem; letter-spacing: 0.05em; color: #fff; }
        .title { font-size: 1.5rem; font-weight: 700; }
        .header-meta { display: flex; gap: 1rem; align-items: center; font-size: 0.875rem; color: var(--muted); }
        .node-chip { background: var(--card); border: 1px solid var(--border); padding: 0.35rem 0.75rem; border-radius: 9999px; display: flex; align-items: center; gap: 0.5rem; }
        .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--success); }
        .btn-ca { background: #1e293b; color: var(--accent); border: 1px solid #38bdf844; padding: 0.4rem 0.8rem; border-radius: 0.375rem; font-size: 0.875rem; text-decoration: none; cursor: pointer; transition: 0.2s; }
        .btn-ca:hover { background: #38bdf822; }

        .stats-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 1.25rem; margin-bottom: 2rem; }
        .stat-card { background: var(--card); border: 1px solid var(--border); border-radius: 0.75rem; padding: 1.25rem; }
        .stat-label { font-size: 0.8rem; text-transform: uppercase; letter-spacing: 0.05em; color: var(--muted); margin-bottom: 0.5rem; }
        .stat-val { font-size: 2rem; font-weight: 800; color: var(--text); }

        .section { background: var(--card); border: 1px solid var(--border); border-radius: 0.75rem; padding: 1.5rem; margin-bottom: 2rem; }
        .section-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 1rem; }
        .section-title { font-size: 1.15rem; font-weight: 600; }

        table { width: 100%; border-collapse: collapse; text-align: left; font-size: 0.9rem; }
        th { padding: 0.75rem 1rem; border-bottom: 1px solid var(--border); color: var(--muted); font-weight: 500; font-size: 0.8rem; text-transform: uppercase; }
        td { padding: 0.85rem 1rem; border-bottom: 1px solid var(--border); }
        tr:last-child td { border-bottom: none; }
        tr:hover { background: rgba(255,255,255,0.02); }

        .badge { display: inline-block; padding: 0.2rem 0.5rem; border-radius: 0.25rem; font-size: 0.75rem; font-weight: 600; }
        .badge-tls { background: rgba(16, 185, 129, 0.15); color: #34d399; border: 1px solid rgba(16, 185, 129, 0.3); }
        .badge-plain { background: rgba(245, 158, 11, 0.15); color: #fbbf24; border: 1px solid rgba(245, 158, 11, 0.3); }
        .badge-self { background: rgba(56, 189, 248, 0.15); color: #38bdf8; border: 1px solid rgba(56, 189, 248, 0.3); }
        .badge-custom { background: rgba(168, 85, 247, 0.15); color: #c084fc; border: 1px solid rgba(168, 85, 247, 0.3); }

        code { font-family: monospace; background: #090d16; padding: 0.2rem 0.4rem; border-radius: 0.25rem; font-size: 0.85em; color: var(--accent); }
      </style>
    </head>
    <body>
      <div class="container">
        <header>
          <div class="logo-group">
            <div class="logo-badge">VARCO</div>
            <div class="title">Reverse Proxy</div>
          </div>
          <div class="header-meta">
            <div class="node-chip">
              <div class="dot" id="node-dot"></div>
              <span id="node-name">Connecting...</span>
            </div>
            <a href="/api/v1/certificates/ca" class="btn-ca" download="varco-root-ca.crt">Export Root CA</a>
          </div>
        </header>

        <div class="stats-grid">
          <div class="stat-card">
            <div class="stat-label">Active Routes</div>
            <div class="stat-val" id="stat-routes">--</div>
          </div>
          <div class="stat-card">
            <div class="stat-label">TLS Certificates</div>
            <div class="stat-val" id="stat-certs">--</div>
          </div>
          <div class="stat-card">
            <div class="stat-label">Cluster Nodes</div>
            <div class="stat-val" id="stat-nodes">--</div>
          </div>
          <div class="stat-card">
            <div class="stat-label">BEAM Memory</div>
            <div class="stat-val" id="stat-mem">-- MB</div>
          </div>
        </div>

        <div class="section">
          <div class="section-header">
            <div class="section-title">Active Routes & Upstreams</div>
          </div>
          <table>
            <thead>
              <tr>
                <th>ID</th>
                <th>Host Pattern</th>
                <th>Path</th>
                <th>Upstream Backends</th>
                <th>TLS Policy</th>
                <th>Algorithm</th>
              </tr>
            </thead>
            <tbody id="routes-table">
              <tr><td colspan="6" style="text-align:center; color: var(--muted);">Loading routes...</td></tr>
            </tbody>
          </table>
        </div>

        <div class="section">
          <div class="section-header">
            <div class="section-title">TLS Certificates & Local CA</div>
          </div>
          <table>
            <thead>
              <tr>
                <th>Domain</th>
                <th>Type</th>
                <th>Associated SANs</th>
                <th>Expires</th>
              </tr>
            </thead>
            <tbody id="certs-table">
              <tr><td colspan="4" style="text-align:center; color: var(--muted);">Loading certificates...</td></tr>
            </tbody>
          </table>
        </div>
      </div>

      <script>
        function escapeHtml(str) {
          if (str === null || str === undefined) return '';
          return String(str)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
            .replace(/'/g, '&#039;');
        }

        function formatDate(dateStr) {
          if (!dateStr) return 'N/A';
          try {
            const d = new Date(dateStr);
            return isNaN(d.getTime()) ? String(dateStr) : d.toLocaleDateString();
          } catch (_) {
            return String(dateStr);
          }
        }

        async function fetchEndpoint(url) {
          try {
            const res = await fetch(url);
            if (!res.ok) {
              console.warn(`Fetch ${url} failed with status ${res.status}`);
              return null;
            }
            return await res.json();
          } catch (e) {
            console.warn(`Fetch ${url} network error:`, e);
            return null;
          }
        }

        async function refreshData() {
          try {
            const [routesRes, certsRes, clusterRes, metricsRes] = await Promise.all([
              fetchEndpoint('/api/v1/routes'),
              fetchEndpoint('/api/v1/certificates'),
              fetchEndpoint('/api/v1/cluster'),
              fetchEndpoint('/api/v1/metrics')
            ]);

            const dot = document.getElementById('node-dot');
            const nodeName = document.getElementById('node-name');

            if (clusterRes) {
              if (dot) dot.style.background = 'var(--success)';
              if (nodeName) nodeName.textContent = clusterRes.current_node || 'varco@standalone';
              const statNodes = document.getElementById('stat-nodes');
              if (statNodes) statNodes.textContent = clusterRes.node_count ?? 1;
            } else {
              if (dot) dot.style.background = 'var(--warning)';
              if (nodeName && (nodeName.textContent === 'Connecting...' || nodeName.textContent === 'Loading...')) {
                nodeName.textContent = 'Connecting...';
              }
            }

            if (metricsRes) {
              const statMem = document.getElementById('stat-mem');
              if (statMem && metricsRes.beam_memory_bytes !== undefined) {
                statMem.textContent = (metricsRes.beam_memory_bytes / 1024 / 1024).toFixed(1) + ' MB';
              }
            }

            // Render routes
            if (Array.isArray(routesRes)) {
              const statRoutes = document.getElementById('stat-routes');
              if (statRoutes) statRoutes.textContent = routesRes.length;

              const tbody = document.getElementById('routes-table');
              if (tbody) {
                if (routesRes.length === 0) {
                  tbody.innerHTML = '<tr><td colspan="6" style="text-align:center; color: var(--muted);">No routes configured yet. Add routes via REST API, Docker labels, or Kubernetes Ingress.</td></tr>';
                } else {
                  tbody.innerHTML = routesRes.map(r => {
                    const hosts = Array.isArray(r.hosts) && r.hosts.length
                      ? r.hosts.map(h => `<code>${escapeHtml(h)}</code>`).join(' ')
                      : '<em>(any host)</em>';
                    const upstreams = Array.isArray(r.upstreams) && r.upstreams.length
                      ? r.upstreams.map(u => `<code>${escapeHtml(u)}</code>`).join('<br>')
                      : '<em>(no upstreams)</em>';
                    return `
                      <tr>
                        <td><strong>${escapeHtml(r.id || '')}</strong></td>
                        <td>${hosts}</td>
                        <td><code>${escapeHtml(r.path || '/')}</code></td>
                        <td>${upstreams}</td>
                        <td><span class="badge ${r.tls ? 'badge-tls' : 'badge-plain'}">${r.tls ? 'HTTPS / TLS' : 'Plain HTTP'}</span></td>
                        <td>${escapeHtml(r.load_balancer || 'round_robin')}</td>
                      </tr>
                    `;
                  }).join('');
                }
              }
            }

            // Render certs
            if (Array.isArray(certsRes)) {
              const statCerts = document.getElementById('stat-certs');
              if (statCerts) statCerts.textContent = certsRes.length;

              const certsBody = document.getElementById('certs-table');
              if (certsBody) {
                if (certsRes.length === 0) {
                  certsBody.innerHTML = '<tr><td colspan="4" style="text-align:center; color: var(--muted);">No certificates loaded.</td></tr>';
                } else {
                  certsBody.innerHTML = certsRes.map(c => {
                    const domains = Array.isArray(c.domains) && c.domains.length
                      ? c.domains.map(d => escapeHtml(d)).join(', ')
                      : '-';
                    return `
                      <tr>
                        <td><strong>${escapeHtml(c.domain || '')}</strong></td>
                        <td><span class="badge ${c.type === 'self_signed' ? 'badge-self' : 'badge-custom'}">${escapeHtml(c.type || '')}</span></td>
                        <td>${domains}</td>
                        <td>${formatDate(c.expires_at)}</td>
                      </tr>
                    `;
                  }).join('');
                }
              }
            }
          } catch (e) {
            console.error('Failed to update dashboard data', e);
          }
        }

        refreshData();
        setInterval(refreshData, 3000);
      </script>
    </body>
    </html>
    """
  end
end
