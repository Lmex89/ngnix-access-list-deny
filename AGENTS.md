# AGENTS.md

## Codegraph (Mandatory)

Always use codegraph tools (`codegraph_search_semantic`, `codegraph_find_symbol`, `codegraph_context_for_task`, etc.) instead of built-in search tools (`grep`, `glob`, `read`). Fall back to built-in tools only if codegraph does not return satisfactory results.

## Quick Start

```bash
cp .env.example .env && nano .env
bash main.sh
```

## Commands

| Action | Command |
|--------|---------|
| Full pipeline | `bash main.sh` |
| Extract IPs only | `bash logs_reader_access_list.sh` |
| Apply denies only | `bash ngnix.sh` |
| Preview changes | `bash ngnix.sh --dry-run` |
| Local log file | `bash logs_reader_access_list.sh ./my_logs.txt` |
| Rollback latest | `bash rollback_access_list.sh` |
| Rollback specific | `bash rollback_access_list.sh access_list_2_YYYYMMDD_HHMMSS.json` |

## Critical Safety Features

- **Strict error handling**: All scripts use `set -Eeuo pipefail` with ERR traps - they fail fast on any error
- **Allow-all preservation**: Scripts automatically ensure an `allow all` rule exists to prevent lockout
- **Auto-backup**: Every update creates `access_list_backups/access_list_{ID}_{TIMESTAMP}.json`
- **Rollback safety**: Rollback saves current state as `access_list_{ID}_before_rollback_{TIMESTAMP}.json` before restoring

## Key Quirks

- **Filename**: Script supports both `nignix.sh` and `ngnix.sh` (main.sh handles typo)
- **Credentials**: `.env` is gitignored - never commit real values
- **IP list is persistent**: `client_ips.txt` is append-only and never auto-cleaned - manually remove false positives
- **Log format**: Extracts IPs from `[Client IP]` pattern in logs - validate your log format matches
- **Cron compatibility**: `ngnix.sh` sets explicit PATH for cron environments
- **Dry-run**: Always test with `ngnix.sh --dry-run` before applying changes

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

## Testing & CI

- No tests or CI workflows currently exist (see CHECKLIST.md for planned improvements)
- Scripts use strict bash error handling but have no automated test coverage