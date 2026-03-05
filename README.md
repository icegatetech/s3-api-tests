# S3 Compability Tests

A small project with bash scripts for testing S3 API compability:

- `test_put_if_match.sh` - tests `If-Match`
- `test_put_if_not_match.sh` - tests `If-None-Match`
- `test_list_order.sh` - tests global `LIST` order across pagination for WAL keys

Works with both AWS S3 and S3-compatible providers (MinIO, Ceph RGW, etc.).

## Requirements

- `aws` CLI v2
- S3 access (access key, secret key, region)

AWS CLI installation:

- Official install guide (all platforms): https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
- Linux: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html#cliv2-linux-install
- macOS: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html#cliv2-mac-install
- Windows: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html#cliv2-windows-install

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
make test-list-order
```

Or directly:

```bash
bash test_put_if_match.sh
bash test_put_if_not_match.sh
bash test_list_order.sh
```

## S3 API Tests
## Pagination Order Test (WAL)

`test_list_order.sh` creates WAL objects with lexicographic keys:

- `wal/0000001` ... `wal/0000201`

Then it lists objects with page size `100` (`list-objects-v2 --max-keys 100`) and checks:

- pagination is real (`page_count >= 2`)
- first key on each next page is strictly greater than the previous page last key
- global last key from paginated traversal is exactly `wal/0000201`

This verifies that the last WAL key is found globally across pages, not only inside one page.

## Useful `.env` Variables

See in `.env.example`.
