# floci-stack — Shift-Left Cloud Security Sandbox

A local, fully offline sandbox that demonstrates **shift-left cloud security**:
Terraform → tfsec gate → apply against `floci-core` (localstack-style AWS API
mock) → verify against the real API → drift detection → a tiny bounded
"infra engineer" agent that can react to drift but **never touches `.tf`
files or fixes security findings**.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  developer terminal                                                         │
│                                                                             │
│  scripts/scan.sh     ─► tfsec (terraform/) ─► gate ─► dashboard JSON        │
│            │                                                                │
│            ▼ passes                                                         │
│  scripts/deploy.sh   ─► terraform apply (endpoints → floci)                  │
│            │                                                                │
│            ▼                                                                 │
│  scripts/verify.sh   ─► curl floci-core / curl floci-ui     → dashboard JSON│
│            │                                                                │
│            ▼                                                                 │
│  scripts/drift-check.sh ─► terraform plan -detailed-exitcode → dashboard JSON│
│            │                                                                │
│            ▼                                                                 │
│  scripts/agent-loop.sh ─► bounded allowlist (restart / apply drift)         │
│                                                                             │
│  dashboard/         ─► wrangler pages dev dashboard/public (Cloudflare Pages)│
│                        reads the three JSON files as static assets          │
└─────────────────────────────────────────────────────────────────────────────┘
```

## TL;DR demo

```bash
# 1. Bring up floci-core + floci-ui (one command)
podman-compose -f podman-compose.yml up -d

# 2. Run the pipeline (each script tests the one before)
./scripts/scan.sh          # FAILS — the deliberate IAM misconfig is present
./scripts/toggle-fixture.sh off
./scripts/scan.sh          # PASSES
./scripts/deploy.sh        # terraform apply → floci
./scripts/verify.sh        # curl floci directly, confirm bucket / VPC / role exist
./scripts/drift-check.sh   # exit 0
./scripts/agent-loop.sh &  # bounded remediation loop

# 3. In a separate terminal: the dashboard
wrangler pages dev dashboard/public --port 8788
# open http://localhost:8788
```

## Pre-flight: tool pins

This sandbox has **one important tool pin** that must be respected or the
tfsec gate will silently stop working as a gate.

| Tool | Version | Why pinned |
|---|---|---|
| **tfsec** | **1.28.5** | tfsec **1.28.10 has a regression** where `--exclude`/`--config-file`/inline `tfsec:ignore:` are silently ignored. The deliberate misconfig fixture would mark as "clean" and deploy would proceed. Pinned to 1.28.5, which honors ignores correctly. |

Install script (no sudo required — installs to `~/.local/bin`):

```bash
mkdir -p ~/.local/bin
curl -fsSL https://github.com/aquasecurity/tfsec/releases/download/v1.28.5/tfsec-linux-amd64 \
  -o ~/.local/bin/tfsec && chmod +x ~/.local/bin/tfsec
# Hash check (optional but recommended):
#   sha256sum ~/.local/bin/tfsec
#   sha256sum docs/tfsec-1.28.5.sha256
```

If you `brew install tfsec` or `npx tfsec` and get a newer version, **the gate
does not work**. Verify with:

```bash
tfsec --version 2>&1 | grep -E "^v1\.28\.5$" || echo "WRONG VERSION"
```

Also required:

| Tool | Min version | Notes |
|---|---|---|
| podman | 5.x | rootless; DOCKER_HOST=podman.socket if you use the docker CLI |
| terraform | 1.5+ | `terraform init` will pull `hashicorp/aws ~> 5.0` |
| wrangler | 4.x | Cloudflare Pages local dev server |
| jq | 1.7+ | JSON wrangling in scripts |
| podman-compose | 1.6+ | OR `docker compose` with `DOCKER_HOST=unix:///run/user/$UID/podman/podman.sock` |
| python3 | 3.10+ | only used by the dashboard's tiny post-processor, no deps |

## What "deliberate misconfig" means

`terraform/main.tf` contains one resource tagged
`# >>>>>>>>>>>>>>  DELIBERATE MISCONFIGURATION  <<<<<<<<<<<<<<` — an IAM
policy with `Action:"*"`, `Resource:"*"`. Scripts/scan.sh blocks
**any HIGH or CRITICAL** finding. To pass the gate, you either:

1. **Toggle the fixture off** (preferred for the demo):
   ```bash
   ./scripts/toggle-fixture.sh off   # comments out the fixture
   ./scripts/scan.sh                 # → 0 HIGH/CRITICAL
   ./scripts/deploy.sh               # → applies
   ./scripts/toggle-fixture.sh on    # restore for the next demo
   ```

2. Or edit `terraform/main.tf` manually and remove the two `aws_iam_policy`
   and `aws_iam_role_policy_attachment` blocks inside the fixture banner.

The agent-loop is **explicitly forbidden** from doing either. The allowlist
is restart-container + apply-pure-drift. Fixing security findings is a
human job (see "Why the agent is so restricted" below).

## Why the agent is so restricted

`scripts/agent-loop.sh` is a deliberately tiny `bash` loop, not an LLM. The
spec says "bounded local infra engineer" — and the smallest possible
action surface is the safest. It can:

- **Restart a crashed floci container** — `podman restart floci-core`
- **Apply pure config drift** — `terraform apply -auto-approve` only if
  `terraform plan -detailed-exitcode` returned 2 (drift) AND the plan
  contains *no* additions/removals/replacements to security-tagged
  resources (VPC SG, IAM, S3 public access blocks, S3 bucket policies)

It freezes on any open HIGH/CRITICAL tfsec finding. It snapshots
`terraform.tfstate` before every action. It logs every action *and non-action
with reason* to `dashboard/public/data/agent-actions.json`. Everything is
auditable after the fact.

It will never:
- Edit `*.tf` files
- `terraform destroy` anything
- Run `terraform apply` if the plan changes security-tagged resources
- Disable or bypass the tfsec gate
- Touch `dashboard/public/data/*.json` files other than appending well-formed
  events to `agent-actions.json`

This is by design. If you want a smarter agent, you have to read the
allowlist and modify it deliberately — and that review IS the change
control.

## Architecture

```
floci-stack/
├── terraform/             VPC + S3 + IAM + SG + flow logs. Endpoint-overridable.
│   ├── main.tf            The "shape" + one deliberate fixture
│   ├── main.tf.with-fixture    Snapshot used by toggle-fixture.sh (committed)
│   ├── main.tf.without-fixture Snapshot used by toggle-fixture.sh (committed)
│   ├── providers.tf       AWS provider with floci endpoint overrides
│   ├── variables.tf       localstack_enabled = true (default)
│   └── outputs.tf         vpc_id, bucket name, role ARN, SG ID
├── scripts/
│   ├── scan.sh            tfsec gate → dashboard JSON
│   ├── toggle-fixture.sh  comment/uncomment the deliberate misconfig
│   ├── bootstrap-fixture-snapshots.sh  regenerate the two main.tf.* files
│   ├── deploy.sh          terraform apply against floci (guarded)
│   ├── verify.sh          curl floci directly, confirm resources exist
│   ├── drift-check.sh     terraform plan -detailed-exitcode → dashboard JSON
│   ├── agent-loop.sh      bounded remediation loop (allowlist only)
│   └── sync-dashboard.sh  hard-gated publish of dashboard JSON only
├── dashboard/
│   └── public/
│       ├── index.html     ← three JSON files as static assets, no KV/D1
│       ├── app.js
│       └── data/
│           ├── tfsec-last.json       (written by scan.sh)
│           ├── tfsec-history.json    (written by scan.sh)
│           ├── deploy-last.json      (written by deploy.sh)
│           ├── deploy-history.json   (written by deploy.sh)
│           ├── verify-pending.json   (written by deploy.sh, consumed by verify.sh)
│           ├── verify-last.json      (written by verify.sh)
│           ├── verify-history.json   (written by verify.sh)
│           ├── drift-last.json       (written by drift-check.sh)
│           ├── drift-history.json    (written by drift-check.sh)
│           └── agent-actions.json    (written by agent-loop.sh)
├── wrangler.toml          Cloudflare Pages project config (no KV/D1/Workers)
├── podman-compose.yml     floci-core + floci-ui only
└── README.md              (this file)
```

## Offline-first design

- No `apt` deps beyond what's already on Debian
- No Cloudflare account, no KV, no D1, no remote API calls
- All data is local files in `dashboard/public/data/*.json`
- `wrangler pages dev` is **purely local** — it does not talk to Cloudflare
  even if you have a token configured
- The only "external" URLs the sandbox touches are:
  - `http://localhost:4566` (floci-core API)
  - `http://localhost:4569` (floci-ui, if enabled)
  - the wrangler dev server you start on `localhost:8788`

## Backend never exposed — only JSON leaves the machine

The deployment surface that ever leaves this box is exactly three JSON
files under `dashboard/public/data/`:

- `tfsec-last.json` / `tfsec-history.json` (gating verdicts)
- `drift-last.json` / `drift-history.json` (state vs desired)
- `agent-actions.json` (allowlisted actions + heartbeats)

Nothing else — no terraform.tfstate, no AWS account ID, no floci binary,
no podman container, no real credential — ever appears in any file that
gets published. `scripts/sync-dashboard.sh` enforces this with a hard
gate that scans the staged diff for AWS access key prefixes (`AKIA`/`ASIA`),
private key markers, Cloudflare token literals, ARNs with non-floci account
IDs, and rejects anything outside `dashboard/public/data/`.

## Known floci limitation (not a bug in this repo)

`aws_flow_log.main` will appear as `destructive` drift on every
`drift-check.sh` run after a deploy, because floci-core does not echo the
attached IAM role ARN back through its AWS-shaped API. The plan therefore
always reports `delete` + `create` actions for that single resource, which
the drift classifier maps to `destructive`.

This is correct defensive behavior on the part of the agent — a real
production agent should refuse to destroy and recreate a resource whose
state it cannot verify was actually broken. It is **not** a bug in
`scripts/drift-check.sh` or `scripts/agent-loop.sh`. Operators can confirm
the cause by running:

```bash
cd terraform && terraform show -json .drift.tfplan | \
  jq '.resource_changes[] | select(.address == "aws_flow_log.main")'
```

and will see `iam_role_arn: ""` in the `before` block.

## Why floci specifically

`floci-core` is a localstack-style AWS API mock written in Rust. It supports
the subset of AWS API calls that Terraform's AWS provider makes for VPC,
S3, IAM, EC2, and STS. We picked it over localstack because:
- Smaller image (~80MB vs ~1.5GB)
- 100% offline, no license telemetry
- One binary, no Java/Python runtime
- Same API surface for the Terraform provider, so no special Terraform
  config beyond the `endpoints` block.

If you swap to localstack, set `TF_VAR_localstack_endpoint` to its port
(default 4566 anyway) and you're done.

## Demo walkthrough

### State 1: blocked misconfig

```bash
podman-compose -f podman-compose.yml up -d
./scripts/scan.sh
# → tfsec: 2 HIGH (the fixture)
# → gate: FAIL
# → last_run.json shows the failing findings
```

### State 2: passing deploy

```bash
./scripts/toggle-fixture.sh off
./scripts/scan.sh
# → tfsec: 0 HIGH, 0 CRITICAL
# → gate: PASS
./scripts/deploy.sh
# → terraform apply → floci
# → outputs: vpc_id, bucket name, role ARN
./scripts/verify.sh
# → curl floci for each output
# → PASS: VPC, bucket, role, SG all exist
```

### State 3: dashboard

```bash
wrangler pages dev dashboard/public --port 8788
# open http://localhost:8788
# → shows 2 events (1 failed scan, 1 passed scan)
# → shows the deploy + verify events
# → live agent heartbeat from agent-loop.sh
```

### State 4: drift

```bash
# Manually break a tag in floci (or via a script)
./scripts/drift-check.sh
# → exit 2 (drift detected)
# → logs to drift-history.json
./scripts/agent-loop.sh
# → sees drift + sees latest tfsec is clean
# → snapshots terraform.tfstate
# → runs terraform apply -auto-approve
# → logs "reconciled drift" with before/after state snapshot paths
```

## Security decisions in code

Every Terraform resource, every script, has a `SEC_INTENT` or `# SEC:`
comment explaining what's tight, what's loose, and why. The comments are
deliberately verbose — this is a sandbox meant to be read by humans learning
shift-left.

Things that are deliberately loose for the sandbox:
- Egress `0.0.0.0/0` on 443 + 53 (with explicit `tfsec:ignore:` and rationale)
- AES256 SSE instead of CMK (with explicit `tfsec:ignore:` — floci has no KMS)
- IAM `*.s3:GetObject` on `bucket/*` (with explicit `tfsec:ignore:` — bucket-scoped, not account-wide)
- S3 access logging disabled (MEDIUM only, not blocking)
- S3 versioning on flow-logs bucket disabled (MEDIUM only, not blocking)

The only thing intentionally UN-ignored is the IAM `Action:"*"` fixture —
that's the regression test for the gate.

## What this is NOT

- Not a production-grade IaC pipeline. Use Spacelift/Atlantis/Env0 for that.
- Not a real Cloudflare Pages deploy. Use `wrangler pages deploy` for that.
- Not a substitute for Checkov / Trivy / Snyk. tfsec is one of several
  scanners you should run in a real pipeline.
- Not a "smart" agent. The agent-loop is a bash loop with a tight allowlist.
  That's the point.

## License

Local R&D sandbox. Use at will.
