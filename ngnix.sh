#!/usr/bin/env bash
set -euo pipefail

# Ensure essential commands are in PATH for crontab environments
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

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
for var in NPM_URL NPM_EMAIL NPM_PASSWORD ACCESS_LIST_ID; do
  if [[ -z "${!var:-}" ]]; then
    echo "Error: Required environment variable $var is not set" >&2
    exit 1
  fi
done

IP_FILE="client_ips.txt"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$SCRIPT_DIR/access_list_backups"
STATUS_LOG="$SCRIPT_DIR/pipeline_status.log"

log_status() {
  local message="$1"
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$message" >> "$STATUS_LOG"
}

TOKEN=$(
  curl -sS -X POST "$NPM_URL/tokens" \
    -H 'Content-Type: application/json' \
    -d "{\"identity\":\"$NPM_EMAIL\",\"secret\":\"$NPM_PASSWORD\"}" \
  | jq -r '.token'
) || {
  echo "ERROR: Failed to obtain authentication token from $NPM_URL" >&2
  log_status "ERROR: Failed to obtain authentication token from $NPM_URL"
  exit 1
}

if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
  echo "ERROR: Invalid token received from API" >&2
  log_status "ERROR: Invalid token received from API"
  exit 1
fi

CURRENT=$(curl -sS \
  -H "Authorization: Bearer $TOKEN" \
  "$NPM_URL/nginx/access-lists/$ACCESS_LIST_ID?expand=clients,items") || {
  echo "ERROR: Failed to fetch current access list from $NPM_URL" >&2
  log_status "ERROR: Failed to fetch current access list from $NPM_URL"
  exit 1
}

if [[ -z "$CURRENT" || "$CURRENT" == "null" ]]; then
  echo "ERROR: Invalid response from access list API" >&2
  log_status "ERROR: Invalid response from access list API"
  exit 1
fi

mkdir -p "$BACKUP_DIR"
BACKUP_FILE="$BACKUP_DIR/access_list_${ACCESS_LIST_ID}_$(date '+%Y%m%d_%H%M%S').json"
printf '%s\n' "$CURRENT" | jq . > "$BACKUP_FILE"

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

if [[ ! -f "$IP_FILE" ]]; then
  echo "ERROR: IP file not found at $IP_FILE" >&2
  log_status "ERROR: IP file not found at $IP_FILE"
  exit 1
fi

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
  jq_error=$(cat "$DENY_RULES_FILE")
  echo "ERROR: Failed to process deny rules from $IP_FILE" >&2
  echo "DEBUG: CURRENT_DENY_IPS_JSON=$CURRENT_DENY_IPS_JSON" >&2
  echo "DEBUG: jq error: $jq_error" >&2
  log_status "ERROR: Failed to process deny rules from $IP_FILE: $jq_error"
  exit 1
}

DENY_RULES=$(cat "$DENY_RULES_FILE")

NEW_DENY_COUNT=$(jq 'length' <<< "$DENY_RULES") || {
  echo "ERROR: Failed to count new deny rules" >&2
  log_status "ERROR: Failed to count new deny rules"
  exit 1
}

PAYLOAD=$(jq -n \
  --argjson c "$CURRENT" \
  --argjson d "$DENY_RULES" '
{
  name: $c.name,
  satisfy_any: $c.satisfy_any,
  pass_auth: $c.pass_auth,
  items: (($c.items // []) | map({
    username: .username,
    password: ""       # keep existing password in NPM
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

curl -sS -X PUT \
  "$NPM_URL/nginx/access-lists/$ACCESS_LIST_ID" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" | jq . || {
  echo "ERROR: Failed to update access list at $NPM_URL" >&2
  log_status "ERROR: Failed to update access list at $NPM_URL"
  exit 1
}

if [[ "$NEW_DENY_COUNT" -eq 0 ]]; then
  log_status "INFO: No IPs were updated in access list $ACCESS_LIST_ID"
  echo "No IPs were updated in access list $ACCESS_LIST_ID"
else
  log_status "INFO: Updated $NEW_DENY_COUNT IP(s) in access list $ACCESS_LIST_ID"
  echo "Updated $NEW_DENY_COUNT IP(s) in access list $ACCESS_LIST_ID"
fi

echo "Backup saved to $BACKUP_FILE"