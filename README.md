# Dokploy Merge Env GitHub Action

Merges a single environment variable into a Dokploy resource's top-level `env` string without dropping existing vars.

> [!WARNING]
> **Security advisory: versions 1.0 and 2.0 printed the resource env into the job log.**
> Every value read from Dokploy appeared in clear text, because GitHub only masks secrets it knows about.
> If you ran 1.0 or 2.0, delete the logs of those workflow runs and rotate every secret that was in the resource's env.
> Upgrade to `2.1` or later.

## What gets logged
The action never prints the resource env, the new value, the API key or the Dokploy URL (which may contain basic auth).
Log and error messages name only the resource type, the resource ID and the API endpoint path.
On success it prints exactly one line:

```
Merged env var '<NAME>' into Dokploy <type> <id>
```

## How the merge works
- The line that starts with `<NAME>=` is replaced where it stands.
- If no line matches, `<NAME>=<value>` is appended, adding a newline first if the env lacks a final one.
- Every other line is left byte-for-byte as it was: whitespace, blank lines, CRLF endings and quoted values included.
- If `<NAME>=` appears on more than one line, the action fails with `duplicate key` and changes nothing.
- Every request uses `--connect-timeout 10 --max-time 30`.

## Inputs
- `dokploy_url` — Base Dokploy URL (include htaccess if needed), e.g. `https://user:pass@host`
- `api_key` — Dokploy API key
- `resource_type` — Dokploy resource type (`project`, `compose`, `application`, `mysql`, `postgres`, `redis`, `mongo`, `mariadb`)
- `resource_id` — Dokploy resource ID for the selected type
- `env_name` — Variable name to upsert
- `env_value` — Variable value to set

## Usage
```yaml
name: Update Dokploy env
jobs:
  merge:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Merge env var
        uses: nkeneng/dokploy-update-env-gha@2.1
        with:
          dokploy_url: https://${{ secrets.HTACCESS }}@${{ secrets.DOKPLOY_URL }}
          api_key: ${{ secrets.DOKPLOY_API_KEY }}
          resource_type: project
          resource_id: ${{ secrets.DOKPLOY_PROJECT_ID }}
          env_name: PYTHON_IMAGE_TAG
          env_value: ${{ steps.version.outputs.VERSION }}
```

## Tests
```bash
bash tests/merge-env_test.sh
```
The tests use a fake `curl` and need only `bash` and `jq`.

## Manual run
```bash
DOKPLOY_URL="https://your-host" \
DOKPLOY_API_KEY="key" \
DOKPLOY_RESOURCE_TYPE="project" \
DOKPLOY_RESOURCE_ID="projectId" \
ENV_NAME="FOO" \
ENV_VALUE="bar" \
bash merge-env.sh
```

## Changelog

### 2.1
- **Security fix:** the action no longer prints the resource env (or the URL) to the log. See the advisory above.
- Lines other than the one being set are preserved exactly; previously every line was trimmed, blank lines were dropped and `\r` was stripped.
- A duplicate key now fails instead of being silently collapsed.
- curl calls have connect and total timeouts.
- Inputs are unchanged from 2.0.
