#!/usr/bin/env bash
set -euo pipefail

# Universal check for S3 PUT If-None-Match behavior.
# Requirements:
# - aws CLI v2
# - AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION
# Optional:
# - ENDPOINT_URL (for S3-compatible providers; leave empty for AWS S3)
# - BUCKET_NAME (default: auto-generated)
# - KEY_NAME (default: obj)
# - TEST_PREFIX (default: ifnotmatch-test)
# - CREATE_BUCKET (default: true)
# - CLEANUP_BUCKET (default: false)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

ENDPOINT_URL="${ENDPOINT_URL:-}"
AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
TEST_PREFIX="${TEST_PREFIX:-ifnotmatch-test}"
BUCKET_NAME="${BUCKET_NAME:-$TEST_PREFIX-$(date +%s)}"
KEY_NAME="${KEY_NAME:-obj}"
CREATE_BUCKET="${CREATE_BUCKET:-true}"
CLEANUP_BUCKET="${CLEANUP_BUCKET:-false}"

if ! command -v aws >/dev/null 2>&1; then
  echo "ERROR: aws CLI not found"
  exit 1
fi

if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" || -z "${AWS_DEFAULT_REGION:-}" ]]; then
  echo "ERROR: set AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION in env or .env"
  exit 1
fi

aws_args=()
if [[ -n "$ENDPOINT_URL" ]]; then
  aws_args+=(--endpoint-url "$ENDPOINT_URL")
fi

tmp1="$(mktemp)"
tmp2="$(mktemp)"
tmp3="$(mktemp)"
trap 'rm -f "$tmp1" "$tmp2" "$tmp3"' EXIT

echo "v1" >"$tmp1"
echo "v2" >"$tmp2"
echo "v3" >"$tmp3"

if [[ "$CREATE_BUCKET" == "true" ]]; then
  echo "Creating bucket: $BUCKET_NAME"
  if [[ "$AWS_DEFAULT_REGION" == "us-east-1" ]]; then
    aws "${aws_args[@]}" s3api create-bucket --bucket "$BUCKET_NAME" >/dev/null
  else
    aws "${aws_args[@]}" s3api create-bucket \
      --bucket "$BUCKET_NAME" \
      --create-bucket-configuration "LocationConstraint=$AWS_DEFAULT_REGION" >/dev/null
  fi
fi

echo "Uploading initial object: $KEY_NAME"
aws "${aws_args[@]}" s3api put-object \
  --bucket "$BUCKET_NAME" \
  --key "$KEY_NAME" \
  --body "$tmp1" >/dev/null

etag_initial="$(
  aws "${aws_args[@]}" s3api head-object \
    --bucket "$BUCKET_NAME" \
    --key "$KEY_NAME" \
    --query ETag \
    --output text | tr -d '"'
)"
echo "Initial ETag: $etag_initial"

echo "Test 1: If-None-Match '*' on existing object (must fail with HTTP 412)"
set +e
out_star="$(
  aws "${aws_args[@]}" s3api put-object \
    --bucket "$BUCKET_NAME" \
    --key "$KEY_NAME" \
    --body "$tmp2" \
    --if-none-match "*" 2>&1
)"
rc_star=$?
set -e

etag_after_star="$(
  aws "${aws_args[@]}" s3api head-object \
    --bucket "$BUCKET_NAME" \
    --key "$KEY_NAME" \
    --query ETag \
    --output text | tr -d '"'
)"

if [[ $rc_star -ne 0 && "$out_star" == *"PreconditionFailed"* ]]; then
  echo "✅ PASS: If-None-Match '*' rejected overwrite"
elif [[ $rc_star -ne 0 && "$etag_after_star" == "$etag_initial" ]]; then
  echo "✅ PASS: If-None-Match '*' rejected overwrite (ETag unchanged)"
else
  echo "❌ FAIL: expected If-None-Match '*' to reject overwrite, rc=$rc_star"
  echo "$out_star"
  echo "Initial ETag: $etag_initial"
  echo "ETag after attempt: $etag_after_star"
  exit 2
fi

echo "Test 2: If-None-Match current ETag (must fail)"
set +e
out_etag="$(
  aws "${aws_args[@]}" s3api put-object \
    --bucket "$BUCKET_NAME" \
    --key "$KEY_NAME" \
    --body "$tmp3" \
    --if-none-match "$etag_initial" 2>&1
)"
rc_etag=$?
set -e

etag_after_etag="$(
  aws "${aws_args[@]}" s3api head-object \
    --bucket "$BUCKET_NAME" \
    --key "$KEY_NAME" \
    --query ETag \
    --output text | tr -d '"'
)"

if [[ $rc_etag -ne 0 && "$out_etag" == *"PreconditionFailed"* ]]; then
  echo "✅ PASS: If-None-Match with current ETag rejected overwrite"
elif [[ $rc_etag -ne 0 && "$etag_after_etag" == "$etag_initial" ]]; then
  echo "✅ PASS: If-None-Match with current ETag rejected overwrite (ETag unchanged)"
else
  echo "❌ FAIL: expected If-None-Match with current ETag to reject overwrite, rc=$rc_etag"
  echo "$out_etag"
  echo "Initial ETag: $etag_initial"
  echo "ETag after attempt: $etag_after_etag"
  exit 3
fi

if [[ "$CLEANUP_BUCKET" == "true" ]]; then
  echo "Cleanup: delete object and bucket"
  aws "${aws_args[@]}" s3api delete-object --bucket "$BUCKET_NAME" --key "$KEY_NAME" >/dev/null
  aws "${aws_args[@]}" s3api delete-bucket --bucket "$BUCKET_NAME" >/dev/null
fi

echo "Done"
