# Project Improvement Checklist

## Safety and Reliability
- [x] Add a dry-run mode so rules can be reviewed before applying.
- [ ] Add a guard threshold to prevent mass-blocking from bad filters.
- [x] Validate extracted IPs more strictly before writing to `client_ips.txt`.
- [x] Make API calls fail on HTTP errors and check status codes before parsing JSON.

## CI and Verification
- [ ] Add a CI workflow to run `shellcheck` on all `*.sh` files.
- [ ] Add `bash -n` syntax checks for all scripts.
- [ ] Add fixture-based tests for `logs_reader_access_list.sh` using sample logs.
- [ ] Add mocked API tests for `ngnix.sh` update payloads.
- [ ] Add rollback tests for `rollback_access_list.sh`.

## Code Structure
- [ ] Centralize `.env` loading so all scripts use the same loader.
- [ ] Refactor longer scripts to use a `main` function and small helpers.
- [ ] Reduce duplicated logic across scripts (logging, error handling, env validation).

## Project Hygiene
- [ ] Document runtime assumptions: container name, log path, NPM URL, and cron usage.
- [ ] Separate generated artifacts clearly (`logs.txt`, `pipeline_status.log`, `client_ips.txt`).
- [ ] Clarify rollback procedure and backup retention policy.
