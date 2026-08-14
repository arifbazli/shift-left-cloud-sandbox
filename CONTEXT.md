# CONTEXT.md — Architecture & Security Rationale

This document is the deep-dive companion to [README.md](README.md). README is the
quick start; this is *why the sandbox is built the way it is*. See also
[SKILL.md](SKILL.md) (operating rules for AI agents in this repo) and
[CHANGELOG.md](CHANGELOG.md).

## Contents

- [Architecture](#architecture)
- [Why floci specifically](#why-floci-specifically)
- [Why floci-az](#why-floci-az)
- [What "deliberate misconfig" means](#what-deliberate-misconfig-means)
- [Offline-first design](#offline-first-design)
- [Backend never exposed — the data-plane table](#backend-never-exposed--the-data-plane-table)
- [Known floci limitation](#known-floci-limitation)
- [Known floci-az limitations](#known-floci-az-limitations)
- [Growth loop](#growth-loop)
- [Security decisions in code](#security-decisions-in-code)
- [Research log](#research-log)

## Architecture

Four diagrams, each a different zoom level on the same loop. Sources live in
`docs/diagrams/*.mmd`; `scripts/render-mermaid.sh` can render them to SVG for
non-Mermaid viewers, but GitHub renders the blocks below natively.

### Pipeline overview

```mermaid
flowchart LR
    PR[Pull Request] -->|push/PR| GH[GitHub Actions]

    subgraph CI ["CI — floci-self-hosted runner"]
        GH --> SCAN[scan\ntfsec gate]
        SCAN -->|PASS| DEPLOY[deploy-local\nterraform apply]
        SCAN -->|FAIL| BLOCK[blocked ❌]
        SCAN --> COMMENT[pr-comment\ngate summary]
    end

    subgraph PUB ["Publish — ubuntu-latest"]
        DEPLOY --> PAGES[publish-dashboard\nCloudflare Pages]
    end

    subgraph LOCAL ["Local loop"]
        DEPLOY --> VERIFY[verify.sh]
        VERIFY --> DRIFT[drift-check.sh]
        DRIFT -->|safe drift\n+ gate PASS| AGENT[agent-loop.sh]
        AGENT -->|HIGH/CRITICAL| TRIAGE[ai/triage.py\nallowlist only]
    end

    DEPLOY --> DASH[(dashboard JSON)]
    DRIFT  --> DASH
    AGENT  --> DASH
    DASH   --> PAGES

    style BLOCK fill:#fde2e2,stroke:#e05252,color:#7a1f1f
    style SCAN fill:#fff7d6,stroke:#f6c54b,color:#5a4400
    style TRIAGE fill:#e8f4ff,stroke:#4a90e2,color:#1a3a5c
```

### Local sandbox loop

```mermaid
flowchart LR
    subgraph L["LOCAL SANDBOX"]
        direction TB
        TF["Terraform + tfsec"]
        FL["Floci Podman"]
        CK["Checks"]
        AG["Bounded agent"]
        SN["Snapshot + act"]
        TF --> FL --> CK --> AG --> SN
    end

    subgraph SY["SYNC"]
        direction TB
        GATE{"Credential gate"}
        SN --> GATE
    end

    subgraph C["PUBLIC"]
        direction TB
        REPO[("GitHub repo")]
        PAGES["Cloudflare Pages"]
        REPO --> PAGES
    end

    GATE -->|"push"| REPO

    %% 2026 modern aesthetic: black-and-white shape language with one
    %% warm amber accent reserved for the security choke-point (GATE).
    classDef section fill:#ffffff,stroke:#0a0a0a,color:#0a0a0a,stroke-width:1px
    classDef black fill:#0a0a0a,stroke:#0a0a0a,color:#ffffff,stroke-width:2px
    classDef white fill:#ffffff,stroke:#0a0a0a,color:#0a0a0a,stroke-width:1.5px
    classDef diamond fill:#ff6b35,stroke:#ff6b35,color:#ffffff,stroke-width:2px

    class L,SY,C section
    class TF,FL,CK,AG,SN black
    class GATE diamond
    class REPO,PAGES white
```

### GitHub cloud loop

```mermaid
flowchart LR
    subgraph GH["GITHUB CLOUD LOOP"]
        direction TB
        PUSH["Push"]
        CI["CI pipeline"]
        TRI["Triage agent"]
        PI["Harness"]
        HR["Human review"]
        PUSH --> CI --> TRI --> PI --> HR
    end

    %% 2026 modern aesthetic: pure black-and-white. No security gate
    %% in this diagram (the cross-diagram gate is the Human review).
    classDef section fill:#ffffff,stroke:#0a0a0a,color:#0a0a0a,stroke-width:1px
    classDef black fill:#0a0a0a,stroke:#0a0a0a,color:#ffffff,stroke-width:2px

    class GH section
    class PUSH,CI,TRI,PI,HR black
```

### Developer dataflow

```mermaid
flowchart LR
    subgraph S1["① ② GATE & APPLY"]
        direction TB
        SCAN["scan.sh"]
        GATE{"GATE"}
        APPLY["deploy.sh"]
        SCAN --> GATE -->|"PASS"| APPLY
    end

    subgraph S2["③ VERIFY"]
        direction TB
        V1["verify.sh"]
    end

    subgraph S3["④ DRIFT"]
        direction TB
        D1["drift-check.sh"]
    end

    subgraph S4["⑤ ⑥ RESPOND"]
        direction TB
        AG["agent-loop.sh"]
        J[("JSON")]
        DEV["pages dev"]
        DEP["pages deploy"]
        AG --> J
        J --> DEV
        J --> DEP
    end

    APPLY --> V1 --> D1 -->|"drift"| AG

    %% 2026 modern aesthetic: black-and-white shape language with one
    %% warm amber accent reserved for the security choke-point (GATE).
    %% Cluster backgrounds: white with a thin black border; the post-
    %% process CSS injects a soft drop shadow and rounded corners so
    %% each cluster reads as a frosted card lifted off the canvas.
    classDef section fill:#ffffff,stroke:#0a0a0a,color:#0a0a0a,stroke-width:1px
    classDef black fill:#0a0a0a,stroke:#0a0a0a,color:#ffffff,stroke-width:2px
    classDef white fill:#ffffff,stroke:#0a0a0a,color:#0a0a0a,stroke-width:1.5px
    classDef gray fill:#fafafa,stroke:#0a0a0a,color:#0a0a0a,stroke-width:1.5px
    classDef diamond fill:#ff6b35,stroke:#ff6b35,color:#ffffff,stroke-width:2px
    classDef store fill:#ffffff,stroke:#0a0a0a,color:#0a0a0a,stroke-width:1.5px

    class S1,S2,S3,S4 section
    class SCAN,APPLY black
    class V1,D1 white
    class AG,DEV,DEP gray
    class GATE diamond
    class J store
```

## Why floci specifically

`floci-core` runs the real [floci.io](https://floci.io) AWS emulator —
[`docker.io/floci/floci`](https://github.com/floci-io/floci) (MIT, no auth) —
not a stub, and not a nickname for something else. That wasn't always true:
this repo ran `motoserver/moto` under the "floci" name for months, a naming
coincidence discovered and resolved in the same session this section was
rewritten (2026-08-13). The swap happened after direct verification, not a
leap of faith:

- **Plan-level compatibility is real, not marketing.** An isolated test
  applied the full 62-resource configuration against the real binary with
  zero provider-config changes — same `providers.tf`, same default
  `http://localhost:4566` endpoint, same dummy account ID (`000000000000`)
  moto used, matching `sync-dashboard.sh`'s existing credential-gate
  allowlist with no changes needed there either.
- **Apply-level compatibility is mixed — planning cleanly doesn't mean
  every service applies.** See [Known floci limitation](#known-floci-limitation)
  for exactly which resources are confirmed broken, confirmed working, or
  genuinely inconclusive.
- **One container, one port — plus a second, for IMDS.** `floci-core` binds
  `0.0.0.0:4566`; it also runs a separate EC2 IMDS listener on port 9169,
  relevant because `modules/compute` enforces IMDSv2. `network_mode: host`
  exposes both automatically — no explicit `ports:` mapping needed or
  possible under host networking.
- **Only one Terraform variable actually does anything.** `providers.tf`'s
  `endpoints{}` block reads `var.localstack_endpoint` (set via
  `TF_VAR_localstack_endpoint`) for every one of the 7 modules — a single
  shared value, not per-service overrides. A parallel set of
  `TF_<SERVICE>_ENDPOINT` env vars existed in several scripts for a long
  time and did nothing; discovered and removed in the same swap rather than
  wired up, since one emulator container per cloud means per-service
  endpoints would all resolve to the same value anyway.
- **The variable is still named `localstack_endpoint`.** A naming holdover
  from before either moto or floci was involved — not a hint that
  LocalStack is, or ever was, actually running.
- **`network_mode: host`, not bridge.** WSL2's netavark backend cannot apply
  the nftables rules Podman's default bridge network needs (missing kernel
  capability on this host) — host mode sidesteps it entirely, unrelated to
  which emulator image is running.
- **It's explicitly a stub, not a full emulator** — see
  [Known floci limitation](#known-floci-limitation). The tradeoff is deliberate:
  a shift-left CI demo needs something fast, free, and reachable with zero
  setup, not full API fidelity.
- **CI and local dev still run two different Podman versions**, independent
  of the emulator swap. `deploy-local`
  installs whatever Ubuntu 24.04's apt repo ships (currently Podman 4.9.x)
  fresh on every `ubuntu-latest` run; local WSL2 development is documented
  and validated against Podman 5.x (see SKILL.md). Nothing in `scripts/`
  hard-checks Podman's version the way `scan.sh` hard-checks tfsec's, so
  this skew is a known, accepted gap rather than a gate failure.

## Why floci-az

`floci-az` runs the real [floci.io](https://floci.io) Azure emulator —
`docker.io/floci/floci-az` (MIT, no auth) — on its own port (`:4577`),
alongside `floci-core` (AWS, `:4566`). Built and verified
directly in-session (2026-08-13), the same discipline as the AWS emulator
swap above:

- **A completely different provider-redirection mechanism than AWS.** The
  `aws` provider has a `dynamic "endpoints"` block — one HTTP override per
  service. `azurerm` has none: the whole provider is redirected via
  `environment = "stack"` + `metadata_host`, the same mechanism real Azure
  Stack / sovereign-cloud deployments use — Terraform calls
  `GET https://<metadata_host>/metadata/endpoints` to discover where every
  other endpoint (resource manager, login, graph, ...) actually lives.
  Confirmed via a real `terraform init` + `terraform plan` against a live
  `floci-az` container with this exact provider shape (`terraform/azure/
  providers.tf`).
- **TLS is mandatory, not optional** — unlike AWS's plain-HTTP
  `endpoints{}` block. The provider's metadata-discovery call is
  HTTPS-only with no HTTP fallback, and azurerm has no
  insecure-skip-verify-style argument for the ARM endpoint at all
  (confirmed by checking directly — unlike, say, the kubernetes/helm
  providers). `floci-az` must run with `FLOCI_AZ_TLS_ENABLED=true`; its
  self-signed cert is fetched from `/_floci/tls-cert` and trusted via
  `SSL_CERT_FILE` for the calling process only — never a system
  trust-store change.
- **A separate Terraform root, not a shared one with AWS.** `terraform/`'s
  existing full `terraform apply` (`deploy.sh`) would otherwise try to
  plan/apply Azure resources on every AWS-only run, requiring `floci-az`
  to be running with TLS enabled just to do AWS work. `terraform/azure/`
  has its own state (`terraform.tfstate`, gitignored, a separate file from
  AWS's), its own provider block, its own apply lifecycle.
- **The netavark/iptables discovery.** `floci-az`'s Functions/AKS/Redis/ACR
  services spawn real sidecar containers on demand over a mounted Docker
  socket, using Podman's default bridge network. On this WSL2 host,
  rootless Podman's netavark backend can't apply the nftables rules that
  needs (missing kernel capability — the same root cause already forcing
  `network_mode: host` on `floci-core`/`floci-az` themselves). Confirmed
  directly: `floci-az`'s sidecar launcher fails outright with `nft did not
  return successfully while applying ruleset`. `NETAVARK_FW=iptables`
  fixes it — but only if applied to the **host-side** `podman.service`
  process's environment. A container's own `environment:` block in
  `podman-compose.yml` cannot do this by construction: container envs and
  the host-side socket-serving process are separate process trees.
  `scripts/start-floci-az.sh` applies the real fix
  (`systemctl --user set-environment`, reversible, doesn't survive a
  reboot); `podman-compose.yml`'s own `NETAVARK_FW=iptables` line is
  documentation of intent only, not enforcement — see its `SEC_INTENT`
  comment.
- **A second, independent gap the netavark fix does NOT cover.** Rootless
  Podman doesn't delegate the `cpuset` cgroup v2 controller to containers
  spawned via `floci-az`'s Docker-API call — confirmed to crash AKS's
  backing k3s container within ~1 second, regardless of the netavark fix
  being correctly applied. See
  [Known floci-az limitations](#known-floci-az-limitations).
- **Apply-level compatibility is mixed, same as AWS.** Planning cleanly
  doesn't mean every service applies — see
  [Known floci-az limitations](#known-floci-az-limitations) for exactly
  which resources are confirmed stuck, confirmed failed, or genuinely
  inconclusive.
- **Not yet exercised in real CI beyond container startup.** A real
  `ubuntu-latest` CI run confirmed `floci-az`'s own container starts and
  stays up cleanly there — but nothing in `pipeline.yml` calls
  `grow-stack-azure.sh`, so the Docker-socket sidecar-spawning path the
  netavark fix exists for has only been verified locally, under WSL2. See
  the Research log below.

## What "deliberate misconfig" means

One resource, `aws_iam_policy.fixtures_admin` in
`terraform/modules/security/main.tf`, is intentionally written with
`Action:"*"` / `Resource:"*"` — a HIGH finding (`AVD-AWS-0057`) that tfsec is
guaranteed to catch. It exists to give the pipeline something real to gate on.

- **Toggled by file swap, not by editing HCL.** `scripts/toggle-fixture.sh`
  copies between three committed files — `main.tf`, `main.tf.with-fixture`,
  `main.tf.without-fixture` — and runs `terraform validate` before the swap is
  made permanent. No sed/regex on HCL; `cp` is deterministic and reversible.
- **Hard-blocked from auto-remediation everywhere.** `scripts/ai/triage.py`
  keeps `AVD-AWS-0057` in a `FIXTURE_RULES` frozenset it will never touch;
  `scripts/agent-loop.sh` doesn't edit `*.tf` at all. This is enforced in two
  independent places on purpose.
- **Requires human review.** `.github/CODEOWNERS` pins
  `/terraform/modules/security/` to a named reviewer — the fixture can't be
  changed by an unreviewed PR, including one opened by the `floci-agent-loop`
  bot.
- **Demonstrates both pipeline states.** With the fixture `on`, `scan.sh` fails
  and blocks `deploy.sh`. With it `off`, the gate passes and the rest of the
  demo (`deploy.sh` → `verify.sh` → `drift-check.sh` → `agent-loop.sh`) runs
  end to end.
- **Azure has an equivalent fixture, with inverted semantics.**
  `azurerm_key_vault.main` in `terraform/modules/azure-security/main.tf` is
  missing a `network_acls` block on purpose — `AVD-AZU-0013` (CRITICAL).
  Toggled the same way, via `scripts/toggle-fixture-azure.sh
  {on|off|status}` and a 3-file cp-and-validate swap — but INVERTED: this
  fixture is an omission inside an existing resource, not a separate
  resource to comment out, so fixture `on` means `network_acls` is
  *absent*, the opposite of AWS's `on` meaning the extra resource is
  *present*. Confirmed directly against the pinned tfsec 1.28.5 binary.
  `scripts/scan.sh` gates the AWS pipeline on the AWS fixture only — the
  Azure fixture is scanned with the same rigor but never blocks
  `deploy.sh` (see [Growth loop](#growth-loop) and `scan.sh`'s own header
  for the decoupling).

## Offline-first design

Nothing in this sandbox calls real AWS, and that's enforced at more than one
layer rather than assumed:

- **Every module's provider endpoint is overridden** to floci via a single
  shared variable, `var.localstack_endpoint` (set through
  `TF_VAR_localstack_endpoint`) — `providers.tf`'s `endpoints{}` block reads
  this one value for all 7 modules. There's no code path where a module
  falls back to a default AWS endpoint. (A parallel set of per-service
  `TF_<SERVICE>_ENDPOINT` env vars existed for a long time and did nothing
  — see [Why floci specifically](#why-floci-specifically) for that history.)
- **`deploy.sh` and `agent-loop.sh` both refuse to run against real-looking
  credentials.** They pattern-match `AWS_ACCESS_KEY_ID` against real key
  prefixes (`AKIA`, `ASIA`, `AIDA`, …) and refuse if `~/.aws/credentials`
  exists at all, in case the AWS provider would pick it up silently.
- **The dashboard is static-only.** `wrangler.toml` deliberately ships no
  `[vars]`, `[[kv_namespaces]]`, `[[d1_databases]]`, or Workers — it's
  Cloudflare Pages serving files, full stop.
- **Publishing runs entirely on GitHub-hosted runners now, not a
  self-hosted one** — for the pipeline's `scan`/`deploy-local`/
  `publish-dashboard`/`pr-comment` jobs. As of this change they all run on
  `ubuntu-latest`, installing a pinned `tfsec` 1.28.5 and a fresh
  Podman/podman-compose every run, then spinning up an ephemeral floci-core
  for the job's lifetime only. **`auto-fix.yml` still requires the
  `floci-self-hosted` WSL2 runner** — that job wasn't touched by this
  change. The local WSL2 `podman-compose.yml` setup (this section's
  original subject) remains fully intact for manual development —
  `agent-loop.sh`, direct `terraform` work, and anything run by hand still
  targets the persistent local floci-core, not CI's ephemeral one.
- **Pushing is manual by default; only the dashboard JSON auto-syncs**, and
  only through a script that refuses to push anything else (see next
  section).

## Backend never exposed — the data-plane table

| What | Lives where | Ever leaves the machine? |
|---|---|---|
| `floci-core` (real floci.io AWS emulator) | Podman container, `127.0.0.1:4566` (host network) | Never — not reachable outside the WSL host |
| `terraform.tfstate`, `state-snapshots/` | `terraform/` (gitignored) | Never |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | Shell env, always the literal `test` | Never — `deploy.sh`/`agent-loop.sh` refuse real-looking values before running |
| Raw tfsec JSON output | Local temp file | Never — `scan.sh` writes only a trimmed record (severity, rule_id, resource, description, line — no filesystem paths) to `dashboard/public/data/tfsec-last.json` |
| `dashboard/public/data/*.json` (14 files: 10 AWS + 4 Azure) | Local disk, written by `scan.sh`/`deploy.sh`/`verify.sh`/`drift-check.sh`/`agent-loop.sh`/`grow-stack-azure.sh` | **Yes** — pushed to GitHub, then Cloudflare Pages, but only after `sync-dashboard.sh`'s credential gate passes |
| `dashboard/public/{index.html,app.js,style.css,*.svg}` | Local disk | Yes — static assets, no runtime secrets by construction |
| `floci-self-hosted` runner | Debian WSL machine | The runner process never leaves; only job logs and the two artifacts it uploads (`scan-result`, `dashboard-data`) transit GitHub's servers |
| `CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID` | GitHub Actions encrypted secrets | Never printed to logs; scoped to Pages, used only by `publish-dashboard` / `deploy-dashboard.yml` |

The short version: the only thing that ever crosses the boundary from "this
WSL machine" to "the internet" is the dashboard's static JSON and assets —
everything that could contain state, credentials, or raw scan output stays
local.

## Known floci limitation

floci-core runs the real floci.io emulator, not a stub of something else —
but it's still not a full, byte-for-byte AWS clone. It exists to give
`verify.sh` and `drift-check.sh` something to call, not to behave
identically to AWS in every corner case.

> [!TIP]
> `aws_flow_log.main` may show as `destructive` drift on every run — floci
> doesn't echo the IAM role ARN back the way real AWS does. `agent-loop.sh`
> correctly refuses to act on it: destructive drift is outside its allowlist
> regardless of *why* the plan looks destructive.

If you see this specific resource flagged, it's expected — not a bug in the
agent.

> [!TIP]
> Real-floci apply-test findings (2026-08-13, a full 62-resource apply, not
> just plan — see also `growth-queue.yaml`'s inline annotations):
> - `aws_eks_cluster` — **confirmed failure**. Transitions to a `FAILED`
>   state on its own, not a timeout/kill artifact. Same practical outcome
>   as the earlier moto-era uncertainty ("may require floci Pro"), now
>   stated precisely instead of left as "unconfirmed."
> - `aws_elasticache_subnet_group` — **new confirmed failure**, a real
>   regression vs. moto (never flagged as risky before this session):
>   floci returns `UnsupportedOperation: CreateCacheSubnetGroup is not
>   supported`. Also blocks the dependent `aws_elasticache_replication_group`.
> - `aws_msk_cluster`, `aws_db_instance`, `aws_opensearch_domain` — marked
>   **inconclusive**, not confirmed-failed or confirmed-working: all three
>   sat in `Still creating...` for 8.5+ minutes with no resolution: the
>   test was stopped before Terraform's real default timeout rather than
>   left running indefinitely. Whichever way they'd eventually resolve,
>   multi-minute-plus creation time is practically incompatible with the
>   10-minute schedule cadence — growth stalls here in practice regardless
>   of eventual pass/fail.
>
> `scripts/grow-stack.sh` surfaces all of this honestly rather than
> papering over it — a failed or perpetually-slow `-target` apply is
> retried at the same queue position forever, never silently skipped.
> Growth visibly stalling at any of the five resources above is expected,
> not a bug in the script.

## Known floci-az limitations

`floci-az` runs the real floci.io Azure emulator on `:4577` — not a stub of
something else, same as `floci-core` for AWS (see [Why floci-az](#why-floci-az)).
Its documented service coverage (`docs/services/*.md`, 23 services) is
real, but apply-level compatibility is mixed, confirmed the same way AWS's
was: by testing directly against the real binary, not assumed from docs.

**Scope gap, not a confirmed incompatibility:** Phase 2 built 4 of AWS's 7
modules — `azure-network`/`azure-storage`/`azure-security`/`azure-compute`,
mirroring AWS's `network`/`storage`/`security`/`compute`. AWS's
`messaging`/`data`/`api` modules (SQS/SNS/EventBridge/Step Functions,
RDS/ElastiCache/MSK/OpenSearch, API Gateway) have no Azure sibling built at
all yet — not evaluated for `floci-az` support one way or the other, just
out of scope for this phase.

**Confirmed absent** (tested directly against `floci-az`, not inferred
from docs):
- No RBAC/role-assignment equivalent anywhere in `floci-az`'s documented
  service list — AWS's `aws_iam_role.app` + inline policy +
  `aws_iam_instance_profile` (the mechanism that grants compute
  permissions) has no counterpart.
- No Key Vault Keys (KMS equivalent) — a key-create call correctly routes
  to `floci-az`'s own `KeyVaultHandler`, then returns a real 404 from that
  handler itself. Not an auth/routing failure — a genuine absence.
- No Key Vault Certificates (ACM equivalent) — same test, same 404 shape.
- No NSG Flow Logs / Network Watcher equivalent — AWS's `azure-network`
  sibling module provisions `aws_flow_log.main`; `floci-az`'s network
  service docs explicitly enumerate their full scope (VNet, subnets, NIC,
  public IP, NSG, load balancers, application gateways, private DNS
  zones, private endpoints, private link services) and flow logs are not
  among them.
- No ECS Fargate / Container Apps equivalent anywhere in `floci-az`'s 23
  documented services.

> [!TIP]
> Real `floci-az` apply-test findings (2026-08-13, live tests against the
> real binary):
> - `azurerm_storage_container.artifacts`, `azurerm_storage_table.main`,
>   `azurerm_key_vault_secret.app_config` — **confirmed stuck, and
>   confirmed unfixable at the Terraform level** (2026-08-14 follow-up —
>   see the Research log below for the full investigation). All three
>   hang indefinitely on apply with ZERO corresponding request ever
>   appearing in `floci-az`'s own logs — the hang is client-side, before
>   any request is sent. Root cause, confirmed via a direct ARM API probe
>   against the real container: `floci-az`'s response for the parent
>   resource (storage account / Key Vault) returns real-Azure-shaped
>   data-plane hostnames with NO PORT and scheme `http`/`https` — e.g.
>   `"blob":"http://<account>.blob.core.windows.net/"` — instead of a
>   self-referential `floci-az` URL. The azurerm provider targets these
>   directly for data-plane calls. This is NOT just a DNS problem: even a
>   DNS-level fix (custom resolver, `/etc/hosts`) would only route a
>   client to port 80/443, and `floci-az` listens on `:4577` only — a real
>   fix needs a host-level DNS resolver AND a port 80/443→4577 redirect
>   (iptables NAT or a reverse proxy), confirmed by checking `floci-az`'s
>   own docs directly: no DNS/hosts-file component exists, and its
>   `FLOCI_AZ_HOSTNAME`/`FLOCI_AZ_BASE_URL` env vars only affect TLS cert
>   SANs, not ARM response bodies. No per-resource endpoint override
>   exists on the real azurerm provider either — a known limitation
>   independent of `floci-az`, also hit against Azurite. Not attempted:
>   the host-level DNS+port-redirect fix is a materially bigger, more
>   privileged change than this session's tags/405 fix, and was
>   deliberately not forced.
> - `azurerm_service_plan.functions` — **inconclusive**, not confirmed
>   failed: exactly one PUT + one GET reached `floci-az`'s generic
>   `ArmHandler` fallback (`Microsoft.Web` isn't one of `floci-az`'s
>   dedicated ARM provider namespaces), then total silence for 10+ minutes
>   with no error and no completion. Root cause not fully isolated — same
>   treatment as AWS's MSK/RDS/OpenSearch findings above. Because
>   `azurerm_linux_function_app.main` depends on this plan, it never even
>   starts applying while this is stuck.
> - `azurerm_kubernetes_cluster.main` — **confirmed failure, confirmed
>   permanent host limitation** (root-caused further 2026-08-14 — see the
>   Research log below), independent root cause from the two findings
>   above: the netavark/iptables fix (see [Why floci-az](#why-floci-az))
>   works correctly here — the k3s container is created and starts, no
>   nftables error. k3s itself then crashes fatally within ~1 second:
>   `Error: failed to find cpuset cgroup (v2)`. Confirmed directly: the
>   kernel has `cpuset` available at the cgroup v2 root, but systemd does
>   NOT delegate it down to the user slice (both `/sys/fs/cgroup/
>   user.slice/user-<uid>.slice/cgroup.controllers` and `podman info`'s
>   `CgroupControllers` list only `cpu`/`memory`/`pids`). This is a
>   systemd delegation gap, not a Podman config toggle — the only fix is
>   a root-owned systemd drop-in (`Delegate=cpuset` on `user@.service`,
>   then `daemon-reload` + re-login), a privileged host-wide change not
>   attempted here. `floci-az`'s own `provisioningState` never leaves
>   `"Creating"` (it doesn't detect the backing container died), so this
>   stalls forever from the ARM API's perspective too, not just slowly.
> - `azurerm_resource_group.main` — a real, fixed **incremental-apply
>   bug**, not a stall: `floci-az`'s ARM create response doesn't persist
>   the tags sent on create, so any later `-target` apply of a dependent
>   resource sees the missing tags as drift and tries to reconcile via an
>   update call, which `floci-az`'s `ArmHandler` rejects outright (`405
>   Method Not Allowed`) — `growth-queue-azure.yaml`'s one-target-at-a-time
>   pattern got stuck forever on the second queued item. Fixed with
>   `lifecycle { ignore_changes = [tags] }` on the resource group, then
>   re-tested against the other tagged resources in the same queue
>   (`azurerm_virtual_network.main`, `azurerm_network_security_group.app`)
>   to confirm the fix's scope was correctly narrow, not a lucky
>   single-symptom patch — it did not recur.
>
> `scripts/grow-stack-azure.sh` surfaces all of this the same way
> `grow-stack.sh` does for AWS — a failed, timed-out, or perpetually-stuck
> `-target` apply is retried at the same queue position forever, never
> silently skipped. See [Growth loop](#growth-loop) for why this queue
> also needed a per-attempt wall-clock timeout that AWS's never did.

If you see any of the above, it's expected — not a bug in the module or
the growth script.

## Growth loop

A separate, narrower automation from the demo pipeline above:
`scripts/grow-stack.sh` incrementally builds out the floci stack by applying
exactly one new resource per scheduled CI run, using
`terraform apply -target=<address>` against the ordered list in
[`growth-queue.yaml`](growth-queue.yaml).

- **No `.tf` edits, ever.** Every address in `growth-queue.yaml` already
  exists in `terraform/modules/**/*.tf` — the queue only *sequences* existing
  resources, it never defines new ones. `-target` just constrains which
  resource a given `apply` reconciles; the rest of state is untouched.
- **State persists across ephemeral `ubuntu-latest` runs via `actions/cache`**,
  using a per-run-id cache key (`growth-state-${{ github.run_id }}`) with a
  prefix `restore-keys` fallback — cache entries are immutable per key, so a
  mutable "latest state" can't use one static key. On a cache miss (first
  run, or all entries evicted), growth simply restarts from the top of the
  queue — not an error.
- **`schedule`-only by default**, plus an opt-in `workflow_dispatch` input
  (`grow: true`) for manual testing — never on `push`/`pull_request`, so a
  code change never also grows the stack in the same run.
- **Deliberately separate from `scripts/agent-loop.sh`.** Both scripts can
  run `terraform apply`, but they don't call into each other and don't share
  an allowlist. `grow-stack.sh` independently re-implements the same
  "tfsec gate must be PASS" precondition `agent-loop.sh` already enforces for
  drift reconciliation — that duplication is a known, accepted gap (see
  [Security decisions in code](#security-decisions-in-code)), not an oversight.
- **Failure doesn't skip ahead.** If a target apply fails, the same address
  is retried next run rather than silently moving to the next one — see
  [Known floci limitation](#known-floci-limitation) above for which queued
  resources are confirmed to fail, and which are merely too slow for the
  10-minute cadence, against the real floci emulator.
- **Azure gets its own growth loop, not a parametrized shared one.**
  `scripts/grow-stack-azure.sh` + `growth-queue-azure.yaml` mirror the AWS
  pattern exactly — separate sibling script, separate queue, its own
  precondition check (reads `tfsec-azure-last.json`, not AWS's gate file)
  — deliberately not merged into one script with a cloud parameter, same
  reasoning as every other AWS/Azure separation in this repo. Intended
  cache key `growth-state-azure-${{ github.run_id }}` (same
  prefix-`restore-keys` pattern as AWS's), **not yet wired into
  `pipeline.yml`** — Azure's growth loop is proven to run correctly
  locally, but CI never invokes it. Genuinely open, not an oversight
  papered over — see the Research log below.
- **One deliberate deviation from AWS's pattern: a wall-clock apply
  timeout.** AWS's growth loop assumes a stuck target eventually returns
  (fails fast, or is slow but bounded by the provider's own internal
  timeout). Confirmed false for Azure: several targets (storage
  container/table, Key Vault secret, Service Plan) hang with no error and
  no observed natural timeout within 10+ minutes of direct testing — a
  dead client-side stall with zero incremental server-side activity, not
  just slowness. `grow-stack-azure.sh` wraps its apply call in
  `timeout "$APPLY_TIMEOUT_SECONDS"`, default 240s — justified against the
  one legitimate slow-but-working case on the same queue
  (`azurerm_storage_account.main`/`.functions`, both measured at 2m54s in
  a real apply — many sequential provider-side calls populating ~80
  computed attributes, not a bug), not picked arbitrarily. The
  confirmed-stuck targets would time out identically at 30s or 300s —
  there's no evidence a longer wait ever helps them; a smarter
  per-resource timeout table would let those fail fast without risking
  the slow-but-working ones, not built, out of scope for this phase.

## Security decisions in code

Every non-obvious security decision in this repo is tagged `SEC_INTENT:` at
the point it's made, so the reasoning travels with the code instead of living
in someone's head. This table collects them in one place.

| File | Decision |
|---|---|
| `scripts/agent-loop.sh` | The agent's action space is small on purpose — the design goal is to make dangerous actions (edit `*.tf`, destroy) *impossible*, not merely "promised against." |
| `scripts/agent-loop.sh` | Drift reconciliation freezes entirely if the latest tfsec gate isn't `PASS`, even if the drift itself is provably safe — an apply might mask a finding the agent isn't smart enough to chain-check. |
| `scripts/toggle-fixture.sh` | This is the *only* sanctioned way to change the fixture's terraform state. `agent-loop.sh` is forbidden from doing it. Using a third committed file (not regex on HCL) keeps the toggle deterministic. |
| `scripts/scan.sh` | `scan.sh` is the single chokepoint the whole pipeline depends on — it fails loudly (non-zero exit, `FATAL` to stderr) rather than degrading, and hard-pins the tfsec version because a newer one silently drops ignores. |
| `scripts/scan.sh` | The dashboard JSON deliberately excludes raw tfsec descriptions/location data — only what the UI needs (severity, rule_id, resource, description, line) is written out. |
| `scripts/deploy.sh` | The single reachable path from "gate passed" to "resources created." Re-validates the gate itself rather than trusting the caller ran `scan.sh` correctly. |
| `scripts/verify.sh` | Treats `terraform.tfstate` as untrusted. Verification never reads state — only the outputs `deploy.sh` captured, checked directly against floci's API. |
| `scripts/drift-check.sh` | Drift is the agent's *only* legitimate trigger for `terraform apply` — deliberately not conflated with "a security finding needs fixing," which has its own separate gate. |
| `scripts/ai/triage.py` | Hard-coded, non-configurable blocklist: never touches `modules/security/main.tf`, never touches the fixture's rule ID (`AVD-AWS-0057`), never removes a `resource` block, only acts on MEDIUM/LOW severity. |
| `scripts/data-server.py` | Binds `127.0.0.1` only. Script execution goes through a hard-coded allowlist (`scan`/`verify`/`drift`/`deploy`) — no arbitrary command execution from the `/run/<name>` endpoint. |
| `scripts/sync-dashboard.sh` | The only script in the repo allowed to push automatically, and only for `dashboard/public/data/*.json` — anything else staged aborts the run before the credential gate even runs. |
| `.github/CODEOWNERS` | Gate scripts, the fixture, and `.github/` itself require human review — and the agent-loop's bot account is explicitly excluded from owning these paths, so it can never approve its own PRs. |
| `.github/workflows/pipeline.yml` | `scan` is the one chokepoint job; `deploy-local` and `publish-dashboard` only run after it exits 0. |
| `.github/workflows/pipeline.yml` | `scan`/`deploy-local` run on ephemeral `ubuntu-latest` runners, each installing its own pinned `tfsec` and fresh Podman — no shared, persistent state between CI runs and no dependency on the local WSL2 machine being online. `auto-fix.yml` is the only workflow still tied to `floci-self-hosted`. |
| `.github/workflows/auto-fix.yml` | Auto-fix only runs behind an explicit human-applied `auto-fix` label (or an internal dispatch) — never on a bare push — and always opens a PR rather than pushing to `main`. |
| `.github/workflows/deploy-dashboard.yml` | Dashboard publish is treated as read-only w.r.t. infra, which is why it's allowed to deploy independently of the tfsec/terraform jobs. |
| `wrangler.toml` | No `[vars]`, no KV, no D1, no Workers — kept empty deliberately so the "static assets only" claim is enforced by the config, not just documentation. |
| `scripts/grow-stack.sh` | Applies exactly one `-target` per invocation, never advances past a failed target, never destroys, never edits `*.tf` — same "make the dangerous action impossible" philosophy as `agent-loop.sh`, independently implemented rather than shared. |
| `growth-queue.yaml` | Ordering is load-bearing, not cosmetic — an address's dependencies must already appear earlier in the list. Reordering or removing an already-applied address after the fact is undefined behavior, not just a style issue. |
| `scripts/start-floci-az.sh` | Applies the netavark/iptables fix to the HOST-side `podman.service` environment (`systemctl --user set-environment`) — a container's own `environment:` block can't do this by construction. Reversible by design: a systemd user-manager variable, not a `containers.conf` edit; doesn't survive a reboot. |
| `scripts/toggle-fixture-azure.sh` | The *only* sanctioned way to change the Azure fixture's state — same reasoning as `toggle-fixture.sh`, with an inverted presence-check (fixture `on` means `network_acls` is absent). `grow-stack-azure.sh` and `agent-loop.sh` are both forbidden from touching it. |
| `scripts/grow-stack-azure.sh` | Same "make the dangerous action impossible" philosophy as `grow-stack.sh` — one `-target` per invocation, never destroys, never edits `*.tf`. Deliberately wraps its apply in a wall-clock `timeout` (default 240s) — a deviation from `grow-stack.sh` justified by confirmed unbounded stalls on this cloud's slowest targets, not present in AWS's queue. |
| `scripts/scan.sh` | Scans `terraform/azure/` alongside `terraform/`, but the Azure result is intentionally decoupled from this script's own exit code — an Azure-only finding (including its own fixture) must never block the AWS-gated `deploy.sh`. `grow-stack-azure.sh` is the one place that reads the Azure gate file. |

## Research log

Verification work done directly in-session, kept here so the claims above
are traceable rather than asserted.

**Emulator verification gates (2026-08-13, before the moto→floci swap):**
- `AVD-AWS-0057` fires correctly under the exact pinned `tfsec` 1.28.5
  binary CI installs, independent of a `deprecated: true` flag found in
  *current* upstream `trivy-checks` metadata — tested against an isolated
  temp copy with the fixture forced on, not the live repo.
- `floci-az` (the Azure emulator — not yet integrated) starts successfully
  under this machine's WSL2 rootless Podman, both with and without a
  mounted Docker socket. Sidecar-spawning through that socket was not
  verified end-to-end — only container startup.
- The real `floci` AWS image plans the full 62-resource configuration
  cleanly with zero provider-config changes, and defaults to the same
  `000000000000` account ID as moto — the basis for the swap documented
  in [Why floci specifically](#why-floci-specifically) above.

**CI dispatch of `feat/azure-phase2` (2026-08-13):** a real
`workflow_dispatch` run on `ubuntu-latest` confirmed `floci-az`'s
container itself starts and stays up cleanly there — image pull, the
`${XDG_RUNTIME_DIR}/podman/podman.sock` mount (resolves to a different
path than WSL2's, since the runner's UID differs — worked correctly
either way), and the `NETAVARK_FW=iptables` container env var were all
applied without error, and the container was still running at job end.
**What this run did *not* exercise: floci-az's Docker-socket
sidecar-spawning path — the actual reason the netavark/iptables fix
exists.** `pipeline.yml` never calls `grow-stack-azure.sh` (deliberately
out of scope for this branch), so nothing in CI ever asks floci-az to
spawn a bridge-networked sidecar container the way `growth-queue-azure.
yaml`'s later items would. That path remains verified only locally,
under WSL2 rootless Podman (see the bullet above) — genuinely open
until `pipeline.yml` eventually wires `grow-stack-azure.sh` in.

**DNS-hang bounded investigation (2026-08-14, `fix/azure-phase2-bugs`):**
20-minute time-boxed check into whether the storage-container/table and
Key-Vault-secret DNS-hang (above) had a floci-az-provided fix before
resorting to a host-level one. Checked, in order: (1) the running
container's filesystem for embedded docs — none found (minimal
Quarkus-native image, no `docs/`); (2) candidate `/_floci/*` and
`/openapi` endpoints for a DNS/capability API — all 404/501, no such
endpoint; (3) floci-az's real GitHub docs (README + `docs/services/
blob.md`) — confirms path-style routing and Host-header support for
account-style hostnames *if* the request reaches floci-az at all, but no
DNS/hosts-file component and no env var that changes ARM response
hostnames (`FLOCI_AZ_HOSTNAME`/`FLOCI_AZ_BASE_URL` are TLS-cert-SAN-only);
(4) a direct ARM API probe against the live container (`PUT .../
storageAccounts/{name}`) to see the exact returned URL, confirming no
port and `http` scheme. Conclusion: genuinely a host-level problem
(DNS + port redirect), not a floci-az or Terraform-level one — matches
the "different kind of change than the tags/405 fix" framing going in.
Not attempted, per the same bounded-effort framing as AWS's inconclusive
MSK/RDS/OpenSearch findings.

**AKS cpuset host-capability check (2026-08-14, `fix/azure-phase2-bugs`):**
Before treating the AKS cpuset failure as fixable, checked whether this
host's rootless Podman CAN delegate the cpuset cgroup v2 controller at
all, or whether it's a genuine kernel/systemd gap. `/sys/fs/cgroup/
cgroup.controllers` (the v2 root) lists `cpuset` as available at the
kernel level. But `/sys/fs/cgroup/user.slice/user-1000.slice/
cgroup.controllers` and that slice's `cgroup.subtree_control` both list
only `cpu memory pids` — no `cpuset`, no `io`, no `hugetlb`, no `rdma`.
`podman info`'s `CgroupControllers` confirms the same three, with
`CgroupManager: systemd`. Conclusion: this is systemd's default
per-user delegation policy not including `cpuset`, not a Podman
configuration issue — the fix is a root-owned drop-in
(`/etc/systemd/system/user@.service.d/*.conf`, `Delegate=cpuset`) plus
`daemon-reload` and a fresh login session, a privileged host-wide
change well outside what a repo-local fix should do unprompted. Not
attempted, per the same "report a genuine host gap rather than force a
workaround" framing used for AWS's EKS uncertainty.

**Open, undiagnosed items — not explained away:**
- A `collecting instance settings: empty result` error appeared during the
  full apply test, likely EC2-related (`aws_instance.app`), but was not
  isolated or root-caused.
- `terraform state list` reported 65 resources after the aborted apply
  test — three more than the 62 planned. Not investigated further.
