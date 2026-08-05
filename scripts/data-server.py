#!/usr/bin/env python3
"""
scripts/data-server.py
======================
Local live-data server for the floci-stack dashboard.

Exposes:
  GET /data/<file>.json        — serve latest JSON from dashboard/public/data/
  GET /live                    — SSE stream: pushes all 5 data files every second
  GET /run/<script>            — trigger a script run on-demand (scan/verify/drift/deploy)
  GET /health                  — {"ok": true}

Usage
-----
  python3 scripts/data-server.py            # default port 7788
  python3 scripts/data-server.py --port 7788

Then open the dashboard with the server running:
  wrangler pages dev dashboard/public --port 8788
  # or just open dashboard/public/index.html directly

The dashboard auto-detects the server at http://localhost:7788 and switches
from 10s file-polling to 1s SSE live updates.

SEC_INTENT
----------
Binds to 127.0.0.1 only — never reachable outside the WSL host.
Runs scripts from the repo's scripts/ directory only.
Script allowlist is hard-coded — no arbitrary command execution.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR = Path(__file__).parent.resolve()
ROOT_DIR   = SCRIPT_DIR.parent
DATA_DIR   = ROOT_DIR / "dashboard" / "public" / "data"

# ---------------------------------------------------------------------------
# Script allowlist — maps run-name → script path relative to ROOT_DIR
# SEC_INTENT: only these scripts can be triggered via /run/<name>
# ---------------------------------------------------------------------------
ALLOWED_SCRIPTS: dict[str, Path] = {
    "scan":   SCRIPT_DIR / "scan.sh",
    "verify": SCRIPT_DIR / "verify.sh",
    "drift":  SCRIPT_DIR / "drift-check.sh",
    "deploy": SCRIPT_DIR / "deploy.sh",
}

# ---------------------------------------------------------------------------
# Data file map — maps SSE key → JSON file
# ---------------------------------------------------------------------------
DATA_FILES: dict[str, Path] = {
    "scan":   DATA_DIR / "tfsec-last.json",
    "deploy": DATA_DIR / "deploy-last.json",
    "verify": DATA_DIR / "verify-last.json",
    "drift":  DATA_DIR / "drift-last.json",
    "agent":  DATA_DIR / "agent-actions.json",
}

# ---------------------------------------------------------------------------
# Script runner — runs in a background thread so /run/ returns immediately
# ---------------------------------------------------------------------------
_running: dict[str, bool] = {}
_lock = threading.Lock()

def run_script(name: str) -> dict[str, Any]:
    """Run an allowlisted script. Returns {started, already_running, error}."""
    script = ALLOWED_SCRIPTS.get(name)
    if not script:
        return {"error": f"unknown script '{name}'"}
    if not script.exists():
        return {"error": f"script not found: {script}"}

    with _lock:
        if _running.get(name):
            return {"started": False, "already_running": True}
        _running[name] = True

    def _run():
        env = {
            **os.environ,
            "AWS_ACCESS_KEY_ID":     "test",
            "AWS_SECRET_ACCESS_KEY": "test",
            "AWS_DEFAULT_REGION":    "us-east-1",
            "FLOCI_ENDPOINT":        os.environ.get("FLOCI_ENDPOINT", "http://localhost:4566"),
        }
        try:
            subprocess.run(
                ["bash", str(script)],
                cwd=str(ROOT_DIR),
                env=env,
                timeout=120,
            )
        except Exception as e:
            print(f"[data-server] script {name} error: {e}", file=sys.stderr)
        finally:
            with _lock:
                _running[name] = False

    t = threading.Thread(target=_run, daemon=True)
    t.start()
    return {"started": True, "script": name}

# ---------------------------------------------------------------------------
# Read all data files into one snapshot dict
# ---------------------------------------------------------------------------
def read_snapshot() -> dict[str, Any]:
    snapshot: dict[str, Any] = {}
    for key, path in DATA_FILES.items():
        try:
            with open(path) as f:
                snapshot[key] = json.load(f)
        except FileNotFoundError:
            snapshot[key] = None
        except json.JSONDecodeError as e:
            snapshot[key] = {"__error": f"JSON parse error: {e}"}
        except Exception as e:
            snapshot[key] = {"__error": str(e)}

    # Inject running state so the dashboard can show a spinner
    snapshot["_running"] = {k: v for k, v in _running.items() if v}
    snapshot["_ts"] = time.time()
    return snapshot

# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):  # suppress default access log noise
        pass

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.send_header("Cache-Control", "no-store")

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_GET(self):
        path = self.path.split("?")[0].rstrip("/")

        # ── /health ────────────────────────────────────────────────────────
        if path == "/health":
            self._json({"ok": True, "server": "data-server/1.0"})

        # ── /data/<file>.json ──────────────────────────────────────────────
        elif path.startswith("/data/") and path.endswith(".json"):
            filename = path[len("/data/"):]
            # Security: no path traversal
            if "/" in filename or ".." in filename:
                self._err(400, "invalid path")
                return
            fpath = DATA_DIR / filename
            if not fpath.exists():
                self._err(404, "not found")
                return
            try:
                self._json(json.loads(fpath.read_text()))
            except Exception as e:
                self._err(500, str(e))

        # ── /run/<script> ──────────────────────────────────────────────────
        elif path.startswith("/run/"):
            name = path[len("/run/"):]
            result = run_script(name)
            self._json(result)

        # ── /live  (SSE) ───────────────────────────────────────────────────
        elif path == "/live":
            self._sse()

        else:
            self._err(404, "not found")

    def _json(self, obj: Any, status: int = 200):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self._cors()
        self.end_headers()
        self.wfile.write(body)

    def _err(self, status: int, msg: str):
        self._json({"error": msg}, status)

    def _sse(self):
        """Server-Sent Events stream. Pushes a snapshot every second."""
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("X-Accel-Buffering", "no")
        self._cors()
        self.end_headers()

        last_snapshot_json = ""
        try:
            while True:
                snap = read_snapshot()
                snap_json = json.dumps(snap)

                # Only push when data actually changed (reduces repaints)
                if snap_json != last_snapshot_json:
                    msg = f"data: {snap_json}\n\n"
                    self.wfile.write(msg.encode())
                    self.wfile.flush()
                    last_snapshot_json = snap_json

                time.sleep(1)
        except (BrokenPipeError, ConnectionResetError):
            pass  # client disconnected — normal

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=7788)
    parser.add_argument("--host", type=str, default="127.0.0.1",
                        help="Bind address (default 127.0.0.1 — localhost only)")
    args = parser.parse_args()

    DATA_DIR.mkdir(parents=True, exist_ok=True)

    server = HTTPServer((args.host, args.port), Handler)
    print(f"data-server listening on http://{args.host}:{args.port}")
    print(f"  /health        — health check")
    print(f"  /live          — SSE stream (1s updates)")
    print(f"  /data/<f>.json — serve data file")
    print(f"  /run/<script>  — trigger script (allowed: {', '.join(ALLOWED_SCRIPTS)})")
    print(f"  root: {ROOT_DIR}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\ndata-server stopped.")

if __name__ == "__main__":
    main()
