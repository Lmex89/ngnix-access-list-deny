#!/usr/bin/env bash
set -euo pipefail

# Load environment variables from .env file
ENV_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "Error: .env file not found at $ENV_FILE" >&2
  echo "Please copy .env.example to .env and fill in the values" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$ENV_FILE"

# Validate required variables
for var in NPM_URL NPM_EMAIL NPM_PASSWORD ACCESS_LIST_ID; do
  if [[ -z "${!var:-}" ]]; then
    echo "Error: Required environment variable $var is not set" >&2
    exit 1
  fi
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$SCRIPT_DIR/access_list_backups"

print_usage() {
  echo "Usage: $(basename "$0") [backup_file]"
  echo "If backup_file is omitted, the most recent backup for the access list is restored."
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  print_usage
  exit 0
fi

resolve_backup_file() {
  local requested_file="${1:-}"
  local latest_file

  if [[ ! -d "$BACKUP_DIR" ]]; then
    echo "Backup directory not found: $BACKUP_DIR" >&2
    exit 1
  fi

  if [[ -n "$requested_file" ]]; then
    if [[ -f "$requested_file" ]]; then
      printf '%s\n' "$requested_file"
      return 0
    fi

    if [[ -f "$BACKUP_DIR/$requested_file" ]]; then
      printf '%s\n' "$BACKUP_DIR/$requested_file"
      return 0
    fi

    echo "Backup file not found: $requested_file" >&2
    exit 1
  fi

  latest_file=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name "access_list_${ACCESS_LIST_ID}_*.json" | sort | tail -n 1)

  if [[ -z "$latest_file" ]]; then
    echo "No backup files found for access list $ACCESS_LIST_ID in $BACKUP_DIR" >&2
    exit 1
  fi

  printf '%s\n' "$latest_file"
}

BACKUP_FILE=$(resolve_backup_file "${1:-}")

if ! jq empty "$BACKUP_FILE" >/dev/null 2>&1; then
  echo "Backup file is not valid JSON: $BACKUP_FILE" >&2
  exit 1
fi

TOKEN=$(
  curl -sS -X POST "$NPM_URL/tokens" \
    -H 'Content-Type: application/json' \
    -d "{\"identity\":\"$NPM_EMAIL\",\"secret\":\"$NPM_PASSWORD\"}" \
  | jq -r '.token'
)

if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
  echo "Failed to obtain API token" >&2
  exit 1
fi

mkdir -p "$BACKUP_DIR"

CURRENT=$(curl -sS \
  -H "Authorization: Bearer $TOKEN" \
  "$NPM_URL/nginx/access-lists/$ACCESS_LIST_ID?expand=clients,items")

SAFETY_BACKUP_FILE="$BACKUP_DIR/access_list_${ACCESS_LIST_ID}_before_rollback_$(date '+%Y%m%d_%H%M%S').json"
printf '%s\n' "$CURRENT" | jq . > "$SAFETY_BACKUP_FILE"

PAYLOAD=$(jq '
{
  name: .name,
  satisfy_any: .satisfy_any,
  pass_auth: .pass_auth,
  items: ((.items // []) | map({
    username: .username,
    password: ""
  })),
  clients: ((.clients // []) | map({
    directive: .directive,
    address: .address
  }))
}
| if any(.clients[]?; .directive == "allow" and .address == "all")
  then .
  else .clients += [{directive:"allow", address:"all"}]
  end
' "$BACKUP_FILE")

curl -sS -X PUT \
  "$NPM_URL/nginx/access-lists/$ACCESS_LIST_ID" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" | jq .

echo "Restored access list from $BACKUP_FILE"
echo "Current state backup saved to $SAFETY_BACKUP_FILE"