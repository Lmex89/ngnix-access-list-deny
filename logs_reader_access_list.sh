#!/usr/bin/env bash

set -Eeuo pipefail
trap 'echo "ERROR: $(basename "$0") failed at line $LINENO" >&2' ERR

# ---------------------------------------------------------------------------
# Load environment variables from .env file
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Validate required variables
# ---------------------------------------------------------------------------
for var in DOCKER_CONTAINER_NAME DOCKER_CONTAINER_LOG FILTER_PATTERN LINES_TO_READ; do
  if [[ -z "${!var:-}" ]]; then
    echo "Error: Required environment variable $var is not set" >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------
check_dependencies() {
  local deps=("grep" "sed" "sort" "tail")
  if [[ $# -eq 0 ]]; then
    deps+=("docker")
  fi
  for cmd in "${deps[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Error: Missing required command: $cmd" >&2; exit 1; }
  done
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
output_file="$script_dir/logs.txt"
ip_file="$script_dir/client_ips.txt"

print_usage() {
  echo "Usage: $(basename "$0") [log_file]"
  echo "Without a file, the script refreshes logs.txt from Docker, prints unique client IPs, and appends new ones to client_ips.txt."
}

# Validate that a string is a well-formed IPv4 address (basic octet range check).
validate_ipv4() {
  local ip="$1"
  if [[ ! "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    return 1
  fi
  local IFS='.'
  # shellcheck disable=SC2206
  local octets=($ip)
  for octet in "${octets[@]}"; do
    if (( octet > 255 )); then
      return 1
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  check_dependencies "$@"

  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    print_usage
    exit 0
  fi

  local input_file

  if [[ $# -gt 0 ]]; then
    input_file="$1"
  else
    if ! docker exec "${DOCKER_CONTAINER_NAME}" grep -iE "${FILTER_PATTERN}" "${DOCKER_CONTAINER_LOG}" | tail -n "${LINES_TO_READ}" > "$output_file"; then
      echo "Failed to read logs from container: ${DOCKER_CONTAINER_NAME}" >&2
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

  mapfile -t raw_ips < <(
    grep -oE '\[Client [0-9]{1,3}(\.[0-9]{1,3}){3}\]' "$input_file" \
      | sed -E 's/^\[Client (.*)\]$/\1/' \
      | sort -u
  )

  # Sanitize: reject any value that is not a valid IPv4 address.
  local extracted_ips=()
  for ip in "${raw_ips[@]}"; do
    if validate_ipv4 "$ip"; then
      extracted_ips+=("$ip")
    else
      echo "Warning: Skipping malformed IP: $ip" >&2
    fi
  done

  if [[ ${#extracted_ips[@]} -eq 0 ]]; then
    echo "No valid client IPs found." >&2
    exit 0
  fi

  for ip in "${extracted_ips[@]}"; do
    if ! grep -Fxq -- "$ip" "$ip_file"; then
      echo "$ip" >> "$ip_file"
    fi
  done

  printf '%s\n' "${extracted_ips[@]}"
}

main "$@"
