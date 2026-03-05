#!/usr/bin/env bash
set -euo pipefail

# Universal check for S3 PUT If-Match behavior.
# Requirements:
# - aws CLI v2
# - AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION
# Optional:
# - ENDPOINT_URL (for S3-compatible providers; leave empty for AWS S3)
# - BUCKET_NAME (default: auto-generated)
# - KEY_NAME (default: obj)
# - TEST_PREFIX (default: ifmatch-test)
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
TEST_PREFIX="${TEST_PREFIX:-ifmatch-test}"
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
trap 'rm -f "$tmp1" "$tmp2"' EXIT

echo "v1" >"$tmp1"
echo "v2" >"$tmp2"

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

etag="$(
  aws "${aws_args[@]}" s3api head-object \
    --bucket "$BUCKET_NAME" \
    --key "$KEY_NAME" \
    --query ETag \
    --output text | tr -d '"'
)"
echo "Initial ETag: $etag"

echo "Test 1: matching If-Match (must succeed)"
aws "${aws_args[@]}" s3api put-object \
  --bucket "$BUCKET_NAME" \
  --key "$KEY_NAME" \
  --body "$tmp2" \
  --if-match "$etag" >/dev/null
echo "✅ PASS: matching If-Match accepted"

etag_after_success="$(
  aws "${aws_args[@]}" s3api head-object \
    --bucket "$BUCKET_NAME" \
    --key "$KEY_NAME" \
    --query ETag \
    --output text | tr -d '"'
)"
echo "ETag after matching If-Match PUT: $etag_after_success"

echo "Test 2: wrong If-Match (must fail with HTTP 412)"
set +e
out="$(
  aws "${aws_args[@]}" s3api put-object \
    --bucket "$BUCKET_NAME" \
    --key "$KEY_NAME" \
    --body "$tmp2" \
    --if-match "deadbeef" 2>&1
)"
rc=$?
set -e

etag_after_failed="$(
  aws "${aws_args[@]}" s3api head-object \
    --bucket "$BUCKET_NAME" \
    --key "$KEY_NAME" \
    --query ETag \
    --output text | tr -d '"'
)"

echo "ETag after wrong If-Match PUT attempt: $etag_after_failed"

if [[ $rc -ne 0 && "$out" == *"PreconditionFailed"* ]]; then
  echo "✅ PASS: wrong If-Match rejected with PreconditionFailed"
elif [[ $rc -ne 0 && "$etag_after_failed" == "$etag_after_success" ]]; then
  echo "✅ PASS: wrong If-Match rejected (ETag unchanged from previous successful PUT)"
else
  echo "❌ FAIL: expected rejected update, rc=$rc"
  echo "$out"
  echo "ETag after success: $etag_after_success"
  echo "ETag after failed attempt: $etag_after_failed"
  exit 2
fi

if [[ "$CLEANUP_BUCKET" == "true" ]]; then
  echo "Cleanup: delete object and bucket"
  aws "${aws_args[@]}" s3api delete-object --bucket "$BUCKET_NAME" --key "$KEY_NAME" >/dev/null
  aws "${aws_args[@]}" s3api delete-bucket --bucket "$BUCKET_NAME" >/dev/null
fi

echo "Done"
