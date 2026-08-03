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
const $ = id => document.getElementById(id);

async function safeFetch(path) {
  try {
    const r = await fetch(path, { cache: 'no-store' });
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    return await r.json();
  } catch (e) {
    return { __error: e.message };
  }
}

// Normalise any timestamp string to something Date() can parse.
// Handles compact "20260803T020245Z" (no dashes/colons) that deploy.sh emits.
function normaliseTs(ts) {
  if (!ts) return null;
  // Already valid ISO: contains dashes or is purely numeric milliseconds
  if (ts.includes('-') || /^\d{13,}$/.test(ts)) return ts;
  // Compact basic format YYYYMMDDTHHMMSS[Z] → YYYY-MM-DDTHH:MM:SS[Z]
  const m = ts.match(/^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(Z?)$/);
  if (m) return `${m[1]}-${m[2]}-${m[3]}T${m[4]}:${m[5]}:${m[6]}${m[7]}`;
  return ts;
}

function fmtTs(ts) {
  if (!ts) return '—';
  try {
    const d = new Date(normaliseTs(ts));
    if (isNaN(d.getTime())) return ts;
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

// Set pill className + text directly (no outerHTML swap — preserves the
// element reference between renders).
// cls: pass | fail | warn | idle
function setPill(id, cls, label) {
  const el = $(id);
  el.className = `pill ${cls}`;
  el.textContent = label;
}

function setCardState(id, state) {
  // state: pass | fail | warn | '' (unknown)
  const el = $(id);
  el.classList.remove('state-pass', 'state-fail', 'state-warn');
  if (state) el.classList.add(`state-${state}`);
}

function animCount(el, target, ms = 600) {
  // Respect prefers-reduced-motion: skip tween entirely.
  const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  if (reduce) { el.textContent = target; el._lastVal = target; return; }
  // Clamp target to safe integer range — never let a corrupted cache make us
  // display a negative billion.
  const safeTarget = Math.max(0, Math.min(999, target | 0));
  // Read from cached previous value, not live textContent, so stale values
  // from interrupted tweens don't pollute the start.
  const start = (typeof el._lastVal === 'number') ? el._lastVal
              : Math.max(0, Math.min(999, parseInt(el.textContent, 10) || 0));
  el._lastVal = start;
  if (start === safeTarget) { el.textContent = safeTarget; return; }
  // Cancel any in-flight tween on this element before starting a new one.
  if (el._rafId) cancelAnimationFrame(el._rafId);
  const t0 = Date.now();
  const tick = () => {
    if (document.hidden) { el.textContent = safeTarget; el._lastVal = safeTarget; el._rafId = null; return; }
    const p = Math.min(1, Math.max(0, (Date.now() - t0) / ms));
    const e = 1 - Math.pow(1 - p, 3);
    const v = Math.round(start + (safeTarget - start) * e);
    el.textContent = v;
    if (p < 1) {
      el._rafId = requestAnimationFrame(tick);
    } else {
      el.textContent = safeTarget;
      el._lastVal = safeTarget;
      el._rafId = null;
    }
  };
  el._rafId = requestAnimationFrame(tick);
}

// Hide skeleton, show body or empty-state
function showCard(id, hasData, isEmpty) {
  const skel  = $(id.replace('card-', 'skel-'));
  const body  = $(id.replace('card-', 'body-'));
  const empty = $(id.replace('card-', 'empty-'));
  if (skel)  skel.hidden  = true;
  if (body)  body.hidden  = hasData && !isEmpty ? false : true;
  if (empty) empty.hidden = hasData && !isEmpty ? true  : false;
}

function escHtml(s) {
  return String(s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;')
    .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

// ── staleness ──────────────────────────────────────────────
let __latestTs = null;

function paintStale() {
  const dot  = $('sync-dot');
  const text = $('sync-text');
  if (!dot || !text) return;
  if (__latestTs === null) {
    dot.className = 'dot stale';
    text.textContent = 'no data';
    return;
  }
  const age = Date.now() - __latestTs;
  if (age > 5 * 60_000) {
    dot.className = 'dot dead';
    text.textContent = `stale ${fmtAge(age)}`;
  } else if (age > 2 * 60_000) {
    dot.className = 'dot stale';
    text.textContent = `synced ${fmtAge(age)}`;
  } else {
    dot.className = 'dot';
    text.textContent = `synced ${fmtAge(age)}`;
  }
}

function updateLatestTs(payloads) {
  let latest = null;
  for (const d of payloads) {
    if (!d || d.__error) continue;
    const ts = d.timestamp
      || (Array.isArray(d) && d.length ? d[d.length - 1].timestamp : null);
    if (ts) {
      const t = Date.parse(normaliseTs(ts));
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
    setPill('pill-scan', 'idle', '—');
    showCard(cardId, true, true);
    $('findings-list').innerHTML = '<div class="empty-state">No scan data yet.</div>';
    $('findings-count').textContent = '0 total';
    return;
  }

  const c    = d.counts || {};
  const crit = c.critical || 0, high = c.high || 0,
        med  = c.medium   || 0, low  = c.low  || 0, ign = c.ignored || 0;
  const gate = d.gate || 'UNKNOWN';
  const pass = gate === 'PASS';

  // Pill shows gate + finding count so PASS is honest about what’s underneath.
  // PASS · 3 medium  >  PASS  (when medium findings exist)
  // PASS · clean     >  PASS  (when zero findings)
  const findings = d.findings || d.results || [];
  const nonLow = findings.filter(r => {
    const s = (r.severity || '').toUpperCase();
    return s !== 'LOW' && s !== 'INFO' && s !== 'IGNORED';
  }).length;
  const pillLabel = pass
    ? (nonLow > 0 ? `PASS · ${nonLow}` : 'PASS · clean')
    : gate;

  setPill('pill-scan', pass ? 'pass' : 'fail', pillLabel);
  setCardState(cardId, pass ? 'pass' : 'fail');
  showCard(cardId, true, false);

  animCount($('cnt-critical'), crit);
  animCount($('cnt-high'),     high);
  animCount($('cnt-medium'),   med);
  animCount($('cnt-low'),      low);
  animCount($('cnt-ignored'),  ign);

  $('scan-ts').textContent  = fmtTs(d.timestamp);
  $('scan-ver').textContent = '';  // tfsec_version field doesn't exist in real JSON; keep row clean

  // findings list
  // JSON key is "findings" (not "results"); findings have no "ignored" field
  $('findings-count').textContent = `${findings.length} total`;
  const findingsWrap = document.querySelector('.findings-wrap');
  if (findingsWrap) findingsWrap.classList.toggle('is-empty', findings.length === 0);
  $('findings-list').innerHTML = findings.length === 0
    ? '<div class="empty-state">No open findings — gate is clean.</div>'
    : findings.slice(0, 30).map(r => {
        const sev  = (r.severity || 'low').toLowerCase();
        const bCls = sev === 'critical' ? 'crit' : sev;
        return `<div class="list-row">
          <span class="sev-badge ${bCls}">${r.severity}</span>
          <span class="rule-id">${escHtml(r.rule_id || '')}</span>
          <span class="rule-desc">${escHtml(r.description || '')}</span>
          <span class="rule-res">${escHtml(r.resource || '')}</span>
        </div>`;
      }).join('');
}

function renderDeploy(d) {
  const cardId = 'card-deploy';
  if (!d || d.__error) {
    setPill('pill-deploy', 'idle', '—');
    showCard(cardId, true, true);
    return;
  }

  // deploy-last.json schema: {timestamp, endpoint, outputs:{…}, state_snapshot,
  // pages_url, pages_deploy_at}  — no "status" or "resources_created" fields.
  // Infer success from presence of outputs keys.
  const outputKeys = Object.keys(d.outputs || {});
  const ok = outputKeys.length > 0;
  setPill('pill-deploy', ok ? 'pass' : 'fail', ok ? 'PASS' : 'FAIL');
  setCardState(cardId, ok ? 'pass' : 'fail');
  showCard(cardId, true, false);

  $('dep-endpoint').textContent  = d.endpoint || '—';
  $('dep-endpoint').title        = d.endpoint || '';  // hover shows full URL
  $('dep-resources').textContent = outputKeys.length
    ? `${outputKeys.length} outputs` : '—';
  $('dep-gate').textContent = d.pages_url ? 'synced' : 'local only';
  $('dep-gate').title = d.pages_url || '';
  $('dep-ts').textContent   = fmtTs(d.timestamp);
}

function renderVerify(d) {
  const cardId = 'card-verify';
  if (!d || d.__error) {
    setPill('pill-verify', 'idle', '—');
    showCard(cardId, true, true);
    return;
  }

  const ok      = d.all_passed === true;
  const pillCls = ok ? 'pass' : (d.all_passed === false ? 'fail' : 'warn');
  setPill('pill-verify', pillCls, ok ? 'PASS' : 'FAIL');
  setCardState(cardId, ok ? 'pass' : 'fail');
  showCard(cardId, true, false);

  $('ver-endpoint').textContent = d.endpoint || '—';
  $('ver-passed').textContent   = `${d.passed ?? '?'} / ${d.total ?? '?'}`;
  $('ver-detail').textContent   = ok ? 'all resources reachable' : 'check verify-last.json';
  $('ver-ts').textContent       = fmtTs(d.timestamp);
}

function renderDrift(d) {
  const cardId = 'card-drift';
  if (!d || d.__error || d.result === undefined) {
    setPill('pill-drift', 'idle', '—');
    showCard(cardId, true, true);
    return;
  }

  const cls   = d.classification || 'unknown';
  const clean = d.result === 'no_drift';
  // Color logic:
  //   pass  - clean / no drift (green)
  //   warn  - drift detected but agent is still able to reason about it
  //           (safe = could auto-fix, destructive = held back, security_only = blocked)
  //   fail  - reserved for HTTP-level failures, not policy decisions
  const pillCls = clean ? 'pass' : 'warn';
  const pillLabel = clean ? 'CLEAN'
    : cls === 'safe'           ? 'DRIFT · safe'
    : cls === 'destructive'    ? 'HELD · destructive'
    : cls === 'security_only'  ? 'FROZEN · security'
    : 'DRIFT';

  setPill('pill-drift', pillCls, pillLabel);
  setCardState(cardId, clean ? 'pass' : 'warn');
  showCard(cardId, true, false);

  $('drift-class').textContent = `classification: ${cls}`;
  $('drift-ts').textContent    = fmtTs(d.timestamp);

  const changes = (d.changes || []).filter(c => !(c.actions || []).every(a => a === 'no-op'));
  $('drift-count').textContent = `${changes.length} change${changes.length === 1 ? '' : 's'}`;

  $('drift-changes').innerHTML = changes.length === 0
    ? '<div class="list-row"><span class="list-mono" style="color:var(--text-muted)">no-op across all resources</span></div>'
    : changes.slice(0, 20).map(c => {
        const acts = (c.actions || []).join('|');
        // Red only for actual delete/create (destructive change).
        // Everything else is warn (in-place update) or idle (no-op).
        const aCls = acts.includes('delete') || acts.includes('create') ? 'warn'
                  : acts.includes('update') ? 'idle'
                  : 'idle';
        return `<div class="list-row">
          <span class="pill ${aCls}" style="font-size:10px;padding:1px 7px;border-radius:5px;flex-shrink:0">${acts}</span>
          <span class="list-mono" title="${escHtml(c.address)}">${escHtml(c.address)}</span>
        </div>`;
      }).join('');
}

function renderAgent(d) {
  const cardId = 'card-agent';
  const arr = Array.isArray(d) ? d : [];

  if (!d || d.__error || !Array.isArray(d)) {
    setPill('pill-agent', 'idle', 'IDLE');
    // Show real error in empty-state instead of leaving skeleton up
    const emptyEl = $('empty-agent');
    if (emptyEl && d && d.__error) {
      emptyEl.innerHTML = `Could not load agent-actions.json: <code>${escHtml(d.__error)}</code>`;
    }
    showCard(cardId, true, true);
    return;
  }

  // Deduplicate consecutive identical reasons so <n> identical rows don't
  // visually flood the card. Keep the most recent; collapse the rest into one
  // summary row.
  const events  = arr.filter(e => e.kind !== 'heartbeat').slice(-5).reverse();
  const deduped = [];
  for (const e of events) {
    const prev = deduped[deduped.length - 1];
    if (prev && prev.kind === e.kind && prev.action === e.action
             && prev.reason === e.reason) {
      prev._count = (prev._count || 1) + 1;
    } else {
      deduped.push({ ...e, _count: 1 });
    }
  }
  const lastHb  = arr.filter(e => e.kind === 'heartbeat').pop() || null;
  const lastEvt = arr.slice().reverse().find(e => e.kind !== 'heartbeat');

  // Distinguish 3 states:
  //   IDLE     — no events at all (loop never started)
  //   WATCHING — loop is running but last event was no_action (the common case
  //             when the agent decides to stand down)
  //   ACTIVE   — last event was a real action (restart / apply_drift)
  //   FROZEN   — tfsec gate is holding the agent back
  let pillCls = 'idle', pillLabel = 'IDLE';
  if (lastEvt) {
    if ((lastEvt.reason || '').includes('FROZEN')) { pillCls = 'warn'; pillLabel = 'FROZEN'; }
    else if (lastEvt.kind === 'action')             { pillCls = 'pass'; pillLabel = 'ACTIVE'; }
    else if (lastEvt.kind === 'no_action')          { pillCls = 'idle'; pillLabel = 'WATCHING'; }
  }

  setPill('pill-agent', pillCls, pillLabel);
  setCardState(cardId, pillCls === 'fail' ? 'fail' : pillCls === 'warn' ? 'warn' : 'pass');
  showCard(cardId, true, false);

  $('agent-list').innerHTML = deduped.map(e => {
    const kindCls = (e.reason || '').includes('FROZEN') ? 'frozen' : (e.kind || 'no_action');
    const countTxt = e._count > 1 ? ` <span class="act-count">×${e._count}</span>` : '';
    const reasonHtml = e.reason
      ? `<div class="act-reason" title="${escHtml(e.reason)}">${escHtml(e.reason)}</div>`
      : '';
    return `<div class="agent-row ${e.kind}">
      <div class="agent-row-head">
        <span class="act-kind ${kindCls}">${e.kind}.${e.action || '—'}${countTxt}</span>
        <span class="list-ts">${fmtTs(e.timestamp)}</span>
      </div>
      ${reasonHtml}
    </div>`;
  }).join('');

  $('agent-heartbeat').textContent = lastHb ? fmtTs(lastHb.timestamp) : '—';
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

// Announce refreshes to screen readers via a polite live region.
const liveEl = $('aria-live');
async function fetchAllAndAnnounce() {
  await fetchAll();
  if (liveEl) liveEl.textContent = `Dashboard refreshed at ${fmtTs(new Date().toISOString())}`;
}

fetchAllAndAnnounce();
setInterval(fetchAllAndAnnounce, REFRESH_MS);
setInterval(paintStale, 1000);

// Sync dot is a click-to-refresh affordance. Make it accessible.
const syncEl = $('sync-status');
if (syncEl) {
  syncEl.setAttribute('role', 'button');
  syncEl.setAttribute('tabindex', '0');
  syncEl.setAttribute('aria-label', 'Refresh dashboard');
  syncEl.addEventListener('click', e => { e.preventDefault(); fetchAllAndAnnounce(); });
  syncEl.addEventListener('keydown', e => {
    if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); fetchAllAndAnnounce(); }
  });
}
