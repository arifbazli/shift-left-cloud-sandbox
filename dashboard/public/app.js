/* ============================================================
   Salus · Shift-Left Sandbox — dashboard renderer

   Live mode  : connects to data-server.py SSE stream at
                http://localhost:7788/live  (1-second updates)
   Fallback   : fetches JSON files from data/ every 10 s
                (works on Cloudflare Pages with no server)
   ============================================================ */

'use strict';

// ── utils ──────────────────────────────────────────────────
const $ = id => document.getElementById(id);

function getRefreshMs() {
  let fromQuery = null, fromStorage = null;
  try { fromQuery = parseInt(new URLSearchParams(location.search).get('refresh'), 10); } catch {}
  try { fromStorage = parseInt(localStorage.getItem('dashboard.refreshMs'), 10); } catch {}
  const ms = fromQuery || fromStorage || 10_000;
  return Math.max(2_000, ms);   // never poll faster than 2s
}
const REFRESH_MS    = getRefreshMs();   // ?refresh=<ms> or localStorage 'dashboard.refreshMs'
const DATA_SERVER   = 'http://localhost:7788';  // local data-server

// Absolute paths, not relative -- app.js is now loaded from two different
// nested pages (/aws/, /azure/), and a relative 'data/...' path resolves
// against the PAGE's URL, not the script's location. A relative path here
// would 404 as /aws/data/tfsec-last.json instead of the real /data/... .
// Confirmed via a real fetch test after the routing split (findings-list
// silently fell back to "No scan data yet" -- every fetch was 404ing).
const FETCH_TARGETS = [
  '/data/tfsec-last.json',
  '/data/deploy-last.json',
  '/data/growth-last.json',
  '/data/verify-last.json',
  '/data/drift-last.json',
  '/data/agent-actions.json',
];

// Azure page data -- fetched independently of the AWS SSE/poll path above.
// data-server.py's live snapshot only knows about the AWS files, so every
// Azure card polls on its own cadence, never pushed over SSE. All 5 have
// real scripts and real data as of the verify/drift/agent-loop siblings
// merged 2026-08-14 -- deploy has no fetch target, it's a static
// permanent-gap card (see azure/index.html), not data-driven.
const FETCH_TARGETS_AZURE = [
  '/data/tfsec-azure-last.json',
  '/data/growth-last-azure.json',
  '/data/verify-last-azure.json',
  '/data/drift-last-azure.json',
  '/data/agent-actions-azure.json',
];

// fmtDataAge: given epoch seconds (file mtime), return e.g. "3s ago" / "2m ago"
function fmtDataAge(epochSec) {
  if (!epochSec) return '—';
  const diff = Math.floor(Date.now() / 1000 - epochSec);
  if (diff < 5)   return 'just now';
  if (diff < 60)  return `${diff}s ago`;
  if (diff < 3600) return `${Math.floor(diff/60)}m ago`;
  return `${Math.floor(diff/3600)}h ago`;
}

// Store latest mtimes from SSE snapshot for the live age ticker
const _cardMtimes = {};
setInterval(() => {
  ['scan','deploy','verify','drift','agent'].forEach(name => {
    const el = $(`${name}-age`);
    if (el && _cardMtimes[name]) el.textContent = fmtDataAge(_cardMtimes[name]);
  });
}, 1000);

async function safeFetch(path) {
  try {
    const r = await fetch(path, { cache: 'no-store' });
    if (!r.ok) return { __error: `HTTP ${r.status}` };
    return await r.json();
  } catch (e) {
    return { __error: e.message, __networkError: true };
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

// ── sparklines (reads *-history.json, independent of the SSE/poll path
//    since data-server.py's SSE snapshot only carries *-last.json) ──────
const HISTORY_TARGETS = {
  scan:   '/data/tfsec-history.json',
  deploy: '/data/deploy-history.json',
  growth: '/data/growth-history.json',
  verify: '/data/verify-history.json',
  drift:  '/data/drift-history.json',
  'scan-azure':   '/data/tfsec-azure-history.json',
  'growth-azure': '/data/growth-history-azure.json',
  'verify-azure': '/data/verify-history-azure.json',
  'drift-azure':  '/data/drift-history-azure.json',
};
const HISTORY_POLL_MS = 30_000;

function renderSparkline(svgId, values) {
  const svg = $(svgId);
  if (!svg) return;
  const pts = (values || []).filter(v => typeof v === 'number' && !isNaN(v));
  if (pts.length < 2) { svg.innerHTML = ''; return; }
  const w = 100, h = 24, pad = 2;
  const min = Math.min(...pts), max = Math.max(...pts);
  const range = max - min || 1;
  const step = (w - pad * 2) / (pts.length - 1);
  const coords = pts.map((v, i) => {
    const x = pad + i * step;
    const y = pad + (h - pad * 2) * (1 - (v - min) / range);
    return `${x.toFixed(1)},${y.toFixed(1)}`;
  });
  const fillPts = `${pad},${h - pad} ${coords.join(' ')} ${w - pad},${h - pad}`;
  svg.innerHTML =
    `<polygon class="spark-fill" points="${fillPts}"></polygon>` +
    `<polyline class="spark-line" points="${coords.join(' ')}"></polyline>`;
}

async function fetchHistories() {
  const entries = await Promise.all(
    Object.entries(HISTORY_TARGETS).map(async ([key, path]) => [key, await safeFetch(path)])
  );
  for (const [key, data] of entries) {
    if (!data || data.__error || !Array.isArray(data)) continue;
    const recent = data.slice(-20);
    let series = null;
    if (key === 'scan')   series = recent.map(r => (r.counts?.critical || 0) + (r.counts?.high || 0));
    if (key === 'deploy') series = recent.map(r => Object.keys(r.outputs || {}).length);
    if (key === 'growth') series = recent.map(r => r.applied_count || 0);
    if (key === 'verify') series = recent.map(r => (r.total ? r.passed / r.total : 0));
    if (key === 'drift')  series = recent.map(r => (r.changes || []).filter(c => !(c.actions || []).every(a => a === 'no-op')).length);
    if (key === 'scan-azure')   series = recent.map(r => (r.counts?.critical || 0) + (r.counts?.high || 0));
    if (key === 'growth-azure') series = recent.map(r => r.applied_count || 0);
    if (key === 'verify-azure') series = recent.map(r => (r.total ? r.found / r.total : 0));
    if (key === 'drift-azure')  series = recent.map(r => (r.changes || []).length);
    if (series) renderSparkline(`spark-${key}`, series);
  }
}

// Independent fetch cycle for the Azure page's 5 real cards (deploy is a
// static permanent-gap card, not data-driven -- see azure/index.html).
// Not part of applySnapshot()/the SSE path -- see FETCH_TARGETS_AZURE above.
async function fetchAllAzure() {
  const results = await Promise.all(FETCH_TARGETS_AZURE.map(safeFetch));
  const [scanAzure, growthAzure, verifyAzure, driftAzure, agentAzure] = results;
  if (results.every(d => d && d.__networkError)) {
    showToast('Can’t reach dashboard data — retrying…');
  } else {
    hideToast();
  }
  const renderers = [
    ['renderScanAzure',   () => renderScanAzure(scanAzure)],
    ['renderGrowthAzure', () => renderGrowthAzure(growthAzure)],
    ['renderVerifyAzure', () => renderVerifyAzure(verifyAzure)],
    ['renderDriftAzure',  () => renderDriftAzure(driftAzure)],
    ['renderAgentAzure',  () => renderAgentAzure(agentAzure)],
  ];
  for (const [name, fn] of renderers) {
    try { fn(); } catch (e) { console.error(`${name} failed:`, e); }
  }
  // Keeps the sync-status dot/text meaningful on the Azure page too --
  // without this, __latestTs (set only from the AWS path) would stay
  // null forever here and the header would perpetually show "no data"
  // even while Azure's own cards are loading fine.
  updateLatestTs([scanAzure, growthAzure, verifyAzure, driftAzure, agentAzure]);
  if (liveEl) liveEl.textContent = `Dashboard refreshed at ${fmtTs(new Date().toISOString())}`;
}

// ── fetch-error toast ──────────────────────────────────────────────────
let _toastHideTimer = null;
function showToast(msg) {
  const t = $('toast'), m = $('toast-msg');
  if (!t || !m) return;
  m.textContent = msg;
  t.hidden = false;
  clearTimeout(_toastHideTimer);
  _toastHideTimer = setTimeout(hideToast, 8000);
}
function hideToast() { const t = $('toast'); if (t) t.hidden = true; }
$('toast-dismiss')?.addEventListener('click', hideToast);

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

// Map resource-type prefix to module name for grouping the findings list.
// Shared by both clouds' scan cards (renderScanGeneric below).
const AWS_MODULE_MAP = [
  ['aws_vpc', 'network'],       ['aws_subnet', 'network'],
  ['aws_security_group', 'network'], ['aws_flow_log', 'network'],
  ['aws_s3_bucket', 'storage'], ['aws_dynamodb', 'storage'],
  ['aws_instance', 'compute'],  ['aws_launch', 'compute'],
  ['aws_lambda', 'compute'],    ['aws_ecs', 'compute'],    ['aws_eks', 'compute'],
  ['aws_sqs', 'messaging'],     ['aws_sns', 'messaging'],
  ['aws_cloudwatch_event', 'messaging'], ['aws_sfn', 'messaging'],
  ['aws_db_', 'data'],          ['aws_rds', 'data'],
  ['aws_elasticache', 'data'],  ['aws_msk', 'data'],       ['aws_opensearch', 'data'],
  ['aws_iam', 'security'],      ['aws_kms', 'security'],
  ['aws_secretsmanager', 'security'], ['aws_acm', 'security'],
  ['aws_api_gateway', 'api'],   ['aws_cloudwatch_log', 'api'],
  ['aws_cloudwatch_metric', 'api'],
];
const AZURE_MODULE_MAP = [
  ['azurerm_resource_group', 'network'], ['azurerm_virtual_network', 'network'],
  ['azurerm_subnet', 'network'],         ['azurerm_network_security', 'network'],
  ['azurerm_storage', 'storage'],
  ['azurerm_key_vault', 'security'],
  ['azurerm_linux_virtual_machine', 'compute'], ['azurerm_network_interface', 'compute'],
  ['azurerm_service_plan', 'compute'],   ['azurerm_linux_function_app', 'compute'],
  ['azurerm_kubernetes_cluster', 'compute'], ['tls_private_key', 'compute'],
];
// Most tfsec findings in this repo are attributed at the MODULE level
// (resource: "module.storage", "module.azure-security", not a specific
// address) -- confirmed directly against the real pinned binary for both
// clouds. Handle that shape first; fall back to the resource-type-prefix
// map for the findings that DO carry a full address (e.g. "aws_db_instance.main").
function getModule(resource, moduleMap) {
  if (!resource) return 'other';
  const modMatch = resource.match(/^module\.(azure-)?([a-z]+)/);
  if (modMatch) return modMatch[2];
  const map = moduleMap || AWS_MODULE_MAP;
  const entry = map.find(([prefix]) => resource.startsWith(prefix));
  return entry ? entry[1] : 'other';
}

// Generic scan-card renderer -- drives both AWS's and Azure's scan cards.
// ids: { card, pill, cntCritical, cntHigh, cntMedium, cntLow, cntIgnored,
//        ts, findingsList, findingsCount }
function renderScanGeneric(d, ids, moduleMap) {
  if (!d || d.__error) {
    setPill(ids.pill, 'idle', '—');
    showCard(ids.card, true, true);
    $(ids.findingsList).innerHTML = '<div class="empty-state">No scan data yet.</div>';
    $(ids.findingsCount).textContent = '0 total';
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

  setPill(ids.pill, pass ? 'pass' : 'fail', pillLabel);
  setCardState(ids.card, pass ? 'pass' : 'fail');
  showCard(ids.card, true, false);

  // Gate banner headline/counts -- optional fields, only present on the
  // scan card's ids object (the banner that replaced the old scan card).
  if (ids.headline) $(ids.headline).textContent = pass ? 'Gate passing' : 'Gate failing';
  if (ids.counts) $(ids.counts).textContent = `${crit} critical · ${high} high · ${med} medium · ${low} low`;

  animCount($(ids.cntCritical), crit);
  animCount($(ids.cntHigh),     high);
  animCount($(ids.cntMedium),   med);
  animCount($(ids.cntLow),      low);
  animCount($(ids.cntIgnored),  ign);

  $(ids.ts).textContent = fmtTs(d.timestamp);

  // findings list
  // JSON key is "findings" (not "results"); findings have no "ignored" field
  $(ids.findingsCount).textContent = `${findings.length} total`;
  // Scope to THIS card's own findings-wrap, not a global querySelector —
  // there are now two .findings-wrap elements on the page (AWS + Azure).
  const findingsWrap = $(ids.findingsList).closest('.findings-wrap');
  if (findingsWrap) findingsWrap.classList.toggle('is-empty', findings.length === 0);

  if (findings.length === 0) {
    $(ids.findingsList).innerHTML = '<div class="empty-state">No open findings \u2014 gate is clean.</div>';
    return;
  }

  // Flat list, sorted CRITICAL/HIGH first, then MEDIUM, then LOW (and
  // anything else -- INFO/IGNORED -- alongside LOW). Replaces the old
  // per-module grouping: severity is the thing worth scanning for first.
  const SEV_RANK = { CRITICAL: 0, HIGH: 0, MEDIUM: 1, LOW: 2 };
  const sorted = findings.slice(0, 30).slice().sort((a, b) => {
    const ra = SEV_RANK[(a.severity || '').toUpperCase()] ?? 2;
    const rb = SEV_RANK[(b.severity || '').toUpperCase()] ?? 2;
    return ra - rb;
  });

  $(ids.findingsList).innerHTML = sorted.map(r => {
    const sev    = (r.severity || 'low').toLowerCase();
    const bCls   = sev === 'critical' ? 'crit' : sev;
    const isLow  = (SEV_RANK[(r.severity || '').toUpperCase()] ?? 2) === 2;
    const mod    = getModule(r.resource || '', moduleMap);
    const detail = `${r.rule_id || ''} · ${r.resource || ''}`;
    return `<div class="finding-row${isLow ? ' is-low' : ''}" title="${escHtml(detail)}">
        <span class="sev-badge ${bCls}">${r.severity}</span>
        <span class="finding-desc">${escHtml(r.description || '')}</span>
        <span class="finding-module">${escHtml(mod)}</span>
      </div>`;
  }).join('');
}

const SCAN_IDS = {
  card: 'card-scan', pill: 'pill-scan',
  cntCritical: 'cnt-critical', cntHigh: 'cnt-high', cntMedium: 'cnt-medium',
  cntLow: 'cnt-low', cntIgnored: 'cnt-ignored',
  ts: 'scan-ts', findingsList: 'findings-list', findingsCount: 'findings-count',
  headline: 'gate-banner-headline', counts: 'gate-banner-counts',
};
const SCAN_AZURE_IDS = {
  card: 'card-scan-azure', pill: 'pill-scan-azure',
  cntCritical: 'cnt-critical-azure', cntHigh: 'cnt-high-azure', cntMedium: 'cnt-medium-azure',
  cntLow: 'cnt-low-azure', cntIgnored: 'cnt-ignored-azure',
  ts: 'scan-azure-ts', findingsList: 'findings-list-azure', findingsCount: 'findings-count-azure',
  headline: 'gate-banner-headline-azure', counts: 'gate-banner-counts-azure',
};

function renderScan(d) { renderScanGeneric(d, SCAN_IDS, AWS_MODULE_MAP); }
function renderScanAzure(d) { renderScanGeneric(d, SCAN_AZURE_IDS, AZURE_MODULE_MAP); }

// growth-last*.json: {timestamp, status, next_target, total_queued,
// applied_count, error?} -- written by scripts/grow-stack.sh /
// grow-stack-azure.sh. AWS's growth card has no committed data file as
// of this build (grow-stack.sh + its scheduled CI job exist, but nothing
// has synced real output to dashboard/public/data/growth-last.json yet)
// -- it renders the same empty-state as any other never-run card until
// that happens; seeding real data is a separate concern from this UI.
// ids: { card, pill, progress, next, ts }
function renderGrowthGeneric(d, ids) {
  if (!d || d.__error) {
    setPill(ids.pill, 'idle', '—');
    showCard(ids.card, true, true);
    return;
  }

  const status = d.status || 'unknown';
  const PILL_BY_STATUS = {
    applied:   ['pass', 'GROWING'],
    complete:  ['clean', 'COMPLETE'],
    failed:    ['fail', 'FAILED'],
    timed_out: ['warn', 'TIMED OUT'],
    stalled_known_issue: ['na', 'KNOWN ISSUE'],
  };
  const byStatus = PILL_BY_STATUS[status] || ['idle', status.toUpperCase()];
  const pillCls = byStatus[0], pillLabel = byStatus[1];
  setPill(ids.pill, pillCls, pillLabel);
  setCardState(ids.card, (pillCls === 'pass' || pillCls === 'clean') ? 'pass'
    : pillCls === 'fail' ? 'fail'
    : pillCls === 'na' ? ''
    : 'warn');
  showCard(ids.card, true, false);

  const total = d.total_queued ?? '?';
  const applied = d.applied_count ?? '?';
  $(ids.progress).textContent = `${applied} / ${total}`;
  $(ids.next).textContent = d.next_target || '(queue complete)';
  $(ids.ts).textContent = fmtTs(d.timestamp);

  // Thin progress-bar fill on the quiet growth tile -- additive, doesn't
  // touch anything the pill/border-state logic above already computed.
  if (ids.bar) {
    const pct = (typeof total === 'number' && total > 0 && typeof applied === 'number')
      ? Math.max(0, Math.min(100, (applied / total) * 100)) : 0;
    $(ids.bar).style.width = `${pct}%`;
  }
}

const GROWTH_IDS = {
  card: 'card-growth', pill: 'pill-growth',
  progress: 'growth-progress', next: 'growth-next', ts: 'growth-ts',
  bar: 'growth-bar-fill',
};
const GROWTH_AZURE_IDS = {
  card: 'card-growth-azure', pill: 'pill-growth-azure',
  progress: 'growth-azure-progress', next: 'growth-azure-next', ts: 'growth-azure-ts',
  bar: 'growth-azure-bar-fill',
};
function renderGrowth(d) { renderGrowthGeneric(d, GROWTH_IDS); }
function renderGrowthAzure(d) { renderGrowthGeneric(d, GROWTH_AZURE_IDS); }

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
  // Bare number -- the quiet tile's "big number" treatment supplies the
  // "outputs" unit as a static label beside it, not part of this text.
  $('dep-resources').textContent = outputKeys.length ? String(outputKeys.length) : '—';
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

// verify-last-azure.json: {timestamp, endpoint, total, found, not_found,
// timed_out, check_error, not_applicable, stuck, unexpected_issues,
// all_expected_healthy, results}. Deliberately NOT reusing renderVerify's
// logic -- full parity means most resources are expected to be
// not_found/check_error/stuck (documented known_issue gaps), so "healthy"
// here means "zero UNEXPECTED issues", not "everything found" the way
// AWS's all_passed does.
function renderVerifyAzure(d) {
  const cardId = 'card-verify-azure';
  if (!d || d.__error) {
    setPill('pill-verify-azure', 'idle', '—');
    showCard(cardId, true, true);
    return;
  }

  const ok = d.all_expected_healthy === true;
  setPill('pill-verify-azure', ok ? 'pass' : 'warn', ok ? 'PASS' : `${d.unexpected_issues ?? '?'} unexpected`);
  setCardState(cardId, ok ? 'pass' : 'warn');
  showCard(cardId, true, false);

  const knownGaps = (d.results || []).filter(r => r.known_issue).length;
  $('ver-azure-found').textContent      = `${d.found ?? '?'} / ${d.total ?? '?'}`;
  // Bare number -- the quiet tile's context line supplies "known/excluded"
  // and "unexpected" as static labels, not part of this text.
  $('ver-azure-known').textContent      = String(knownGaps);
  $('ver-azure-unexpected').textContent = String(d.unexpected_issues ?? '?');
  $('ver-azure-ts').textContent         = fmtTs(d.timestamp);
}

// ids: { card, pill, class, count, ts, changes, pending? }
// `pending` is Azure-only (drift-check-azure.sh's pending_growth array --
// AWS's drift-check.sh has no equivalent concept, see its header comment).
function renderDriftGeneric(d, ids) {
  if (!d || d.__error || d.result === undefined) {
    setPill(ids.pill, 'idle', '—');
    showCard(ids.card, true, true);
    return;
  }

  const cls   = d.classification || 'unknown';
  const clean = d.result === 'no_drift';
  // Color logic:
  //   pass  - clean / no drift (green)
  //   warn  - drift detected but agent is still able to reason about it
  //           (safe = could auto-fix, destructive = held back, security_only = blocked)
  //   fail  - reserved for HTTP-level failures, not policy decisions
  const pillCls = clean ? 'clean'
    : cls === 'destructive'   ? 'destructive'
    : cls === 'security_only' ? 'warn'
    : cls === 'safe'          ? 'drift'
    : 'warn';
  const pillLabel = clean ? 'CLEAN'
    : cls === 'safe'           ? 'DRIFT · safe'
    : cls === 'destructive'    ? 'HELD · destructive'
    : cls === 'security_only'  ? 'FROZEN · security'
    : 'DRIFT';

  setPill(ids.pill, pillCls, pillLabel);
  setCardState(ids.card, clean ? 'pass' : cls === 'destructive' ? 'fail' : 'warn');
  showCard(ids.card, true, false);

  $(ids.class).textContent = `classification: ${cls}`;
  $(ids.ts).textContent    = fmtTs(d.timestamp);

  // AWS's raw changes can include no-ops; Azure's drift-check-azure.sh
  // already excludes them (and pending_growth separately) -- filtering
  // here is a no-op for Azure's already-clean array, harmless either way.
  const changes = (d.changes || []).filter(c => !(c.actions || []).every(a => a === 'no-op'));
  $(ids.count).textContent = `${changes.length} change${changes.length === 1 ? '' : 's'}`;

  if (ids.pending) {
    const pending = d.pending_growth || [];
    $(ids.pending).textContent = pending.length
      ? `${pending.length} resource${pending.length === 1 ? '' : 's'} (not drift)` : '0';
  }

  $(ids.changes).innerHTML = changes.length === 0
    ? '<div class="drift-row"><span class="drift-address" style="color:var(--text-muted);font-style:italic">no-op across all resources</span></div>'
    : changes.slice(0, 20).map(c => {
        const acts = (c.actions || []).join('|');
        // Amber/warn for delete/create (destructive change); idle for update/no-op.
        const aCls = acts.includes('delete') || acts.includes('create') ? 'warn'
                  : 'idle';
        return `<div class="drift-row">
          <span class="pill ${aCls}">${escHtml(acts)}</span>
          <span class="drift-address" title="${escHtml(c.address || '')}">${escHtml(c.address || '')}</span>
        </div>`;
      }).join('');
}

const DRIFT_IDS = {
  card: 'card-drift', pill: 'pill-drift', class: 'drift-class',
  count: 'drift-count', ts: 'drift-ts', changes: 'drift-changes',
};
const DRIFT_AZURE_IDS = {
  card: 'card-drift-azure', pill: 'pill-drift-azure', class: 'drift-azure-class',
  count: 'drift-azure-count', ts: 'drift-azure-ts', changes: 'drift-azure-changes',
  pending: 'drift-azure-pending',
};
function renderDrift(d) { renderDriftGeneric(d, DRIFT_IDS); }
function renderDriftAzure(d) { renderDriftGeneric(d, DRIFT_AZURE_IDS); }

// ids: { card, pill, list, heartbeat, empty }
function renderAgentGeneric(d, ids) {
  const arr = Array.isArray(d) ? d : [];

  if (!d || d.__error || !Array.isArray(d)) {
    setPill(ids.pill, 'idle', 'IDLE');
    // Show real error in empty-state instead of leaving skeleton up
    const emptyEl = $(ids.empty);
    if (emptyEl && d && d.__error) {
      emptyEl.innerHTML = `Could not load agent data: <code>${escHtml(d.__error)}</code>`;
    }
    showCard(ids.card, true, true);
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

  setPill(ids.pill, pillCls, pillLabel);
  setCardState(ids.card, pillCls === 'fail' ? 'fail' : pillCls === 'warn' ? 'warn' : 'pass');
  showCard(ids.card, true, false);

  $(ids.list).innerHTML = deduped.map(e => {
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

  $(ids.heartbeat).textContent = lastHb ? fmtTs(lastHb.timestamp) : '—';
}

const AGENT_IDS = {
  card: 'card-agent', pill: 'pill-agent', list: 'agent-list',
  heartbeat: 'agent-heartbeat', empty: 'empty-agent',
};
const AGENT_AZURE_IDS = {
  card: 'card-agent-azure', pill: 'pill-agent-azure', list: 'agent-azure-list',
  heartbeat: 'agent-azure-heartbeat', empty: 'empty-agent-azure',
};
function renderAgent(d) { renderAgentGeneric(d, AGENT_IDS); }
function renderAgentAzure(d) { renderAgentGeneric(d, AGENT_AZURE_IDS); }

// ── refresh ────────────────────────────────────────────────
async function fetchAll() {
  const results = await Promise.all(FETCH_TARGETS.map(safeFetch));
  const [scan, deploy, growth, verify, drift, agent] = results;
  if (results.every(d => d && d.__networkError)) {
    showToast('Can’t reach dashboard data — retrying…');
  } else {
    hideToast();
  }
  applySnapshot({ scan, deploy, growth, verify, drift, agent, _running: {}, _ts: Date.now() });
}

// Announce refreshes to screen readers via a polite live region.
const liveEl = $('aria-live');
async function fetchAllAndAnnounce() {
  await fetchAll();
  if (liveEl) liveEl.textContent = `Dashboard refreshed at ${fmtTs(new Date().toISOString())}`;
}

// ── Live mode via SSE (data-server.py) ────────────────────
// Tries to connect to the local data-server SSE endpoint.
// If the server is not running, falls back to file polling.
let _sseActive   = false;
let _pollTimer   = null;
let _modeEl      = $('live-mode-badge'); // optional badge element

function applySnapshot(snap) {
  // Update mtimes for the live age ticker
  const mtimes = snap._mtimes || {};
  ['scan','deploy','verify','drift','agent'].forEach(name => {
    if (mtimes[name]) _cardMtimes[name] = mtimes[name];
  });

  // snap = { scan, deploy, growth, verify, drift, agent, _running, _ts }
  const renderers = [
    ['scan',   renderScan,   snap.scan],
    ['deploy', renderDeploy, snap.deploy],
    ['growth', renderGrowth, snap.growth],
    ['verify', renderVerify, snap.verify],
    ['drift',  renderDrift,  snap.drift],
    ['agent',  renderAgent,  snap.agent],
  ];
  for (const [name, fn, data] of renderers) {
    try { fn(data); }
    catch (e) {
      console.error(`render${name} failed:`, e);
      try {
        const pillEl = $(`pill-${name}`);
        if (pillEl) setPill(`pill-${name}`, 'fail', 'ERROR');
        const cardId = `card-${name}`;
        setCardState(cardId, 'fail');
        const cardEl = $(cardId);
        if (cardEl) {
          cardEl.querySelectorAll('.list-mono').forEach(el => { el.textContent = '\u2014'; });
          cardEl.querySelectorAll('.stat-num').forEach(el => { el.textContent = '0'; el._lastVal = 0; });
        }
        if (name === 'scan') {
          $('findings-count').textContent = '0 total';
          $('findings-list').innerHTML = '<div class="empty-state">No scan data yet.</div>';
        }
      } catch {}
    }
  }
  updateLatestTs([snap.scan, snap.deploy, snap.growth, snap.verify, snap.drift, snap.agent]);

  // Show spinner on cards whose script is currently running
  const running = snap._running || {};
  Object.keys(running).forEach(name => {
    const pill = $(`pill-${name}`);
    if (pill && running[name]) pill.classList.add('pill-running');
  });
  // Clear spinners for completed scripts
  ['scan','deploy','verify','drift'].forEach(name => {
    if (!running[name]) $(`pill-${name}`)?.classList.remove('pill-running');
  });
}

function startSSE() {
  const es = new EventSource(`${DATA_SERVER}/live`);

  es.onopen = () => {
    _sseActive = true;
    clearInterval(_pollTimer);
    _pollTimer = null;
    if (_modeEl) { _modeEl.textContent = 'LIVE ●'; _modeEl.classList.add('live'); }
    if (liveEl) liveEl.textContent = 'Live data stream connected.';
    console.log('[dashboard] SSE connected — 1s live mode');
  };

  es.onmessage = e => {
    try {
      const snap = JSON.parse(e.data);
      applySnapshot(snap);
      if (liveEl) liveEl.textContent = `Live — ${fmtTs(new Date().toISOString())}`;
    } catch (err) {
      console.warn('[dashboard] SSE parse error:', err);
    }
  };

  es.onerror = () => {
    if (_sseActive) {
      _sseActive = false;
      if (_modeEl) { _modeEl.textContent = 'POLLING'; _modeEl.classList.remove('live'); }
      console.warn('[dashboard] SSE disconnected — falling back to polling');
    }
    es.close();
    // Retry SSE after 5 s, in case the server was restarted
    setTimeout(startSSE, 5_000);
    // Start polling immediately so the UI doesn't go stale
    if (!_pollTimer) startPolling();
  };
}

function startPolling() {
  if (_pollTimer) return;
  fetchAllAndAnnounce();
  _pollTimer = setInterval(fetchAllAndAnnounce, REFRESH_MS);
  if (_modeEl) { _modeEl.textContent = 'POLLING'; _modeEl.classList.remove('live'); }
}

// ── Pipeline trigger button ─────────────────────────────────
const pipelineBtn = $('pipeline-trigger-btn');
if (pipelineBtn) {
  pipelineBtn.addEventListener('click', async () => {
    pipelineBtn.disabled = true;
    pipelineBtn.textContent = '\u23f3 triggering\u2026';
    try {
      const r = await fetch(`${DATA_SERVER}/trigger`);
      const j = await r.json();
      if (j.triggered) {
        pipelineBtn.textContent = '\u2713 triggered';
        pipelineBtn.classList.add('triggered');
        setTimeout(() => {
          pipelineBtn.textContent = '\u25ba Pipeline';
          pipelineBtn.classList.remove('triggered');
          pipelineBtn.disabled = false;
        }, 4000);
      } else {
        pipelineBtn.textContent = '\u26a0 failed';
        console.warn('[dashboard] pipeline trigger failed:', j);
        setTimeout(() => { pipelineBtn.textContent = '\u25ba Pipeline'; pipelineBtn.disabled = false; }, 3000);
      }
    } catch (e) {
      pipelineBtn.textContent = '\u26a0 server offline';
      console.warn('[dashboard] /trigger failed:', e);
      setTimeout(() => { pipelineBtn.textContent = '\u25ba Pipeline'; pipelineBtn.disabled = false; }, 3000);
    }
  });
}

// ── Run-button wiring ─────────────────────────────────────
// Any element with data-run="scan|verify|drift|deploy" calls
// the data-server /run/<script> endpoint on click.
document.querySelectorAll('[data-run]').forEach(btn => {
  btn.addEventListener('click', async () => {
    const name = btn.dataset.run;
    if (!name) return;
    try {
      const r = await fetch(`${DATA_SERVER}/run/${name}`);
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      const j = await r.json();
      if (j.already_running) {
        console.log(`[dashboard] ${name} already running`);
      } else if (j.started) {
        const pill = $(`pill-${name}`);
        if (pill) pill.classList.add('pill-running');
        console.log(`[dashboard] ${name} started`);
      } else {
        console.warn(`[dashboard] /run/${name} failed:`, j);
      }
    } catch (e) {
      console.warn(`[dashboard] run button (${name}) failed — server not running?`, e);
    }
  });
});

// ── Boot sequence ─────────────────────────────────────────
// /aws and /azure are now real, separate pages (not a client-side tab
// switch) sharing this one app.js. Detect which page loaded it by
// checking for that page's own scan card, rather than a body data
// attribute -- same defensive existence-check style already used
// throughout this file (e.g. `if (pipelineBtn) ...`).
const HAS_AWS_PAGE   = !!$('card-scan');
const HAS_AZURE_PAGE = !!$('card-scan-azure');

// On Cloudflare Pages (HTTPS) the browser blocks HTTP localhost
// as mixed content — EventSource never fires onerror cleanly,
// so the fallback never starts. Gate SSE on hostname.
const IS_LOCAL = ['localhost', '127.0.0.1', ''].includes(location.hostname);

// Hide localhost-only controls on remote (Pages) deployments
if (!IS_LOCAL) {
  document.querySelectorAll('[data-run], #pipeline-trigger-btn').forEach(el => {
    el.style.display = 'none';
  });
}

// Safe to call regardless of which page loaded this script -- each
// sparkline render is a no-op if its target <svg> isn't on the page.
fetchHistories();
setInterval(fetchHistories, HISTORY_POLL_MS);

if (HAS_AWS_PAGE) {
  // Always do an immediate file fetch so the dashboard isn't blank.
  fetchAllAndAnnounce();

  if (IS_LOCAL) {
    // Local dev: use SSE for 1s live updates.
    startSSE();
  } else {
    // Cloudflare Pages / any remote host: pure file polling.
    // No localhost server is reachable; mixed-content blocks HTTP anyway.
    startPolling();
    if (_modeEl) { _modeEl.textContent = 'POLLING'; _modeEl.classList.remove('live'); }
  }
}

if (HAS_AZURE_PAGE) {
  // Azure page: independent poll cycle, same cadence as AWS's fallback
  // polling. No SSE path -- data-server.py's live snapshot only knows
  // about the AWS files.
  fetchAllAzure();
  setInterval(fetchAllAzure, REFRESH_MS);
  if (_modeEl) { _modeEl.textContent = 'POLLING'; _modeEl.classList.remove('live'); }
}

setInterval(paintStale, 1000);

// Sync dot is a click-to-refresh affordance. Make it accessible.
// Dispatches to whichever page actually loaded -- calling AWS's refresh
// on the Azure page (or vice versa) would just throw caught-but-spurious
// console errors against IDs that don't exist on that page.
function refreshCurrentPage() {
  if (HAS_AWS_PAGE) return fetchAllAndAnnounce();
  if (HAS_AZURE_PAGE) return fetchAllAzure();
}
const syncEl = $('sync-status');
if (syncEl) {
  syncEl.setAttribute('role', 'button');
  syncEl.setAttribute('tabindex', '0');
  syncEl.setAttribute('aria-label', 'Refresh dashboard');
  syncEl.addEventListener('click', e => { e.preventDefault(); refreshCurrentPage(); });
  syncEl.addEventListener('keydown', e => {
    if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); refreshCurrentPage(); }
  });
}
