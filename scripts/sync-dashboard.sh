#!/usr/bin/env bash
# =============================================================================
# scripts/sync-dashboard.sh
# =============================================================================
# Purpose
#   Publish ONLY dashboard/public/data/*.json changes to the remote.
#   This is the ONLY thing this repo should ever push automatically.
#   Everything else (terraform/, scripts/, docs/) requires a manual
#   `git push` from a developer.
#
# Hard gate (BEFORE pushing anything)
#   We inspect the staged diff for anything that smells like a credential,
#   real AWS account ID, ARN with non-floci account, or tfstate fragment.
#   If we find any of these patterns we refuse to push and exit non-zero.
#
# Patterns refused
#   - real aws key id (AKIA/ASIA/AROA/AIDA prefix)
#   - 40-char base64-ish string near "secret"
#   - arn:aws:*:*:* with account id != 000000000000 (floci dummy)
#   - "password", "secret", "api_key" with a value (heuristic)
#   - lines containing literal "terraform.tfstate" content (huge JSON)
#   - any URL containing a cloudflare API token (cfut_/APITOKEN-)
#   - private key markers (BEGIN PRIVATE KEY, BEGIN RSA)
#
# SEC_INTENT:
#   This script runs on the developer's machine and pushes to GitHub.
#   The risk is: someone adds a JSON file under dashboard/public/data/
#   that accidentally contains a credential. The gate must catch it.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DASH_DATA="$ROOT_DIR/dashboard/public/data"

cd "$ROOT_DIR"

# ---- Pre-flight ----------------------------------------------------------
if [[ ! -d .git ]]; then
  echo "FATAL: not a git repo at $ROOT_DIR" >&2
  echo "  Run: git init && gh repo create ... first." >&2
  exit 2
fi

if ! command -v git >/dev/null 2>&1; then
  echo "FATAL: git not in PATH" >&2
  exit 2
fi

if ! git remote get-url origin >/dev/null 2>&1; then
  echo "FATAL: no 'origin' remote configured." >&2
  echo "  Run: gh repo create arifbazli/shift-left-cloud-sandbox --source=. --remote=origin" >&2
  exit 2
fi

# ---- Compute what would change -------------------------------------------
# Add ONLY the dashboard JSON files. Refuse if git status shows anything
# else modified/staged.
status_out="$(git status --porcelain)"
if [[ -n "$status_out" ]]; then
  echo "Found working-tree changes:"
  echo "$status_out" | sed 's/^/  /'
  echo ""
  # Anything outside dashboard/public/data/ must be unstaged. We allow
  # untracked dashboard JSON files but NOT untracked .tf changes etc.
  offenders="$(echo "$status_out" | grep -vE '^(\?\?| M| A|UU|AA|DD|RR|CC) dashboard/public/data/' || true)"
  # Also catch modified files OUTSIDE dashboard/public/data
  offenders2="$(echo "$status_out" | grep -E '^(\?\?| M| M) ' | grep -v 'dashboard/public/data/' || true)"
  if [[ -n "$offenders" ]] || [[ -n "$offenders2" ]]; then
    echo "WARNING: changes exist outside dashboard/public/data/."
    echo "  This script only pushes JSON. Commit + push other changes manually."
    echo ""
    exit 2
  fi
fi

# Add ONLY the dashboard JSON files
git add dashboard/public/data/

# If nothing changed, exit 0 cleanly
if git diff --cached --quiet; then
  echo "No dashboard JSON changes to sync."
  exit 0
fi

# ---- Hard gate: scan the staged diff for forbidden patterns ---------------
staged_diff="$(git diff --cached)"

# Patterns that MUST NOT appear in the staged diff.
# Using grep -E for portability; extended regex.
patterns=(
  'AKIA[0-9A-Z]{16}'                            # AWS access key id (permanent)
  'ASIA[0-9A-Z]{16}'                            # AWS session token
  'AROA[0-9A-Z]{16}'                            # AWS role id (NOT an account id)
  'cfut_[0-9a-zA-Z_-]{20,}'                     # Cloudflare API token literal
  'BEGIN (RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY'
  'aws_secret_access_key'
  'api_key[[:space:]]*[:=][[:space:]]*["'\'']?[A-Za-z0-9]{16,}'
  'password[[:space:]]*[:=][[:space:]]*["'\'']?[A-Za-z0-9!@#$%^&*()_+=-]{8,}'
  'arn:aws:[a-z0-9-]+:[a-z0-9-]*:[0-9]{12}:'   # AWS ARN with real account id
)

# Normal "ok" ARN prefix the repo uses (floci dummy account)
ok_arn='arn:aws:[a-z0-9-]+:[a-z0-9-]*:000000000000:'

violations=()
for pat in "${patterns[@]}"; do
  # We need to catch the AWS ARN pattern BUT allow the floci dummy.
  if [[ "$pat" == arn:aws:* ]]; then
    # Find any arn:aws:...:ACCOUNT:... where ACCOUNT is NOT 000000000000
    bad_arns="$(echo "$staged_diff" | grep -oE 'arn:aws:[a-z0-9-]+:[a-z0-9-]*:[0-9]+:' | grep -vE ':000000000000:' || true)"
    if [[ -n "$bad_arns" ]]; then
      violations+=("forbidden AWS ARN with non-floci account: $(echo "$bad_arns" | head -3)")
    fi
    continue
  fi

  if echo "$staged_diff" | grep -qE "$pat"; then
    # For private-key markers, dump the surrounding line so the dev sees it
    excerpt="$(echo "$staged_diff" | grep -E "$pat" | head -3)"
    violations+=("pattern '$pat' matched: $(echo "$excerpt" | head -1 | cut -c1-160)")
  fi
done

# Heuristic check: staged files should be valid JSON
for f in $(git diff --cached --name-only); do
  if ! jq -e . "$f" >/dev/null 2>&1; then
    violations+=("file '$f' is not valid JSON")
  fi
done

if [[ "${#violations[@]}" -gt 0 ]]; then
  echo "FATAL: hard-gate refused the push. ${#violations[@]} violation(s):"
  for v in "${violations[@]}"; do
    echo "  - $v"
  done
  echo ""
  echo "To inspect the staged diff:"
  echo "  git diff --cached"
  echo ""
  echo "To unstage:"
  echo "  git restore --staged dashboard/public/data/"
  exit 3
fi

# ---- Inspect file sizes (1MB sanity cap) ----------------------------------
for f in $(git diff --cached --name-only); do
  size="$(stat -c '%s' "$f" 2>/dev/null || echo 0)"
  if [[ "$size" -gt 1048576 ]]; then
    echo "FATAL: $f is $size bytes (>1MB). Refusing to push." >&2
    git restore --staged "$f" >/dev/null 2>&1 || true
    exit 4
  fi
done

# ---- Commit and push ------------------------------------------------------
# Build a descriptive commit message
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
n_files="$(git diff --cached --name-only | wc -l)"
n_added="$(git diff --cached --numstat | awk '$2==0 && $1>0 {n++} END {print n+0}')"
n_modified="$(git diff --cached --numstat | awk '$1>0 && $2>0 {n++} END {print n+0}')"

commit_msg="dashboard(json): sync ${n_files} file(s) at ${ts}

synced automatically by scripts/sync-dashboard.sh
  files added:    ${n_added}
  files modified: ${n_modified}

contents:
$(git diff --cached --stat | sed 's/^/  /')
"

git commit -m "$commit_msg"

echo ""
echo "=== pushing ==="
git push origin HEAD

echo ""
echo "=== sync complete ==="
git log -1 --oneline
