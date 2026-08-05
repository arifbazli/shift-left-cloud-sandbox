# =============================================================================
# .github/branch-protection.md
# =============================================================================
# Branch protection reference — manual setup required in GitHub UI.
# (GitHub's branch protection API requires a GitHub App or a PAT with
# admin:repo scope; we document the settings here instead of scripting them.)
#
# Apply at: Settings → Branches → Add branch ruleset → main
# =============================================================================

## Branch: `main`

### Required status checks (must pass before merge)

| Check name                        | Required |
|-----------------------------------|----------|
| `tfsec gate`                      | ✅ Yes   |
| `terraform apply (LocalStack)`    | ✅ Yes   |

### Pull request rules

| Setting                                          | Value    |
|--------------------------------------------------|----------|
| Require a pull request before merging           | Yes      |
| Required approvals                              | 1        |
| Dismiss stale pull request approvals on push    | Yes      |
| Require review from Code Owners (CODEOWNERS)   | Yes      |
| Require conversation resolution before merging  | Yes      |

### Push rules

| Setting                          | Value |
|----------------------------------|-------|
| Restrict who can push to main    | Admins only (no bot accounts) |
| Require signed commits           | Recommended (optional for sandbox) |
| Block force pushes               | Yes   |

### Bot account rules

The `floci-agent-loop` bot account (used by auto-fix.yml) must **not** be
in the bypass list. It can only merge via PR after human approval.

---

## Branch: `feat/**`

No branch protection — developers push freely to feature branches.
The scan job still runs on every push to provide early feedback.

---

## Setting up the self-hosted runner (`floci-self-hosted`)

```bash
# On the Debian WSL machine:
mkdir -p ~/actions-runner && cd ~/actions-runner

# Download the GitHub Actions runner (replace <TOKEN> with repo runner token):
curl -o actions-runner-linux-x64.tar.gz -L \
  https://github.com/actions/runner/releases/download/v2.317.0/actions-runner-linux-x64-2.317.0.tar.gz
tar xzf actions-runner-linux-x64.tar.gz

# Configure (Settings → Actions → Runners → New self-hosted runner):
./config.sh \
  --url https://github.com/arifbazli/shift-left-cloud-sandbox \
  --token <TOKEN> \
  --labels floci-self-hosted \
  --name  floci-wsl-runner \
  --unattended

# Install as a systemd service (or run manually for dev):
sudo ./svc.sh install
sudo ./svc.sh start
```

### Pre-requisites on the runner host

```bash
# Tools that must be available on PATH:
tfsec  --version   # must print 1.28.5
terraform --version
python3 --version  # ≥ 3.10
podman  --version  # rootless
podman-compose --version
```
