# floci-stack — Shift-Left Cloud Security Sandbox

floci-stack is a local, shift-left security sandbox powered entirely by real [floci.io](https://floci.io) emulators — **floci-core** for AWS and **floci-az** for Azure, running as equal siblings under one sandbox, not "AWS with Azure bolted on." Every `terraform apply` is gated behind a pinned tfsec scan, and each cloud carries one deliberate misconfiguration fixture so the gate has something real to catch. Nothing here ever touches a real cloud account.

**Live dashboard:** https://shift-left-cloud-sandbox.pages.dev

## Quick start

```bash
git clone https://github.com/arifbazli/shift-left-cloud-sandbox.git
cd shift-left-cloud-sandbox
./scripts/start-floci-az.sh   # starts floci-core (:4566) + floci-az (:4577) together
./scripts/scan.sh             # tfsec gate against terraform/ and terraform/azure/
```

**Prerequisites** (identical for both clouds): `podman` 5.x · `terraform` 1.9.8 · `tfsec` **1.28.5** (pinned — [why](SKILL.md#tool-pins)) · `jq` 1.7.1 · `podman-compose` 1.6.0 · `python3` 3.10+ · WSL2 (Debian). CI provisions its own toolchain fresh on `ubuntu-latest` and needs none of this locally-documented setup.

## Repo layout

| Path | Purpose |
|---|---|
| `terraform/` | AWS root — 7 modules (network/storage/security/compute/messaging/data/api) |
| `terraform/azure/` | Azure root — 4 modules (network/storage/security/compute), separate state and provider |
| `scripts/` | All automation — see [SKILL.md](SKILL.md) for the full task-to-script map |
| `dashboard/public/` | Static Cloudflare Pages dashboard — AWS/Azure tab switcher, JSON only |
| `.github/workflows/` | CI pipeline — see [CI secrets](#ci-secrets) below |

Full module-by-module breakdown and every non-obvious design decision: **[CONTEXT.md](CONTEXT.md)**.

## What each cloud can do today

| Cloud | scan | deploy | verify | drift | agent-loop | growth-loop |
|---|---|---|---|---|---|---|
| AWS | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Azure | ✓ | N/A | partial | partial | partial | partial |

Azure's `partial`/`N/A` cells are confirmed *permanent* floci-az limitations (DNS routing, a systemd cgroup gap, a fallback-handler gap) — not something this repo's scripts can fix, and not uncertain the way AWS's slowest resources are. Full explanation: [CONTEXT.md § Known floci-az limitations](CONTEXT.md#known-floci-az-limitations).

## CI secrets

`scan`/`deploy-local`/`publish-dashboard`/`pr-comment` all run on GitHub-hosted `ubuntu-latest` — no self-hosted runner needed. `.github/workflows/auto-fix.yml` is the one exception, still requiring the `floci-self-hosted` runner. Two repo secrets are needed regardless: `CLOUDFLARE_API_TOKEN` (Pages-scoped) and `CLOUDFLARE_ACCOUNT_ID`. Full setup and branch protection: [`.github/branch-protection.md`](.github/branch-protection.md).

## Docs

[CONTEXT.md](CONTEXT.md) — architecture, why floci, every confirmed gap · [SKILL.md](SKILL.md) — AI agent operating guide · [CHANGELOG.md](CHANGELOG.md) — history

## License

Local R&D sandbox. Use at will.
