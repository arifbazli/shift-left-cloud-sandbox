# Changelog

All notable changes to this project are documented in this file.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

> **Note on versioning:** this repo has no git tags or published releases —
> it's a local R&D sandbox, not a shipped package. The version numbers below
> are a retroactive grouping of the 44 commits in `git log`, oldest to
> newest, into 6 logical phases — not real releases. Short hashes are
> included per entry so you can trace each line back to `git show <hash>`.

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
