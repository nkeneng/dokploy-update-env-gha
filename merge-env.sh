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

resource_url="${scheme_prefixed_url%/}/api/${read_endpoint}?${id_key}=${resource_id}"
resource_json="$(curl -fsS -X GET "$resource_url" -H "x-api-key: $DOKPLOY_API_KEY")"
if [ -z "$resource_json" ]; then
  echo "Failed to fetch resource config from $resource_url" >&2
  exit 1
fi

current_env="$(printf '%s' "$resource_json" | jq -r 'if type=="object" and has("env") then .env // "" else "" end')"
echo "Fetched existing env:" >&2
printf '%s\n' "$current_env" >&2

merged_lines=()
found="false"

while IFS= read -r line || [ -n "$line" ]; do
  trimmed="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/\r$//')"
  if [ -z "$trimmed" ]; then
    continue
  fi

  key="${trimmed%%=*}"
  if [ "$key" = "$ENV_NAME" ]; then
    merged_lines+=("$ENV_NAME=$ENV_VALUE")
    found="true"
  else
    merged_lines+=("$trimmed")
  fi
done < <(printf '%s' "$current_env")

if [ "$found" = "false" ]; then
  merged_lines+=("$ENV_NAME=$ENV_VALUE")
fi

merged_env="$(printf '%s\n' "${merged_lines[@]}")"

payload="$(jq -n \
  --arg id "$resource_id" \
  --arg env "$merged_env" \
  --arg idKey "$id_key" \
  '$ARGS.named | {env} + {($idKey): $id}')"

update_url="${scheme_prefixed_url%/}/api/${update_endpoint}"
curl -fsS -X POST "$update_url" \
  -H "x-api-key: $DOKPLOY_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$payload" \
  >/dev/null

echo "Merged env var '$ENV_NAME' into Dokploy ${resource_type} ${resource_id}"
