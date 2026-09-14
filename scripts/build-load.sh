#!/usr/bin/env bash
# Build the OpenSRE image, load it straight into the kind node, and apply the
# kind overlay. There is no registry: `kind load` is how the node gets the
# image, which is why the Deployment pins imagePullPolicy: IfNotPresent.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CLUSTER=${CLUSTER:-opensre}
SRC=${OPENSRE_SRC:-"$ROOT/../opensre"}
TAG=${1:-$(git -C "$SRC" rev-parse --short HEAD)}

[[ -f .env ]] || { echo "missing .env" >&2; exit 1; }
[[ -d "$SRC" ]] || { echo "no OpenSRE checkout at $SRC" >&2; exit 1; }

echo "==> building opensre:$TAG from $SRC"
docker build -t "opensre:$TAG" -t opensre:poc "$SRC"

echo "==> loading into kind cluster '$CLUSTER'"
kind load docker-image "opensre:poc" --name "$CLUSTER"

echo "==> generating the secret from .env"
bash scripts/render-secret.sh

echo "==> applying k8s/overlays/kind"
kubectl --context "kind-$CLUSTER" apply -k k8s/overlays/kind
kubectl --context "kind-$CLUSTER" apply -f k8s/base/secret-env.yaml

# The image tag never changes (opensre:poc), so an apply alone would not restart
# a running pod onto the new bytes.
echo "==> restarting the deployment onto the new image"
kubectl --context "kind-$CLUSTER" -n opensre rollout restart deploy/opensre-gateway
kubectl --context "kind-$CLUSTER" -n opensre rollout status deploy/opensre-gateway --timeout=180s

echo
echo "OpenAI-compatible surface: http://localhost:8080/v1  (key: \$OPENAI_COMPAT_API_KEY)"
