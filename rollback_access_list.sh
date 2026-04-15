#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "ERROR: $(basename "$0") failed at line $LINENO" >&2' ERR

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

# ---------------------------------------------------------------------------
# Validate required variables
# ---------------------------------------------------------------------------
for var in NPM_URL NPM_EMAIL NPM_PASSWORD ACCESS_LIST_ID; do
  if [[ -z "${!var:-}" ]]; then
    echo "Error: Required environment variable $var is not set" >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$SCRIPT_DIR/access_list_backups"

print_usage() {
  echo "Usage: $(basename "$0") [backup_file]"
  echo "If backup_file is omitted, the most recent backup for the access list is restored."
}

# Perform an authenticated API request.  Sets HTTP_CODE and BODY globals.
# Usage: api_request GET|POST|PUT <url> [data_json]
api_request() {
  local method="$1" url="$2" data="${3:-}"
  local response_file
  response_file=$(mktemp)

  local http_code
  local curl_args=(
    -sS -w "%{http_code}"
    -X "$method"
    -H "Content-Type: application/json"
    "$url"
  )
  if [[ -n "${TOKEN:-}" ]]; then
    curl_args+=(-H "Authorization: Bearer $TOKEN")
  fi

  if [[ -n "$data" ]]; then
    curl_args+=(-d "$data")
  fi

  http_code=$(curl "${curl_args[@]}" -o "$response_file" 2>/dev/null) || {
    rm -f "$response_file"
    echo "ERROR: curl request failed to $url" >&2
    return 1
  }

  BODY=$(cat "$response_file")
  rm -f "$response_file"
  HTTP_CODE="$http_code"
}

# ---------------------------------------------------------------------------
# Resolve backup file path
# ---------------------------------------------------------------------------
resolve_backup_file() {
  local requested_file="${1:-}"
  local latest_file

  if [[ ! -d "$BACKUP_DIR" ]]; then
    echo "Backup directory not found: $BACKUP_DIR" >&2
    return 1
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
    return 1
  fi

  latest_file=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name "access_list_${ACCESS_LIST_ID}_*.json" | sort | tail -n 1)

  if [[ -z "$latest_file" ]]; then
    echo "No backup files found for access list $ACCESS_LIST_ID in $BACKUP_DIR" >&2
    return 1
  fi

  printf '%s\n' "$latest_file"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    print_usage
    exit 0
  fi

  local BACKUP_FILE
  BACKUP_FILE=$(resolve_backup_file "${1:-}") || exit 1

  if ! jq empty "$BACKUP_FILE" >/dev/null 2>&1; then
    echo "Backup file is not valid JSON: $BACKUP_FILE" >&2
    exit 1
  fi

  # --- Authenticate ---
  local login_data
  login_data=$(jq -n --arg id "$NPM_EMAIL" --arg secret "$NPM_PASSWORD" \
    '{"identity": $id, "secret": $secret}')

  api_request POST "$NPM_URL/tokens" "$login_data" || {
    echo "ERROR: Failed to obtain authentication token from $NPM_URL" >&2
    exit 1
  }
  if [[ "$HTTP_CODE" -ne 200 ]]; then
    echo "ERROR: Authentication failed (HTTP $HTTP_CODE)" >&2
    exit 1
  fi

  TOKEN=$(echo "$BODY" | jq -r '.token')
  if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
    echo "ERROR: Invalid token received from API" >&2
    exit 1
  fi

  # --- Fetch current access list (for safety backup) ---
  api_request GET "$NPM_URL/nginx/access-lists/$ACCESS_LIST_ID?expand=clients,items"
  if [[ "$HTTP_CODE" -ne 200 ]]; then
    echo "ERROR: Failed to fetch current access list (HTTP $HTTP_CODE)" >&2
    exit 1
  fi
  local CURRENT="$BODY"

  mkdir -p "$BACKUP_DIR"

  local SAFETY_BACKUP_FILE="$BACKUP_DIR/access_list_${ACCESS_LIST_ID}_before_rollback_$(date '+%Y%m%d_%H%M%S').json"
  printf '%s\n' "$CURRENT" | jq . > "$SAFETY_BACKUP_FILE"

  # --- Build restore payload ---
  local PAYLOAD
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

  # --- Apply rollback ---
  api_request PUT "$NPM_URL/nginx/access-lists/$ACCESS_LIST_ID" "$PAYLOAD"
  if [[ "$HTTP_CODE" -ne 200 ]]; then
    echo "ERROR: Failed to restore access list (HTTP $HTTP_CODE)" >&2
    echo "Response: $BODY" >&2
    exit 1
  fi

  echo "$BODY" | jq .

  echo "Restored access list from $BACKUP_FILE"
  echo "Current state backup saved to $SAFETY_BACKUP_FILE"
}

main "$@"
