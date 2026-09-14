#!/usr/bin/env bash
# Build k8s/base/secret-env.yaml from the secrets in .env.
#
# Only the secret-bearing keys are copied: everything non-secret lives in
# configmap-env.yaml, in git. The generated file is gitignored.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[[ -f .env ]] || { echo "missing .env" >&2; exit 1; }
set -a; . ./.env; set +a

OUT=k8s/base/secret-env.yaml

# The gateway reaches Mattermost and Grafana over the shared kind network, so
# the browser-facing localhost URLs in .env are rewritten to in-cluster names.
kubectl create secret generic opensre-secrets \
  --namespace opensre \
  --dry-run=client -o yaml \
  --from-literal=CUSTOM_OPENAI_API_KEY="${CUSTOM_OPENAI_API_KEY:-EMPTY}" \
  --from-literal=GRAFANA_READ_TOKEN="${GRAFANA_READ_TOKEN:-}" \
  --from-literal=MATTERMOST_BOT_TOKEN="${MATTERMOST_BOT_TOKEN:-}" \
  --from-literal=MATTERMOST_DEFAULT_CHANNEL_ID="${MATTERMOST_DEFAULT_CHANNEL_ID:-}" \
  --from-literal=MATTERMOST_ALLOWED_USERS="${MATTERMOST_ALLOWED_USERS:-}" \
  --from-literal=OPENAI_COMPAT_API_KEY="${OPENAI_COMPAT_API_KEY:-}" \
  > "$OUT"

echo "wrote $OUT (gitignored)"
