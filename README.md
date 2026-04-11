# Nginx Access List Deny Automation

Automates deny-list updates in Nginx Proxy Manager using suspicious IPs extracted from access logs.

## What this project does

1. Reads recent log lines from a Docker container and extracts client IPs.
2. Stores newly discovered IPs in `client_ips.txt`.
3. Adds those IPs as `deny` rules to an existing Nginx Proxy Manager access list.
4. Creates JSON backups before any update.
5. Provides rollback to a previous backup.

## Files

- `logs_reader_access_list.sh`: Extracts unique client IPs from logs and appends new ones to `client_ips.txt`.
- `ngnix.sh`: Updates Nginx Proxy Manager access list by adding deny rules for IPs in `client_ips.txt`.
- `main.sh`: Runs log extraction first, then access-list update, and writes status to `pipeline_status.log`.
- `rollback_access_list.sh`: Restores access list from backup JSON.
- `client_ips.txt`: Persistent list of discovered IPs.
- `access_list_backups/`: Auto-generated backups of access-list payloads.

## Prerequisites

- Bash
- Docker CLI (for log reading)
- `curl`
- `jq`
- Network access to your Nginx Proxy Manager API

## Setup

1. Copy environment template:

```bash
cp .env.example .env
```

2. Edit `.env` and fill real values:

```bash
nano .env
```

3. (Optional) Make scripts executable:

```bash
chmod +x logs_reader_access_list.sh ngnix.sh main.sh rollback_access_list.sh
```

## Environment variables

Defined in `.env`:

- `NPM_URL`: Nginx Proxy Manager API base URL (example: `http://127.0.0.1:81/api`)
- `NPM_EMAIL`: API login email
- `NPM_PASSWORD`: API login password
- `ACCESS_LIST_ID`: Access list ID to update
- `DOCKER_CONTAINER_NAME`: Container that has the target access log
- `DOCKER_CONTAINER_LOG`: Log path inside container
- `FILTER_PATTERN`: Regex used to filter interesting log entries
- `LINES_TO_READ`: Number of latest filtered lines to process

## Usage

Run full pipeline:

```bash
bash main.sh
```

Run only log extraction:

```bash
bash logs_reader_access_list.sh
```

Run log extraction against a local file instead of Docker:

```bash
bash logs_reader_access_list.sh ./my_logs.txt
```

Apply deny rules without running the reader:

```bash
bash ngnix.sh
```

Rollback to latest backup:

```bash
bash rollback_access_list.sh
```

Rollback to specific backup:

```bash
bash rollback_access_list.sh access_list_2_YYYYMMDD_HHMMSS.json
```

## Backups and rollback

- `ngnix.sh` saves the current access list before updating.
- `rollback_access_list.sh` also saves a safety backup of current state before restore.
- Backups are written under `access_list_backups/`.

## Notes

- `main.sh` supports both `nignix.sh` and `ngnix.sh` file names for compatibility.
- `.env` is ignored by git. Do not commit real credentials.
- `client_ips.txt` grows over time; review it periodically.

## Troubleshooting

- Missing variable error: verify `.env` exists and all required values are set.
- Empty extracted IP list: broaden `FILTER_PATTERN` or increase `LINES_TO_READ`.
- API auth failure: recheck `NPM_EMAIL`, `NPM_PASSWORD`, and `NPM_URL`.
- Script not found from main script: ensure scripts are in the same directory and names are unchanged.
