# Changelog

All notable changes to this project are documented in this file.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

> **Note on versioning:** this repo has no git tags or published releases —
> it's a local R&D sandbox, not a shipped package. The version numbers below
> are a retroactive grouping of the 44 commits in `git log`, oldest to
> newest, into 6 logical phases — not real releases. Short hashes are
> included per entry so you can trace each line back to `git show <hash>`.

## [0.10.0] - 2026-08-13 — Phase 2: Azure via floci-az

### Added
- `podman-compose.yml`: `floci-az` service (`docker.io/floci/floci-az:latest`,
  `:4577`, `network_mode: host`) alongside `floci-core`; `scripts/
  start-floci-az.sh` applies the netavark/iptables fix to the HOST-side
  `podman.service` process's environment (`systemctl --user
  set-environment`) — required for floci-az's Functions/AKS/Redis/ACR
  sidecar-spawning services, and not achievable via the container's own
  `environment:` block (separate process trees; that line in
  `podman-compose.yml` documents intent only) (`68d15ab`)
- `terraform/azure/`: a separate root (own state, own provider, own apply
  lifecycle — deliberately not sharing AWS's root, so AWS-only work never
  needs floci-az/TLS running) plus 4 modules mirroring AWS's `network`/
  `storage`/`security`/`compute` as closely as floci-az's confirmed
  service coverage allows: `azure-network` (RG/VNet/subnet/NSG+rules, all
  10 resources confirmed working), `azure-storage` (storage account
  confirmed working; container/table confirmed STUCK on apply — a
  client-side DNS-hang against real-Azure-shaped hostnames floci-az
  returns), `azure-security` (Key Vault + secret; RBAC/Keys/Certificates
  confirmed absent, secret apply confirmed STUCK — same DNS-hang root
  cause), `azure-compute` (VM confirmed working — mocked, no real OS;
  Function App's Service Plan inconclusive; AKS confirmed FAILED — cpuset
  cgroup v2 not delegated to floci-az's spawned k3s container). The
  `azurerm_resource_group.main` tags/405 incremental-apply bug (floci-az
  doesn't persist create-time tags, so a later `-target` apply sees drift
  and floci-az's `ArmHandler` rejects the reconciling update with `405`)
  found and fixed via `lifecycle { ignore_changes = [tags] }`, then
  re-verified against the other tagged resources in the same growth queue
  to confirm the fix didn't need to be broader (`9796a01`)
- `AVD-AZU-0013` fixture (`azurerm_key_vault.main` missing `network_acls`,
  CRITICAL) — Azure sibling of the AWS `AVD-AWS-0057` fixture, toggled via
  `scripts/toggle-fixture-azure.sh {on|off|status}` and the same 3-file
  cp-and-validate mechanism, INVERTED (fixture `on` means `network_acls`
  is absent, not present). Verified directly against the pinned tfsec
  1.28.5 binary (`9796a01`)
- `growth-queue-azure.yaml` + `scripts/grow-stack-azure.sh`: Azure sibling
  of the AWS growth loop — separate queue, separate script, own
  precondition (reads `tfsec-azure-last.json`). One deliberate deviation
  from AWS's pattern: an explicit `APPLY_TIMEOUT_SECONDS` wall-clock wrap
  (default 240s) around each apply, justified against the one confirmed
  slow-but-working case on this queue (`azurerm_storage_account.main`/
  `.functions`, ~2m54s each in a real apply) — the confirmed-stuck targets
  show zero evidence a longer timeout would ever help them (`4374993`)
- `scripts/scan.sh`: now scans `terraform/azure/` alongside `terraform/`,
  writing its own gate files (`tfsec-azure-last.json`/`-history.json`) —
  but intentionally decoupled from this script's own exit code, so an
  Azure-only finding (including its own fixture) never blocks the
  AWS-gated `deploy.sh`. Removed `--force-all-dirs` from the tfsec
  invocation after confirming it leaked Azure's findings into the AWS gate
  (Azure's root is physically nested inside `terraform/`); confirmed
  module-graph resolution alone still finds every AWS module's own
  findings correctly without it. `grow-stack-azure.sh`'s precondition
  simplified to read this new gate file instead of invoking tfsec itself
  (`ef40997`)
- Dashboard: an AWS/Azure cloud tab switcher (AWS default, state persisted
  via `localStorage`), reusing the existing card components. Only scan +
  growth are real, wired cards on the Azure tab — verify/drift/agent are
  explicit "no Azure equivalent yet" placeholder cards, not faked empty
  states (`45d5f5b`)
- `CONTEXT.md`: Research-log entry noting that a real `ubuntu-latest` CI
  run confirmed floci-az's own container starts and stays up cleanly
  there, but — since `pipeline.yml` doesn't call `grow-stack-azure.sh` —
  never exercised floci-az's Docker-socket sidecar-spawning path, the
  actual reason the netavark/iptables fix exists. That path remains
  verified only locally, under WSL2 (`c0b9797`)

### Notes
- Phase 2 mirrors 4 of AWS's 7 modules (network/storage/security/compute).
  AWS's messaging/data/api modules have no Azure sibling built at all yet
  — not evaluated for floci-az support one way or the other, just out of
  scope for this phase.
- `pipeline.yml` was not modified — no Azure-specific CI step exists yet
  (no TLS enable, no `grow-stack-azure.sh` invocation, no Azure growth
  cache key). Confirmed via a real dispatched CI run against this branch
  before merge: the tfsec-gate decoupling holds under real CI (Azure gate
  FAIL, job conclusion still success), and floci-az's container itself
  starts cleanly on `ubuntu-latest` — but the sidecar-spawning path is
  untested there, per the point above.
- Merged via PR #12, a real merge commit (`a3fff15`), same as PR #11 — not
  a bypass.

## [0.9.0] - 2026-08-13 — AWS emulator swap: motoserver/moto → real floci.io floci

### Changed
- `podman-compose.yml`: image `docker.io/motoserver/moto` →
  `docker.io/floci/floci`. Removed moto-specific config that doesn't apply
  to the real binary (command override, `MOTO_ACCOUNT_ID`, the
  `/tmp/moto` volume mount) — each verified unnecessary/incorrect via
  direct isolated testing rather than guessed (`10fcca2`)
- `deploy.sh`/`drift-check.sh`/`agent-loop.sh`/`grow-stack.sh`: removed
  4-to-20 `TF_<SERVICE>_ENDPOINT` env vars each — `providers.tf`'s
  `endpoints{}` block only ever reads `TF_VAR_localstack_endpoint`. Dead
  code discovered this session, unrelated to which emulator backs it.
  `verify.sh` untouched — it never had them, it doesn't invoke Terraform
  (`10fcca2`)
- `growth-queue.yaml`: inline annotations updated with real full-apply
  findings against real floci (not moto): `aws_eks_cluster` confirmed
  `FAILED` state; `aws_elasticache_subnet_group` a **new** confirmed
  failure (`UnsupportedOperation`), also blocking the dependent
  `aws_elasticache_replication_group`; `aws_db_instance`/`aws_msk_cluster`/
  `aws_opensearch_domain` marked inconclusive (8.5+ min unresolved,
  manually killed before Terraform's real timeout) — practically
  incompatible with the 10-minute schedule cadence regardless of
  eventual pass/fail. All five kept per the existing
  visible-stall-over-silent-skip design (`10fcca2`)

### Notes
- Plan-level compatibility (62/62 resources, zero provider-config
  changes) and the matching dummy account ID (`000000000000`) were
  verified via isolated testing before this swap, alongside a check that
  `AVD-AWS-0057` still fires correctly under the exact pinned tfsec 1.28.5
  binary independent of a `deprecated: true` flag in current upstream
  `trivy-checks` metadata.
- Two items intentionally left undiagnosed, not speculated on: a
  `collecting instance settings: empty result` error (possibly
  EC2-related) and a 65-vs-62 resource count in terraform state after the
  aborted apply test. Both are open follow-up items.

## [0.8.0] - 2026-08-13 — Growth loop: autonomous incremental stack building

### Added
- `growth-queue.yaml`: 62 existing resource addresses across all 7
  modules, ordered to respect terraform-graph dependencies — sequences
  existing resources only, never defines new ones. Security fixture
  excluded (`toggle-fixture.sh` owns it exclusively) (`ed737ba`)
- `scripts/grow-stack.sh`: applies exactly one
  `terraform apply -target=<address>` per invocation — the next
  `growth-queue.yaml` entry not yet in `terraform state list`. Never
  edits `*.tf`, never destroys, never advances past a failed target
  (same address retried next run, not skipped). Preconditions: tfsec
  gate must be `PASS`, floci-core must be reachable — independently
  re-implemented, does not call into or modify `agent-loop.sh`. Writes
  `growth-last.json`/`growth-history.json` via the same atomic-write
  pattern as `scan.sh`/`drift-check.sh` (`ed737ba`)
- `pipeline.yml`: new `grow` boolean input on `workflow_dispatch`
  (default `false`) for manual testing without waiting on the
  `*/10 * * * *` schedule; growth steps gated to `schedule`-triggered
  runs or explicit `grow: true`, never `push`/`pull_request` (`ed737ba`)
- `terraform.tfstate` persists across ephemeral `ubuntu-latest` runs via
  `actions/cache`, using a `growth-state-${{ github.run_id }}` key with
  prefix `restore-keys` — cache entries are immutable per key, so a
  mutable "latest state" needs the unique-key + prefix-restore pattern,
  not one static key. A cache miss (first run, or eviction) restarts
  growth from the top of the queue, not an error (`ed737ba`)
- Completion fast-path: a "Check growth status" step reads
  `growth-last.json` and skips the entire Restore/Grow/Save sequence
  once `status: "complete"`, so a finished 62-entry queue stops paying
  full job cost every 10-minute tick forever. Defaults safely to "not
  complete" when the file doesn't exist yet (`ed737ba`)
- `CONTEXT.md`/`SKILL.md`: new "Growth loop" architecture section, a
  floci-limitation note for moto's unconfirmed `aws_eks_cluster`/
  `aws_msk_cluster`/`aws_opensearch_domain` coverage, 2 new
  `SEC_INTENT` table rows, and a queue-ordering/cache-key-convention
  checklist item (`ed737ba`)

### Notes
- Three queued resources (`aws_eks_cluster`, `aws_msk_cluster`,
  `aws_opensearch_domain`) may never apply successfully against moto —
  module comments already flagged partial/Pro-tier coverage before this
  loop existed. A failure stalls growth visibly at that exact queue
  position (retried every run) rather than silently skipping ahead —
  intentional, not a bug if it happens.
- Deliberately deferred, not implemented: a stuck-target circuit
  breaker (e.g. alert after N consecutive failures on one address), and
  gating `Install Podman`/`Start floci-core`/`Stop floci-core` on the
  completion fast-path — both known, accepted gaps.

## [0.6.0] - 2026-08-05 — Live dashboard: SSE, auto-trigger, data-server

### Added
- `scripts/data-server.py`: local SSE server for 1-second live dashboard
  updates, on-demand run-buttons, and a hard-coded script allowlist
  (`fbccf4c`)
- Live data-age ticker and an auto-refresh scheduler inside `data-server.py`
  (`7271b57`)
- Pipeline auto-trigger: cron schedule, `workflow_dispatch`,
  `repository_dispatch`, and a "Pipeline" button in the dashboard header
  (`8d9670a`)

### Fixed
- Cloudflare Pages dashboard stuck loading — HTTPS pages blocking HTTP SSE
  as mixed content, plus stale-file fallback handling (`598a958`)
- Restored a missing `$` DOM-lookup helper that left every dashboard card
  showing `—` (`2913b47`)

## [0.5.0] - 2026-08-05 — CI pipeline hardening for the self-hosted runner

### Fixed
- `setup-runner.sh`: extract semver via `grep -oE`, absorb SIGPIPE with
  `|| true` (`ab91cf8`)
- Start `floci-core` inside the `deploy-local` job, not just locally
  (`4d5b8e1`)
- `PATH`, `XDG_RUNTIME_DIR`, and the Podman socket path wired correctly for
  the self-hosted runner (`119096b`)
- Switched the AWS stub to the `motoserver/moto` image, added
  `network_mode: host`, added `terraform validate` to CI (`3351085`)

### Added
- Test commit confirming the runner `PATH` fix (`be22272`)

## [0.4.0] - 2026-08-05 — 7-module Terraform, CI pipeline, AI triage

### Added
- 7-module Terraform layout: `network`, `storage`, `compute`, `messaging`,
  `data`, `security`, `api` (`ae92c2a`)
- GitHub Actions CI pipeline (`scan` → `deploy-local` → `publish-dashboard`
  → `pr-comment`), `.github/CODEOWNERS`, `branch-protection.md`,
  `scripts/ai/triage.py` allowlisted remediation, `.github/labels.yml`
  (`e5871f6`)
- `scripts/setup-runner.sh` self-hosted runner bootstrap; README v3
  (`5260b61`)

## [0.3.0] - 2026-08-03 — Dashboard UI modernization

### Changed
- Dashboard modernized, README trimmed (`deb2d66`, merged `65b335e`)
- Teal-accent dark theme applied: pills, skeleton loaders, list-rows
  (`4eb2c31`)
- README simplified to a single diagram (`0e6f42f`, merged `a8d082e`)
- Dashboard cards reordered to match the pipeline flow: scan → deploy →
  verify → drift → agent (`cb83a78`, `459b6ab`)
- Comprehensive visual + accessibility pass: pill semantics, agent state,
  event dedup, `prefers-reduced-motion` (`9b8df1e`)
- Layout polish: agent reasons wrap, drift rows reboxed, balanced grid,
  taller cards (`e54719e`)
- "Recent findings" moved into the grid, spanning columns beside agent loop
  (`d1c5d37`, `80ac1a4`)
- Dropped "Salus" branding from the page title and meta description
  (`5a67bc1`)

### Fixed
- Dashboard data rendering and empty-state bugs (`08c13c4`)
- Agent card overflow: stacked rows, clipped reason text, `overflow:hidden`
  (`c821b3f`)
- Shipped the missing `podman-compose.yml`; refreshed live data; fixed
  Mermaid light-mode contrast (`459b6ab`)
- Cancelled in-flight count tweens and clamped values — no more runaway
  negative counters (`0eac79e`)
- Isolated each card renderer in its own try/catch so one bad JSON file
  can't blank the whole dashboard (`def8d80`)
- Removed a dead `scan-ver` reference that threw a `TypeError` and left
  findings stale (`f01c761`)

### Data
- Refreshed dashboard JSON fixtures after the UI pass (`70f36de`)

## [0.2.0] - 2026-08-03 — Mermaid architecture diagrams + dashboard staleness

### Added
- `scripts/deploy-dashboard.sh` and a "last synced" staleness indicator on
  the dashboard (`6abf576`)
- Mermaid dataflow diagram replacing the ASCII tree (`4ff9a2c`), rendered
  horizontally (`137e44a`), then enlarged for readability (`691e61e`)
- `scripts/render-mermaid.sh` to render `.mmd` sources to SVG, embedded as
  `<img>` (`17b7fc9`)
- 2026 modern black-and-white diagram aesthetic with an amber gate accent
  (`cf33b11`, `a85b498`)

### Changed
- README rewritten in the 2026-modernized style (`ed7e684`)

### Fixed
- Diagram arrow visibility at column width (`20eb57b`)
- Removed black cluster backgrounds, kept white boxes (`a652d85`)
- README captions realigned with the new diagram design (`bf1ed02`)

## [0.1.0] - 2026-08-03 — Initial sandbox scaffold

### Added
- Initial shift-left cloud security sandbox: single-file Terraform root
  module, `scan.sh`/`deploy.sh`/`verify.sh`/`drift-check.sh`/
  `agent-loop.sh`/`toggle-fixture.sh`, `bootstrap-fixture-snapshots.sh`,
  `sync-dashboard.sh`, the Cloudflare Pages dashboard (HTML/CSS/JS + JSON
  data), `wrangler.toml`, `.gitignore` (`bca0df7`)
