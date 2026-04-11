#!/usr/bin/env bash

set -euo pipefail

container_name="lmex89-nginix-proxy-mananger-app-1"
container_log="/data/logs/proxy-host-9_access.log"
filter_pattern='bot|crawl|wp|env|.git|config.js|aws|docker'
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
output_file="$script_dir/logs.txt"
ip_file="$script_dir/client_ips.txt"
lines_to_read="200"

print_usage() {
  echo "Usage: $(basename "$0") [log_file]"
  echo "Without a file, the script refreshes logs.txt from Docker, prints unique client IPs, and appends new ones to client_ips.txt."
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  print_usage
  exit 0
fi

if [[ $# -gt 0 ]]; then
  input_file="$1"
else
  if ! docker exec "$container_name" grep -iE "$filter_pattern" "$container_log" | tail -n "$lines_to_read" > "$output_file"; then
    echo "Failed to read logs from container: $container_name" >&2
    exit 1
  fi

  input_file="$output_file"
fi

if [[ ! -f "$input_file" ]]; then
  echo "Log file not found: $input_file" >&2
  exit 1
fi

if [[ ! -f "$ip_file" ]]; then
  touch "$ip_file"
fi

mapfile -t extracted_ips < <(
  grep -oE '\[Client [0-9]{1,3}(\.[0-9]{1,3}){3}\]' "$input_file" \
    | sed -E 's/^\[Client (.*)\]$/\1/' \
    | sort -u
)

for ip in "${extracted_ips[@]}"; do
  if ! grep -Fxq -- "$ip" "$ip_file"; then
    echo "$ip" >> "$ip_file"
  fi
done

printf '%s\n' "${extracted_ips[@]}"
