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
  adminKey: '',
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

async function postAdmin(path, bodyObj) {
  const res = await fetch(path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...adminHeaders() },
    body: JSON.stringify(bodyObj),
  });
  if (!res.ok) {
    const txt = await res.text();
    throw new Error(`${res.status} ${res.statusText}: ${txt}`);
  }
  const txt = await res.text();
  if (!txt) return null;
  try {
    return JSON.parse(txt);
  } catch {
    return txt;
  }
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
      btn.innerHTML = `<span>${escapeHtml(fn.name)}</span><span class="badge ${escapeHtml(fn.kind)}">${escapeHtml(fn.kind)}</span>`;
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
    const isReadOnly = ns === '_system';
    try {
      const docs = await fetchAdmin(`/_admin/table?ns=${encodeURIComponent(ns)}&table=${encodeURIComponent(table)}&limit=100`);
      $main.innerHTML = `
        <div class="card">
          <h2>${escapeHtml(label)} <span class="pill">${docs.length} docs</span></h2>
          <pre id="data-error" class="code" style="display:none;color:var(--err);margin-bottom:10px"></pre>
          ${docs.length === 0 ? '<div class="empty">Empty table</div>' : `<table class="grid"><thead><tr><th>ID</th><th>Created At</th><th>Document</th>${isReadOnly ? '' : '<th>Actions</th>'}</tr></thead><tbody id="data-tbody"></tbody></table>`}
        </div>`;

      const tbody = document.getElementById('data-tbody');
      const errBox = document.getElementById('data-error');
      const showErr = (msg) => {
        if (!errBox) return;
        errBox.textContent = msg;
        errBox.style.display = 'block';
      };

      if (tbody) {
        for (const d of docs) {
          const tr = document.createElement('tr');

          const tdId = document.createElement('td');
          tdId.textContent = d.id || '';
          tr.appendChild(tdId);

          const tdCreated = document.createElement('td');
          tdCreated.textContent = d.created_at ?? '';
          tr.appendChild(tdCreated);

          const tdDoc = document.createElement('td');
          const renderDocPre = () => {
            tdDoc.textContent = '';
            const pre = document.createElement('pre');
            pre.className = 'code';
            pre.textContent = JSON.stringify(d, null, 2);
            tdDoc.appendChild(pre);
          };
          renderDocPre();
          tr.appendChild(tdDoc);

          if (!isReadOnly) {
            const tdAct = document.createElement('td');
            if (d.id) {
              const wrap = document.createElement('div');
              wrap.className = 'row';
              wrap.style.marginBottom = '0';
              wrap.style.flexWrap = 'nowrap';

              const editBtn = document.createElement('button');
              editBtn.type = 'button';
              editBtn.className = 'btn secondary';
              editBtn.textContent = 'Edit';
              editBtn.addEventListener('click', () => {
                if (tdDoc.querySelector('textarea')) return;
                const editable = {};
                for (const [k, v] of Object.entries(d)) {
                  if (k !== 'id' && k !== 'created_at') editable[k] = v;
                }
                tdDoc.textContent = '';

                const ta = document.createElement('textarea');
                ta.value = JSON.stringify(editable, null, 2);
                tdDoc.appendChild(ta);

                const rowErr = document.createElement('div');
                rowErr.style.color = 'var(--err)';
                rowErr.style.marginTop = '6px';
                rowErr.style.fontSize = '12px';

                const controls = document.createElement('div');
                controls.className = 'row';
                controls.style.marginTop = '8px';
                controls.style.marginBottom = '0';

                const saveBtn = document.createElement('button');
                saveBtn.type = 'button';
                saveBtn.className = 'btn';
                saveBtn.textContent = 'Save';

                const cancelBtn = document.createElement('button');
                cancelBtn.type = 'button';
                cancelBtn.className = 'btn secondary';
                cancelBtn.textContent = 'Cancel';

                cancelBtn.addEventListener('click', renderDocPre);
                saveBtn.addEventListener('click', async () => {
                  let patch;
                  try {
                    patch = JSON.parse(ta.value);
                    if (!patch || typeof patch !== 'object' || Array.isArray(patch)) {
                      throw new Error('Patch must be a JSON object');
                    }
                  } catch (e) {
                    rowErr.textContent = `Invalid JSON: ${e.message}`;
                    return;
                  }
                  rowErr.textContent = '';
                  saveBtn.disabled = true;
                  cancelBtn.disabled = true;
                  try {
                    await postAdmin('/_admin/doc/patch', { ns, table, id: d.id, patch });
                    await refreshStats();
                    await renderMain();
                  } catch (e) {
                    rowErr.textContent = e.message;
                    saveBtn.disabled = false;
                    cancelBtn.disabled = false;
                  }
                });

                controls.appendChild(saveBtn);
                controls.appendChild(cancelBtn);
                tdDoc.appendChild(controls);
                tdDoc.appendChild(rowErr);
              });

              const delBtn = document.createElement('button');
              delBtn.type = 'button';
              delBtn.className = 'btn secondary';
              delBtn.style.color = 'var(--err)';
              delBtn.textContent = 'Delete';
              delBtn.addEventListener('click', async () => {
                if (!window.confirm(`Delete document "${d.id}" from ${label}?`)) return;
                delBtn.disabled = true;
                try {
                  await postAdmin('/_admin/doc/delete', { ns, table, id: d.id });
                  await refreshStats();
                  await renderMain();
                } catch (e) {
                  showErr(e.message);
                  delBtn.disabled = false;
                }
              });

              wrap.appendChild(editBtn);
              wrap.appendChild(delBtn);
              tdAct.appendChild(wrap);
            }
            tr.appendChild(tdAct);
          }

          tbody.appendChild(tr);
        }
      }
    } catch (err) {
      $main.innerHTML = `<div class="card"><h2>Error</h2><pre class="code">${escapeHtml(err.message)}</pre></div>`;
    }
  } else if (state.tab === 'functions') {
    const fn = state.selectedFn;
    if (!fn) {
      $main.innerHTML = '<div class="empty">No functions registered.</div>';
      return;
    }
    const safeKind = escapeHtml(fn.kind);
    $main.innerHTML = `
      <div class="card">
        <h2>${escapeHtml(fn.name)} <span class="badge ${safeKind}">${safeKind}</span></h2>
        <div class="row"><label>Arguments JSON</label></div>
        <textarea id="fn-args">{}</textarea>
        <div class="row" style="margin-top:10px">
          <button id="fn-run" class="btn">Run ${safeKind}</button>
          ${fn.kind === 'query' ? '<button id="fn-sub" class="btn secondary">Subscribe Live (WS)</button>' : ''}
          <input id="fn-token" type="password" autocomplete="off" placeholder="Optional auth token (e.g. dev:alice)" style="flex:1" />
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
        const res = await fetch(`/api/${encodeURIComponent(fn.kind)}/${encodeURIComponent(fn.name)}`, {
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
        client.setAuth($tok.value.trim() || null);
        const q = client.query({ name: fn.name }, parsed);
        const timer = setInterval(() => {
          const snap = q();
          $out.textContent = `// LIVE WS SUBSCRIPTION\n${JSON.stringify({ status: snap.status, data: snap.data, error: snap.error }, null, 2)}`;
        }, 120);
        state.activeSubStop = () => { clearInterval(timer); q.dispose(); };
      };
    }
  } else if (state.tab === 'jobs') {
    try {
      const jobs = await fetchAdmin('/_admin/jobs');
      const crons = state.stats.crons || [];
      const cronRows = crons.map((c) => `<tr><td>${escapeHtml(c.name)}</td><td>${escapeHtml(c.interval_ms ?? '')} ms</td><td>${escapeHtml(c.fn_name)}</td><td>${escapeHtml(c.args_json)}</td></tr>`).join('');
      $main.innerHTML = `
        <div class="card">
          <h2>Registered Crons <span class="pill">${crons.length}</span></h2>
          ${crons.length === 0 ? '<div class="empty">No crons configured.</div>' : `<table class="grid"><thead><tr><th>Name</th><th>Interval</th><th>Function</th><th>Args</th></tr></thead><tbody>${cronRows}</tbody></table>`}
        </div>
        <div class="card">
          <h2>Scheduled Jobs <span class="pill">${jobs.length}</span></h2>
          <pre id="jobs-error" class="code" style="display:none;color:var(--err);margin-bottom:10px"></pre>
          ${jobs.length === 0 ? '<div class="empty">No scheduled jobs recorded.</div>' : `<table class="grid"><thead><tr><th>ID</th><th>Status</th><th>Function</th><th>Run At (ms)</th><th>Attempts</th><th>Last Error</th><th>Actions</th></tr></thead><tbody id="jobs-tbody"></tbody></table>`}
        </div>`;

      const jobsTbody = document.getElementById('jobs-tbody');
      const jobsErr = document.getElementById('jobs-error');
      const showJobErr = (msg) => {
        if (!jobsErr) return;
        jobsErr.textContent = msg;
        jobsErr.style.display = 'block';
      };

      if (jobsTbody) {
        for (const j of jobs) {
          const tr = document.createElement('tr');

          const tdId = document.createElement('td');
          tdId.textContent = j.id || '';
          tr.appendChild(tdId);

          const tdStatus = document.createElement('td');
          const badge = document.createElement('span');
          const st = j.status || '';
          badge.className = `badge ${st === 'dead' ? 'dead failed' : st}`;
          badge.textContent = st;
          tdStatus.appendChild(badge);
          tr.appendChild(tdStatus);

          const tdFn = document.createElement('td');
          tdFn.textContent = j.fn_name || '';
          tr.appendChild(tdFn);

          const tdRunAt = document.createElement('td');
          tdRunAt.textContent = j.run_at_ms ?? '';
          tr.appendChild(tdRunAt);

          const tdAttempts = document.createElement('td');
          tdAttempts.textContent = String(j.attempts ?? 0);
          tr.appendChild(tdAttempts);

          const tdErr = document.createElement('td');
          tdErr.textContent = j.last_error || '';
          tr.appendChild(tdErr);

          const tdAct = document.createElement('td');
          if (st === 'failed' || st === 'dead') {
            const retryBtn = document.createElement('button');
            retryBtn.type = 'button';
            retryBtn.className = 'btn secondary';
            retryBtn.textContent = 'Retry';
            retryBtn.addEventListener('click', async () => {
              retryBtn.disabled = true;
              try {
                await postAdmin('/_admin/jobs/retry', { job_id: j.id });
                await refreshStats();
                await renderMain();
              } catch (e) {
                showJobErr(e.message);
                retryBtn.disabled = false;
              }
            });
            tdAct.appendChild(retryBtn);
          } else if (st === 'pending') {
            const cancelBtn = document.createElement('button');
            cancelBtn.type = 'button';
            cancelBtn.className = 'btn secondary';
            cancelBtn.style.color = 'var(--err)';
            cancelBtn.textContent = 'Cancel';
            cancelBtn.addEventListener('click', async () => {
              cancelBtn.disabled = true;
              try {
                await postAdmin('/_admin/jobs/cancel', { job_id: j.id });
                await refreshStats();
                await renderMain();
              } catch (e) {
                showJobErr(e.message);
                cancelBtn.disabled = false;
              }
            });
            tdAct.appendChild(cancelBtn);
          }
          tr.appendChild(tdAct);

          jobsTbody.appendChild(tr);
        }
      }
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
      const outEl = document.getElementById('rt-out');
      if (!p.startsWith('/') || p.startsWith('//') || /[\r\n]/.test(p)) {
        outEl.textContent = 'Error: route path must be a relative same-origin path starting with "/"';
        return;
      }
      try {
        const opts = { method: m, headers: { 'Content-Type': 'application/json' } };
        if (m !== 'GET' && m !== 'HEAD') opts.body = b;
        const res = await fetch(p, opts);
        const txt = await res.text();
        outEl.textContent = `HTTP ${res.status} ${res.statusText}\n\n${txt}`;
        refreshStats();
      } catch (e) {
        outEl.textContent = `Error: ${e.message}`;
      }
    };
  }
}

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

async function refreshAll() {
  await refreshStats();
  renderSidebar();
  await renderMain();
}

refreshAll();
setInterval(refreshStats, 2000);
