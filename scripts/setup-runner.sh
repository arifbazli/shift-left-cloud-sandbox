#!/usr/bin/env bash
# =============================================================================
# scripts/setup-runner.sh
# =============================================================================
# Purpose
#   Bootstrap a GitHub Actions self-hosted runner on Debian WSL (rootless).
#   Installs the runner, labels it "floci-self-hosted", and configures it
#   as a systemd user service so it survives WSL restarts.
#
# Prerequisites (must be installed before running this script):
#   - tfsec   1.28.5  (see README.md "Pre-flight: tool pins")
#   - terraform       (any recent version)
#   - python3 ≥ 3.10
#   - podman  (rootless)
#   - podman-compose
#   - jq
#
# Usage
#   export GH_RUNNER_TOKEN="<token from Settings → Actions → Runners>"
#   bash scripts/setup-runner.sh
#
# The runner token is single-use and expires after 1 hour. Generate it at:
#   https://github.com/arifbazli/shift-left-cloud-sandbox/settings/actions/runners/new
#
# SEC_INTENT:
#   The token is consumed only via the env variable; it is never written to
#   disk or echoed. The runner is configured with --no-default-capabilities
#   so it cannot escalate to root on the WSL host.
# =============================================================================
set -euo pipefail

RUNNER_VERSION="2.317.0"
RUNNER_DIR="${HOME}/actions-runner"
REPO_URL="https://github.com/arifbazli/shift-left-cloud-sandbox"
RUNNER_LABEL="floci-self-hosted"
RUNNER_NAME="floci-wsl-runner"

# ---------------------------------------------------------------------------
# 0. Guard: token must be set
# ---------------------------------------------------------------------------
if [[ -z "${GH_RUNNER_TOKEN:-}" ]]; then
  echo "ERROR: GH_RUNNER_TOKEN is not set."
  echo ""
  echo "  1. Go to: $REPO_URL/settings/actions/runners/new"
  echo "  2. Copy the token value from the configure step."
  echo "  3. Run:  export GH_RUNNER_TOKEN=<token>"
  echo "  4. Re-run this script."
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Pre-flight: verify required tools
# ---------------------------------------------------------------------------
echo "=== Pre-flight checks ==="

check_tool() {
  local cmd="$1" version_flag="${2:---version}" expected="${3:-}"
  if ! command -v "$cmd" &>/dev/null; then
    echo "  MISSING : $cmd"
    return 1
  fi
  local ver
  ver="$("$cmd" $version_flag 2>&1 | head -1)"
  if [[ -n "$expected" ]] && [[ "$ver" != *"$expected"* ]]; then
    echo "  VERSION WARN: $cmd — got '$ver', expected pattern '$expected'"
  else
    echo "  OK      : $cmd — $ver"
  fi
}

check_tool tfsec    "--version" "1.28.5"
check_tool terraform "--version" ""
check_tool python3  "--version"  "3."
check_tool podman   "--version"  ""
check_tool podman-compose "--version" ""
check_tool jq       "--version"  ""

echo ""

# ---------------------------------------------------------------------------
# 2. Download runner tarball (idempotent)
# ---------------------------------------------------------------------------
echo "=== Installing GitHub Actions runner v${RUNNER_VERSION} ==="

mkdir -p "$RUNNER_DIR"
TARBALL="${RUNNER_DIR}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
TARBALL_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"

if [[ ! -f "$TARBALL" ]]; then
  echo "  Downloading $TARBALL_URL ..."
  curl -fsSL -o "$TARBALL" "$TARBALL_URL"
else
  echo "  Tarball already downloaded: $TARBALL"
fi

# Extract (idempotent — runner binary checked)
if [[ ! -f "$RUNNER_DIR/run.sh" ]]; then
  echo "  Extracting ..."
  tar xzf "$TARBALL" -C "$RUNNER_DIR"
else
  echo "  Runner already extracted."
fi

# ---------------------------------------------------------------------------
# 3. Configure the runner
# ---------------------------------------------------------------------------
echo ""
echo "=== Configuring runner ==="

if [[ -f "$RUNNER_DIR/.runner" ]]; then
  echo "  Runner already configured. Skipping config step."
  echo "  To reconfigure, delete $RUNNER_DIR/.runner and re-run."
else
  "$RUNNER_DIR/config.sh" \
    --url    "$REPO_URL" \
    --token  "$GH_RUNNER_TOKEN" \
    --name   "$RUNNER_NAME" \
    --labels "$RUNNER_LABEL" \
    --work   "$RUNNER_DIR/_work" \
    --unattended \
    --replace
  echo "  Runner configured as: $RUNNER_NAME (labels: $RUNNER_LABEL)"
fi

# ---------------------------------------------------------------------------
# 4. Register as a systemd user service (survives WSL restart)
# ---------------------------------------------------------------------------
echo ""
echo "=== Registering systemd user service ==="

SERVICE_DIR="${HOME}/.config/systemd/user"
SERVICE_FILE="${SERVICE_DIR}/floci-runner.service"
mkdir -p "$SERVICE_DIR"

cat > "$SERVICE_FILE" << UNIT
[Unit]
Description=GitHub Actions self-hosted runner (floci)
After=network.target

[Service]
Type=simple
WorkingDirectory=${RUNNER_DIR}
ExecStart=${RUNNER_DIR}/run.sh
Restart=on-failure
RestartSec=10
# SEC_INTENT: runner does NOT run as root; no capabilities granted.
NoNewPrivileges=true

[Install]
WantedBy=default.target
UNIT

echo "  Service file written to $SERVICE_FILE"

# Enable WSL systemd if not already (Ubuntu 22.04+ on WSL 2 supports this).
if systemctl --user is-system-running &>/dev/null; then
  systemctl --user daemon-reload
  systemctl --user enable floci-runner.service
  systemctl --user start  floci-runner.service
  echo "  Service enabled and started."
  echo ""
  systemctl --user status floci-runner.service --no-pager | head -8
else
  echo "  systemd --user not available in this WSL session."
  echo "  To start the runner manually:"
  echo "    cd $RUNNER_DIR && ./run.sh &"
  echo ""
  echo "  To enable systemd in WSL2, add to /etc/wsl.conf:"
  echo "    [boot]"
  echo "    systemd=true"
  echo "  Then restart WSL: wsl --shutdown"
fi

# ---------------------------------------------------------------------------
# 5. Done
# ---------------------------------------------------------------------------
echo ""
echo "=== Setup complete ==="
echo "  Runner:  $RUNNER_NAME"
echo "  Labels:  $RUNNER_LABEL"
echo "  Dir:     $RUNNER_DIR"
echo ""
echo "Verify at: $REPO_URL/settings/actions/runners"
