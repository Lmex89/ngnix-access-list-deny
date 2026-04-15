#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "ERROR: $(basename "$0") failed at line $LINENO" >&2' ERR

# Ensure essential commands are in PATH for crontab environments
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

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
IP_FILE="$SCRIPT_DIR/client_ips.txt"
BACKUP_DIR="$SCRIPT_DIR/access_list_backups"
STATUS_LOG="$SCRIPT_DIR/pipeline_status.log"

log_status() {
  local message="$1"
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$message" >> "$STATUS_LOG"
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
# Main
# ---------------------------------------------------------------------------
main() {
  local dry_run=false
  if [[ "${1:-}" == "--dry-run" ]]; then
    dry_run=true
  elif [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo "Usage: $(basename "$0") [--dry-run]"
    echo "  --dry-run   Show planned deny rules without applying them."
    exit 0
  fi

  # --- Authenticate ---
  local login_data
  login_data=$(jq -n --arg id "$NPM_EMAIL" --arg secret "$NPM_PASSWORD" \
    '{"identity": $id, "secret": $secret}')

  api_request POST "$NPM_URL/tokens" "$login_data" || {
    echo "ERROR: Failed to obtain authentication token from $NPM_URL" >&2
    log_status "ERROR: Failed to obtain authentication token from $NPM_URL"
    exit 1
  }
  if [[ "$HTTP_CODE" -ne 200 ]]; then
    echo "ERROR: Authentication failed (HTTP $HTTP_CODE)" >&2
    log_status "ERROR: Authentication failed (HTTP $HTTP_CODE)"
    exit 1
  fi

  TOKEN=$(echo "$BODY" | jq -r '.token')
  if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
    echo "ERROR: Invalid token received from API" >&2
    log_status "ERROR: Invalid token received from API"
    exit 1
  fi

  # --- Fetch current access list ---
  api_request GET "$NPM_URL/nginx/access-lists/$ACCESS_LIST_ID?expand=clients,items"
  if [[ "$HTTP_CODE" -ne 200 ]]; then
    echo "ERROR: Failed to fetch access list (HTTP $HTTP_CODE)" >&2
    log_status "ERROR: Failed to fetch access list (HTTP $HTTP_CODE)"
    exit 1
  fi
  CURRENT="$BODY"

  if [[ -z "$CURRENT" || "$CURRENT" == "null" ]]; then
    echo "ERROR: Invalid response from access list API" >&2
    log_status "ERROR: Invalid response from access list API"
    exit 1
  fi

  # --- Backup current state ---
  mkdir -p "$BACKUP_DIR"
  local BACKUP_FILE="$BACKUP_DIR/access_list_${ACCESS_LIST_ID}_$(date '+%Y%m%d_%H%M%S').json"
  printf '%s\n' "$CURRENT" | jq . > "$BACKUP_FILE"

  # --- Extract currently denied IPs ---
  local CURRENT_DENY_IPS_JSON
  CURRENT_DENY_IPS_JSON=$(jq -c '
    (.clients // [])
    | map(select(.directive == "deny") | .address)
  ' <<< "$CURRENT") || {
    echo "ERROR: Failed to extract current deny IPs from API response" >&2
    echo "DEBUG: API Response: $(echo "$CURRENT" | head -c 500)" >&2
    log_status "ERROR: Failed to extract current deny IPs from API response"
    exit 1
  }

  # Validate that CURRENT_DENY_IPS_JSON is valid JSON
  if ! jq . <<< "$CURRENT_DENY_IPS_JSON" > /dev/null 2>&1; then
    echo "ERROR: Extracted deny IPs are not valid JSON" >&2
    echo "DEBUG: CURRENT_DENY_IPS_JSON=$CURRENT_DENY_IPS_JSON" >&2
    log_status "ERROR: Extracted deny IPs are not valid JSON"
    exit 1
  fi

  # --- Read client_ips.txt ---
  if [[ ! -f "$IP_FILE" ]]; then
    echo "ERROR: IP file not found at $IP_FILE" >&2
    log_status "ERROR: IP file not found at $IP_FILE"
    exit 1
  fi

  local DENY_RULES_FILE
  DENY_RULES_FILE=$(mktemp) || {
    echo "ERROR: Failed to create temporary file" >&2
    log_status "ERROR: Failed to create temporary file"
    exit 1
  }
  trap "rm -f '$DENY_RULES_FILE'" EXIT

  jq -Rsc --argjson existing "$CURRENT_DENY_IPS_JSON" '
    split("\n")
    | map(select(length > 0))
    | map(select(. as $ip | ($existing | index($ip) | not)))
    | map({directive:"deny", address:.})
  ' "$IP_FILE" > "$DENY_RULES_FILE" 2>&1 || {
    local jq_error
    jq_error=$(cat "$DENY_RULES_FILE")
    echo "ERROR: Failed to process deny rules from $IP_FILE" >&2
    echo "DEBUG: CURRENT_DENY_IPS_JSON=$CURRENT_DENY_IPS_JSON" >&2
    echo "DEBUG: jq error: $jq_error" >&2
    log_status "ERROR: Failed to process deny rules from $IP_FILE: $jq_error"
    exit 1
  }

  local DENY_RULES
  DENY_RULES=$(cat "$DENY_RULES_FILE")

  local NEW_DENY_COUNT
  NEW_DENY_COUNT=$(jq 'length' <<< "$DENY_RULES") || {
    echo "ERROR: Failed to count new deny rules" >&2
    log_status "ERROR: Failed to count new deny rules"
    exit 1
  }

  # --- Dry-run: show what would change and stop ---
  if $dry_run; then
    echo "=== DRY RUN — no changes will be applied ===" >&2
    echo "New deny rules to add: $NEW_DENY_COUNT" >&2
    if [[ "$NEW_DENY_COUNT" -gt 0 ]]; then
      echo "" >&2
      echo "IPs:" >&2
      jq -r '.[].address' <<< "$DENY_RULES" | sed 's/^/  /' >&2
    fi
    echo "=== END DRY RUN ===" >&2
    log_status "DRY-RUN: $NEW_DENY_COUNT new deny rule(s) would be added"
    exit 0
  fi

  # --- Build payload ---
  local PAYLOAD
  PAYLOAD=$(jq -n \
    --argjson c "$CURRENT" \
    --argjson d "$DENY_RULES" '
  {
    name: $c.name,
    satisfy_any: $c.satisfy_any,
    pass_auth: $c.pass_auth,
    items: (($c.items // []) | map({
      username: .username,
      password: ""
    })),
    clients: (
      (($c.clients // []) | map({directive: .directive, address: .address}))
      + $d
      | unique_by(.directive + "|" + .address)
    )
  }
  | if any(.clients[]; .directive == "allow" and .address == "all")
    then .
    else .clients += [{directive:"allow", address:"all"}]
    end
  ')

  # --- Apply update ---
  api_request PUT "$NPM_URL/nginx/access-lists/$ACCESS_LIST_ID" "$PAYLOAD"
  if [[ "$HTTP_CODE" -ne 200 ]]; then
    echo "ERROR: Failed to update access list (HTTP $HTTP_CODE)" >&2
    echo "Response: $BODY" >&2
    log_status "ERROR: Failed to update access list (HTTP $HTTP_CODE)"
    exit 1
  fi

  echo "$BODY" | jq .

  if [[ "$NEW_DENY_COUNT" -eq 0 ]]; then
    log_status "INFO: No IPs were updated in access list $ACCESS_LIST_ID"
    echo "No IPs were updated in access list $ACCESS_LIST_ID"
  else
    log_status "INFO: Updated $NEW_DENY_COUNT IP(s) in access list $ACCESS_LIST_ID"
    echo "Updated $NEW_DENY_COUNT IP(s) in access list $ACCESS_LIST_ID"
  fi

  echo "Backup saved to $BACKUP_FILE"
}

main "$@"
