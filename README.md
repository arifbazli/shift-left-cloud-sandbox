# floci-stack — Shift-Left Cloud Security Sandbox

> Local-only R&D sandbox for shift-left cloud security on Debian WSL + rootless Podman.

<div align="center">

[![live dashboard](https://img.shields.io/badge/dashboard-live-00d4aa?style=for-the-badge&logo=cloudflare&logoColor=white)](https://shift-left-cloud-sandbox.pages.dev)
[![tfsec pinned](https://img.shields.io/badge/tfsec-pinned_1.28.5-f6c54b?style=for-the-badge&logo=terraform&logoColor=white)](SKILL.md#tool-pins)
[![offline only](https://img.shields.io/badge/backend-offline_only-6c7afc?style=for-the-badge&logo=podman&logoColor=white)](CONTEXT.md#offline-first-design)
[![no kv/d1](https://img.shields.io/badge/cloudflare-pages_static_only-ff8c42?style=for-the-badge&logo=cloudflarepages&logoColor=white)](CONTEXT.md#backend-never-exposed--the-data-plane-table)
[![MIT-style](https://img.shields.io/badge/license-local_R%26D-5b6376?style=for-the-badge)](#license)

</div>

**Docs:** [CONTEXT.md](CONTEXT.md) (architecture, why floci, security rationale) · [SKILL.md](SKILL.md) (AI agent operating guide) · [CHANGELOG.md](CHANGELOG.md)

floci-stack gates every `terraform apply` behind a pinned tfsec scan, applies only once the gate passes, against **floci** — a single-container [moto](https://github.com/getmoto/moto) AWS stub, not real AWS — then lets a deliberately narrow agent reconcile only safe drift. A static Cloudflare Pages dashboard shows the whole loop live; the only thing that ever leaves this machine is that dashboard's JSON.

## TL;DR

```bash
podman-compose -f podman-compose.yml up -d   # start floci-core (moto) on :4566
./scripts/toggle-fixture.sh off              # disable the deliberate misconfig fixture
./scripts/scan.sh && ./scripts/deploy.sh     # tfsec gate → terraform apply (7 modules)
./scripts/verify.sh && ./scripts/drift-check.sh && ./scripts/agent-loop.sh &
wrangler pages dev dashboard/public --port 8788   # open http://localhost:8788
```

**Prerequisites (local dev):** `podman` 5.x · `terraform` 1.9.8 · `tfsec` **1.28.5** (pinned — [why](SKILL.md#tool-pins)) · `jq` 1.7.1 · `podman-compose` 1.6.0 · `python3` 3.10+ · WSL2 (Debian) — see [SKILL.md](SKILL.md#before-touching-this-repo) before running anything. CI's `scan`/`deploy-local` jobs provision their own tfsec/Terraform/Podman on `ubuntu-latest` and don't need any of this locally-documented setup.

**Live dashboard:** **https://shift-left-cloud-sandbox.pages.dev**

For architecture diagrams, why floci is a `moto` stub instead of real AWS, what the deliberate misconfig demonstrates, and the full security-decision catalog, see **[CONTEXT.md](CONTEXT.md)**.

## Demo walkthrough

```bash
./scripts/toggle-fixture.sh on  && ./scripts/scan.sh   # HIGH finding → gate FAIL → deploy blocked
./scripts/toggle-fixture.sh off && ./scripts/scan.sh   # gate PASS → ./scripts/deploy.sh → ./scripts/verify.sh
./scripts/drift-check.sh && ./scripts/agent-loop.sh    # safe drift + gate PASS → agent reconciles
```

## Security controls (top-level)

| Control | Behaviour |
|---|---|
| tfsec gate | Blocks `deploy.sh`; freezes agent drift-reconciliation while any HIGH/CRITICAL is open |
| Credential gate | `sync-dashboard.sh` refuses to push if it finds AWS keys, private keys, or non-floci ARNs |
| CODEOWNERS | `modules/security/`, gate scripts, and `.github/` all require human review |
| Agent allowlist | `agent-loop.sh` may only restart `floci-core` or apply safe drift — never edits `*.tf`, never destroys |

Full catalog (14 `SEC_INTENT` decisions, one per file): [CONTEXT.md § Security decisions in code](CONTEXT.md#security-decisions-in-code).

## Repo layout

| Path | Purpose |
|---|---|
| `terraform/` | Root module — wires all 7 modules |
| `terraform/modules/network/` | VPC, private subnet, SG, flow logs |
| `terraform/modules/storage/` | S3 artifacts + DynamoDB |
| `terraform/modules/security/` | IAM app role, KMS CMK, Secrets Manager, ACM + **fixture** |
| `terraform/modules/compute/` | EC2 (IMDSv2), Lambda, ECS Fargate, EKS (CMK secrets) |
| `terraform/modules/messaging/` | SQS + DLQ, SNS (CMK), EventBridge, Step Functions |
| `terraform/modules/data/` | RDS, ElastiCache Redis, MSK Kafka (CMK), OpenSearch |
| `terraform/modules/api/` | API Gateway REGIONAL, CloudWatch logs + alarm |
| `.github/workflows/pipeline.yml` | Main CI: scan → deploy-local → publish-dashboard → pr-comment |
| `.github/workflows/auto-fix.yml` | `scripts/ai/triage.py` remediation, triggered by the `auto-fix` label |
| `.github/workflows/deploy-dashboard.yml` | Standalone dashboard publish |
| `.github/CODEOWNERS` | Gate scripts + fixture path require review — see [SKILL.md](SKILL.md) |
| `scripts/scan.sh` | tfsec gate → dashboard JSON |
| `scripts/toggle-fixture.sh` | Toggle the deliberate misconfig on/off |
| `scripts/deploy.sh` | `terraform apply` against floci (hard guards + output capture) |
| `scripts/verify.sh` | Confirms deployed resources exist, independent of terraform state |
| `scripts/drift-check.sh` | `terraform plan -detailed-exitcode` → classified dashboard JSON |
| `scripts/agent-loop.sh` | Bounded remediation loop (allowlist only — see [SKILL.md](SKILL.md)) |
| `scripts/ai/triage.py` | Allowlisted MEDIUM/LOW auto-remediation for the `auto-fix` workflow |
| `scripts/sync-dashboard.sh` | The only script allowed to auto-push — credential-gated |
| `scripts/data-server.py` | Local SSE server: 1s live dashboard updates, run-buttons |
| `scripts/setup-runner.sh` | Bootstrap the `floci-self-hosted` GitHub Actions runner |
| `dashboard/public/` | Static HTML/JS/CSS + JSON — no backend, no KV, no D1 |

## CI secrets

The pipeline needs a **self-hosted runner** (`floci-self-hosted`, on the Debian WSL machine — floci isn't reachable from GitHub-hosted runners) and two repo secrets: `CLOUDFLARE_API_TOKEN` (Pages-scoped) and `CLOUDFLARE_ACCOUNT_ID`. Full setup and branch protection: [`.github/branch-protection.md`](.github/branch-protection.md).

## License

Local R&D sandbox. Use at will.

---

<div align="center">
<sub>
<a href="https://github.com/arifbazli/shift-left-cloud-sandbox"><code>shift-left-cloud-sandbox</code></a> ·
<a href="https://shift-left-cloud-sandbox.pages.dev">shift-left-cloud-sandbox.pages.dev</a>
</sub>
</div>
