# S3 If-Match / If-None-Match Tests

A small project with bash scripts for testing conditional `PUT` requests in S3:

- `test_put_if_match.sh` - tests `If-Match`
- `test_put_if_not_match.sh` - tests `If-None-Match`

Works with both AWS S3 and S3-compatible providers (MinIO, Ceph RGW, etc.).

## Requirements

- `aws` CLI v2
- S3 access (access key, secret key, region)

## Setup

1. Create `.env` from the example:

```bash
cp .env.example .env
```

2. Fill required fields in `.env`:

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_DEFAULT_REGION`

3. `ENDPOINT_URL`:

- keep empty for AWS S3
- set URL for S3-compatible service, for example `http://127.0.0.1:9000`

## Run

Using `make`:

```bash
make test-if-match
make test-if-not-match
make test-all
```

Or directly:

```bash
bash test_put_if_match.sh
bash test_put_if_not_match.sh
```

## Useful `.env` Variables

- `BUCKET_NAME` - fixed bucket name (if not set, generated automatically)
- `KEY_NAME` - object key (default: `obj`)
- `CREATE_BUCKET` - create bucket in test (`true`/`false`)
- `CLEANUP_BUCKET` - delete object and bucket after test (`true`/`false`)
- `TEST_PREFIX` - prefix for auto-generated bucket name
