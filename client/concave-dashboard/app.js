import { ConcaveClient } from '/_concave/index.js';

const wsProto = location.protocol === 'https:' ? 'wss:' : 'ws:';
const client = new ConcaveClient(`${wsProto}//${location.host}/ws`);

const state = {
  tab: 'data',
  stats: null,
  selectedTable: null,
  selectedFn: null,
  selectedRoute: null,
  activeSubStop: null,
  adminKey: sessionStorage.getItem('concave_admin_key') || '',
};

const $dot = document.getElementById('live-dot');
const $appName = document.getElementById('app-name');
const $ts = document.getElementById('m-ts');
const $clients = document.getElementById('m-clients');
const $subs = document.getElementById('m-subs');
const $adminKey = document.getElementById('admin-key');
const $sidebar = document.getElementById('sidebar-list');
const $main = document.getElementById('main-view');

$adminKey.value = state.adminKey;
$adminKey.addEventListener('change', () => {
  state.adminKey = $adminKey.value.trim();
  sessionStorage.setItem('concave_admin_key', state.adminKey);
  refreshAll();
});

document.getElementById('refresh-btn').addEventListener('click', refreshAll);

document.querySelectorAll('.tab').forEach((btn) => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('.tab').forEach((b) => b.classList.remove('active'));
    btn.classList.add('active');
    stopLiveSub();
    state.tab = btn.dataset.tab;
    renderSidebar();
    renderMain();
  });
});

function adminHeaders() {
  const h = {};
  if (state.adminKey) h['Authorization'] = `Bearer ${state.adminKey}`;
  return h;
}

async function fetchAdmin(path) {
  const res = await fetch(path, { headers: adminHeaders() });
  if (!res.ok) {
    const txt = await res.text();
    throw new Error(`${res.status} ${res.statusText}: ${txt}`);
  }
  return await res.json();
}

function stopLiveSub() {
  if (state.activeSubStop) {
    state.activeSubStop();
    state.activeSubStop = null;
  }
}

function allTables() {
  if (!state.stats) return [];
  const out = [];
  for (const t of state.stats.tables || []) out.push({ ns: '', table: t.name, label: t.name });
  for (const c of state.stats.components || []) {
    for (const t of c.tables || []) out.push({ ns: c.namespace, table: t.name, label: `${c.namespace}.${t.name}` });
  }
  out.push({ ns: '_system', table: '_scheduled_jobs', label: '_system._scheduled_jobs' });
  return out;
}

async function refreshStats() {
  try {
    state.stats = await fetchAdmin('/_admin/stats');
    $dot.className = 'dot ok';
    $appName.textContent = state.stats.app_name || 'concave';
    $ts.textContent = String(state.stats.commit_ts ?? 0);
    $clients.textContent = String(state.stats.active_clients ?? 0);
    $subs.textContent = String(state.stats.active_subscriptions ?? 0);
    if (!state.selectedTable && allTables().length > 0) state.selectedTable = allTables()[0];
    if (!state.selectedFn && (state.stats.functions || []).length > 0) state.selectedFn = state.stats.functions[0];
    if (!state.selectedRoute && (state.stats.http_routes || []).length > 0) state.selectedRoute = state.stats.http_routes[0];
  } catch (err) {
    $dot.className = 'dot err';
    $main.innerHTML = `<div class="card"><h2>Admin API Error</h2><pre class="code">${escapeHtml(err.message)}</pre></div>`;
  }
}

function renderSidebar() {
  $sidebar.innerHTML = '';
  if (!state.stats) return;

  if (state.tab === 'data') {
    for (const tbl of allTables()) {
      const btn = document.createElement('button');
      const isSel = state.selectedTable && state.selectedTable.ns === tbl.ns && state.selectedTable.table === tbl.table;
      btn.className = `list-item ${isSel ? 'selected' : ''}`;
      btn.textContent = tbl.label;
      btn.onclick = () => { state.selectedTable = tbl; renderSidebar(); renderMain(); };
      $sidebar.appendChild(btn);
    }
  } else if (state.tab === 'functions') {
    for (const fn of state.stats.functions || []) {
      const btn = document.createElement('button');
      const isSel = state.selectedFn && state.selectedFn.name === fn.name;
      btn.className = `list-item ${isSel ? 'selected' : ''}`;
      btn.innerHTML = `<span>${escapeHtml(fn.name)}</span><span class="badge ${fn.kind}">${fn.kind}</span>`;
      btn.onclick = () => { stopLiveSub(); state.selectedFn = fn; renderSidebar(); renderMain(); };
      $sidebar.appendChild(btn);
    }
  } else if (state.tab === 'jobs') {
    const info = document.createElement('div');
    info.className = 'empty';
    info.textContent = `${(state.stats.crons || []).length} registered cron(s)`;
    $sidebar.appendChild(info);
  } else if (state.tab === 'routes') {
    for (const r of state.stats.http_routes || []) {
      const btn = document.createElement('button');
      const isSel = state.selectedRoute && state.selectedRoute.path === r.path && state.selectedRoute.method === r.method;
      btn.className = `list-item ${isSel ? 'selected' : ''}`;
      btn.innerHTML = `<span>${escapeHtml(r.path)}</span><span class="badge action">${escapeHtml(r.method)}</span>`;
      btn.onclick = () => { state.selectedRoute = r; renderSidebar(); renderMain(); };
      $sidebar.appendChild(btn);
    }
  }
}

async function renderMain() {
  if (!state.stats) return;
  if (state.tab === 'data') {
    if (!state.selectedTable) {
      $main.innerHTML = '<div class="empty">No tables registered.</div>';
      return;
    }
    const { ns, table, label } = state.selectedTable;
    try {
      const docs = await fetchAdmin(`/_admin/table?ns=${encodeURIComponent(ns)}&table=${encodeURIComponent(table)}&limit=100`);
      const rows = docs.map((d) => `<tr><td>${escapeHtml(d.id || '')}</td><td>${d.created_at || ''}</td><td><pre class="code">${escapeHtml(JSON.stringify(d, null, 2))}</pre></td></tr>`).join('');
      $main.innerHTML = `
        <div class="card">
          <h2>${escapeHtml(label)} <span class="pill">${docs.length} docs</span></h2>
          ${docs.length === 0 ? '<div class="empty">Empty table</div>' : `<table class="grid"><thead><tr><th>ID</th><th>Created At</th><th>Document</th></tr></thead><tbody>${rows}</tbody></table>`}
        </div>`;
    } catch (err) {
      $main.innerHTML = `<div class="card"><h2>Error</h2><pre class="code">${escapeHtml(err.message)}</pre></div>`;
    }
  } else if (state.tab === 'functions') {
    const fn = state.selectedFn;
    if (!fn) {
      $main.innerHTML = '<div class="empty">No functions registered.</div>';
      return;
    }
    $main.innerHTML = `
      <div class="card">
        <h2>${escapeHtml(fn.name)} <span class="badge ${fn.kind}">${fn.kind}</span></h2>
        <div class="row"><label>Arguments JSON</label></div>
        <textarea id="fn-args">{}</textarea>
        <div class="row" style="margin-top:10px">
          <button id="fn-run" class="btn">Run ${fn.kind}</button>
          ${fn.kind === 'query' ? '<button id="fn-sub" class="btn secondary">Subscribe Live (WS)</button>' : ''}
          <input id="fn-token" type="text" placeholder="Optional auth token (e.g. dev:alice)" style="flex:1" />
        </div>
        <pre class="code" id="fn-out">// output will appear here</pre>
      </div>`;

    const $args = document.getElementById('fn-args');
    const $out = document.getElementById('fn-out');
    const $tok = document.getElementById('fn-token');

    document.getElementById('fn-run').onclick = async () => {
      stopLiveSub();
      try {
        const headers = { 'Content-Type': 'application/json' };
        if ($tok.value.trim()) headers['Authorization'] = `Bearer ${$tok.value.trim()}`;
        const res = await fetch(`/api/${fn.kind}/${fn.name}`, {
          method: 'POST', headers, body: $args.value || '{}',
        });
        const data = await res.json();
        $out.textContent = JSON.stringify(data, null, 2);
        refreshStats();
      } catch (e) {
        $out.textContent = `Error: ${e.message}`;
      }
    };

    const subBtn = document.getElementById('fn-sub');
    if (subBtn) {
      subBtn.onclick = () => {
        stopLiveSub();
        let parsed = {};
        try { parsed = JSON.parse($args.value || '{}'); } catch (e) { $out.textContent = `Invalid JSON: ${e.message}`; return; }
        if ($tok.value.trim()) client.setAuth($tok.value.trim());
        const q = client.query(fn.name, parsed);
        const timer = setInterval(() => {
          $out.textContent = `// LIVE WS SUBSCRIPTION\n${JSON.stringify({ status: q.status(), value: q.value(), error: q.error() }, null, 2)}`;
        }, 120);
        state.activeSubStop = () => { clearInterval(timer); q.dispose(); };
      };
    }
  } else if (state.tab === 'jobs') {
    try {
      const jobs = await fetchAdmin('/_admin/jobs');
      const crons = state.stats.crons || [];
      const cronRows = crons.map((c) => `<tr><td>${escapeHtml(c.name)}</td><td>${c.interval_ms} ms</td><td>${escapeHtml(c.fn_name)}</td><td>${escapeHtml(c.args_json)}</td></tr>`).join('');
      const jobRows = jobs.map((j) => `<tr><td>${escapeHtml(j.id)}</td><td><span class="badge ${escapeHtml(j.status || '')}">${escapeHtml(j.status || '')}</span></td><td>${escapeHtml(j.fn_name || '')}</td><td>${j.run_at_ms || ''}</td><td>${j.attempts ?? 0}</td><td>${escapeHtml(j.last_error || '')}</td></tr>`).join('');
      $main.innerHTML = `
        <div class="card">
          <h2>Registered Crons <span class="pill">${crons.length}</span></h2>
          ${crons.length === 0 ? '<div class="empty">No crons configured.</div>' : `<table class="grid"><thead><tr><th>Name</th><th>Interval</th><th>Function</th><th>Args</th></tr></thead><tbody>${cronRows}</tbody></table>`}
        </div>
        <div class="card">
          <h2>Scheduled Jobs <span class="pill">${jobs.length}</span></h2>
          ${jobs.length === 0 ? '<div class="empty">No scheduled jobs recorded.</div>' : `<table class="grid"><thead><tr><th>ID</th><th>Status</th><th>Function</th><th>Run At (ms)</th><th>Attempts</th><th>Last Error</th></tr></thead><tbody>${jobRows}</tbody></table>`}
        </div>`;
    } catch (err) {
      $main.innerHTML = `<div class="card"><h2>Error</h2><pre class="code">${escapeHtml(err.message)}</pre></div>`;
    }
  } else if (state.tab === 'routes') {
    const r = state.selectedRoute;
    if (!r) {
      $main.innerHTML = '<div class="empty">No custom HTTP routes registered.</div>';
      return;
    }
    const defaultPath = r.path.endsWith('*') ? r.path.slice(0, -1) + 'test' : r.path;
    $main.innerHTML = `
      <div class="card">
        <h2>${escapeHtml(r.method)} ${escapeHtml(r.path)}</h2>
        <div class="row">
          <input id="rt-method" value="${escapeHtml(r.method === '*' ? 'POST' : r.method)}" style="width:90px" />
          <input id="rt-path" value="${escapeHtml(defaultPath)}" style="flex:1" />
          <button id="rt-send" class="btn">Send Request</button>
        </div>
        <textarea id="rt-body">{}</textarea>
        <pre class="code" id="rt-out" style="margin-top:10px">// response will appear here</pre>
      </div>`;
    document.getElementById('rt-send').onclick = async () => {
      const m = document.getElementById('rt-method').value.trim() || 'GET';
      const p = document.getElementById('rt-path').value.trim();
      const b = document.getElementById('rt-body').value;
      const opts = { method: m, headers: { 'Content-Type': 'application/json' } };
      if (m !== 'GET' && m !== 'HEAD') opts.body = b;
      const res = await fetch(p, opts);
      const txt = await res.text();
      document.getElementById('rt-out').textContent = `HTTP ${res.status} ${res.statusText}\n\n${txt}`;
      refreshStats();
    };
  }
}

function escapeHtml(s) {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

async function refreshAll() {
  await refreshStats();
  renderSidebar();
  await renderMain();
}

refreshAll();
setInterval(refreshStats, 2000);
