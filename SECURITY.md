# Security Configuration Guide

## Changes Made

All sensitive data has been removed from the scripts and externalized to environment variables. The following scripts have been updated:

- `logs_reader_access_list.sh` - Now reads Docker and filter configuration from `.env`
- `ngnix.sh` - Now reads NPM API credentials and configuration from `.env`
- `rollback_access_list.sh` - Now reads NPM API credentials and configuration from `.env`

## Environment Files

### `.env` (KEEP PRIVATE)
Contains actual sensitive values:
- NPM API URL, email, and password
- Docker container name and log path
- Filter patterns and configuration

⚠️ **IMPORTANT**: This file is already in `.gitignore` and should NEVER be committed to version control.

### `.env.example` (SAFE TO COMMIT)
Template showing what environment variables are needed with placeholder values.
Share this with other developers so they know what to configure.

## Setup Instructions

1. **First-time setup**:
   ```bash
   cp .env.example .env
   ```

2. **Update `.env` with actual values**:
   ```bash
   # Edit .env and fill in your actual values
   nano .env
   ```

3. **Run scripts as normal**:
   ```bash
   bash logs_reader_access_list.sh
   bash ngnix.sh
   bash pipeline.sh
   ```

## Security Features

✅ Automatic validation - Scripts will fail if required environment variables are missing
✅ Clear error messages - Users are guided to set up `.env` if it's missing
✅ Git protection - `.env` is in `.gitignore` to prevent accidental commits

## Environment Variables Reference

| Variable | Purpose | Example |
|----------|---------|---------|
| `NPM_URL` | Nginx Proxy Manager API endpoint | `http://127.0.0.1:81/api` |
| `NPM_EMAIL` | NPM admin email | `admin@example.com` |
| `NPM_PASSWORD` | NPM admin password | `secure-password` |
| `ACCESS_LIST_ID` | Access list ID in NPM | `2` |
| `DOCKER_CONTAINER_NAME` | Docker container running Nginx | `lmex89-nginix-proxy-manager-app-1` |
| `DOCKER_CONTAINER_LOG` | Path to container access logs | `/data/logs/proxy-host-9_access.log` |
| `FILTER_PATTERN` | Grep pattern for log filtering | `bot\|crawl\|wp\|env` |
| `LINES_TO_READ` | Number of recent log lines to process | `200` |

## Best Practices

1. Never commit `.env` to version control
2. Use `.env.example` as documentation for required variables
3. For production, consider using secrets management tools (e.g., HashiCorp Vault, AWS Secrets Manager)
4. Rotate credentials periodically
5. Keep backups directory (`access_list_backups/`) in `.gitignore` as it may contain sensitive data

