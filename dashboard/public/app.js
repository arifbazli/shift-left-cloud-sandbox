/* ============================================================
   Salus · Shift-Left Sandbox — dashboard renderer
   Static-only. Fetches JSON files from data/. No KV, no D1,
   no Workers, no external calls beyond these files.
   ============================================================ */

'use strict';

const REFRESH_MS = 10_000;

const FETCH_TARGETS = [
  'data/tfsec-last.json',
  'data/deploy-last.json',
  'data/verify-last.json',
  'data/drift-last.json',
  'data/agent-actions.json',
];

// ── utils ──────────────────────────────────────────────────
const $  = id => document.getElementById(id);

async function safeFetch(path) {
  try {
    const r = await fetch(path, { cache: 'no-store' });
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    return await r.json();
  } catch (e) {
    return { __error: e.message };
  }
}

function fmtTs(ts) {
  if (!ts) return '—';
  try {
    const d = new Date(ts);
    return d.toLocaleDateString('en-GB', { day: 'numeric', month: 'short' })
      + ' ' + d.toTimeString().slice(0, 5);
  } catch { return ts; }
}

function fmtAge(ms) {
  const s = Math.floor(ms / 1000);
  if (s < 60)  return `${s}s ago`;
  const m = Math.floor(s / 60);
  if (m < 60)  return `${m}m ${s % 60}s ago`;
  return `${Math.floor(m / 60)}h ${m % 60}m ago`;
}

function pill(cls, label) {
  return `<span class="pill pill-${cls}">${label}</span>`;
}

function animCount(el, target, ms = 600) {
  const start = parseInt(el.textContent, 10) || 0;
  const t0 = performance.now();
  const tick = now => {
    const p = Math.min(1, (now - t0) / ms);
    const e = 1 - Math.pow(1 - p, 3);
    el.textContent = Math.round(start + (target - start) * e);
    if (p < 1) requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
}

function flashCard(id) {
  const el = $(id);
  el.classList.remove('card-updated');
  void el.offsetWidth; // reflow to restart animation
  el.classList.add('card-updated');
}

function showCard(id, hasData, isEmpty) {
  $(id.replace('card-', 'skel-')).hidden = true;
  if (hasData && !isEmpty) {
    $(id.replace('card-', 'body-')).hidden = false;
    $(id.replace('card-', 'empty-')).hidden = true;
  } else {
    $(id.replace('card-', 'body-')).hidden = true;
    $(id.replace('card-', 'empty-')).hidden = false;
  }
}

// ── staleness ──────────────────────────────────────────────
let __latestTs = null;

function paintStale() {
  const badge = $('stale-badge');
  if (__latestTs === null) { badge.className = ''; return; }
  const age = Date.now() - __latestTs;
  if (age > 5 * 60_000) {
    badge.className = 'crit';
    badge.textContent = `stale ${fmtAge(age)}`;
  } else if (age > 2 * 60_000) {
    badge.className = 'warn';
    badge.textContent = `stale ${fmtAge(age)}`;
  } else {
    badge.className = '';
  }
}

function updateLatestTs(payloads) {
  let latest = null;
  for (const d of payloads) {
    if (!d || d.__error) continue;
    const ts = d.timestamp
      || (Array.isArray(d) && d.length ? d[d.length - 1].timestamp : null);
    if (ts) {
      const t = Date.parse(ts);
      if (!isNaN(t) && (latest === null || t > latest)) latest = t;
    }
  }
  __latestTs = latest;
  paintStale();
}

// ── renderers ──────────────────────────────────────────────

function renderScan(d) {
  const cardId = 'card-scan';
  if (!d || d.__error) {
    $('pill-scan').outerHTML = pill('none', '—');
    showCard(cardId, true, true);
    return;
  }

  const c = d.counts || {};
  const crit = c.critical || 0, high = c.high || 0,
        med  = c.medium  || 0, low  = c.low   || 0, ign = c.ignored || 0;
  const gate = d.gate || 'UNKNOWN';
  const pass = gate === 'PASS';

  $('pill-scan').outerHTML = pill(pass ? 'pass' : 'fail', gate);
  $(cardId).dataset.state = pass ? 'pass' : 'fail';
  showCard(cardId, true, false);

  animCount($('cnt-critical'), crit);
  animCount($('cnt-high'),     high);
  animCount($('cnt-medium'),   med);
  animCount($('cnt-low'),      low);
  animCount($('cnt-ignored'),  ign);

  $('scan-ts').textContent  = fmtTs(d.timestamp);
  $('scan-ver').textContent = `tfsec ${d.tfsec_version || '—'}`;
  flashCard(cardId);
}

function renderDeploy(d) {
  const cardId = 'card-deploy';
  if (!d || d.__error) {
    $('pill-deploy').outerHTML = pill('none', '—');
    showCard(cardId, true, true);
    return;
  }

  const ok = d.status === 'success';
  $('pill-deploy').outerHTML = pill(ok ? 'pass' : 'fail', ok ? 'PASS' : 'FAIL');
  $(cardId).dataset.state = ok ? 'pass' : 'fail';
  showCard(cardId, true, false);

  $('dep-endpoint').textContent  = d.endpoint || '—';
  $('dep-resources').textContent = d.resources_created != null
    ? `${d.resources_created} resources` : '—';
  $('dep-gate').textContent = d.tfsec_gate || '—';
  $('dep-ts').textContent   = fmtTs(d.timestamp);
  flashCard(cardId);
}

function renderVerify(d) {
  const cardId = 'card-verify';
  if (!d || d.__error) {
    $('pill-verify').outerHTML = pill('none', '—');
    showCard(cardId, true, true);
    return;
  }

  const ok = d.all_passed === true;
  const pillCls = ok ? 'pass' : (d.all_passed === false ? 'fail' : 'warn');
  $('pill-verify').outerHTML = pill(pillCls, ok ? 'PASS' : 'FAIL');
  $(cardId).dataset.state = ok ? 'pass' : 'fail';
  showCard(cardId, true, false);

  $('ver-endpoint').textContent = d.endpoint || '—';
  $('ver-passed').textContent   = `${d.passed ?? '?'} / ${d.total ?? '?'}`;
  $('ver-detail').textContent   = ok ? 'all resources reachable' : 'check verify-last.json';
  $('ver-ts').textContent       = fmtTs(d.timestamp);
  flashCard(cardId);
}

function renderDrift(d) {
  const cardId = 'card-drift';
  if (!d || d.__error || d.result === undefined) {
    $('pill-drift').outerHTML = pill('none', '—');
    showCard(cardId, true, true);
    return;
  }

  const cls  = d.classification || 'unknown';
  const res  = d.result || 'unknown';
  const clean = res === 'no_drift';
  const pillCls = clean ? 'pass'
    : cls === 'safe' ? 'warn'
    : cls === 'destructive' || cls === 'security_only' ? 'fail'
    : 'warn';
  const pillLabel = clean ? 'CLEAN'
    : cls === 'destructive' ? 'DESTRUCTIVE'
    : cls === 'security_only' ? 'FROZEN'
    : cls === 'safe' ? 'DRIFT' : 'DRIFT';

  $('pill-drift').outerHTML = pill(pillCls, pillLabel);
  $(cardId).dataset.state = clean ? 'pass'
    : cls === 'destructive' || cls === 'security_only' ? 'fail' : 'warn';
  showCard(cardId, true, false);

  $('drift-class').textContent = `classification: ${cls}`;
  $('drift-ts').textContent = fmtTs(d.timestamp);

  const changes = (d.changes || []).filter(c => !(c.actions || []).every(a => a === 'no-op'));
  $('drift-count').textContent = `${changes.length} change${changes.length === 1 ? '' : 's'}`;

  const ul = $('drift-changes');
  ul.innerHTML = changes.length === 0
    ? '<li class="dim"><span class="addr">no-op across all resources</span></li>'
    : changes.slice(0, 20).map(c =>
        `<li><span class="addr">${escHtml(c.address)}</span><span class="act">[${(c.actions || []).join('|')}]</span></li>`
      ).join('');

  flashCard(cardId);
}

function renderAgent(d) {
  const cardId = 'card-agent';
  const arr = Array.isArray(d) ? d : [];

  if (!d || d.__error || arr.length === 0) {
    $('pill-agent').outerHTML = pill('none', 'IDLE');
    showCard(cardId, true, true);
    return;
  }

  // last 5 non-heartbeat events
  const events = arr.filter(e => e.kind !== 'heartbeat').slice(-5).reverse();
  const heartbeats = arr.filter(e => e.kind === 'heartbeat');
  const lastHb = heartbeats.length ? heartbeats[heartbeats.length - 1] : null;

  // determine pill state from most recent meaningful event
  const lastMeaningful = arr.slice().reverse().find(e => e.kind !== 'heartbeat');
  let pillCls = 'info', pillLabel = 'RUNNING';
  if (lastMeaningful) {
    if ((lastMeaningful.reason || '').includes('FROZEN')) { pillCls = 'warn'; pillLabel = 'FROZEN'; }
    else if (lastMeaningful.kind === 'action') { pillCls = 'pass'; pillLabel = 'ACTIVE'; }
    else { pillCls = 'info'; pillLabel = 'IDLE'; }
  }

  $('pill-agent').outerHTML = pill(pillCls, pillLabel);
  $(cardId).dataset.state = pillCls === 'pass' ? 'pass' : pillCls === 'warn' ? 'warn' : 'pass';
  showCard(cardId, true, false);

  const ul = $('agent-list');
  ul.innerHTML = events.map(e => {
    const kindCls = (e.reason || '').includes('FROZEN') ? 'frozen' : (e.kind || 'heartbeat');
    return `<li>
      <div style="display:flex;justify-content:space-between;align-items:center;">
        <span class="act-kind ${kindCls}">${e.kind || '—'}.${e.action || '—'}</span>
        <span class="act-ts">${fmtTs(e.timestamp)}</span>
      </div>
      ${e.reason ? `<div class="act-reason">${escHtml(e.reason)}</div>` : ''}
    </li>`;
  }).join('');

  $('agent-heartbeat').textContent = lastHb
    ? `last heartbeat: ${fmtTs(lastHb.timestamp)}`
    : 'last heartbeat: —';

  flashCard(cardId);
}

function escHtml(s) {
  return String(s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;')
    .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

// ── refresh ────────────────────────────────────────────────
async function fetchAll() {
  const [tfsec, deploy, verify, drift, agent] = await Promise.all(
    FETCH_TARGETS.map(safeFetch)
  );
  renderScan(tfsec);
  renderDeploy(deploy);
  renderVerify(verify);
  renderDrift(drift);
  renderAgent(agent);
  updateLatestTs([tfsec, deploy, verify, drift, agent]);
}

// show skeletons on first load (already visible via HTML), then fetch
fetchAll();
setInterval(fetchAll, REFRESH_MS);
setInterval(paintStale, 1000);

$('btn-refresh').addEventListener('click', () => {
  $('btn-refresh').textContent = '↻ …';
  fetchAll().finally(() => { $('btn-refresh').textContent = '↻ Refresh'; });
});
