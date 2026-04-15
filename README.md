> **Note**: This is a personal self-hosted project built for my own home lab environment. It is provided as-is and is not intended for enterprise or production use.

# Nginx Access List Deny Automation

Automates deny-list updates in Nginx Proxy Manager using suspicious IPs extracted from Docker container logs. Detects and blocks bots, crawlers, and suspicious clients via configurable regex filtering.

## Quick Start

```bash
cp .env.example .env          # Copy config template
nano .env                      # Edit with real credentials and container info
bash main.sh                  # Run: extract IPs, apply deny rules
```

Your Nginx Proxy Manager access list is now updated with new deny rules and fully backed up.

## How it works

1. **Extract**—reads recent filtered log lines from Docker container and scrapes client IPs
2. **Validate**—rejects malformed or invalid IPs (strict IPv4 format + octet range check)
3. **Deduplicate**—stores only new IPs not already in `client_ips.txt`
4. **Apply**—adds those IPs as `deny` rules to Nginx Proxy Manager access list
5. **Backup**—saves full access list state as JSON before applying changes
6. **Safeties**—allow-all rule is preserved; HTTP errors are caught explicitly; rollback always available

## File reference

| File | Purpose |
|------|----------|
| `logs_reader_access_list.sh` | Extract unique IPs from Docker logs matching filter pattern; append new ones to `client_ips.txt` |
| `ngnix.sh` | Update Nginx Proxy Manager access list with deny rules for all IPs in `client_ips.txt` |
| `main.sh` | Orchestrator: runs log extract, then access-list update; logs status to `pipeline_status.log` |
| `rollback_access_list.sh` | Restore access list to a previous backup; saves safety snapshot before restoring |
| `client_ips.txt` | Persistent, growing list of all extracted IPs; manually edit to remove or add IPs |
| `access_list_backups/` | Auto-created backups as JSON; named `access_list_2_YYYYMMDD_HHMMSS.json` |

## Prerequisites

- Bash
- Docker CLI (for log reading)
- `curl`
- `jq`
- Network access to your Nginx Proxy Manager API

## Setup

1. **Copy config template**:

   ```bash
   cp .env.example .env
   ```

2. **Edit `.env` with your values**:

   ```bash
   nano .env
   ```

3. **Optional — make scripts executable**:

   ```bash
   chmod +x logs_reader_access_list.sh ngnix.sh main.sh rollback_access_list.sh
   ```

## Configuration (`.env`)

### Nginx Proxy Manager

- `NPM_URL` — API base URL, typically `http://127.0.0.1:81/api` (or your external IP)
- `NPM_EMAIL` — Admin email used to authenticate
- `NPM_PASSWORD` — Admin password
- `ACCESS_LIST_ID` — Numeric ID of the access list to update (check NPM UI)

### Docker & Logging

- `DOCKER_CONTAINER_NAME` — Name of container running Nginx or your app
- `DOCKER_CONTAINER_LOG` — Path to log file inside container (e.g., `/data/logs/proxy-host-9_access.log`)
- `FILTER_PATTERN` — Regex to match suspicious entries; example: `bot|crawl|wp|env|.git|config.js|aws|docker`
- `LINES_TO_READ` — Number of recent log lines to process in each run (e.g., `200`)

### Filter Pattern Tips

- Match request paths: `wp-admin|env.local|config.php`
- Match user agents: `bot|crawler|scrapy|curl`
- Match both: `(wp-admin|wp-login|.git|config).*(bot|curl|python)`

## Commands

### Full pipeline (recommended)

```bash
bash main.sh
```

Extracts IPs from logs, applies deny rules, logs status to `pipeline_status.log`, and creates backup.

### Step by step

Run only log extraction:

```bash
bash logs_reader_access_list.sh
```

Preview planned deny rules without applying them (dry-run):

```bash
bash ngnix.sh --dry-run
```

Apply deny rules without running the reader (uses existing `client_ips.txt`):

```bash
bash ngnix.sh
```

### Testing & local files

Test extraction against a local log file instead of Docker:

```bash
bash logs_reader_access_list.sh ./path/to/my_logs.txt
```

This prints extracted IPs to stdout without modifying `client_ips.txt` unless new IPs are found.

### Rollback & recovery

Restore from latest backup:

```bash
bash rollback_access_list.sh
```

Restore from specific backup by filename:

```bash
bash rollback_access_list.sh access_list_2_20260410_121530.json
```

Or by full path:

```bash
bash rollback_access_list.sh ./access_list_backups/access_list_2_20260410_121530.json
```

## Backups & safety

- **Auto-backup on update**: Every time `ngnix.sh` runs, it saves the full current access list to `access_list_backups/` with timestamp.
- **Safety backup before restore**: When `rollback_access_list.sh` runs, it saves current state before restoring from backup.
- **Backup format**: Plain JSON, human-readable, includes all rules, items, and metadata.
- **Never deleted**: Backups are kept indefinitely; manually clean up old ones or add retention to `.gitignore`.

## Running on schedule (cron)

To automatically extract and update deny rules every hour:

```bash
# Run `crontab -e` and add:
0 * * * * cd /path/to/scripts && bash main.sh >> logs/main.log 2>&1
```

Or every 30 minutes:

```bash
*/30 * * * * cd /path/to/scripts && bash main.sh >> logs/main.log 2>&1
```

## Important notes

- **Git safety**: `.env` is in `.gitignore` — never commit credentials. Use `.env.example` for documentation.
- **IP list grows**: `client_ips.txt` is persistent and never auto-cleaned. Manually review and remove false positives.
- **Script names**: `main.sh` gracefully handles both `nignix.sh` and `ngnix.sh` naming for compatibility.
- **Allow-all rule**: Scripts automatically preserve an `allow all` rule in the access list to prevent lockout.
- **Status log**: `main.sh` writes timestamped events to `pipeline_status.log` for monitoring.
- **Dry-run**: Use `ngnix.sh --dry-run` to preview changes before applying them to your access list.
- **Strict error handling**: All scripts fail on unset variables, pipeline errors (`set -Eeuo pipefail`), and catch API HTTP errors (4xx/5xx) explicitly.

## Troubleshooting

**Missing variable error**
- Verify `.env` exists: `ls -la .env`
- Verify all required variables are set: `grep -E "^[A-Z_]+" .env`

**Empty IP extraction**
- Check container logs manually: `docker exec CONTAINER_NAME tail -f LOG_PATH | grep -iE "FILTER_PATTERN"`
- Try a broader filter: `.*` to match all lines
- Increase `LINES_TO_READ` to scan more history

**API authentication fails**
- Verify credentials are correct in `.env`
- Test manually: `curl -X POST http://NPM_URL/tokens -d '{"identity":"EMAIL", "secret":"PASSWORD"}'`
- Check network/firewall access to NPM server

**Deny rules not appearing in NPM UI**
- Refresh the access list page in browser
- Check for JSON errors: `jq empty access_list_backups/*.json`
- Verify `ACCESS_LIST_ID` matches the list you're editing in NPM

## See also

- [SECURITY.md](SECURITY.md) — credentials management and best practices
- Nginx Proxy Manager docs: https://nginxproxymanager.com
