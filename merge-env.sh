#!/usr/bin/env bash
set -euo pipefail

required_vars=(
  DOKPLOY_URL
  DOKPLOY_API_KEY
  DOKPLOY_RESOURCE_TYPE
  DOKPLOY_RESOURCE_ID
  ENV_NAME
  ENV_VALUE
)

for var in "${required_vars[@]}"; do
  if [ -z "${!var:-}" ]; then
    echo "Missing required env: $var" >&2
    exit 1
  fi
done

scheme_prefixed_url="$DOKPLOY_URL"
if ! printf '%s' "$scheme_prefixed_url" | grep -qE '^https?://'; then
  scheme_prefixed_url="https://$scheme_prefixed_url"
fi

resource_type="$(printf '%s' "$DOKPLOY_RESOURCE_TYPE" | tr '[:upper:]' '[:lower:]')"
resource_id="$DOKPLOY_RESOURCE_ID"
id_key=""
read_endpoint=""
update_endpoint=""

case "$resource_type" in
  project)
    id_key="projectId"
    read_endpoint="project.one"
    update_endpoint="project.update"
    ;;
  compose)
    id_key="composeId"
    read_endpoint="compose.one"
    update_endpoint="compose.update"
    ;;
  application)
    id_key="applicationId"
    read_endpoint="application.one"
    update_endpoint="application.update"
    ;;
  mysql)
    id_key="mysqlId"
    read_endpoint="mysql.one"
    update_endpoint="mysql.update"
    ;;
  postgres)
    id_key="postgresId"
    read_endpoint="postgres.one"
    update_endpoint="postgres.update"
    ;;
  redis)
    id_key="redisId"
    read_endpoint="redis.one"
    update_endpoint="redis.update"
    ;;
  mongo)
    id_key="mongoId"
    read_endpoint="mongo.one"
    update_endpoint="mongo.update"
    ;;
  mariadb)
    id_key="mariadbId"
    read_endpoint="mariadb.one"
    update_endpoint="mariadb.update"
    ;;
  *)
    echo "Unsupported resource type: $DOKPLOY_RESOURCE_TYPE" >&2
    exit 1
    ;;
esac

# Never print the env, ENV_VALUE, the API key or the URL (it may embed basic
# auth). Messages name only the resource type, id and endpoint path.
api_base="${scheme_prefixed_url%/}/api"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
resource_file="$workdir/resource.json"
payload_file="$workdir/payload.json"
response_file="$workdir/response.json"
curl_err_file="$workdir/curl.err"

# dokploy_curl <endpoint> <output-file> [curl args...]
# Runs curl without letting its stderr (which can include the host) reach the log.
dokploy_curl() {
  local endpoint="$1" out="$2"
  shift 2
  local status=0 http_code
  http_code="$(curl -fsS --connect-timeout 10 --max-time 30 \
    -o "$out" -w '%{http_code}' "$@" 2>"$curl_err_file")" || status=$?
  if [ "$status" -ne 0 ]; then
    echo "Dokploy request ${endpoint} failed for ${resource_type} ${resource_id} (curl exit ${status}, HTTP ${http_code:-000})" >&2
    return 1
  fi
}

dokploy_curl "$read_endpoint" "$resource_file" \
  -X GET "${api_base}/${read_endpoint}?${id_key}=${resource_id}" \
  -H "x-api-key: $DOKPLOY_API_KEY"

if ! jq -e 'type == "object" and has("env")' "$resource_file" >/dev/null 2>&1; then
  echo "Unexpected response from ${read_endpoint} for ${resource_type} ${resource_id}: no env field" >&2
  exit 1
fi

hits="$(jq --arg p "$ENV_NAME=" \
  '[(.env // "") | split("\n")[] | select(startswith($p))] | length' "$resource_file")"
if [ "$hits" -gt 1 ]; then
  echo "duplicate key '${ENV_NAME}' in env of Dokploy ${resource_type} ${resource_id}; refusing to update" >&2
  exit 1
fi

# Line edit on the JSON string itself: split on \n, replace the line that
# starts with "NAME=", else append. Every other byte is left untouched.
jq --arg name "$ENV_NAME" --arg value "$ENV_VALUE" \
  --arg id "$resource_id" --arg idKey "$id_key" '
  (.env // "") as $env
  | ($name + "=") as $prefix
  | if any($env | split("\n")[]; startswith($prefix)) then
      $env | split("\n") | map(if startswith($prefix) then $prefix + $value else . end) | join("\n")
    elif $env == "" then $prefix + $value
    elif ($env | endswith("\n")) then $env + $prefix + $value + "\n"
    else $env + "\n" + $prefix + $value
    end
  | {env: .} + {($idKey): $id}
' "$resource_file" >"$payload_file"

dokploy_curl "$update_endpoint" "$response_file" \
  -X POST "${api_base}/${update_endpoint}" \
  -H "x-api-key: $DOKPLOY_API_KEY" \
  -H "Content-Type: application/json" \
  --data-binary "@${payload_file}"

echo "Merged env var '$ENV_NAME' into Dokploy ${resource_type} ${resource_id}"
