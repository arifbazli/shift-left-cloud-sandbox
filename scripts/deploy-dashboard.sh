#!/usr/bin/env bash
# =============================================================================
# scripts/deploy-dashboard.sh
# =============================================================================
# Purpose
#   Publish the static dashboard/ directory to Cloudflare Pages.
#
# Auth
#   Relies on wrangler's existing authentication. Do one of:
#     - wrangler login  (OAuth — caches token in ~/.config/.wrangler/)
#     - export CLOUDFLARE_API_TOKEN=<token>  (legacy API token)
#   This script does NOT call `wrangler login`. Auth is a manual one-time
#   prerequisite that the developer must complete on their own machine.
#
# What this script does
#   - Runs: wrangler pages deploy dashboard/public --project-name=...
#   - Captures the live *.pages.dev URL wrangler prints
#   - Writes that URL to dashboard/public/data/deploy-last.json so the
#     dashboard can show "where it lives" once rendered live
#   - Logs the deploy to deploy-history.json (same file deploy.sh writes)
#
# What this script does NOT do (security boundary)
#   - NEVER touches terraform/, scripts/*.tf, terraform.tfstate, state-snapshots/
#   - NEVER reads or echoes CLOUDFLARE_API_TOKEN (env vars are not printed)
#   - NEVER talks to floci-core / localhost:4566 — only dashboard/public/
#     static files leave the local machine
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DASHBOARD_DIR="$ROOT_DIR/dashboard/public"
DASH_DATA="$ROOT_DIR/dashboard/public/data"
PROJECT_NAME="${PAGES_PROJECT_NAME:-shift-left-cloud-sandbox}"

# ---- Pre-flight ----------------------------------------------------------
if [[ ! -d "$DASHBOARD_DIR" ]]; then
  echo "FATAL: $DASHBOARD_DIR does not exist" >&2
  exit 2
fi

if ! command -v wrangler >/dev/null 2>&1; then
  echo "FATAL: wrangler not in PATH" >&2
  echo "  Install: npm install -g wrangler  (or use the system package)" >&2
  exit 2
fi

# Verify wrangler can authenticate without printing the credential.
# Important: don't use `! wrangler whoami >/dev/null 2>&1` — pipefail and
# redirection can mask the real exit code. Run it plainly and capture.
auth_output="$(wrangler whoami 2>&1)"
auth_exit=$?
if [[ $auth_exit -ne 0 ]]; then
  echo "FATAL: wrangler is not authenticated (exit $auth_exit)." >&2
  echo "  Run 'wrangler login' once on this machine, or" >&2
  echo "  export CLOUDFLARE_API_TOKEN=<token> before re-running." >&2
  echo "---- wrangler output ----" >&2
  echo "$auth_output" >&2
  exit 2
fi
if echo "$auth_output" | grep -qiE "not authenticated|please run .wrangler login"; then
  echo "FATAL: wrangler reports it is not authenticated." >&2
  echo "  Run 'wrangler login' once on this machine, or" >&2
  echo "  export CLOUDFLARE_API_TOKEN=<token> before re-running." >&2
  echo "---- wrangler output ----" >&2
  echo "$auth_output" >&2
  exit 2
fi

# ---- Deploy ---------------------------------------------------------------
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
deploy_log="$(mktemp)"
trap 'rm -f "$deploy_log"' EXIT

echo "---- pages deploy ($ts) ----"
echo "  project: $PROJECT_NAME"
echo "  source:  $DASHBOARD_DIR"

# wrangler pages deploy prints the live URL on stdout, e.g.:
#   ✨ Deployment complete! Take a peek over at https://<hash>.<project>.pages.dev
# or:
#   Published <project> (X.XX sec)
#   https://<hash>.<project>.pages.dev
set +e
wrangler pages deploy "$DASHBOARD_DIR" \
  --project-name="$PROJECT_NAME" \
  --commit-dirty=true \
  >"$deploy_log" 2>&1
deploy_exit=$?
set -e

# ---- Extract the live URL -------------------------------------------------
# wrangler prints it in the form https://<hash>.<project>.pages.dev
live_url="$(grep -oE 'https://[a-z0-9-]+\.'"$PROJECT_NAME"'\.pages\.dev' "$deploy_log" | head -1 || true)"
if [[ -z "$live_url" ]]; then
  # Some versions print https://<project>.pages.dev without a hash
  live_url="$(grep -oE 'https://'"$PROJECT_NAME"'\.pages\.dev' "$deploy_log" | head -1 || true)"
fi

if [[ "$deploy_exit" -ne 0 ]]; then
  echo "FATAL: wrangler pages deploy failed (exit $deploy_exit)" >&2
  echo "---- wrangler log ----" >&2
  cat "$deploy_log" >&2
  exit 1
fi

if [[ -z "$live_url" ]]; then
  echo "WARN: deploy succeeded but live URL could not be parsed." >&2
  echo "---- wrangler log ----"
  cat "$deploy_log"
  echo ""
  echo "  Check the Cloudflare dashboard for the URL."
  exit 0
fi

echo "  live url: $live_url"

# ---- Record the deploy in dashboard JSON ---------------------------------
# Append to deploy-history.json (same file as scripts/deploy.sh writes, so
# the dashboard has one consolidated deploy log).
report="$(jq -n \
  --arg ts "$ts" \
  --arg url "$live_url" \
  --arg script "scripts/deploy-dashboard.sh" \
  --arg project "$PROJECT_NAME" \
  '{
    timestamp: $ts,
    kind: "pages_deploy",
    source: $script,
    project: $project,
    url: $url
  }')"

mkdir -p "$DASH_DATA"
hist_file="$DASH_DATA/deploy-history.json"
hist_tmp="$(mktemp)"
if [[ -s "$hist_file" ]] && jq -e 'type == "array"' "$hist_file" >/dev/null 2>&1; then
  jq --argjson r "$report" '. + [$r]' "$hist_file" >"$hist_tmp"
else
  echo "[$report]" | jq '.' >"$hist_tmp"
fi
mv "$hist_tmp" "$hist_file"

# Update deploy-last.json with the live URL (do NOT overwrite existing fields
# that scripts/deploy.sh writes — only add the pages fields if missing).
last_file="$DASH_DATA/deploy-last.json"
if [[ -s "$last_file" ]] && jq -e 'type == "object"' "$last_file" >/dev/null 2>&1; then
  jq --arg url "$live_url" --arg ts "$ts" \
    '. + {pages_url: $url, pages_deploy_at: $ts}' \
    "$last_file" >"$hist_tmp"
  mv "$hist_tmp" "$last_file"
fi

echo "---- pages deploy complete ----"
echo "  live url: $live_url"
echo "  recorded: $DASH_DATA/deploy-history.json"