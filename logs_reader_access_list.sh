#!/usr/bin/env bash

set -euo pipefail

# Load environment variables from .env file
ENV_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "Error: .env file not found at $ENV_FILE" >&2
  echo "Please copy .env.example to .env and fill in the values" >&2
  exit 1
fi

load_env_file() {
  local env_file="$1"
  local line key value

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"

    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

    if [[ ! "$line" =~ ^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*= ]]; then
      continue
    fi

    key="${line%%=*}"
    value="${line#*=}"

    key="${key#${key%%[![:space:]]*}}"
    key="${key%${key##*[![:space:]]}}"
    value="${value#${value%%[![:space:]]*}}"
    value="${value%${value##*[![:space:]]}}"

    if [[ "$value" =~ ^\".*\"$ || "$value" =~ ^\'.*\'$ ]]; then
      value="${value:1:${#value}-2}"
    fi

    export "$key=$value"
  done < "$env_file"
}

load_env_file "$ENV_FILE"

# Validate required variables
for var in DOCKER_CONTAINER_NAME DOCKER_CONTAINER_LOG FILTER_PATTERN LINES_TO_READ; do
  if [[ -z "${!var:-}" ]]; then
    echo "Error: Required environment variable $var is not set" >&2
    exit 1
  fi
done

container_name="${DOCKER_CONTAINER_NAME}"
container_log="${DOCKER_CONTAINER_LOG}"
filter_pattern="${FILTER_PATTERN}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
output_file="$script_dir/logs.txt"
ip_file="$script_dir/client_ips.txt"
lines_to_read="${LINES_TO_READ}"

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
