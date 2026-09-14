#!/usr/bin/env bash
# Bring the POC up from nothing: kind cluster, Compose stack, demo workloads.
# Idempotent — safe to re-run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CLUSTER=opensre
COMPOSE=(docker compose -f compose/docker-compose.yml --env-file .env)

[[ -f .env ]] || { echo "missing .env — copy .env.example and fill it in" >&2; exit 1; }
set -a; . ./.env; set +a

# --- 1. kind cluster -------------------------------------------------------
# The unrelated "homelab" cluster shares the kind network; never touch it.
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "==> kind cluster '$CLUSTER' already exists"
else
  echo "==> creating kind cluster '$CLUSTER'"
  kind create cluster --config kind/kind-config.yaml
fi
kubectl config use-context "kind-$CLUSTER"

# --- 2. secrets that config files read from disk ---------------------------
# Alertmanager does not expand env vars in its config, so the Mattermost
# webhook URL is handed to it as a file (gitignored).
touch compose/alertmanager/mattermost_webhook_url
if [[ -n "${MATTERMOST_WEBHOOK_URL:-}" ]]; then
  # .env holds the browser-facing URL; Alertmanager calls it from its own
  # container, so rewrite the host to the Compose service name.
  printf '%s' "${MATTERMOST_WEBHOOK_URL/http:\/\/localhost:8065/http:\/\/mattermost:8065}" \
    > compose/alertmanager/mattermost_webhook_url
else
  echo "==> MATTERMOST_WEBHOOK_URL empty; run scripts/mattermost-bootstrap.sh then re-run this script"
fi

# --- 3. Compose stack ------------------------------------------------------
echo "==> starting Compose stack (vllm may take several minutes to load the model)"
"${COMPOSE[@]}" up -d "$@"

# --- 4. in-cluster demo workloads -----------------------------------------
echo "==> applying kube-state-metrics"
kubectl apply -f k8s/demo/kube-state-metrics.yaml
kubectl -n kube-state-metrics rollout status deploy/kube-state-metrics --timeout=120s

echo
echo "up. Next:  scripts/smoke.sh"
echo "  Grafana      http://localhost:3000   (admin / \$GRAFANA_ADMIN_PASSWORD)"
echo "  Prometheus   http://localhost:9090"
echo "  Alertmanager http://localhost:9093"
echo "  Mattermost   http://localhost:8065"
echo "  vLLM         http://localhost:8000/v1/models"
