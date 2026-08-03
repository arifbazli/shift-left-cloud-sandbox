# floci-stack — Shift-Left Cloud Security Sandbox

> Local-only R&D sandbox for shift-left cloud security on Debian WSL + rootless Podman.

<br>

<div align="center">

[![live dashboard](https://img.shields.io/badge/dashboard-live-00d4aa?style=for-the-badge&logo=cloudflare&logoColor=white)](https://shift-left-cloud-sandbox.pages.dev)
[![tfsec pinned](https://img.shields.io/badge/tfsec-pinned_1.28.5-f6c54b?style=for-the-badge&logo=terraform&logoColor=white)](#tool-pins)
[![offline only](https://img.shields.io/badge/backend-offline_only-6c7afc?style=for-the-badge&logo=podman&logoColor=white)](#data--privacy)
[![no kv/d1](https://img.shields.io/badge/cloudflare-pages_static_only-ff8c42?style=for-the-badge&logo=cloudflarepages&logoColor=white)](#data--privacy)
[![MIT-style](https://img.shields.io/badge/license-local_R%26D-5b6376?style=for-the-badge)](#license)

</div>

<br>

## Contents

- [Quick Start](#quick-start)
- [Dataflow](#dataflow)
- [Repo layout](#repo-layout)
- [Demo walkthrough](#demo-walkthrough)
- [Security controls](#security-controls)
- [Tool pins](#tool-pins)
- [Misconfig demo](#misconfig-demo)
- [Data & Privacy](#data--privacy)
- [Floci limitation](#floci-limitation)
- [License](#license)

<br>

## Quick Start

**Prerequisites:** `podman` 5.x · `terraform` 1.5+ · `wrangler` 4.x · `jq` 1.7+ · `podman-compose` 1.6+ · `python3` 3.10+

```bash
# 1. Bring up floci-core
podman-compose -f podman-compose.yml up -d

# 2. Run the pipeline
./scripts/scan.sh             # FAILS — deliberate IAM misconfig present
./scripts/toggle-fixture.sh off
./scripts/scan.sh             # PASSES
./scripts/deploy.sh           # terraform apply → floci
./scripts/verify.sh           # curl floci directly, confirm bucket / VPC / role exist
./scripts/drift-check.sh      # exit 0 (or 2 if drift)
./scripts/agent-loop.sh &     # bounded remediation loop

# 3. Dashboard (local)
wrangler pages dev dashboard/public --port 8788
# open http://localhost:8788
```

Live: **https://shift-left-cloud-sandbox.pages.dev**

<br>

## Dataflow

> [!NOTE]
> **Diagram design language.** Black-filled rectangles = action nodes; white rectangles = pass-throughs; amber diamond = security gate (the only color); white cylinder = JSON data store. Frosted-card clusters with soft drop shadows and 14px rounded corners. Inter/system-ui at 12px.

<img src="dashboard/public/data/developer-dataflow.svg" width="900" alt="Developer-terminal dataflow. Six stages left-to-right: scan.sh and deploy.sh (black action nodes) plus amber GATE diamond in '① ② GATE & APPLY'; verify.sh (white pass-through) in '③ VERIFY'; drift-check.sh (white pass-through) in '④ DRIFT'; agent-loop.sh feeding the JSON cylinder, branching to pages dev and pages deploy in '⑤ ⑥ RESPOND'."/>

<sub>Source: <a href="docs/diagrams/developer-dataflow.mmd">docs/diagrams/developer-dataflow.mmd</a> · rendered with <a href="scripts/render-mermaid.sh">scripts/render-mermaid.sh</a> · <a href="docs/diagrams/mermaid-config.json">mermaid-config.json</a></sub>

<br>

## Repo layout

| Path | Purpose |
|---|---|
| `terraform/` | VPC + S3 + IAM + SG + flow logs (endpoint-overridable) |
| `terraform/main.tf` | Shape + one deliberate HIGH fixture |
| `scripts/scan.sh` | tfsec gate → dashboard JSON |
| `scripts/toggle-fixture.sh` | Toggle the deliberate misconfig on/off |
| `scripts/deploy.sh` | `terraform apply` against floci (4 hard guards) |
| `scripts/verify.sh` | curl floci directly, confirm resources exist |
| `scripts/drift-check.sh` | `terraform plan -detailed-exitcode` → dashboard JSON |
| `scripts/agent-loop.sh` | Bounded remediation loop (allowlist only) |
| `scripts/sync-dashboard.sh` | Hard-gated publish of dashboard JSON |
| `dashboard/public/` | Static HTML/JS/CSS + 10 JSON data files |
| `wrangler.toml` | Cloudflare Pages config (no KV/D1/Workers) |
| `podman-compose.yml` | floci-core + floci-ui only |

<br>

## Demo walkthrough

> Assumes `podman-compose -f podman-compose.yml up -d` has run.

### State 1 — blocked misconfig

```bash
./scripts/scan.sh
# → tfsec: 2 HIGH (the fixture)  →  gate: FAIL  →  deploy blocked
```

### State 2 — passing deploy

```bash
./scripts/toggle-fixture.sh off
./scripts/scan.sh             # gate: PASS
./scripts/deploy.sh           # terraform apply → floci outputs: vpc_id, bucket, role ARN
./scripts/verify.sh           # PASS: VPC, bucket, role, SG all exist
```

### State 3 — dashboard

```bash
wrangler pages dev dashboard/public --port 8788
# open http://localhost:8788
# → tfsec gate card + drift card + agent loop + deploy/verify
# → "stale" badge warns past 2 min, escalates past 5 min
```

### State 4 — drift + agent

```bash
./scripts/drift-check.sh      # exit 2 (drift)
./scripts/agent-loop.sh       # snapshot → terraform apply (if safe + tfsec PASS)
```

<br>

## Security controls

| Control | Behaviour |
|---|---|
| **tfsec gate** | Blocks `deploy.sh`; freezes agent drift-reconciliation when any HIGH/CRITICAL is open |
| **Snapshot-first** | `terraform.tfstate` snapshotted before every `terraform apply`, no exceptions |
| **Credential gate** | `sync-dashboard.sh` refuses push if `AKIA`/`cfut_`/`BEGIN PRIVATE KEY`/non-floci ARNs found in staged diff |

Agent allowlist — only two actions, nothing else:

- `podman restart floci-core` — when container is not running
- `terraform apply -auto-approve` — only when drift is `safe` **and** latest tfsec gate is `PASS`; never touches `*.tf`; never destroys; never applies if security-tagged resources change

<br>

## Tool pins

> [!CAUTION]
> tfsec **1.28.10 has a regression** where `tfsec:ignore:` directives are silently dropped — the deliberate misconfig would appear clean and unblock deploy. Pin to 1.28.5.

<details>
<summary>Pinned tool versions + install snippets</summary>

| Tool | Version | Why |
|---|---|---|
| `tfsec` | **1.28.5** | 1.28.10 regression: ignores silently dropped |
| `terraform` | 1.9.8 | Last 1.x BSL release tested |
| `jq` | 1.7.1 | `--rawfile` flag needed by scripts |
| `podman-compose` | 1.6.0 | Rootless Podman compatibility |

```bash
# tfsec (no sudo — installs to ~/.local/bin)
mkdir -p ~/.local/bin
curl -fsSL https://github.com/aquasecurity/tfsec/releases/download/v1.28.5/tfsec-linux-amd64 \
  -o ~/.local/bin/tfsec && chmod +x ~/.local/bin/tfsec

# Verify
tfsec --version 2>&1 | grep -E "^v1\.28\.5$" || echo "WRONG VERSION"
```

</details>

<br>

## Misconfig demo

One deliberate HIGH misconfig (`aws_iam_policy.fixtures_admin`, `Action:"*"` / `Resource:"*"`) is compiled in. Toggle with `scripts/toggle-fixture.sh on|off`.

**Option A (preferred):** `toggle-fixture.sh off` → `scan.sh` → 0 HIGH → `deploy.sh` unblocked → `toggle-fixture.sh on` to restore.

> [!WARNING]
> `agent-loop.sh` cannot toggle or fix this — security findings are a human job.

<br>

## Data & Privacy

- All IaC targets LocalStack-style floci (endpoint override) — **no real AWS calls, no real AWS account**
- floci-core runs as a rootless Podman container, no host-network
- Dashboard is static JSON served by `wrangler pages dev` — **no backend, no KV, no D1, no Workers**
- Nothing outside `dashboard/public/data/*.json` ever leaves the machine; `sync-dashboard.sh` hard-gates on credential patterns before any push

<br>

## Floci limitation

floci-core is a Podman-managed stub container — not a real production workload. It exists only to give `verify.sh` and `drift-check.sh` something to call.

> [!TIP]
> If `aws_flow_log.main` shows as `destructive` drift on every run, that's expected — floci doesn't echo the attached IAM role ARN back, so the plan always reports delete+create for that resource. The agent correctly refuses.

<br>

## License

Local R&D sandbox. Use at will.

---

<div align="center">
<sub>
<a href="https://github.com/arifbazli/shift-left-cloud-sandbox"><code>shift-left-cloud-sandbox</code></a> ·
<a href="https://shift-left-cloud-sandbox.pages.dev">shift-left-cloud-sandbox.pages.dev</a> ·
<a href="https://github.com/arifbazli/shift-left-cloud-sandbox/issues">report a bug</a>
</sub>
</div>
