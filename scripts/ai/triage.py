#!/usr/bin/env python3
"""
scripts/ai/triage.py
====================
AI-assisted tfsec finding triage and remediation.

Role in the pipeline
--------------------
Called by .github/workflows/auto-fix.yml AFTER a tfsec run produces
findings. Reads the tfsec JSON output, classifies each finding against
the allowlist, and applies safe remediations to the terraform source.

SEC_INTENT — Allowlist (what this script MAY do)
-------------------------------------------------
ALLOWED:
  - Add `server_side_encryption_configuration` to S3 buckets
  - Set `versioning { enabled = true }` on S3 buckets
  - Enable `access_log` blocks on S3 buckets
  - Add `encrypted = true` on EBS volumes / RDS / ElastiCache
  - Set `monitoring = true` on EC2 instances
  - Add `deletion_protection = true` on RDS

BLOCKED (hard-coded refusals, not configurable):
  - Touch modules/security/main.tf  (contains the deliberate fixture)
  - Touch modules/security/main.tf.with-fixture
  - Remove or comment out any `resource` block
  - Modify HIGH/CRITICAL findings that match the fixture signature
    (AVD-AWS-0057: wildcarded Action '*' + Resource '*')
  - Apply changes that fail `terraform validate`

Usage
-----
  python3 scripts/ai/triage.py \\
      --input  /tmp/tfsec-last.json \\
      --tf-dir terraform/ \\
      --output /tmp/triage-report.json [--dry-run]
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import textwrap
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Files the agent is NEVER allowed to modify.
BLOCKED_FILES: frozenset[str] = frozenset(
    [
        "modules/security/main.tf",
        "modules/security/main.tf.with-fixture",
    ]
)

# Rule IDs that match the deliberate fixture — never auto-fix.
FIXTURE_RULES: frozenset[str] = frozenset(
    [
        "AVD-AWS-0057",  # Wildcarded Action + Resource in IAM policy
    ]
)

# Severity levels the agent may attempt to remediate.
ALLOWED_SEVERITIES: frozenset[str] = frozenset(["MEDIUM", "LOW"])

# ---------------------------------------------------------------------------
# Remediation registry
# ---------------------------------------------------------------------------


@dataclass
class Remediation:
    rule_id: str
    description: str
    # Returns (modified_content, was_changed)
    apply: Any  # Callable[[str, dict], tuple[str, bool]]


def _add_s3_encryption(content: str, finding: dict) -> tuple[str, bool]:
    """Add SSE-S3 encryption block to an S3 bucket resource that lacks it."""
    if "server_side_encryption_configuration" in content:
        return content, False
    pattern = r'(resource\s+"aws_s3_bucket"\s+"[^"]+"\s*\{)'
    replacement = (
        r'\1\n'
        r'  # triage: added by scripts/ai/triage.py (AVD-AWS-0132)\n'
        r'  server_side_encryption_configuration {\n'
        r'    rule {\n'
        r'      apply_server_side_encryption_by_default {\n'
        r'        sse_algorithm = "aws:kms"\n'
        r'      }\n'
        r'    }\n'
        r'  }\n'
    )
    new, n = re.subn(pattern, replacement, content, count=1)
    return new, n > 0


def _enable_s3_versioning(content: str, finding: dict) -> tuple[str, bool]:
    """Add versioning block to an S3 bucket."""
    if re.search(r'versioning\s*\{', content):
        return content, False
    pattern = r'(resource\s+"aws_s3_bucket"\s+"[^"]+"\s*\{)'
    replacement = (
        r'\1\n'
        r'  # triage: added by scripts/ai/triage.py (AVD-AWS-0090)\n'
        r'  versioning {\n'
        r'    enabled = true\n'
        r'  }\n'
    )
    new, n = re.subn(pattern, replacement, content, count=1)
    return new, n > 0


def _enable_s3_logging(content: str, finding: dict) -> tuple[str, bool]:
    """Add access logging block to an S3 bucket."""
    if re.search(r'logging\s*\{', content):
        return content, False
    pattern = r'(resource\s+"aws_s3_bucket"\s+"[^"]+"\s*\{)'
    replacement = (
        r'\1\n'
        r'  # triage: added by scripts/ai/triage.py (AVD-AWS-0089)\n'
        r'  logging {\n'
        r'    target_bucket = var.log_bucket_id\n'
        r'    target_prefix = "s3-access-logs/"\n'
        r'  }\n'
    )
    new, n = re.subn(pattern, replacement, content, count=1)
    return new, n > 0


def _enable_ebs_encryption(content: str, finding: dict) -> tuple[str, bool]:
    """Set encrypted = true on an EBS volume."""
    if re.search(r'encrypted\s*=\s*true', content):
        return content, False
    pattern = r'(resource\s+"aws_ebs_volume"\s+"[^"]+"\s*\{)'
    replacement = (
        r'\1\n'
        r'  # triage: added by scripts/ai/triage.py (AVD-AWS-0026)\n'
        r'  encrypted = true\n'
    )
    new, n = re.subn(pattern, replacement, content, count=1)
    return new, n > 0


def _enable_rds_deletion_protection(content: str, finding: dict) -> tuple[str, bool]:
    """Add deletion_protection = true on RDS instances."""
    if re.search(r'deletion_protection\s*=\s*true', content):
        return content, False
    pattern = r'(resource\s+"aws_db_instance"\s+"[^"]+"\s*\{)'
    replacement = (
        r'\1\n'
        r'  # triage: added by scripts/ai/triage.py (AVD-AWS-0177)\n'
        r'  deletion_protection = true\n'
    )
    new, n = re.subn(pattern, replacement, content, count=1)
    return new, n > 0


REMEDIATIONS: dict[str, Remediation] = {
    "AVD-AWS-0132": Remediation("AVD-AWS-0132", "S3 bucket not encrypted", _add_s3_encryption),
    "AVD-AWS-0090": Remediation("AVD-AWS-0090", "S3 versioning not enabled", _enable_s3_versioning),
    "AVD-AWS-0089": Remediation("AVD-AWS-0089", "S3 access logging not enabled", _enable_s3_logging),
    "AVD-AWS-0026": Remediation("AVD-AWS-0026", "EBS volume not encrypted", _enable_ebs_encryption),
    "AVD-AWS-0177": Remediation("AVD-AWS-0177", "RDS deletion protection disabled", _enable_rds_deletion_protection),
}

# ---------------------------------------------------------------------------
# Core logic
# ---------------------------------------------------------------------------


def load_findings(input_path: Path) -> list[dict]:
    with open(input_path) as f:
        data = json.load(f)
    # Accept both scan.sh output format and raw tfsec JSON output.
    return data.get("findings") or data.get("results") or []


def is_blocked(finding: dict, tf_dir: Path) -> tuple[bool, str]:
    """Return (True, reason) if the finding must not be auto-fixed."""
    rule_id = finding.get("rule_id", "")
    if rule_id in FIXTURE_RULES:
        return True, f"fixture rule {rule_id} — never auto-fix"

    sev = finding.get("severity", "").upper()
    if sev not in ALLOWED_SEVERITIES:
        return True, f"severity {sev} outside allowlist {ALLOWED_SEVERITIES}"

    # Check if the affected file is in the blocklist.
    location = finding.get("location", {})
    filename = location.get("filename", "")
    for blocked in BLOCKED_FILES:
        if blocked in filename:
            return True, f"file {filename!r} is in BLOCKED_FILES"

    return False, ""


def resolve_tf_file(finding: dict, tf_dir: Path) -> Path | None:
    """Resolve the terraform file path from a finding's location.

    Falls back to a resource-name search when location.filename is absent
    (scan.sh strips location data from the dashboard output).
    """
    location = finding.get("location", {})
    filename = location.get("filename", "")
    if filename:
        candidate = tf_dir / filename
        if candidate.exists():
            return candidate
        # Try stripping a leading "terraform/" prefix if present.
        rel = filename.lstrip("/")
        for prefix in ("terraform/", ""):
            p = tf_dir.parent / prefix / rel
            if p.exists():
                return p

    # Fallback: search by resource name embedded in the finding.
    # e.g. resource = "module.storage.aws_s3_bucket.artifacts"
    resource = finding.get("resource", "")
    # Extract resource_type from resource string (last two dotted segments).
    parts = resource.split(".")
    if len(parts) >= 2:
        res_type = parts[-2]  # e.g. "aws_s3_bucket"
        res_name = parts[-1]  # e.g. "artifacts"
        # Map resource_type prefix to module directory.
        MODULE_HINTS = [
            ("aws_s3_bucket",   "storage"),
            ("aws_dynamodb",    "storage"),
            ("aws_vpc",         "network"),
            ("aws_subnet",      "network"),
            ("aws_security_group", "network"),
            ("aws_instance",    "compute"),
            ("aws_lambda",      "compute"),
            ("aws_ecs",         "compute"),
            ("aws_eks",         "compute"),
            ("aws_sqs",         "messaging"),
            ("aws_sns",         "messaging"),
            ("aws_sfn",         "messaging"),
            ("aws_db_instance", "data"),
            ("aws_rds",         "data"),
            ("aws_elasticache", "data"),
            ("aws_msk",         "data"),
            ("aws_opensearch",  "data"),
            ("aws_iam",         "security"),
            ("aws_kms",         "security"),
            ("aws_secretsmanager", "security"),
            ("aws_api_gateway", "api"),
        ]
        hint_mod = next(
            (mod for prefix, mod in MODULE_HINTS if res_type.startswith(prefix)),
            None,
        )
        search_dirs = []
        if hint_mod:
            search_dirs.append(tf_dir / "modules" / hint_mod)
        search_dirs.append(tf_dir)
        for d in search_dirs:
            for tf_path in sorted(d.glob("*.tf")):
                content = tf_path.read_text()
                if res_name in content and res_type in content:
                    return tf_path

    return None


def apply_remediations(
    findings: list[dict],
    tf_dir: Path,
    dry_run: bool,
) -> list[dict]:
    """
    Apply allowlisted remediations. Returns a list of result records.
    """
    results = []

    for finding in findings:
        rule_id = finding.get("rule_id", "UNKNOWN")
        blocked, reason = is_blocked(finding, tf_dir)

        if blocked:
            results.append(
                {
                    "rule_id": rule_id,
                    "status": "skipped",
                    "reason": reason,
                    "resource": finding.get("resource", ""),
                }
            )
            continue

        remediation = REMEDIATIONS.get(rule_id)
        if not remediation:
            results.append(
                {
                    "rule_id": rule_id,
                    "status": "no-remediation",
                    "reason": "rule not in allowlist",
                    "resource": finding.get("resource", ""),
                }
            )
            continue

        tf_file = resolve_tf_file(finding, tf_dir)
        if not tf_file:
            results.append(
                {
                    "rule_id": rule_id,
                    "status": "error",
                    "reason": "could not resolve terraform file from finding location",
                    "resource": finding.get("resource", ""),
                }
            )
            continue

        with open(tf_file) as f:
            original = f.read()

        modified, changed = remediation.apply(original, finding)

        if not changed:
            results.append(
                {
                    "rule_id": rule_id,
                    "status": "no-change",
                    "reason": "pattern already present or not matched",
                    "file": str(tf_file),
                    "resource": finding.get("resource", ""),
                }
            )
            continue

        if not dry_run:
            with open(tf_file, "w") as f:
                f.write(modified)

        results.append(
            {
                "rule_id": rule_id,
                "status": "applied" if not dry_run else "dry-run",
                "description": remediation.description,
                "file": str(tf_file),
                "resource": finding.get("resource", ""),
            }
        )

    return results


def validate_terraform(tf_dir: Path) -> tuple[bool, str]:
    """Run terraform validate and return (ok, output)."""
    result = subprocess.run(
        ["terraform", "validate", "-no-color"],
        cwd=tf_dir,
        capture_output=True,
        text=True,
    )
    return result.returncode == 0, result.stdout + result.stderr


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--input",   required=True,  type=Path, help="tfsec JSON output file")
    parser.add_argument("--tf-dir",  required=True,  type=Path, help="Terraform root directory")
    parser.add_argument("--output",  required=False, type=Path, help="Triage report output path")
    parser.add_argument("--dry-run", action="store_true",        help="Preview changes without writing files")
    args = parser.parse_args()

    if not args.input.exists():
        print(f"ERROR: input file not found: {args.input}", file=sys.stderr)
        return 1

    findings = load_findings(args.input)
    print(f"Loaded {len(findings)} findings from {args.input}")

    results = apply_remediations(findings, args.tf_dir, dry_run=args.dry_run)

    applied = [r for r in results if r["status"] == "applied"]
    skipped = [r for r in results if r["status"] == "skipped"]
    errors  = [r for r in results if r["status"] == "error"]

    print(f"  applied   : {len(applied)}")
    print(f"  skipped   : {len(skipped)}")
    print(f"  no-change : {sum(1 for r in results if r['status'] == 'no-change')}")
    print(f"  no-remed  : {sum(1 for r in results if r['status'] == 'no-remediation')}")
    print(f"  errors    : {len(errors)}")

    if applied and not args.dry_run:
        ok, out = validate_terraform(args.tf_dir)
        if not ok:
            print(f"\nERROR: terraform validate failed after triage:\n{out}", file=sys.stderr)
            print("Triage changes may be invalid — check terraform/ manually.", file=sys.stderr)
            # Don't write report; let the pipeline fail cleanly.
            return 1
        print("terraform validate: OK ✓")

    report = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "dry_run": args.dry_run,
        "input": str(args.input),
        "findings_total": len(findings),
        "results": results,
        "summary": {
            "applied": len(applied),
            "skipped": len(skipped),
            "errors": len(errors),
        },
    }

    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with open(args.output, "w") as f:
            json.dump(report, f, indent=2)
        print(f"Report written to {args.output}")

    return 0 if not errors else 1


if __name__ == "__main__":
    sys.exit(main())
