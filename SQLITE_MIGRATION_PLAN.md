# SQLite Migration Plan

## Goal
Replace `client_ips.txt` with a SQLite database that stores IPs plus metadata (reason and original log line), and validates existence efficiently.

## Scope
- Replace read/write operations to `client_ips.txt` with SQLite queries.
- Store `reason` and `original_log_line` for each IP.
- Keep the existing NPM update flow intact.

## Database Design
- File: `blocked_ips.db` (repo root)
- Schema:
  ```sql
  CREATE TABLE IF NOT EXISTS blocked_ips (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ip TEXT NOT NULL,
    reason TEXT,
    original_log_line TEXT,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
  );

  CREATE UNIQUE INDEX IF NOT EXISTS idx_blocked_ips_ip ON blocked_ips (ip);
  ```

## Implementation Plan

### 1. Preparation
- Create `schema.sql` containing the `CREATE TABLE` and `CREATE INDEX` statements.
- Add a new env var `SQLITE_DB_PATH` (default to `./blocked_ips.db`).
- Decide how to derive `reason` from `FILTER_PATTERN` (match groups or fixed label).

### 2. Data Migration
- Create `migrate.sh` to:
  - Initialize the database using `schema.sql`.
  - Read existing `client_ips.txt`.
  - Insert entries into the SQLite DB:
    - `ip`: Extracted IP.
    - `reason`: 'legacy_import'.
    - `original_log_line`: 'N/A'.
  - Use `INSERT OR IGNORE` to handle duplicate IPs present in the text file.

### 3. Script Refactoring
- **Update `logs_reader_access_list.sh`**:
  - Capture the full log line and extracted IP (do not discard the line after grep).
  - Determine `reason` based on the `FILTER_PATTERN` match.
  - Use `sqlite3` to insert new records:
    ```sql
    INSERT OR IGNORE INTO blocked_ips (ip, reason, original_log_line)
    VALUES ('$ip', '$reason', '$log_line');
    ```
  - Replace the `client_ips.txt` append logic with DB writes.
- **Update `ngnix.sh`**:
  - Replace the text file read (`cat client_ips.txt`) with:
    ```bash
    sqlite3 "$SQLITE_DB_PATH" "SELECT ip FROM blocked_ips"
    ```

### 4. Validation
- Run `logs_reader_access_list.sh` against a sample log file to verify:
  - Table population.
  - Correct metadata (reason, log line) capture.
  - Duplicate IPs are ignored.
- Confirm `ngnix.sh` successfully fetches the full list of IPs to be denied.
- Confirm the access list update behavior is unchanged.

### 5. Cleanup & Cutover
- Archive `client_ips.txt` and remove it from the active workflow.
- Update README to reflect SQLite usage and new env var.

## Best Practices and Guardrails
- **Failure handling**: make API calls fail on HTTP errors (`curl -f`) and check status before `jq`.
- **Logging**: include database path and insert counts in `pipeline_status.log`.
- **Idempotency**: rely on the unique index and `INSERT OR IGNORE` for safe reruns.
- **Backups**: include `blocked_ips.db` in `access_list_backups/` or a new `db_backups/`.
- **Security**: keep credentials in `.env` only; do not log tokens or raw secrets.
- **Input hygiene**: validate IP format before insert to avoid corrupt data.

## TODOs
- [ ] Add `schema.sql` and `migrate.sh`.
- [ ] Add `SQLITE_DB_PATH` to `.env.example` and docs.
- [ ] Refactor `logs_reader_access_list.sh` to store IPs in SQLite with metadata.
- [ ] Refactor `ngnix.sh` to read IPs from SQLite.
- [ ] Add a one-time migration step to convert `client_ips.txt`.
- [ ] Update README with the new flow and dependency (`sqlite3`).
- [ ] Add `blocked_ips.db` to `.gitignore`.
- [ ] Add basic validation tests using a sample log file.

## Rollback Strategy
- Before starting, make a backup of `client_ips.txt`.
- If migration fails, delete `blocked_ips.db` and revert to the backup `client_ips.txt`.
- Once cutover is complete, include the DB file in future backups.
