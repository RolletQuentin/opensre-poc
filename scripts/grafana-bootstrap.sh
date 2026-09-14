#!/usr/bin/env bash
# Create a Viewer service account in Grafana, mint a token, and write
# GRAFANA_READ_TOKEN plus the datasource UIDs to .env. Idempotent.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[[ -f .env ]] || { echo "missing .env" >&2; exit 1; }
set -a; . ./.env; set +a

GF=${GRAFANA_URL:-http://localhost:3000}
AUTH=(-u "admin:${GRAFANA_ADMIN_PASSWORD}")
SA_NAME=opensre

put_env() {
  local key=$1 value=$2
  if grep -q "^${key}=" .env; then
    python3 - "$key" "$value" <<'PY'
import pathlib, sys
key, value = sys.argv[1], sys.argv[2]
p = pathlib.Path(".env")
lines = p.read_text().splitlines()
p.write_text("\n".join(f"{key}={value}" if l.startswith(f"{key}=") else l for l in lines) + "\n")
PY
  else
    printf '%s=%s\n' "$key" "$value" >> .env
  fi
}

echo "==> service account '$SA_NAME' (Viewer)"
SA_ID=$(curl -sS "${AUTH[@]}" "$GF/api/serviceaccounts/search?query=$SA_NAME" \
        | jq -r --arg n "$SA_NAME" '.serviceAccounts[]? | select(.name==$n) | .id' | head -1)
if [[ -z "$SA_ID" ]]; then
  SA_ID=$(curl -sS "${AUTH[@]}" -X POST "$GF/api/serviceaccounts" -H 'Content-Type: application/json' \
          -d "$(jq -nc --arg n "$SA_NAME" '{name:$n, role:"Viewer", isDisabled:false}')" | jq -r '.id')
fi
[[ -n "$SA_ID" && "$SA_ID" != "null" ]] || { echo "could not create the service account" >&2; exit 1; }

# Grafana never returns an existing token's secret, so reuse the one in .env
# when it still authenticates and only mint a new one otherwise.
TOKEN=${GRAFANA_READ_TOKEN:-}
if [[ -n "$TOKEN" ]] && curl -sf -H "Authorization: Bearer $TOKEN" "$GF/api/datasources" >/dev/null 2>&1; then
  echo "==> reusing the token already in .env"
else
  echo "==> minting a token"
  STAMP=$(date +%s)
  TOKEN=$(curl -sS "${AUTH[@]}" -X POST "$GF/api/serviceaccounts/$SA_ID/tokens" \
          -H 'Content-Type: application/json' -d "{\"name\":\"opensre-poc-$STAMP\"}" | jq -r '.key // empty')
fi
[[ -n "$TOKEN" ]] || { echo "could not mint a Grafana token" >&2; exit 1; }

echo "==> datasource UIDs"
DS=$(curl -sS -H "Authorization: Bearer $TOKEN" "$GF/api/datasources")
LOKI_UID=$(echo "$DS" | jq -r '.[] | select(.type=="loki") | .uid' | head -1)
PROM_UID=$(echo "$DS" | jq -r '.[] | select(.type=="prometheus") | .uid' | head -1)

put_env GRAFANA_READ_TOKEN "$TOKEN"
put_env GRAFANA_LOKI_DATASOURCE_UID "${LOKI_UID:-}"
put_env GRAFANA_PROMETHEUS_DATASOURCE_UID "${PROM_UID:-}"

echo
echo "==> done"
echo "    service account id  $SA_ID (Viewer)"
echo "    prometheus uid      ${PROM_UID:-<none>}"
echo "    loki uid            ${LOKI_UID:-<none, start the 'logs' profile>}"
