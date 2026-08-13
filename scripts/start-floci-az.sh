#!/usr/bin/env bash
# =============================================================================
# scripts/start-floci-az.sh
# =============================================================================
# Purpose
#   Start floci-core + floci-az (podman-compose.yml) with the netavark/
#   iptables fix ACTUALLY applied, not just documented.
#
# Why this exists instead of a plain `podman-compose up -d`
#   floci-az's Functions/AKS/Redis/ACR services spawn sidecar containers on
#   demand, over a mounted Docker socket, using Podman's default bridge
#   network. On this WSL2 rootless-Podman host, netavark's native nftables
#   driver fails for that (missing kernel capability — the same root cause
#   already documented for floci-core's network_mode: host workaround).
#   Switching netavark to its iptables-nft driver fixes it — but the fix has
#   to be applied to the environment of the HOST-side `podman.service`
#   process that serves the mounted socket, not to any container's own env.
#   podman-compose.yml's floci-az environment: block cannot do this by
#   construction (container envs and the host-side socket-serving process
#   are separate process trees) — see the SEC_INTENT comment there.
#
# SEC_INTENT: reversible by design — this sets a systemd user-manager
#   environment variable (systemctl --user set-environment), not a
#   containers.conf edit. Nothing here survives a reboot or persists outside
#   this login session; re-run this script after a reboot if needed.
#   Verified 2026-08-13 — see CONTEXT.md's Research log for the full test
#   that found and validated this fix.
#
# If floci-az's Functions/AKS/Redis/ACR services are never used, this script
# is unnecessary — a plain `podman-compose -f podman-compose.yml up -d`
# still works fine for AWS-only (floci-core) work, since floci-core never
# spawns sidecars and never touches netavark.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
  echo "Applying netavark iptables fix (host-side, systemd user environment)..."
  systemctl --user set-environment NETAVARK_FW=iptables
  # podman.service may already be running with the OLD environment cached —
  # stop it so the next request re-triggers socket activation with the
  # environment we just set. Not an error if it's already inactive.
  systemctl --user stop podman.service 2>/dev/null || true
  systemctl --user restart podman.socket
else
  echo "WARNING: systemctl --user is not available on this host — skipping the" >&2
  echo "  netavark/iptables fix. floci-az's Functions/AKS/Redis/ACR services may" >&2
  echo "  fail to spawn sidecar containers with an nftables error. See" >&2
  echo "  CONTEXT.md's Research log for details." >&2
fi

echo "Starting floci-core + floci-az..."
podman-compose -f "$ROOT_DIR/podman-compose.yml" up -d
