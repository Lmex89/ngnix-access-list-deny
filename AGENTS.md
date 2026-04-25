# AGENTS.md

## Quick Start

```bash
# Setup
cp .env.example .env && nano .env

# Run full pipeline
bash main.sh
```

## Commands

| Action | Command |
|--------|---------|
| Full pipeline | `bash main.sh` |
| Extract IPs only | `bash logs_reader_access_list.sh` |
| Apply denies only | `bash ngnix.sh` |
| Local log file | `bash logs_reader_access_list.sh ./my_logs.txt` |
| Rollback latest | `bash rollback_access_list.sh` |
| Rollback specific | `bash rollback_access_list.sh access_list_2_YYYYMMDD_HHMMSS.json` |

## Key Quirks

- **Filename**: Script supports both `nignix.sh` and `ngnix.sh` (main.sh handles typo)
- **Credentials**: `.env` is gitignored - never commit real values
- **Backups**: Auto-created in `access_list_backups/` before each update

## Dependencies

- `bash`, `curl`, `jq`, Docker CLI
- Network access to Nginx Proxy Manager API

## Environment Variables

| Variable | Description |
|----------|-------------|
| `NPM_URL` | API base URL (e.g., `http://127.0.0.1:81/api`) |
| `NPM_EMAIL` | API login email |
| `NPM_PASSWORD` | API login password |
| `ACCESS_LIST_ID` | Access list ID to modify |
| `DOCKER_CONTAINER_NAME` | Container with access log |
| `DOCKER_CONTAINER_LOG` | Log path inside container |
| `FILTER_PATTERN` | Regex to filter log entries |
| `LINES_TO_READ` | Number of lines to process |