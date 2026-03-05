#!/usr/bin/env bash
set -euo pipefail

# Universal check for global LIST order across pagination for objects (e.g. WAL).
# Requirements:
# - aws CLI v2
# - AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION
# Optional:
# - ENDPOINT_URL (for S3-compatible providers; leave empty for AWS S3)
# - BUCKET_NAME (default: auto-generated)
# - TEST_PREFIX (default: list-order-test)
# - CREATE_BUCKET (default: true)
# - CLEANUP_BUCKET (default: false)
# - CATALOG_PREFIX (default: list/)
# - OBJECTS_COUNT (default: 202)
# - PAGE_SIZE (default: 100)
# - OBJECT_KEY_WIDTH (default: 7)

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
TEST_PREFIX="${TEST_PREFIX:-list-order-test}"
BUCKET_NAME="${BUCKET_NAME:-$TEST_PREFIX-$(date +%s)}"
CREATE_BUCKET="${CREATE_BUCKET:-true}"
CLEANUP_BUCKET="${CLEANUP_BUCKET:-false}"
if [[ -n "${CATALOG_PREFIX:-}" ]]; then
  CATALOG_PREFIX="$CATALOG_PREFIX"
else
  CATALOG_PREFIX="list-$(date +%s)-$RANDOM/"
fi
OBJECTS_COUNT="${OBJECTS_COUNT:-202}"
PAGE_SIZE="${PAGE_SIZE:-100}"
OBJECT_KEY_WIDTH="${OBJECT_KEY_WIDTH:-7}"

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

calc_objects_per_second() {
  local objects_created="$1"
  local started_at="$2"
  local ended_at="$3"
  local elapsed_seconds=$((ended_at - started_at))

  if ((elapsed_seconds <= 0)); then
    elapsed_seconds=1
  fi

  awk -v objects="$objects_created" -v elapsed="$elapsed_seconds" 'BEGIN { printf "%.2f", objects / elapsed }'
}

tmp_body="$(mktemp)"
trap 'rm -f "$tmp_body"' EXIT

echo "object-test-payload" >"$tmp_body"

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

echo "Uploading $OBJECTS_COUNT objects with keys ${CATALOG_PREFIX}%0${OBJECT_KEY_WIDTH}d"
progress_step=$((OBJECTS_COUNT / 20))
if ((progress_step < 1)); then
  progress_step=1
fi

upload_started_at="$(date +%s)"
for ((i = 1; i <= OBJECTS_COUNT; i++)); do
  printf -v object_num "%0${OBJECT_KEY_WIDTH}d" "$i"
  object_key="${CATALOG_PREFIX}${object_num}"
  aws "${aws_args[@]}" s3api put-object \
    --bucket "$BUCKET_NAME" \
    --key "$object_key" \
    --body "$tmp_body" >/dev/null

  if ((i == 1 || i == OBJECTS_COUNT || i % progress_step == 0)); then
    progress_pct=$((i * 100 / OBJECTS_COUNT))
    echo "Upload progress: $i/$OBJECTS_COUNT (${progress_pct}%) last_key=$object_key"
  fi
done
upload_ended_at="$(date +%s)"
objects_per_second="$(calc_objects_per_second "$OBJECTS_COUNT" "$upload_started_at" "$upload_ended_at")"
echo "Upload speed: ${objects_per_second} objects/sec"

expected_last="$(printf "%s%0${OBJECT_KEY_WIDTH}d" "$CATALOG_PREFIX" "$OBJECTS_COUNT")"
expected_first="$(printf "%s%0${OBJECT_KEY_WIDTH}d" "$CATALOG_PREFIX" 1)"

echo "Checking max-keys=1 returns first lexicographic key under prefix '$CATALOG_PREFIX'"
first_key_single_page="$(
  aws "${aws_args[@]}" s3api list-objects-v2 \
    --bucket "$BUCKET_NAME" \
    --prefix "$CATALOG_PREFIX" \
    --max-keys 1 \
    --query 'Contents[0].Key' \
    --output text
)"

echo "max-keys=1 result: got=$first_key_single_page expected=$expected_first"
if [[ "$first_key_single_page" != "$expected_first" ]]; then
  echo "❌ FAIL: max-keys=1 does not return first lexicographic key: expected=$expected_first got=$first_key_single_page"
  exit 2
fi

echo "✅ PASS: first object key is $first_key_single_page"

echo "Listing objects with max-keys=$PAGE_SIZE under prefix '$CATALOG_PREFIX'"
page_count=0
candidate_last=""
prev_last=""
continuation_token=""

while true; do
  page_count=$((page_count + 1))

  cmd=(aws "${aws_args[@]}" s3api list-objects-v2
    --bucket "$BUCKET_NAME"
    --prefix "$CATALOG_PREFIX"
    --max-keys "$PAGE_SIZE"
    --query '[Contents[0].Key, Contents[-1].Key, NextContinuationToken, length(Contents)]'
    --output text)

  if [[ -n "$continuation_token" ]]; then
    cmd+=(--continuation-token "$continuation_token")
  fi

  page_out="$("${cmd[@]}")"
  read -r first_key last_key next_token object_count <<<"$page_out"

  echo "Page $page_count: count=$object_count first=$first_key last=$last_key"

  if [[ "$object_count" == "0" || "$first_key" == "None" || "$last_key" == "None" ]]; then
    echo "❌ FAIL: empty page detected during pagination (page=$page_count)"
    exit 2
  fi

  if [[ -n "$prev_last" && ! "$first_key" > "$prev_last" ]]; then
    echo "❌ FAIL: page boundary order violation: prev_last=$prev_last current_first=$first_key (page=$page_count)"
    exit 2
  fi

  candidate_last="$last_key"
  prev_last="$last_key"

  if [[ "$next_token" == "None" || -z "$next_token" ]]; then
    break
  fi

  continuation_token="$next_token"
done

echo "Pagination completed: page_count=$page_count candidate_last=$candidate_last expected_last=$expected_last"

if ((page_count <= 1)); then
  echo "❌ FAIL: expected pagination across multiple pages, got page_count=$page_count"
  exit 2
fi

if [[ "$candidate_last" != "$expected_last" ]]; then
  echo "❌ FAIL: wrong global last object key: expected=$expected_last got=$candidate_last"
  exit 2
fi

echo "✅ PASS: global list order across pages is consistent; last object key is $candidate_last"

if [[ "$CLEANUP_BUCKET" == "true" ]]; then
  echo "Cleanup: delete objects and bucket"
  aws "${aws_args[@]}" s3 rm "s3://$BUCKET_NAME/$CATALOG_PREFIX" --recursive >/dev/null
  aws "${aws_args[@]}" s3api delete-bucket --bucket "$BUCKET_NAME" >/dev/null
fi

echo "Done"
