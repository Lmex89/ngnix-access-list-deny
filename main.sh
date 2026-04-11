#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log_reader_script="$script_dir/logs_reader_access_list.sh"
status_log="$script_dir/pipeline_status.log"

# Support both names in case of typo in existing files.
if [[ -f "$script_dir/nignix.sh" ]]; then
  nginx_script="$script_dir/nignix.sh"
elif [[ -f "$script_dir/ngnix.sh" ]]; then
  nginx_script="$script_dir/ngnix.sh"
else
  echo "Could not find nignix.sh or ngnix.sh in $script_dir" >&2
  exit 1
fi

log_status() {
  local message="$1"
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$message" >> "$status_log"
}

if [[ ! -f "$log_reader_script" ]]; then
  echo "Missing script: $log_reader_script" >&2
  log_status "ERROR: Missing logs_reader_access_list.sh"
  exit 1
fi

log_status "Starting pipeline"

if bash "$log_reader_script"; then
  log_status "SUCCESS: logs_reader_access_list.sh completed"
else
  log_status "ERROR: logs_reader_access_list.sh failed"
  exit 1
fi

if bash "$nginx_script"; then
  log_status "SUCCESS: $(basename "$nginx_script") completed"
else
  log_status "ERROR: $(basename "$nginx_script") failed"
  exit 1
fi

log_status "Pipeline completed successfully"
echo "Pipeline finished successfully. Status saved to $status_log"
