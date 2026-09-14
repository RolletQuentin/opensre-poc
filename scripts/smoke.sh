#!/usr/bin/env bash
# Check every moving part of the POC and report pass/fail per item.
# Does not exit on first failure — the point is the full picture.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[[ -f .env ]] && { set -a; . ./.env; set +a; }

FAILED=0
check() {  # check <label> <command...>
  local label="$1"; shift
  if out=$("$@" 2>&1); then
    printf '  \033[32mok\033[0m    %s\n' "$label"
  else
    printf '  \033[31mFAIL\033[0m  %s\n' "$label"
    printf '        %s\n' "${out:0:300}"
    FAILED=$((FAILED + 1))
  fi
}

echo "== host -> Compose services =="
check "vLLM /v1/models"       curl -fsS --max-time 5 http://localhost:8000/v1/models
check "Prometheus ready"      curl -fsS --max-time 5 http://localhost:9090/-/ready
check "Alertmanager healthy"  curl -fsS --max-time 5 http://localhost:9093/-/healthy
check "Grafana health"        curl -fsS --max-time 5 http://localhost:3000/api/health
check "Mattermost ping"       curl -fsS --max-time 5 http://localhost:8065/api/v4/system/ping

echo
echo "== kind cluster =="
check "cluster reachable"     kubectl --context kind-opensre get --raw /readyz
check "kube-state-metrics up" kubectl --context kind-opensre -n kube-state-metrics \
                                  rollout status deploy/kube-state-metrics --timeout=10s

echo
echo "== Compose -> cluster (shared 'kind' network) =="
check "prometheus scrapes ksm" docker compose -f compose/docker-compose.yml exec -T prometheus \
    wget -q -O- --timeout=5 http://opensre-control-plane:30081/metrics

echo
echo "== Prometheus sees the cluster =="
if kube_up=$(curl -fsS -G --max-time 5 http://localhost:9090/api/v1/query \
      --data-urlencode 'query=up{job="kube-state-metrics"}==1' 2>&1); then
  if echo "$kube_up" | grep -q '"value"'; then
    printf '  \033[32mok\033[0m    kube-state-metrics target is up\n'
  else
    printf '  \033[31mFAIL\033[0m  kube-state-metrics target has no samples yet\n'
    FAILED=$((FAILED + 1))
  fi
else
  printf '  \033[31mFAIL\033[0m  Prometheus query failed\n'; FAILED=$((FAILED + 1))
fi

echo
echo "== OpenSRE gateway in the cluster =="
check "deployment available" kubectl --context kind-opensre -n opensre \
    rollout status deploy/opensre-gateway --timeout=10s
if [[ -n "${OPENAI_COMPAT_API_KEY:-}" ]]; then
  check "/v1/models via NodePort" curl -fsS --max-time 5 \
      -H "Authorization: Bearer ${OPENAI_COMPAT_API_KEY}" http://localhost:8080/v1/models
fi
# An unkeyed caller must never reach a turn.
if code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:8080/v1/models 2>&1); then
  if [[ "$code" == "401" ]]; then
    printf '  \033[32mok\033[0m    /v1 refuses an unkeyed caller\n'
  else
    printf '  \033[31mFAIL\033[0m  /v1 answered %s to an unkeyed caller\n' "$code"
    FAILED=$((FAILED + 1))
  fi
fi

echo
if [[ $FAILED -eq 0 ]]; then
  printf '\033[32mall checks passed\033[0m\n'
else
  printf '\033[31m%d check(s) failed\033[0m\n' "$FAILED"
fi
exit $FAILED
