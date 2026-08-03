/* ============================================================
   shift-left cloud sandbox — dashboard renderer
   Pure client-side. Fetches three JSON files. No KV, no D1,
   no Workers, no other network calls.
   ============================================================ */

const REFRESH_MS = 10_000;

// Only these three files leave the local machine. Everything else
// (floci, podman, terraform.tfstate) stays on the box.
const FETCH_TARGETS = [
  { id: 'tfsec',   last: 'data/tfsec-last.json',   history: 'data/tfsec-history.json' },
  { id: 'drift',   last: 'data/drift-last.json',   history: 'data/drift-history.json' },
  { id: 'verify',  last: 'data/verify-last.json',  history: 'data/verify-history.json' },
  { id: 'deploy',  last: 'data/deploy-last.json' },
  { id: 'agent',   last: 'data/agent-actions.json' },
];

const $ = id => document.getElementById(id);

// ---------- utilities ----------
async function safeFetchJSON(path) {
  try {
    const r = await fetch(path, { cache: 'no-store' });
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    return await r.json();
  } catch (e) {
    return { __error: e.message };
  }
}

function classifyTfsec(gate, high, critical) {
  if (gate === 'PASS')    return 'pass';
  if (gate === 'FAIL' && (high > 0 || critical > 0)) return 'fail';
  return 'unknown';
}

function classifyDrift(d) {
  if (!d || d.result === undefined) return 'unknown';
  if (d.result === 'no_drift') return 'pass';
  if (d.classification === 'safe')        return 'pass';
  if (d.classification === 'security_only') return 'frozen';
  if (d.classification === 'destructive') return 'destructive';
  if (d.result === 'drift') return 'destructive';
  return 'warn';
}

function fmtTime(ts) {
  if (!ts) return '—';
  try {
    return new Date(ts).toISOString().replace('T', ' ').replace(/\.\d+Z$/, 'Z');
  } catch { return ts; }
}

function fmtShortTime(ts) {
  if (!ts) return '—';
  try {
    return new Date(ts).toISOString().slice(11, 19) + 'Z';
  } catch { return ts; }
}

// count-up animation
function animateCount(el, target, ms = 700) {
  const start = parseInt(el.textContent, 10) || 0;
  const t0 = performance.now();
  function tick(now) {
    const t = Math.min(1, (now - t0) / ms);
    const eased = 1 - Math.pow(1 - t, 3);
    el.textContent = Math.round(start + (target - start) * eased);
    if (t < 1) requestAnimationFrame(tick);
  }
  requestAnimationFrame(tick);
}

// ---------- per-section renderers ----------
function renderTfsec(d) {
  if (!d || d.__error) {
    $('gate-verdict').textContent = '—';
    $('gate-sub').textContent = 'no data';
    return;
  }
  const gate = d.gate || 'UNKNOWN';
  const counts = d.counts || {};
  const c = {
    critical: counts.critical || 0,
    high:     counts.high || 0,
    medium:   counts.medium || 0,
    low:      counts.low || 0,
    ignored:  counts.ignored || 0,
  };
  const state = classifyTfsec(gate, c.high, c.critical);
  const card = $('card-gate');
  card.dataset.state = state;

  $('gate-tag').textContent = state === 'pass' ? 'OPEN' : (state === 'fail' ? 'BLOCKED' : 'IDLE');
  $('gate-verdict').textContent = gate;
  $('gate-sub').textContent =
    state === 'pass' ? 'deploys unblocked · agent reconcile unblocked' :
    state === 'fail' ? 'deploys blocked · agent reconcile FROZEN' :
    'awaiting scan';
  $('gate-ts').textContent = fmtTime(d.timestamp);
  $('gate-version').textContent = `tfsec ${d.tfsec_version || '—'} · pinned 1.28.5`;

  animateCount($('count-critical'), c.critical);
  animateCount($('count-high'),     c.high);
  animateCount($('count-medium'),   c.medium);
  animateCount($('count-low'),      c.low);
  animateCount($('count-ignored'),  c.ignored);

  // findings list — last run's results, if present
  const fl = $('findings-list');
  fl.innerHTML = '';
  const results = d.results || [];
  const filtered = results.filter(r => !r.ignored);
  $('findings-count').textContent = filtered.length;
  filtered.slice(0, 30).forEach(r => {
    const li = document.createElement('li');
    li.className = `sev-${(r.severity || 'low').toLowerCase()}`;
    li.innerHTML = `
      <span class="sev">${r.severity}</span>
      <span class="rule">${r.rule_id}</span>
      <span class="desc">${r.description || ''} <span style="color:var(--text-mute)">· ${r.resource || ''}</span></span>
    `;
    fl.appendChild(li);
  });
  if (filtered.length === 0) {
    fl.innerHTML = '<li style="border-left-color:transparent;color:var(--text-mute);padding:6px 10px">no open findings</li>';
  }
}

function renderDrift(d) {
  const card = $('card-drift');
  if (!d || d.__error || d.result === undefined) {
    card.dataset.state = 'unknown';
    $('drift-verdict').textContent = '—';
    $('drift-sub').textContent = 'no data';
    $('drift-class').textContent = 'classification: —';
    $('drift-changes').innerHTML = '';
    $('drift-count').textContent = '0 changes';
    return;
  }
  const state = classifyDrift(d);
  card.dataset.state = state;

  $('drift-tag').textContent =
    state === 'pass' ? 'CLEAN' :
    state === 'frozen' ? 'FROZEN' :
    state === 'destructive' ? 'DESTRUCTIVE' :
    state === 'warn' ? 'WARN' : 'IDLE';

  $('drift-verdict').textContent = d.result || '—';
  $('drift-sub').textContent =
    state === 'pass' ? 'state matches desired · no agent action needed' :
    state === 'frozen' ? 'classification requires human attention · agent refuses' :
    state === 'destructive' ? 'delete/create/replace detected · agent refuses' :
    '—';

  const cls = d.classification || 'unknown';
  const clsEl = $('drift-class');
  clsEl.textContent = `classification: ${cls}`;
  clsEl.className = 'drift-class';
  if (cls === 'safe') clsEl.classList.add('is-safe');
  else if (cls === 'destructive') clsEl.classList.add('is-destructive');
  else if (cls === 'security_only') clsEl.classList.add('is-frozen');
  else clsEl.classList.add('is-security');

  $('drift-ts').textContent = fmtTime(d.timestamp);

  const ul = $('drift-changes');
  ul.innerHTML = '';
  const changes = (d.changes || []).filter(c => !(c.actions || []).every(a => a === 'no-op'));
  $('drift-count').textContent = `${changes.length} change${changes.length === 1 ? '' : 's'}`;
  changes.slice(0, 30).forEach(c => {
    const li = document.createElement('li');
    li.innerHTML = `
      <span class="addr">${c.address}</span>
      <span class="act">[${(c.actions || []).join('|')}]</span>
    `;
    ul.appendChild(li);
  });
  if (changes.length === 0) {
    ul.innerHTML = '<li style="color:var(--text-mute)"><span class="addr">no-op across all resources</span></li>';
  }
}

function renderAgent(events) {
  const arr = Array.isArray(events) ? events : [];
  const last30 = arr.slice(-30).reverse();

  const actions   = arr.filter(e => e.kind === 'action').length;
  const noactions = arr.filter(e => e.kind === 'no_action').length;
  const frozen    = arr.filter(e => (e.reason || '').includes('FROZEN')).length;

  animateCount($('stat-actions'),   actions);
  animateCount($('stat-noactions'), noactions);
  animateCount($('stat-frozen'),    frozen);

  // determine current state from the most recent event
  let state = 'unknown';
  let pulseClass = 'idle';
  for (let i = arr.length - 1; i >= 0; i--) {
    const e = arr[i];
    if (e.kind === 'heartbeat' && e.action === 'shutdown') break;
    if (e.kind === 'action') { state = 'active'; pulseClass = ''; break; }
    if (e.kind === 'no_action' && (e.reason || '').includes('FROZEN')) { state = 'frozen'; pulseClass = 'frozen'; break; }
    if (e.kind === 'no_action' && (e.reason || '').includes('FAILED')) { state = 'fail'; pulseClass = 'fail'; break; }
  }
  const card = $('card-agent');
  card.dataset.state = state === 'active' ? 'pass' : (state === 'frozen' ? 'frozen' : (state === 'fail' ? 'fail' : 'unknown'));

  $('agent-tag').textContent = state.toUpperCase();
  $('agent-state').textContent = state;
  const pd = $('pulse-dot');
  pd.className = 'pulse-dot ' + pulseClass;

  // log window
  const win = $('log-window');
  win.innerHTML = last30.map(e => {
    const kindClass = e.kind === 'action' ? 'l-action' :
                      e.kind === 'no_action' ? 'l-noact' : 'l-kind';
    const reasonClass = (e.reason || '').includes('FROZEN') ? ' l-frozen' :
                        (e.reason || '').includes('FAIL') ? ' l-fail' : '';
    return `<span class="l-ts">[${fmtShortTime(e.timestamp)}]</span> ` +
           `<span class="${kindClass}">${e.kind}.${e.action}</span> ` +
           `<span class="${reasonClass.trim()}">${escapeHTML(e.reason || '')}</span>`;
  }).join('\n');

  $('log-count').textContent = arr.length;
}

function renderDeploy(d) {
  const card = $('card-deploy');
  if (!d || d.__error) {
    card.dataset.state = 'unknown';
    ['dep-endpoint','dep-resources','dep-ts','dep-tfsec'].forEach(id => $(id).textContent = '—');
    return;
  }
  const ok = d.status === 'success';
  card.dataset.state = ok ? 'pass' : 'fail';
  $('deploy-tag').textContent = ok ? 'OK' : 'FAIL';
  $('dep-endpoint').textContent = d.endpoint || '—';
  $('dep-resources').textContent = d.resources_created != null ? `${d.resources_created} resources` : '—';
  $('dep-ts').textContent = fmtTime(d.timestamp);
  $('dep-tfsec').textContent = d.tfsec_gate || '—';
}

function renderVerify(d) {
  const card = $('card-verify');
  if (!d || d.__error) {
    card.dataset.state = 'unknown';
    $('verify-verdict').textContent = '—';
    $('verify-sub').textContent = 'no data';
    $('verify-list').innerHTML = '';
    return;
  }
  const ok = d.all_passed === true;
  card.dataset.state = ok ? 'pass' : (d.all_passed === false ? 'fail' : 'unknown');
  $('verify-tag').textContent = ok ? 'PASS' : 'FAIL';
  $('verify-verdict').textContent = ok ? 'PASS' : 'FAIL';
  $('verify-sub').textContent = ok
    ? `${d.passed}/${d.total} resources reachable directly via floci api`
    : `${d.passed || 0}/${d.total || 0} reachable — investigate`;

  const ul = $('verify-list');
  ul.innerHTML = '';
  (d.results || []).forEach(r => {
    const li = document.createElement('li');
    li.className = r.found ? 'pass' : 'fail';
    li.textContent = `[${r.found ? '✓' : '✗'}] ${r.resource} (${r.id})  HTTP ${r.http_status}`;
    ul.appendChild(li);
  });
}

function escapeHTML(s) {
  return String(s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#039;');
}

// ---------- refresh loop ----------
async function refresh() {
  const fetched = {};
  for (const t of FETCH_TARGETS) {
    fetched[t.id] = await safeFetchJSON(t.last);
  }
  renderTfsec(fetched.tfsec);
  renderDrift(fetched.drift);
  renderAgent(fetched.agent);
  renderDeploy(fetched.deploy);
  renderVerify(fetched.verify);
  renderSyncIndicator(fetched);
  $('meta-refresh').textContent = fmtShortTime(new Date().toISOString());
}

// Holds the latest timestamp we observed across payloads. Updated by
// renderSyncIndicator; consulted by the 1-second tick.
let __latestSyncTs = null;

function renderSyncIndicator(payloads) {
  const staleWarnMs = 2 * 60 * 1000; // 2 minutes past = warn
  let latestTs = null;
  for (const k of Object.keys(payloads)) {
    const p = payloads[k];
    if (!p || p.__error) continue;
    const ts = p.timestamp || (Array.isArray(p) && p.length > 0 ? p[p.length - 1].timestamp : null);
    if (ts) {
      const t = Date.parse(ts);
      if (!isNaN(t) && (latestTs === null || t > latestTs)) latestTs = t;
    }
  }
  __latestSyncTs = latestTs;
  paintSyncIndicator();
}

function paintSyncIndicator() {
  const el = $('meta-synced');
  const warn = $('meta-stale');
  if (__latestSyncTs === null) {
    el.textContent = 'never';
    warn.classList.remove('visible');
    warn.removeAttribute('data-age');
    return;
  }
  const ageMs = Date.now() - __latestSyncTs;
  el.textContent = fmtAge(ageMs);
  if (ageMs > 5 * 60 * 1000) {
    warn.classList.add('visible');
    warn.setAttribute('data-age', 'critical');
  } else if (ageMs > 2 * 60 * 1000) {
    warn.classList.add('visible');
    warn.setAttribute('data-age', 'warn');
  } else {
    warn.classList.remove('visible');
    warn.removeAttribute('data-age');
  }
}

function fmtAge(ms) {
  const s = Math.floor(ms / 1000);
  if (s < 60) return `${s}s ago`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ${s % 60}s ago`;
  const h = Math.floor(m / 60);
  return `${h}h ${m % 60}m ago`;
}

refresh();
// Re-fetch from server every REFRESH_MS to pick up new JSON.
setInterval(refresh, REFRESH_MS);
// Re-paint the staleness counter every second so "Xs ago" stays fresh
// even between fetches. This does NOT change any data — just the label.
setInterval(paintSyncIndicator, 1000);
