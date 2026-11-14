# AGENTS.md

Bash cron pipeline: scrape suspicious client IPs from Docker proxy logs, then push
`deny` rules into a **live** Nginx Proxy Manager (NPM) access list. Four shell scripts,
no build system, no tests, no CI.

## This touches a live system

- `ngnix.sh` and `main.sh` mutate a real NPM access list over the network. There is no
  staging environment and no test suite — treat any edit to `ngnix.sh` as production.
- `--dry-run` is not side-effect free: it still authenticates, `GET`s the list, and writes
  a backup file. It only skips the final `PUT`.
- `client_ips.txt` **is** the state. Every line in it becomes a `deny` rule on the next
  `ngnix.sh` run. Add IPs there deliberately, never in bulk.
- Removing a false positive = delete the line from `client_ips.txt`, then remove the rule
  in the NPM UI. The scripts only ever add denies; they never revoke them.
- `client_ips.txt` is tracked in git even though `.gitignore` lists it (`gitignore` does not
  affect tracked files). Expect it to show up as modified after every pipeline run.

## Commands

| Action | Command |
|--------|---------|
| Full pipeline (scrape + apply) | `bash main.sh` |
| Scrape IPs only | `bash logs_reader_access_list.sh` |
| Scrape from a local file (no Docker) | `bash logs_reader_access_list.sh ./fixture.log` |
| Preview pending denies | `bash ngnix.sh --dry-run` |
| Apply denies from existing `client_ips.txt` | `bash ngnix.sh` |
| Roll back latest backup | `bash rollback_access_list.sh` |
| Roll back a specific backup | `bash rollback_access_list.sh access_list_2_YYYYMMDD_HHMMSS.json` |

Verification (no CI exists, `shellcheck` is **not** installed):

```bash
bash -n main.sh ngnix.sh rollback_access_list.sh logs_reader_access_list.sh
```

To exercise scraping without Docker or NPM, point the reader at a fixture containing lines
like `[Client 203.0.113.9]`. It appends only IPs not already in `client_ips.txt` — use a
temp copy of the repo if you must not pollute it.

## How the pieces fit

- `main.sh` → `logs_reader_access_list.sh`, then `ngnix.sh`. Both child failures abort the
  pipeline and are recorded in `pipeline_status.log`.
- Reader: `docker exec … grep -iE "$FILTER_PATTERN" "$DOCKER_CONTAINER_LOG" | tail -n "$LINES_TO_READ"`
  → overwrites `logs.txt` → extracts `[Client <ipv4>]` → validates octets → appends new IPs.
  `LINES_TO_READ` counts matching lines, not raw log lines.
- Applier: auth `POST /tokens` → `GET access-lists/{id}?expand=clients,items` → JSON backup →
  diff against existing `deny` entries → `PUT`. The payload rebuilds `items` with blanked
  passwords (the API never returns them) and always re-adds `allow all`; it dedupes clients
  by `directive|address`. Dropping either behavior can lock you out or wipe basic-auth users.
  It also pins `PATH` to standard system dirs at the top, which is what makes it cron-safe.
- Each script resolves its own `SCRIPT_DIR`, so cwd never matters, and each loads `.env`
  from the repo root with a hand-rolled `load_env_file` loop — **not** `source`. So no shell
  expansion in `.env` values. Adding a new required variable means adding it to the
  per-script validation `for var in …` loop too.
  - Reader requires: `DOCKER_CONTAINER_NAME`, `DOCKER_CONTAINER_LOG`, `FILTER_PATTERN`, `LINES_TO_READ`
  - `ngnix.sh` / rollback require: `NPM_URL`, `NPM_EMAIL`, `NPM_PASSWORD`, `ACCESS_LIST_ID`

## Do not read or glob these

Runtime artifacts, gitignored, huge:

- `pipeline_cron.log` — ~854 MB. Never `cat`/`grep` it. `tail -n 50` at most.
- `pipeline_status.log` — multi-MB; `tail -n 20` is enough.
- `access_list_backups/` — ~11,000 files. Never `ls`/glob it; list with a narrow
  `access_list_${ACCESS_LIST_ID}_*.json` pattern or `find … | sort | tail -1`.
- `logs.txt` — overwritten on every no-arg reader run; don't edit it by hand.
- `.agents/` and `skills-lock.json` — untracked third-party skill installs, unrelated to the
  automation.

## Naming quirk

`ngnix.sh` (misspelled) is the real, canonical filename. `main.sh` probes for `nignix.sh`
first, then `ngnix.sh`, so both work — don't "fix" the typo without updating `main.sh`.

## Codegraph

This repo has a `.codegraph/` index. The only tool exposed in this session is
`codegraph_explore`; the older `codegraph_search_semantic` / `codegraph_find_symbol` names no
longer exist. With four ~150-line shell scripts, plain `Read` is usually faster.

## See also

`README.md` documents every env var and cron setup. `CHECKLIST.md` lists planned hardening
(deny-count guard, shellcheck CI, fixture tests) that does not exist yet — don't assume it.
