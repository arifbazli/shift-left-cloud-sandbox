#!/usr/bin/env bash
# =============================================================================
# scripts/verify.sh
# =============================================================================
# Purpose
#   Independently verify that the resources claimed by the last deploy.sh
#   actually exist in floci-core. This is NOT a trust of terraform's state
#   file — it hits the AWS-shaped API directly via Sigv4-signed requests.
#
# What we check (per resource type)
#   VPC:        EC2 DescribeVpcs
#   Subnet:     EC2 DescribeSubnets
#   SG:         EC2 DescribeSecurityGroups
#   Bucket:     S3 HEAD bucket
#   IAM role:   IAM GetRole
#
# Output
#   - Writes dashboard/public/data/verify-history.json
#   - Writes dashboard/public/data/verify-last.json
#   - Exits 0 if ALL resources verified, non-zero on any mismatch
#
# SEC_INTENT: this script treats the terraform state as UNTRUSTED. It does
# not read terraform.tfstate. It only reads the outputs captured by
# deploy.sh (which are valid HCL outputs, not internal state). If floci-core
# reports the resource is gone, the deploy is wrong even if state thinks
# it's fine.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DASH_DATA="$ROOT_DIR/dashboard/public/data"
PENDING_FILE="$DASH_DATA/verify-pending.json"
LAST_FILE="$DASH_DATA/verify-last.json"
HIST_FILE="$DASH_DATA/verify-history.json"
SIGV4_HELPER="$(mktemp /tmp/floci-sigv4.XXXXXX.py)"
VERIFY_DRIVER="$(mktemp /tmp/floci-verify.XXXXXX.py)"

mkdir -p "$DASH_DATA"
trap 'rm -f "$SIGV4_HELPER" "$VERIFY_DRIVER"' EXIT

# ---- Pre-flight ------------------------------------------------------------
if [[ ! -s "$PENDING_FILE" ]]; then
  echo "FATAL: $PENDING_FILE does not exist." >&2
  echo "  Run scripts/deploy.sh first." >&2
  exit 2
fi

FLOCI_ENDPOINT="${FLOCI_ENDPOINT:-http://localhost:4566}"
export FLOCI_ENDPOINT
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION

if ! curl -sf -m 3 -o /dev/null "$FLOCI_ENDPOINT/health" 2>/dev/null \
   && ! curl -sf -m 3 -o /dev/null "$FLOCI_ENDPOINT/" 2>/dev/null; then
  echo "FATAL: floci-core is not reachable at $FLOCI_ENDPOINT" >&2
  exit 2
fi

# ---- Sigv4 helper ----------------------------------------------------------
# python3's stdlib has hashlib, hmac, urllib. That's enough for Sigv4.
# We only implement the request-1.0 minimum (no session tokens, no extra
# headers). floci-core accepts dummy signatures anyway — the signature is
# only checked for shape, not cryptographic validity.
cat >"$SIGV4_HELPER" <<'PYEOF'
import sys, os, json, hmac, hashlib, datetime, urllib.request, urllib.error

method, region, service, path, query, body, host, endpoint = sys.argv[1:9]
ak = os.environ.get('AWS_ACCESS_KEY_ID', 'test')
sk = os.environ.get('AWS_SECRET_ACCESS_KEY', 'test')

def sha256_hex(b):
    return hashlib.sha256(b).hexdigest()

t = datetime.datetime.utcnow()
amzdate  = t.strftime('%Y%m%dT%H%M%SZ')
datestamp = t.strftime('%Y%m%d')
canonical_uri = path
canonical_querystring = query
payload_hash = sha256_hex(body.encode())
canonical_headers = f"host:{host}\nx-amz-date:{amzdate}\n"
signed_headers = "host;x-amz-date"
canonical_request = (
    f"{method}\n{canonical_uri}\n{canonical_querystring}\n"
    f"{canonical_headers}\n{signed_headers}\n{payload_hash}"
)
algorithm = "AWS4-HMAC-SHA256"
credential_scope = f"{datestamp}/{region}/{service}/aws4_request"
string_to_sign = (
    f"{algorithm}\n{amzdate}\n{credential_scope}\n"
    f"{sha256_hex(canonical_request.encode())}"
)
def sign_key(k, date, region, service):
    k_date   = hmac.new(('AWS4' + k).encode(), date.encode(), hashlib.sha256).digest()
    k_region = hmac.new(k_date, region.encode(), hashlib.sha256).digest()
    k_service = hmac.new(k_region, service.encode(), hashlib.sha256).digest()
    return hmac.new(k_service, 'aws4_request'.encode(), hashlib.sha256).digest()
sig = hmac.new(sign_key(sk, datestamp, region, service), string_to_sign.encode(), hashlib.sha256).hexdigest()
auth = f"{algorithm} Credential={ak}/{credential_scope}, SignedHeaders={signed_headers}, Signature={sig}"

url = f"{endpoint}{path}"
if query:
    url += "?" + query
req = urllib.request.Request(
    url, data=(body.encode() if body else None), method=method,
    headers={
        "Host": host,
        "X-Amz-Date": amzdate,
        "Authorization": auth,
        "Content-Type": "application/x-www-form-urlencoded; charset=utf-8",
    }
)
try:
    resp = urllib.request.urlopen(req, timeout=10)
    data = resp.read().decode()
    print(json.dumps({"status": resp.status, "body": data}))
except urllib.error.HTTPError as e:
    print(json.dumps({"status": e.code, "body": e.read().decode() if e.fp else ""}))
PYEOF

# ---- Verification driver ---------------------------------------------------
cat >"$VERIFY_DRIVER" <<'PYEOF'
import sys, json, subprocess, os

endpoint = os.environ.get('FLOCI_ENDPOINT', 'http://localhost:4566')
helper = os.environ.get('VERIFY_SIGV4_HELPER', '')

with open(sys.argv[1]) as f:
    pending = json.load(f)
expected_out = pending.get('outputs', {})
expected = {
    "vpc_id":                expected_out.get('vpc_id', {}).get('value', ''),
    "private_subnet_id":     expected_out.get('private_subnet_id', {}).get('value', ''),
    "artifacts_bucket":      expected_out.get('artifacts_bucket', {}).get('value', ''),
    "app_security_group_id": expected_out.get('app_security_group_id', {}).get('value', ''),
    "app_role_arn":          expected_out.get('app_role_arn', {}).get('value', ''),
}
results = []

def call(method, region, service, path, query, body, host):
    env = {**os.environ, 'VERIFY_SIGV4_HELPER': helper}
    out = subprocess.run(
        ['python3', helper, method, region, service, path, query, body, host, endpoint],
        capture_output=True, text=True, env=env
    )
    return json.loads(out.stdout)

# --- VPC (EC2) ---
vpc_id = expected.get('vpc_id', '')
if vpc_id:
    body = f"Action=DescribeVpcs&Version=2016-11-15&VpcId.1={vpc_id}"
    j = call('POST', 'us-east-1', 'ec2', '/', '', body, 'localhost')
    body_text = j.get('body', '')
    found = vpc_id in body_text
    results.append({
        "resource": "aws_vpc.main", "id": vpc_id, "found": found,
        "http_status": j.get('status'), "evidence": body_text[:200]
    })

# --- Subnet (EC2) ---
subnet_id = expected.get('private_subnet_id', '')
if subnet_id:
    body = f"Action=DescribeSubnets&Version=2016-11-15&SubnetId.1={subnet_id}"
    j = call('POST', 'us-east-1', 'ec2', '/', '', body, 'localhost')
    body_text = j.get('body', '')
    found = subnet_id in body_text
    results.append({
        "resource": "aws_subnet.private", "id": subnet_id, "found": found,
        "http_status": j.get('status'), "evidence": body_text[:200]
    })

# --- Security Group (EC2) ---
sg_id = expected.get('app_security_group_id', '')
if sg_id:
    body = f"Action=DescribeSecurityGroups&Version=2016-11-15&GroupId.1={sg_id}"
    j = call('POST', 'us-east-1', 'ec2', '/', '', body, 'localhost')
    body_text = j.get('body', '')
    found = sg_id in body_text
    results.append({
        "resource": "aws_security_group.app", "id": sg_id, "found": found,
        "http_status": j.get('status'), "evidence": body_text[:200]
    })

# --- S3 Bucket (S3 HEAD) ---
bucket = expected.get('artifacts_bucket', '')
if bucket:
    j = call('HEAD', 'us-east-1', 's3', f'/{bucket}', '', '', f'{bucket}.localhost')
    status = j.get('status', 0)
    found = 200 <= status < 300
    results.append({
        "resource": "aws_s3_bucket.artifacts", "id": bucket, "found": found,
        "http_status": status, "evidence": j.get('body', '')[:200]
    })

# --- IAM Role ---
role_arn = expected.get('app_role_arn', '')
role_name = role_arn.split('/')[-1] if role_arn else ''
if role_name:
    body = f"Action=GetRole&Version=2010-05-08&RoleName={role_name}"
    j = call('POST', 'us-east-1', 'iam', '/', '', body, 'localhost')
    body_text = j.get('body', '')
    found = role_name in body_text
    results.append({
        "resource": "aws_iam_role.app", "id": role_name, "found": found,
        "http_status": j.get('status'), "evidence": body_text[:200]
    })

print(json.dumps(results))
PYEOF

# ---- Run the verification --------------------------------------------------
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
results_json="$(VERIFY_SIGV4_HELPER="$SIGV4_HELPER" python3 "$VERIFY_DRIVER" "$PENDING_FILE")"

total="$(echo "$results_json" | jq 'length')"
passed="$(echo "$results_json" | jq '[.[] | select(.found == true)] | length')"
if [[ "$passed" -eq "$total" ]]; then
  all_passed=true
else
  all_passed=false
fi

report="$(jq -n \
  --arg ts "$ts" \
  --arg endpoint "$FLOCI_ENDPOINT" \
  --argjson total "$total" \
  --argjson passed "$passed" \
  --argjson all_passed "$all_passed" \
  --argjson results "$results_json" \
  '{
    timestamp: $ts,
    endpoint: $endpoint,
    total: $total,
    passed: $passed,
    all_passed: $all_passed,
    results: $results
  }')"

# Write to dashboard JSON
echo "$report" | jq '.' >"$LAST_FILE"
hist_tmp="$(mktemp)"
if [[ -s "$HIST_FILE" ]] && jq -e 'type == "array"' "$HIST_FILE" >/dev/null 2>&1; then
  jq --argjson r "$report" '. + [$r]' "$HIST_FILE" >"$hist_tmp"
else
  echo "[$report]" | jq '.' >"$hist_tmp"
fi
mv "$hist_tmp" "$HIST_FILE"

# Human summary
echo "---- verify ($ts) ----"
echo "  endpoint: $FLOCI_ENDPOINT"
echo "  results:  passed=$passed / total=$total"
echo "  status:   $([[ "$all_passed" == true ]] && echo PASS || echo FAIL)"
echo ""
echo "$results_json" | jq -r '.[] | "  [\(.found | tostring | ascii_upcase)] \(.resource) (\(.id)) — HTTP \(.http_status))"'

# Per-resource failure detail
echo ""
echo "$results_json" | jq -r '.[] | select(.found == false) | "  FAIL: \(.resource) (\(.id))\n    evidence: \(.evidence)"'

if [[ "$all_passed" == "true" ]]; then
  exit 0
else
  exit 1
fi
