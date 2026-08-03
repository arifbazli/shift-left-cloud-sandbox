#!/usr/bin/env bash
# =============================================================================
# scripts/bootstrap-fixture-snapshots.sh
# =============================================================================
# Purpose
#   Regenerate terraform/main.tf.with-fixture and terraform/main.tf.without-fixture
#   from the currently-checked-out main.tf. Use this after editing the fixture
#   region of main.tf by hand.
#
# Usage
#   1. Edit terraform/main.tf to contain the fixture (the "on" state)
#   2. Run this script
#   3. Commit all three files
#
# This script is read-only on main.tf. It will:
#   - Copy main.tf → main.tf.with-fixture
#   - Generate main.tf.without-fixture by commenting out the two fixture
#     resources via a brace-counting Python helper
#
# SEC_INTENT: this is the only sanctioned way to regenerate the snapshot
# files. The agent-loop is forbidden from running it (and forbidden from
# running any script that touches *.tf).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/../terraform"
MAIN="$TF_DIR/main.tf"
ON_SNAPSHOT="$TF_DIR/main.tf.with-fixture"
OFF_SNAPSHOT="$TF_DIR/main.tf.without-fixture"

if [[ ! -f "$MAIN" ]]; then
  echo "FATAL: $MAIN not found." >&2
  exit 2
fi

# Verify main.tf is in the ON state (fixture resource uncommented).
if ! grep -qE '^resource "aws_iam_policy" "fixtures_admin"' "$MAIN"; then
  echo "FATAL: main.tf is not in the ON state." >&2
  echo "  Edit it so the fixture resource is uncommented, then re-run." >&2
  exit 2
fi

cp "$MAIN" "$ON_SNAPSHOT"
echo "Wrote $ON_SNAPSHOT"

python3 - "$ON_SNAPSHOT" "$OFF_SNAPSHOT" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    content = f.read()

def comment_block(content, start_idx):
    lines = content.split('\n')
    char_count = 0
    line_idx = 0
    for i, line in enumerate(lines):
        if char_count + len(line) + 1 > start_idx:
            line_idx = i
            break
        char_count += len(line) + 1
    block_start = line_idx
    depth = 0
    block_end = block_start
    for j in range(block_start, len(lines)):
        for ch in lines[j]:
            if ch == '{':
                depth += 1
            elif ch == '}':
                depth -= 1
        if depth == 0:
            block_end = j
            break
    new_lines = list(lines)
    for j in range(block_start, block_end + 1):
        if new_lines[j]:
            new_lines[j] = '# ' + new_lines[j]
    return '\n'.join(new_lines)

for resource_str in (
    'resource "aws_iam_policy" "fixtures_admin"',
    'resource "aws_iam_role_policy_attachment" "fixtures_admin_attach"',
):
    idx = content.find(resource_str)
    if idx < 0:
        raise SystemExit(f"could not find {resource_str}")
    content = comment_block(content, idx)

with open(dst, 'w') as f:
    f.write(content)
PY
echo "Wrote $OFF_SNAPSHOT"

# Verify both files are valid HCL
echo "--- terraform validate on each ---"
TERRAFORM_BIN="${TERRAFORM_BIN:-terraform}"
for f in "$ON_SNAPSHOT" "$OFF_SNAPSHOT"; do
  if "$TERRAFORM_BIN" -chdir="$TF_DIR" validate -no-color; then
    echo "  ✓ $f"
  else
    echo "  ✗ $f (validation failed)" >&2
    exit 2
  fi
done

echo ""
echo "Done. Both snapshot files are valid HCL."
echo "Remember to commit all three files together."
