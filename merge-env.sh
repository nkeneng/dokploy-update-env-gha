#!/usr/bin/env bash
set -euo pipefail

required_vars=(
  DOKPLOY_URL
  DOKPLOY_API_KEY
  DOKPLOY_PROJECT_ID
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

project_url="${scheme_prefixed_url%/}/api/project.one?projectId=${DOKPLOY_PROJECT_ID}"
project_json="$(curl -fsS -X GET "$project_url" -H "x-api-key: $DOKPLOY_API_KEY")"
if [ -z "$project_json" ]; then
  echo "Failed to fetch project config from $project_url" >&2
  exit 1
fi

current_env="$(printf '%s' "$project_json" | jq -r 'if type=="object" and has("env") then .env // "" else "" end')"
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
  --arg projectId "$DOKPLOY_PROJECT_ID" \
  --arg env "$merged_env" \
  '{projectId: $projectId, env: $env}')"

update_url="${scheme_prefixed_url%/}/api/project.update"
curl -fsS -X POST "$update_url" \
  -H "x-api-key: $DOKPLOY_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$payload" \
  >/dev/null

echo "Merged env var '$ENV_NAME' into Dokploy project $DOKPLOY_PROJECT_ID"
