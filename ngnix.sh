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

IP_FILE="client_ips.txt"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$SCRIPT_DIR/access_list_backups"

TOKEN=$(
  curl -sS -X POST "$NPM_URL/tokens" \
    -H 'Content-Type: application/json' \
    -d "{\"identity\":\"$NPM_EMAIL\",\"secret\":\"$NPM_PASSWORD\"}" \
  | jq -r '.token'
)

CURRENT=$(curl -sS \
  -H "Authorization: Bearer $TOKEN" \
  "$NPM_URL/nginx/access-lists/$ACCESS_LIST_ID?expand=clients,items")

mkdir -p "$BACKUP_DIR"
BACKUP_FILE="$BACKUP_DIR/access_list_${ACCESS_LIST_ID}_$(date '+%Y%m%d_%H%M%S').json"
printf '%s\n' "$CURRENT" | jq . > "$BACKUP_FILE"

CURRENT_DENY_IPS_JSON=$(jq -c '
  (.clients // [])
  | map(select(.directive == "deny") | .address)
' <<< "$CURRENT")

DENY_RULES=$(jq -Rsc --argjson existing "$CURRENT_DENY_IPS_JSON" '
  split("\n")
  | map(select(length > 0))
  | map(select(. as $ip | ($existing | index($ip) | not)))
  | map({directive:"deny", address:.})
' "$IP_FILE")

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
  -d "$PAYLOAD" | jq .

echo "Backup saved to $BACKUP_FILE"