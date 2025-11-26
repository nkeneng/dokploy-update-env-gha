# Dokploy Merge Env GitHub Action

Merges a single environment variable into a Dokploy project's top-level `env` string without dropping existing vars.

## Inputs
- `dokploy_url` — Base Dokploy URL (include htaccess if needed), e.g. `https://user:pass@host`
- `api_key` — Dokploy API key
- `project_id` — Dokploy project ID
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
        uses: your-org/dokploy-merge-env-action@v1
        with:
          dokploy_url: https://${{ secrets.HTACCESS }}@${{ secrets.DOKPLOY_URL }}
          api_key: ${{ secrets.DOKPLOY_API_KEY }}
          project_id: ${{ secrets.DOKPLOY_PROJECT_ID }}
          env_name: PYTHON_IMAGE_TAG
          env_value: ${{ steps.version.outputs.VERSION }}
```

## Local test
```bash
DOKPLOY_URL="https://your-host" \
DOKPLOY_API_KEY="key" \
DOKPLOY_PROJECT_ID="projectId" \
ENV_NAME="FOO" \
ENV_VALUE="bar" \
bash -x merge-env.sh
```
